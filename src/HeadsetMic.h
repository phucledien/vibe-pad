#import "DS4HID.h"

// One take from the controller headset: the decoded WAV, its level-adjusted
// copy for Whisper, timing statistics and, when unusable, a failure message.
@interface HeadsetTake : NSObject
@property NSData *original, *wave;       // wave is level-adjusted, ready for Whisper
@property NSDictionary *info;            // held, seconds, startup, gaps, level, gain…
@property NSString *failure;             // nil when the take can be transcribed
@property BOOL handsFree;
@end

@protocol HeadsetMicDelegate
// phase: opening, recording, stalled, finishing, idle
- (void)headsetPhase:(NSString *)phase text:(NSString *)text;
- (void)headsetFinished:(HeadsetTake *)take;
@end

// Owns the mic state machine for one connected pad: push-to-talk on the talk
// button, latched hands-free takes, release tail, queue drain, keepalive and
// re-arm. Every output report also carries the current lightbar and rumble.
@interface HeadsetMic : NSObject
@property(weak) id<HeadsetMicDelegate> delegate;
@property(nonatomic) IOHIDDeviceRef device;      // not retained; owner keeps it alive
@property(readonly) Capture *capture;
@property(nonatomic) uint32_t talkButton;
@property(nonatomic) BOOL armed;                 // NO while transcribing or sending
@property(readonly) BOOL active, handsFree;      // a take is in progress
@property NSTimeInterval limit;                  // seconds; push-to-talk default 60
@property NSTimeInterval handsFreeLimit;         // default 300
- (void)receive:(uint32_t)reportID bytes:(uint8_t *)bytes size:(CFIndex)size;
- (void)service;                                 // call every ~40 ms
- (void)startHandsFree;
- (void)stopHandsFree;                           // finish and deliver the take
- (void)cancel;                                  // stop and drop the take
- (void)deviceLost;
- (void)resetCapture;
// Lightbar and rumble. Writes immediately and on every later mic write.
- (void)setLightRed:(uint8_t)r green:(uint8_t)g blue:(uint8_t)b flash:(BOOL)flash;
- (void)rumble:(uint8_t)strength weak:(uint8_t)weak seconds:(NSTimeInterval)seconds;
@end
