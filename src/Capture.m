#import "Capture.h"
#include <sbc/sbc.h>
#include <zlib.h>

uint32_t reportCRC(uint8_t prefix, const uint8_t *bytes, size_t count) {
    return (uint32_t)crc32(crc32(0, &prefix, 1), bytes, (uInt)count);
}

size_t inputLength(uint8_t reportID) {
    if (reportID == 0x19) return 547;
    if (reportID >= 0x11 && reportID <= 0x18) return 78 + 64 * (reportID - 0x11);
    return 0;
}

NSData *ds4OutputReport(DS4Output o) {
    // Mic-on keeps the flags of the proven micCommand; mic-off also updates the flash timing.
    uint8_t bytes[78] = {0x11, 0xc0, o.mic ? 0xa1 : 0xa0, o.mic ? 0xf3 : 0xf7};
    bytes[6] = o.rumbleWeak; bytes[7] = o.rumbleStrong;
    bytes[8] = o.red; bytes[9] = o.green; bytes[10] = o.blue;
    bytes[11] = o.flashOn; bytes[12] = o.flashOff;
    bytes[23] = o.mic ? 0x40 : 0;
    uint32_t crc = CFSwapInt32HostToLittle(reportCRC(0xa2, bytes, sizeof(bytes) - 4));
    memcpy(bytes + sizeof(bytes) - 4, &crc, 4);
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

NSData *micCommand(BOOL enable) {
    uint8_t bytes[78] = {0x11, 0xc0, enable ? 0xa1 : 0, enable ? 0xf3 : 0xf0};
    bytes[10] = 0x30; // Blue light during microphone mode.
    bytes[23] = enable ? 0x40 : 0;
    uint32_t crc = CFSwapInt32HostToLittle(reportCRC(0xa2, bytes, sizeof(bytes) - 4));
    memcpy(bytes + sizeof(bytes) - 4, &crc, 4);
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static BOOL micTarget(uint8_t target) { return target == 1 || target == 3; }

// Bit order follows the three DS4 button bytes in both Bluetooth state layouts.
uint32_t ds4Button(NSString *name) {
    NSArray *names = @[@"square", @"cross", @"circle", @"triangle", @"l1", @"r1",
                       @"l2", @"r2", @"share", @"options", @"l3", @"r3", @"ps", @"touchpad"];
    NSUInteger index = [names indexOfObject:name.lowercaseString];
    return index == NSNotFound ? 0 : (1u << (4 + index));
}

@implementation Capture {
    NSMutableData *_pcm;
    sbc_t _sbc, _msbc;
    BOOL _sbcReady, _msbcReady, _haveSequence;
    uint16_t _nextSequence;
}

- (instancetype)init {
    if ((self = [super init])) {
        _pcm = [NSMutableData data];
        _hat = 8;
        _lx = _ly = _rx = _ry = 128;
        _talkButton = ds4Button(@"l1");
        _sbcReady = sbc_init(&_sbc, 0) == 0;
        _msbcReady = sbc_init_msbc(&_msbc, 0) == 0;
        if (!_sbcReady || !_msbcReady) return nil;
        _sbc.endian = _msbc.endian = SBC_LE;
    }
    return self;
}

- (void)dealloc {
    if (_sbcReady) sbc_finish(&_sbc);
    if (_msbcReady) sbc_finish(&_msbc);
}

- (void)readButtons:(const uint8_t *)bytes axes:(const uint8_t *)axes {
    _hat = bytes[0] & 15;
    _lx = axes[0]; _ly = axes[1]; _rx = axes[2]; _ry = axes[3];
    uint32_t down = (bytes[0] & 0xf0) | (bytes[1] << 8) | ((bytes[2] & 3) << 16);
    _rawButtons = down;
    _haveButtons = YES;
    if (_waitForNeutral) {
        if ((down & _waitForNeutral) == 0) _waitForNeutral = 0;
        return;
    }
    _buttons = down;
    BOOL talking = (down & _talkButton) != 0 || _latched;
    if (_held && !talking) _finished = YES;
    else if (talking && _releaseTailEnabled) _finished = NO;
    _held = talking;
}

- (void)receive:(const uint8_t *)r length:(size_t)n {
    if ((!_releaseTailEnabled && _finished) || !n) return;
    _reports++;
    if (r[0] == 1 && n >= 7) {
        uint8_t buttons[] = {r[5], r[6], n >= 8 ? r[7] : 0};
        [self readButtons:buttons axes:r + 1];
        return;
    }
    size_t length = inputLength(r[0]);
    if (!length || n < length) return;
    size_t end = length - 4;
    uint32_t crc;
    memcpy(&crc, r + end, 4);
    if (CFSwapInt32LittleToHost(crc) != reportCRC(0xa1, r, end)) {
        _badCRC++;
        return;
    }

    BOOL wasHeld = _held;
    BOOL state = (r[1] & 0x80) != 0;
    BOOL audio = (r[2] & 0x80) != 0;
    // Some revisions place audio directly after the header even with the state flag set.
    size_t offset = state && end >= 81 && micTarget(r[80]) ? 78 : 3;
    if (audio && !micTarget(r[offset + 2]) && end >= 81 && micTarget(r[80])) offset = 78;
    if (state && !(audio && offset == 3 && micTarget(r[5]))) {
        _haveJackStatus = YES;
        _jackFlags = r[32] & 0x60;
        [self readButtons:r + 7 axes:r + 3];
    }
    BOOL acceptingAudio = _held || (_finished && (wasHeld || _releaseTailEnabled));
    if (!acceptingAudio || !audio || !micTarget(r[offset + 2])) return;
    _audioReports++;
    uint16_t sequence = r[offset] | ((uint16_t)r[offset + 1] << 8);
    for (size_t i = offset + 3; i + 4 <= end;) {
        // Accept the headset's 16 kHz mono SBC and wideband-speech mSBC frames.
        BOOL msbc = r[i] == 0xad && !r[i + 1] && !r[i + 2];
        BOOL sbc = r[i] == 0x9c && (r[i + 1] & 0xcc) == 0;
        if (!msbc && !sbc) { i++; continue; }
        int16_t samples[128];
        size_t written = 0;
        uint16_t gap = sequence - _nextSequence;
        if (_haveSequence && gap >= 0x8000) {
            // A partially repeated batch can still contain new frames at its end.
            unsigned subbands = (r[i + 1] & 1) ? 8 : 4;
            unsigned blocks = 4 * (1 + ((r[i + 1] >> 4) & 3));
            size_t frameLength = msbc ? 57 : 4 + subbands / 2 + (blocks * r[i + 2] + 7) / 8;
            if (frameLength > end - i) break;
            i += frameLength;
            sequence++;
            continue;
        }
        ssize_t used = sbc_decode(msbc ? &_msbc : &_sbc, r + i, end - i,
                                  samples, sizeof(samples), &written);
        if (used <= 0 || !written) { i++; continue; }
        if (_haveSequence) _gaps += gap;
        _haveSequence = YES;
        _nextSequence = ++sequence;
        [_pcm appendBytes:samples length:written];
        for (size_t j = 0; j < written / 2; j++) {
            int amplitude = abs(samples[j]);
            if (amplitude > _peak) _peak = amplitude;
        }
        _frames++;
        i += (size_t)used;
    }
}

- (void)restartSequence { _haveSequence = NO; }

- (NSUInteger)sampleCount { return _pcm.length / 2; }

- (NSData *)wave {
    if (!_pcm.length) return nil;
    uint32_t length = (uint32_t)_pcm.length;
    uint32_t riffLength = length + 36;
    // All supported Macs are little-endian. PCM is mono, signed 16-bit at 16 kHz.
    uint8_t header[44] = "RIFF\0\0\0\0WAVEfmt \x10\0\0\0\1\0\1\0\x80\x3e\0\0\0\x7d\0\0\2\0\x10\0data";
    memcpy(header + 4, &riffLength, 4);
    memcpy(header + 40, &length, 4);
    NSMutableData *wav = [NSMutableData dataWithBytes:header length:sizeof(header)];
    [wav appendData:_pcm];
    return wav;
}
@end
