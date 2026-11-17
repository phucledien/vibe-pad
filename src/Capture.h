#import <Foundation/Foundation.h>

uint32_t ds4Button(NSString *name);
uint32_t reportCRC(uint8_t prefix, const uint8_t *bytes, size_t count);
size_t inputLength(uint8_t reportID);
NSData *micCommand(BOOL enable);

// Everything Bluetooth report 0x11 carries. Keepalives rewrite the whole report,
// so callers keep one state and compose every write from it.
typedef struct {
    BOOL mic;
    uint8_t red, green, blue;
    uint8_t flashOn, flashOff;      // units of 10 ms; both 0 = steady light
    uint8_t rumbleWeak, rumbleStrong;
} DS4Output;
NSData *ds4OutputReport(DS4Output state);

@interface Capture : NSObject
@property(readonly) BOOL held, finished;
// The playground owns the stop deadline and can receive queued mic frames after release.
@property BOOL releaseTailEnabled;
@property uint32_t talkButton, waitForNeutral;
// Hands-free mode: behaves as if the talk button were held until cleared.
@property BOOL latched;
@property(readonly) uint32_t buttons;
// Every pressed button, updated even while waitForNeutral holds `buttons` back.
@property(readonly) uint32_t rawButtons;
@property(readonly) BOOL haveButtons;
@property(readonly) uint8_t hat, lx, ly, rx, ry;
@property(readonly) unsigned frames, badCRC, gaps, reports, audioReports;
@property(readonly) NSUInteger sampleCount;
@property(readonly) int peak;
@property(readonly) BOOL haveJackStatus;
@property(readonly) uint8_t jackFlags;
- (void)receive:(const uint8_t *)report length:(size_t)length;
// A successful re-arm after a stall may restart the controller's frame counter.
- (void)restartSequence;
- (NSData *)wave;
@end
