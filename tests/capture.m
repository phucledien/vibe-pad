#import "Capture.h"
#import "VoiceLevel.h"
#include <assert.h>
#include <math.h>
#include <sbc/sbc.h>

static void seal(uint8_t *r) {
    size_t end = inputLength(r[0]) - 4;
    uint32_t crc = CFSwapInt32HostToLittle(reportCRC(0xa1, r, end));
    memcpy(r + end, &crc, 4);
}

static void take(BOOL wideband, NSString *output) {
    Capture *capture = [[Capture alloc] init];
    sbc_t encoder;
    assert((wideband ? sbc_init_msbc(&encoder, 0) : sbc_init(&encoder, 0)) == 0);
    encoder.frequency = SBC_FREQ_16000;
    encoder.mode = SBC_MODE_MONO;
    encoder.endian = SBC_LE;
    size_t samplesPerFrame = sbc_get_codesize(&encoder) / 2;
    assert(samplesPerFrame <= 128);
    uint8_t packet[270] = {0};
    uint8_t simple[] = {1, 128, 128, 128, 128, 8, 0};
    [capture receive:simple length:sizeof(simple)];
    for (unsigned frame = 0; frame < 670; frame++) {
        // Cross the 16-bit sequence wrap. Exercise audio-only and combined reports.
        BOOL combined = (frame % 2) == 0;
        memset(packet, 0, sizeof(packet));
        packet[0] = 0x14;
        packet[1] = combined ? 0x80 : 0;
        packet[2] = 0x80;
        size_t offset = combined ? 78 : 3;
        if (combined) packet[8] = 1;
        uint16_t seq = (uint16_t)(65530 + frame);
        packet[offset] = seq;
        packet[offset + 1] = seq >> 8;
        packet[offset + 2] = wideband ? 1 : 3;
        int16_t tone[128];
        for (size_t i = 0; i < samplesPerFrame; i++) {
            tone[i] = 8000 * sin((frame * samplesPerFrame + i) * 2 * M_PI * 440 / 16000);
        }
        ssize_t encoded;
        assert(sbc_encode(&encoder, tone, samplesPerFrame * 2, packet + offset + 3,
                          sizeof(packet) - offset - 7, &encoded) > 0);
        seal(packet);
        if (!frame) {
            // Even valid microphone packets may arrive before L1 is pressed.
            packet[8] = 0;
            seal(packet);
            [capture receive:packet length:sizeof(packet)];
            assert(!capture.frames && !capture.held);
            simple[6] = 1;
            [capture receive:simple length:sizeof(simple)];
            assert(capture.held);
            packet[8] = 1;
            seal(packet);
        }
        [capture receive:packet length:12]; // Truncated packet.
        packet[269] ^= 1;
        [capture receive:packet length:sizeof(packet)]; // Corrupted packet.
        packet[269] ^= 1;
        [capture receive:packet length:sizeof(packet)];
        [capture receive:packet length:sizeof(packet)]; // Duplicate.
    }
    uint8_t release[78] = {0x11, 0x80};
    seal(release);
    [capture receive:release length:sizeof(release)];
    [capture receive:packet length:sizeof(packet)];
    assert(capture.finished && !capture.held);
    assert(capture.frames == 670 && capture.badCRC == 670 && !capture.gaps);
    assert(capture.peak > 5000 && capture.peak < 12000);
    assert(capture.sampleCount == 670 * samplesPerFrame);
    NSData *wave = capture.wave;
    assert(wave.length == 44 + capture.sampleCount * 2);
    if (output) assert([wave writeToFile:output atomically:YES]);
    printf("%s decode: %.3f seconds, peak %d\n", wideband ? "mSBC" : "SBC",
           capture.sampleCount / 16000.0, capture.peak);
    sbc_finish(&encoder);
}

static void overlappingReports(void) {
    sbc_t encoder;
    assert(sbc_init_msbc(&encoder, 0) == 0);
    int16_t samples[120] = {0};
    uint8_t packet[270] = {0x14, 0, 0x80, 100, 0, 1};
    ssize_t written;
    assert(sbc_encode(&encoder, samples, sizeof(samples), packet+6, 57, &written) > 0 && written == 57);
    memcpy(packet+63, packet+6, 57);
    Capture *capture = [Capture new];
    uint8_t held[] = {1, 128, 128, 128, 128, 8, 1};
    [capture receive:held length:sizeof(held)];
    seal(packet);
    [capture receive:packet length:sizeof(packet)];
    assert(capture.frames == 2);
    packet[3] = 101; // The last frame of the previous packet and one new frame.
    seal(packet);
    [capture receive:packet length:sizeof(packet)];
    assert(capture.frames == 3 && capture.gaps == 0);
    [capture restartSequence];
    packet[3] = 0;
    seal(packet);
    [capture receive:packet length:sizeof(packet)];
    assert(capture.frames == 5 && capture.gaps == 0);

    memmove(packet+81, packet+6, 114);
    packet[1] = 0x80;
    memset(packet+3, 0, 78);
    packet[78] = 2;
    packet[80] = 1;
    seal(packet);
    [capture receive:packet length:sizeof(packet)];
    assert(capture.finished && capture.frames == 7);
    sbc_finish(&encoder);
}

static void queuedSpeechAfterRelease(void) {
    sbc_t encoder;
    assert(sbc_init_msbc(&encoder, 0) == 0);
    int16_t samples[120];
    for (unsigned i = 0; i < 120; i++) samples[i] = 8000 * sin(i * 2 * M_PI / 16);
    uint8_t packet[142] = {0x12, 0, 0x80, 0, 0, 1};
    ssize_t written;
    assert(sbc_encode(&encoder, samples, sizeof(samples), packet+6, 57, &written) > 0);
    seal(packet);
    Capture *capture = [Capture new];
    capture.releaseTailEnabled = YES;
    [capture receive:packet length:sizeof(packet)];
    assert(!capture.frames); // Idle mic reports never start a take.
    uint8_t button[] = {1, 128, 128, 128, 128, 8, 1};
    [capture receive:button length:sizeof(button)];
    [capture receive:packet length:sizeof(packet)];
    button[6] = 0;
    [capture receive:button length:sizeof(button)];
    assert(capture.finished && !capture.held && capture.frames == 1);
    for (unsigned frame = 1; frame <= 40; frame++) {
        packet[3] = frame;
        seal(packet);
        [capture receive:packet length:sizeof(packet)];
        [capture receive:packet length:sizeof(packet)]; // Retransmission at release.
    }
    assert(capture.finished && capture.frames == 41 && capture.gaps == 0);
    assert(capture.sampleCount == 41*120 && capture.wave.length == 44+41*240);
    button[6] = 1;
    [capture receive:button length:sizeof(button)];
    assert(capture.held && !capture.finished && capture.frames == 41);
    sbc_finish(&encoder);
}

static void checkVoiceLevel(void) {
    const NSUInteger count = 16000;
    NSMutableData *wav = [NSMutableData dataWithLength:44 + count * 2];
    int16_t *samples = (int16_t *)((uint8_t *)wav.mutableBytes + 44);
    VoiceLevel *silent = [[VoiceLevel alloc] initWithCaptureWave:wav];
    assert(!silent.gainDB && silent.wave == wav);
    samples[0] = INT16_MIN;
    for (NSUInteger i = 1; i < count; i++) samples[i] = i % 2 ? 250 : -250;
    VoiceLevel *quiet = [[VoiceLevel alloc] initWithCaptureWave:wav];
    const int16_t *boosted = (const int16_t *)((const uint8_t *)quiet.wave.bytes + 44);
    assert(quiet.wave.length == wav.length && quiet.gainDB == 16 && quiet.levelDB < -40);
    assert(boosted[0] >= -32767 && boosted[1] > 1500 && samples[1] == 250);
    for (NSUInteger i = 0; i < count; i++) samples[i] = i % 2 ? 5500 : -5500;
    VoiceLevel *loud = [[VoiceLevel alloc] initWithCaptureWave:wav];
    assert(!loud.gainDB && loud.wave == wav);
}

static void remappedControls(void) {
    Capture *capture = [Capture new];
    capture.talkButton = ds4Button(@"R2");
    capture.waitForNeutral = capture.talkButton | ds4Button(@"cross") | ds4Button(@"touchpad");
    uint8_t basic[] = {1, 128, 128, 128, 128, 8, 8, 0};
    [capture receive:basic length:sizeof(basic)];
    assert(!capture.held); // Button held when the listener opened.
    basic[6] = 0;
    [capture receive:basic length:sizeof(basic)];
    basic[5] |= 0x20;
    basic[1] = 1;
    basic[2] = 57;
    basic[3] = 181;
    basic[4] = 250;
    basic[5] = (basic[5] & 0xf0) | 1; // D-pad up + right.
    basic[7] = 2;
    [capture receive:basic length:sizeof(basic)];
    assert(capture.hat == 1 && capture.lx == 1 && capture.ly == 57 && capture.rx == 181 && capture.ry == 250);
    assert(capture.buttons == (ds4Button(@"cross") | ds4Button(@"touchpad")));
    uint8_t extended[78] = {0x11, 0x80};
    extended[3] = 26;
    extended[6] = 190;
    extended[7] = 4;
    extended[8] = 8;
    seal(extended);
    [capture receive:extended length:sizeof(extended)];
    assert(capture.held);
    assert(capture.hat == 4 && capture.lx == 26 && capture.ry == 190);
    extended[8] = 0;
    seal(extended);
    [capture receive:extended length:sizeof(extended)];
    assert(capture.finished && !capture.held);
}

static void handsFree(void) {
    Capture *capture = [Capture new];
    capture.releaseTailEnabled = YES;
    uint8_t idle[] = {1, 128, 128, 128, 128, 8, 0, 0};
    [capture receive:idle length:sizeof(idle)];
    assert(!capture.held);
    capture.latched = YES; // No button is down.
    [capture receive:idle length:sizeof(idle)];
    assert(capture.held && !capture.finished);
    idle[5] = 8 | 0x20; // Pressing other buttons keeps the latched take open.
    [capture receive:idle length:sizeof(idle)];
    assert(capture.held && capture.buttons == ds4Button(@"cross"));
    capture.latched = NO;
    [capture receive:idle length:sizeof(idle)];
    assert(capture.finished && !capture.held);
}

static void rawButtonsDuringWait(void) {
    Capture *capture = [Capture new];
    capture.waitForNeutral = ds4Button(@"l1");
    uint8_t held[] = {1, 128, 128, 128, 128, 8 | 0x40, 1, 0}; // Circle and L1 down.
    [capture receive:held length:sizeof(held)];
    assert(capture.rawButtons == (ds4Button(@"circle") | ds4Button(@"l1")));
    assert(capture.haveButtons && !capture.held);
}

static void outputReport(void) {
    NSData *report = ds4OutputReport((DS4Output){.mic = YES, .red = 1, .green = 2, .blue = 3,
                                                 .flashOn = 4, .flashOff = 5, .rumbleWeak = 6, .rumbleStrong = 7});
    const uint8_t *b = report.bytes;
    assert(report.length == 78 && b[0] == 0x11 && b[2] == 0xa1 && b[3] == 0xf3 && b[23] == 0x40);
    assert(b[6] == 6 && b[7] == 7 && b[8] == 1 && b[9] == 2 && b[10] == 3 && b[11] == 4 && b[12] == 5);
    uint32_t crc;
    memcpy(&crc, b + 74, 4);
    assert(CFSwapInt32LittleToHost(crc) == reportCRC(0xa2, b, 74));
    b = ds4OutputReport((DS4Output){.blue = 9}).bytes;
    assert(b[2] == 0xa0 && b[3] == 0xf7 && b[23] == 0 && b[10] == 9);
}

int main(void) {
    @autoreleasepool {
        const uint8_t *cmd;
        NSData *arm = micCommand(YES);
        cmd = arm.bytes;
        assert(arm.length == 78 && cmd[0] == 0x11 && cmd[2] == 0xa1 && cmd[3] == 0xf3 && cmd[23] == 0x40);
        overlappingReports();
        queuedSpeechAfterRelease();
        checkVoiceLevel();
        remappedControls();
        handsFree();
        rawButtonsDuringWait();
        outputReport();
        take(NO, nil);
        take(YES, @".build/test-tone.wav");
    }
}
