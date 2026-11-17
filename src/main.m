#import "DS4HID.h"
#import <IOKit/hid/IOHIDManager.h>
#include <signal.h>
#include <unistd.h>

static volatile sig_atomic_t interrupted;
static void interrupt(int sig) { (void)sig; interrupted = 1; }

typedef struct {
    Capture *__unsafe_unretained capture;
    IOHIDDeviceRef device;
    uint8_t buffer[1024];
    BOOL disconnected, writeFailed;
    CFTimeInterval started, lastCommand, lastAudio;
    unsigned counts[256];
    const char *talkName;
    uint32_t sendButton, discardButton;
    int action;
} Session;

static BOOL sendMode(Session *s, BOOL enable) {
    NSData *cmd = micCommand(enable);
    IOReturn result = IOHIDDeviceSetReport(s->device, kIOHIDReportTypeOutput, 0x11,
                                         cmd.bytes, cmd.length);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "DS4 mic %s write failed (IOKit 0x%08x).\n",
                enable ? "enable" : "disable", result);
        return NO;
    }
    s->lastCommand = NSProcessInfo.processInfo.systemUptime;
    return YES;
}

static void input(void *context, IOReturn result, void *sender, IOHIDReportType type,
                  uint32_t reportID, uint8_t *bytes, CFIndex size) {
    (void)sender; (void)type;
    Session *s = context;
    if (s->action || result || size <= 0 || size > (CFIndex)sizeof(s->buffer) || reportID > 255) return;
    s->counts[reportID]++;
    BOOL held = s->capture.held;
    unsigned previousFrames = s->capture.frames;
    BOOL hadStatus = s->capture.haveJackStatus;
    uint8_t oldJack = s->capture.jackFlags;
    receiveDS4Report(s->capture, reportID, bytes, size);
    if (s->capture.frames != previousFrames) s->lastAudio = NSProcessInfo.processInfo.systemUptime;
    if (!previousFrames && s->capture.frames && s->sendButton) {
        printf("\aMic audio ready. Speak now.\n");
    }
    if (s->capture.haveJackStatus && (!hadStatus || oldJack != s->capture.jackFlags)) {
        printf("Jack flags: headphone=%s, mic=%s (audio frames confirm capture).\n",
               s->capture.jackFlags & 0x20 ? "yes" : "no",
               s->capture.jackFlags & 0x40 ? "yes" : "no");
    }
    if (!s->started && !s->capture.held) {
        if (s->capture.buttons & s->discardButton) s->action = 11;
        else if (s->capture.buttons & s->sendButton) s->action = 10;
    }
    if (!held && s->capture.held) {
        s->started = NSProcessInfo.processInfo.systemUptime;
        if (s->sendButton) puts("Opening headset mic…");
        else printf("%s down. Speak into the controller headset, then release.\n", s->talkName);
        s->writeFailed = !sendMode(s, YES);
    }
}

static void removed(void *context, IOReturn result, void *sender) {
    (void)result; (void)sender;
    ((Session *)context)->disconnected = YES;
}

static int run(BOOL list, BOOL play, char **bindings) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    matchBluetoothPads(manager);
    IOReturn status = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (status != kIOReturnSuccess) {
        fprintf(stderr, "Cannot open controller HID interface (IOKit 0x%08x). Check Input Monitoring for your terminal if access was denied.\n", status);
        CFRelease(manager);
        return 1;
    }
    NSSet *devices = CFBridgingRelease(IOHIDManagerCopyDevices(manager));
    int code = 1;
    for (id entry in devices) {
        IOHIDDeviceRef device = (__bridge IOHIDDeviceRef)entry;
        NSNumber *pid = (__bridge NSNumber *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey));
        printf("Bluetooth DS4 054c:%04x\n", pid.unsignedIntValue);
    }
    if (!devices.count) {
        fputs("No connected Sony Bluetooth DS4. Connect it in System Settings > Bluetooth and retry.\n", stderr);
    } else if (list) {
        code = 0;
    } else if (devices.count > 1) {
        fputs("Multiple DS4s connected. Disconnect the other controller for this take.\n", stderr);
    } else {
        __attribute__((objc_precise_lifetime)) Capture *capture = [[Capture alloc] init];
        if (!capture) { fputs("Codec initialization failed.\n", stderr); goto done; }
        Session session = {.capture = capture, .device = (__bridge IOHIDDeviceRef)devices.anyObject};
        session.talkName = bindings ? bindings[0] : "L1";
        if (bindings) {
            capture.talkButton = ds4Button(@(bindings[0]));
            session.sendButton = ds4Button(@(bindings[1]));
            session.discardButton = ds4Button(@(bindings[2]));
            capture.waitForNeutral = capture.talkButton | session.sendButton | session.discardButton;
        }
        IOHIDDeviceRegisterInputReportCallback(session.device, session.buffer, sizeof(session.buffer), input, &session);
        IOHIDDeviceRegisterRemovalCallback(session.device, removed, &session);
        IOHIDDeviceScheduleWithRunLoop(session.device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        if (bindings) printf("Ready. Hold %s to talk, %s to send, %s to discard.\n", bindings[0], bindings[1], bindings[2]);
        else puts("Ready. Hold L1 for five seconds while speaking. Release to save. Ctrl-C cancels.");
        CFTimeInterval ready = NSProcessInfo.processInfo.systemUptime;
        while (!session.action && !capture.finished && !session.disconnected && !session.writeFailed && !interrupted) {
            @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false); }
            CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
            if (!bindings && !session.started && now - ready > 90) { puts("Timed out waiting for L1."); break; }
            if (session.started && now - session.started > 60) { puts("Reached 60 second limit."); break; }
            if (capture.held && !session.disconnected && !session.writeFailed && now - MAX(session.lastCommand, session.lastAudio) > 0.5)
                session.writeFailed = !sendMode(&session, YES);
        }
        IOHIDDeviceUnscheduleFromRunLoop(session.device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        if (session.started && !session.disconnected) sendMode(&session, NO);
        if (session.action) { code = session.action; goto done; }
        if (session.started) printf("Voice take lasted %.2f seconds.\n", NSProcessInfo.processInfo.systemUptime - session.started);
        printf("HID reports %u, mic reports %u, decoded frames %u, sequence gaps %u, bad CRCs %u, peak %d/32768.\n",
               capture.reports, capture.audioReports, capture.frames, capture.gaps, capture.badCRC, capture.peak);
        for (int i = 0; i < 256; i++) if (session.counts[i]) printf("  report 0x%02x: %u\n", i, session.counts[i]);
        if (session.disconnected) puts("Controller disconnected.");
        if (interrupted) { code = 130; goto done; }
        if (bindings && (session.disconnected || session.writeFailed)) goto done;
        if (bindings && (!capture.finished || !capture.peak)) {
            puts("Take empty or incomplete. Try recording again.");
            code = 12;
            goto done;
        }
        NSData *wav = capture.wave;
        if (!wav) {
            puts("No headset samples received. Check the headset plug, mic switch and connection.");
        } else {
            NSString *name = bindings ? @"take.wav" : [NSString stringWithFormat:@"ds4-%@.wav", NSUUID.UUID.UUIDString];
            NSURL *url = [NSURL fileURLWithPath:name];
            NSError *err = nil;
            if (![wav writeToURL:url options:NSDataWritingWithoutOverwriting error:&err]) {
                fprintf(stderr, "Could not save WAV: %s\n", err.localizedDescription.UTF8String);
                goto done;
            }
            printf("Saved %.2f seconds to %s\n", capture.sampleCount / 16000.0, url.path.UTF8String);
            if (!capture.peak) puts("All decoded samples are silent. Check the headset mic.");
            code = (session.writeFailed || session.disconnected) ? 1 : 0;
            if (play) {
                NSTask *player = [[NSTask alloc] init];
                player.executableURL = [NSURL fileURLWithPath:@"/usr/bin/afplay"];
                player.arguments = @[url.path];
                if ([player launchAndReturnError:&err]) { [player waitUntilExit]; if (player.terminationStatus) code = 1; }
                else { fprintf(stderr, "Playback failed: %s\n", err.localizedDescription.UTF8String); code = 1; }
            }
        }
    }
done:
    IOHIDManagerClose(manager, 0);
    CFRelease(manager);
    return code;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL list = argc == 2 && !strcmp(argv[1], "--list");
        BOOL play = argc == 2 && !strcmp(argv[1], "--play");
        BOOL agentInput = argc == 5 && !strcmp(argv[1], "--agent-input");
        if (agentInput) {
            NSMutableSet *unique = [NSMutableSet set];
            for (int i = 2; i < 5; i++) {
                uint32_t mask = ds4Button(@(argv[i]));
                if (!mask || [unique containsObject:@(mask)]) {
                    fputs("Select three distinct supported DS4 buttons.\n", stderr);
                    return 2;
                }
                [unique addObject:@(mask)];
            }
        }
        if (argc != 1 && !list && !play && !agentInput) { fputs("Usage: ds4-mic [--list | --play]\n", stderr); return 2; }
        setlinebuf(stdout);
        signal(SIGINT, interrupt);
        signal(SIGTERM, interrupt);
        return run(list, play, agentInput ? argv + 2 : NULL);
    }
}
