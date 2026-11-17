#import "SystemMic.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

static NSString *defaultInputName(void) {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioDeviceID device = 0;
    UInt32 size = sizeof device;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) || !device) return nil;
    address.mSelector = kAudioObjectPropertyName;
    CFStringRef name = NULL;
    size = sizeof name;
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name) || !name) return nil;
    return CFBridgingRelease(name);
}

@implementation SystemMic {
    AVAudioEngine *_engine;
    AVAudioConverter *_converter;
    AVAudioFormat *_target;
    NSMutableData *_pcm;
    NSLock *_lock;
@public
    unsigned _taps, _inFrames, _outFrames;
    double _inRate;
}

+ (void)requestAccess:(void (^)(BOOL))reply {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (status == AVAuthorizationStatusAuthorized) { reply(YES); return; }
    if (status != AVAuthorizationStatusNotDetermined) { reply(NO); return; }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ reply(granted); });
    }];
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _target = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16 sampleRate:16000 channels:1 interleaved:YES];
    }
    return self;
}

- (BOOL)start:(NSString **)error {
    if (_recording) return YES;
    _paused = NO; _level = 0;
    // A fresh engine each take follows changes to the default input device.
    _engine = [AVAudioEngine new];
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (format.sampleRate <= 0 || format.channelCount == 0) {
        if (error) *error = @"No microphone input. Pick one in System Settings → Sound → Input.";
        _engine = nil;
        return NO;
    }
    _deviceName = defaultInputName() ?: @"default input";
    _converter = [[AVAudioConverter alloc] initFromFormat:format toFormat:_target];
    _pcm = [NSMutableData data];
    AVAudioConverter *converter = _converter;
    AVAudioFormat *target = _target;
    NSMutableData *pcm = _pcm;
    NSLock *lock = _lock;
    _taps = _inFrames = _outFrames = 0; _inRate = format.sampleRate;
    __unsafe_unretained SystemMic *me = self;
    [input installTapOnBus:0 bufferSize:4096 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        AVAudioFrameCount capacity = (AVAudioFrameCount)(buffer.frameLength * target.sampleRate / format.sampleRate) + 32;
        AVAudioPCMBuffer *out = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:capacity];
        __block BOOL fed = NO;
        NSError *convertError = nil;
        [converter convertToBuffer:out error:&convertError withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count, AVAudioConverterInputStatus *status) {
            (void)count;
            if (fed) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
            fed = YES; *status = AVAudioConverterInputStatus_HaveData; return buffer;
        }];
        me->_taps++; me->_inFrames += buffer.frameLength; me->_outFrames += out.frameLength;
        if (out.frameLength) {
            // Loudness for the meter: RMS in dBFS mapped from -55..-10 dB onto 0..1.
            const int16_t *samples = out.int16ChannelData[0];
            double sum = 0;
            for (AVAudioFrameCount i = 0; i < out.frameLength; i++) sum += (double)samples[i] * samples[i];
            double db = 10 * log10(sum / out.frameLength / (32768.0 * 32768.0) + 1e-12);
            me->_level = (float)fmax(0, fmin(1, (db + 55) / 45));
        }
        if (out.frameLength && !me->_paused) {
            [lock lock];
            [pcm appendBytes:out.int16ChannelData[0] length:out.frameLength * sizeof(int16_t)];
            [lock unlock];
        }
    }];
    NSError *startError = nil;
    if (![_engine startAndReturnError:&startError]) {
        [input removeTapOnBus:0];
        _engine = nil;
        if (error) *error = startError.localizedDescription ?: @"Could not start the microphone.";
        return NO;
    }
    _recording = YES;
    return YES;
}

- (void)halt {
    if (!_engine) return;
    [_engine.inputNode removeTapOnBus:0];
    [_engine stop];
    _engine = nil;
    _recording = NO;
}

- (NSData *)stop {
    [self halt];
    if (getenv("HERDR_PAD_DEBUG")) printf("LOG sysmic taps=%u in=%u out=%u rate=%.0f\n", _taps, _inFrames, _outFrames, _inRate);
    [_lock lock];
    NSData *pcm = [_pcm copy];
    _pcm = nil;
    [_lock unlock];
    if (!pcm.length) return nil;
    uint32_t length = (uint32_t)pcm.length, riff = length + 36;
    uint8_t header[44] = "RIFF\0\0\0\0WAVEfmt \x10\0\0\0\1\0\1\0\x80\x3e\0\0\0\x7d\0\0\2\0\x10\0data";
    memcpy(header + 4, &riff, 4);
    memcpy(header + 40, &length, 4);
    NSMutableData *wav = [NSMutableData dataWithBytes:header length:sizeof header];
    [wav appendData:pcm];
    return wav;
}

- (void)cancel { [self halt]; [_lock lock]; _pcm = nil; [_lock unlock]; }
@end
