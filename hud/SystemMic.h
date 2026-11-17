#import <Foundation/Foundation.h>

// Records the Mac's default input device (System Settings → Sound → Input)
// as mono 16 kHz signed 16-bit PCM, the format Whisper and VoiceLevel expect.
@interface SystemMic : NSObject
@property(readonly) BOOL recording;
@property BOOL paused;                       // drop audio while set
@property(readonly) float level;             // 0..1, recent loudness for meters
@property(readonly) NSString *deviceName;   // the input device of the last start
// Asks for microphone access the first time; reply runs on the main queue.
+ (void)requestAccess:(void (^)(BOOL granted))reply;
- (BOOL)start:(NSString **)error;
- (NSData *)stop;                            // WAV, or nil if nothing was captured
- (void)cancel;
@end
