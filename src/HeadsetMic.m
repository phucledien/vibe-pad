#import "HeadsetMic.h"
#import "VoiceLevel.h"

// Leave the mic on briefly for the last syllable, then drain the Bluetooth queue.
static const NSTimeInterval releaseTail = 0.50;
static const NSTimeInterval drainQuiet = 0.12;
static const NSTimeInterval drainLimit = 0.50;
static const NSTimeInterval micKeepalive = 1.0;
static const NSTimeInterval stalledStream = 0.15;

@implementation HeadsetTake
@end

@implementation HeadsetMic {
    DS4Output _out;
    BOOL _waitingForFrames;
    double _started, _lastWrite, _lastFrame, _firstFrame, _released, _micStopped;
    unsigned _rearms;
    NSUInteger _samplesAtRelease;
    unsigned _rumbleGeneration;
}

- (instancetype)init {
    if ((self = [super init])) {
        _armed = YES;
        _talkButton = ds4Button(@"l1");
        _limit = 60;
        _handsFreeLimit = 300;
        _out.blue = 0x30;
        [self resetCapture];
    }
    return self;
}

static double now(void) { return NSProcessInfo.processInfo.systemUptime; }

- (BOOL)active { return _started != 0; }

- (void)resetCapture {
    _capture = [Capture new];
    _capture.releaseTailEnabled = YES;
    _capture.talkButton = _armed ? _talkButton : 0;
    _capture.waitForNeutral = _talkButton;
    _started = _lastFrame = _firstFrame = _released = _micStopped = 0;
    _rearms = 0;
    _samplesAtRelease = 0;
    _waitingForFrames = NO;
    _handsFree = NO;
}

// Re-arm in place: replacing the Capture would drop its button state mid-press.
- (void)setArmed:(BOOL)armed {
    _armed = armed;
    if (_started) return;
    _capture.talkButton = armed ? _talkButton : 0;
    _capture.waitForNeutral = _talkButton;
}

- (void)setTalkButton:(uint32_t)talkButton {
    _talkButton = talkButton;
    if (_started) return;
    _capture.talkButton = _armed ? talkButton : 0;
    _capture.waitForNeutral = talkButton;
}

- (BOOL)write {
    if (!_device) return NO;
    NSData *report = ds4OutputReport(_out);
    IOReturn status = IOHIDDeviceSetReport(_device, kIOHIDReportTypeOutput, 0x11, report.bytes, report.length);
    _lastWrite = now();
    return status == kIOReturnSuccess;
}

- (BOOL)setMic:(BOOL)enable { _out.mic = enable; return [self write]; }

- (void)setDevice:(IOHIDDeviceRef)device {
    _device = device;
    // Restore the lightbar the app chose while no pad was connected.
    if (device) { _out.mic = NO; _out.rumbleWeak = _out.rumbleStrong = 0; [self write]; }
}

- (void)setLightRed:(uint8_t)r green:(uint8_t)g blue:(uint8_t)b flash:(BOOL)flash {
    uint8_t on = flash ? 30 : 0, off = flash ? 30 : 0;
    if (_out.red == r && _out.green == g && _out.blue == b && _out.flashOn == on) return;
    _out.red = r; _out.green = g; _out.blue = b; _out.flashOn = on; _out.flashOff = off;
    [self write];
}

- (void)rumble:(uint8_t)strength weak:(uint8_t)weak seconds:(NSTimeInterval)seconds {
    _out.rumbleStrong = strength; _out.rumbleWeak = weak;
    [self write];
    unsigned generation = ++_rumbleGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self->_rumbleGeneration) return;
        self->_out.rumbleStrong = self->_out.rumbleWeak = 0;
        [self write];
    });
}

- (void)phase:(NSString *)phase text:(NSString *)text { [_delegate headsetPhase:phase text:text]; }

- (void)startHandsFree {
    if (!_armed || _started || !_device) return;
    _capture.waitForNeutral = 0;
    _capture.latched = YES;
    _handsFree = YES;
    // The next input report starts the take; open the mic now to save a round trip.
    _started = now();
    [self phase:@"opening" text:@"Opening headset mic…"];
    if (![self setMic:YES]) [self finish:@"Could not open the headset mic. Reconnect the controller."];
}

- (void)stopHandsFree {
    if (!_handsFree || !_started) return;
    _capture.latched = NO;
    if (!_released) {
        _released = now();
        _samplesAtRelease = _capture.sampleCount;
        [self phase:@"finishing" text:@"Finishing recording…"];
    }
}

- (void)cancel {
    if (!_started) return;
    if (!_micStopped) [self setMic:NO];
    [self resetCapture];
    [self phase:@"idle" text:@"Recording cancelled"];
}

- (void)deviceLost {
    BOOL wasActive = _started != 0;
    if (wasActive) [self finish:@"Controller disconnected during recording. Reconnect it and try again."];
    _device = NULL;
    [self resetCapture];
}

- (void)receive:(uint32_t)reportID bytes:(uint8_t *)bytes size:(CFIndex)size {
    if (!_device) return;
    unsigned frames = _capture.frames;
    receiveDS4Report(_capture, reportID, bytes, size);
    double t = now();
    if (_capture.held && !_started) {
        _started = t;
        [self phase:@"opening" text:@"Opening headset mic…"];
        if (![self setMic:YES]) { [self finish:@"Could not open the headset mic. Reconnect the controller."]; return; }
    }
    if (!_started) return;
    if (_capture.frames > frames) {
        _lastFrame = t;
        if (!_firstFrame || _waitingForFrames) {
            if (!_firstFrame) _firstFrame = t;
            _waitingForFrames = NO;
            if (!_released) [self phase:@"recording" text:@"● Recording"];
        }
    }
    if (_capture.finished && !_released) {
        _released = t;
        _samplesAtRelease = _capture.sampleCount;
        [self phase:@"finishing" text:@"Finishing recording…"];
    } else if (_capture.held && _released && !_micStopped) {
        // A brief button bounce or immediate re-press continues the same take.
        _released = 0;
        if (_waitingForFrames) [self phase:@"stalled" text:@"Headset audio interrupted"];
        else [self phase:_firstFrame ? @"recording" : @"opening"
                    text:_firstFrame ? @"● Recording" : @"Opening headset mic…"];
    }
}

- (void)service {
    if (!_started || !_device) return;
    double t = now();
    if (_micStopped) {
        // After disarming, only inbound frames can extend the short queue drain.
        if (t - MAX(_lastFrame, _micStopped) >= drainQuiet || t - _micStopped >= drainLimit) [self finish:nil];
        return;
    }
    NSTimeInterval limit = _handsFree ? _handsFreeLimit : _limit;
    if (t - _started >= limit || (_released && t - _released >= releaseTail)) {
        if (!_released) {
            _capture.latched = NO;
            _released = t;
            _samplesAtRelease = _capture.sampleCount;
            [self phase:@"finishing" text:@"Finishing recording…"];
        }
        _micStopped = t;
        if (![self setMic:NO]) [self finish:@"Could not stop the headset mic. Reconnect the controller."];
        return;
    }
    double sinceWrite = t - _lastWrite;
    BOOL stalled = _lastFrame && t - _lastFrame >= stalledStream;
    if (!_released && stalled && !_waitingForFrames && t - _lastFrame >= 0.4) {
        _waitingForFrames = YES;
        [self phase:@"stalled" text:@"Headset audio interrupted"];
    }
    double retryInterval = _waitingForFrames ? micKeepalive : 0.25;
    BOOL startupRetry = !_firstFrame && sinceWrite >= 0.5;
    if ((stalled && sinceWrite >= retryInterval) || startupRetry || sinceWrite >= micKeepalive) {
        if (![self setMic:YES]) { [self finish:@"Headset connection lost. Try another take."]; return; }
        if (stalled || startupRetry) {
            _rearms++;
            [_capture restartSequence];
        }
    }
}

- (void)finish:(NSString *)failure {
    double t = now();
    double held = (_released ?: t) - _started;
    NSUInteger beforeRelease = _released ? _samplesAtRelease : _capture.sampleCount;
    if (!_micStopped && _device) [self setMic:NO];
    _out.mic = NO;
    Capture *capture = _capture;
    HeadsetTake *take = [HeadsetTake new];
    take.handsFree = _handsFree;
    take.original = capture.wave;
    VoiceLevel *level = [[VoiceLevel alloc] initWithCaptureWave:take.original];
    take.wave = level.wave;
    if (!take.original && !failure) {
        if (capture.audioReports)
            failure = @"The controller sent microphone packets, but none could be decoded.";
        else if (capture.haveJackStatus && !capture.jackFlags)
            failure = @"The controller reports an empty headset jack. Plug a headset with a mic into the controller.";
        else
            failure = @"No mic packets arrived from the controller. Check the inline mute switch and reconnect the controller with the headset plugged in.";
    }
    if (!failure && capture.peak <= 0) failure = @"The recording is silent. Check your headset mic and mute switch.";
    take.failure = failure;
    take.info = @{@"held":@(held), @"seconds":@(capture.sampleCount / 16000.0),
                  @"beforeRelease":@(beforeRelease / 16000.0),
                  @"tail":@((capture.sampleCount - beforeRelease) / 16000.0),
                  @"startup":@(_firstFrame ? _firstFrame - _started : 0),
                  @"gaps":@(capture.gaps), @"rearms":@(_rearms), @"micPackets":@(capture.audioReports),
                  @"level":@(level.levelDB), @"gain":@(level.gainDB)};
    [self resetCapture];
    [_delegate headsetFinished:take];
}
@end
