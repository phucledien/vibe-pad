#import <Foundation/Foundation.h>

// Input is the mono, 16 kHz, signed 16-bit PCM WAV produced by Capture.wave.
@interface VoiceLevel : NSObject
@property(readonly) NSData *wave;
@property(readonly) double levelDB, gainDB;
- (instancetype)initWithCaptureWave:(NSData *)wave;
@end
