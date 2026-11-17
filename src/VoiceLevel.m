#import "VoiceLevel.h"
#include <math.h>

@implementation VoiceLevel
- (instancetype)initWithCaptureWave:(NSData *)wave {
    if (!(self = [super init])) return nil;
    _wave = wave;
    _levelDB = -96;
    if (wave.length <= 44) return self;
    NSUInteger count = (wave.length - 44) / 2;
    const int16_t *samples = (const int16_t *)((const uint8_t *)wave.bytes + 44);
    // The headset may click at startup. Base gain on 50 ms RMS windows,
    // excluding the first 100 ms of longer recordings.
    NSMutableArray<NSNumber *> *levels = [NSMutableArray array];
    for (NSUInteger start = count > 4800 ? 1600 : 0; start < count; start += 800) {
        NSUInteger end = MIN(start + 800, count);
        double energy = 0;
        for (NSUInteger i = start; i < end; i++) energy += (double)samples[i] * samples[i];
        [levels addObject:@(sqrt(energy / (end - start)) / 32768.0)];
    }
    [levels sortUsingSelector:@selector(compare:)];
    double level = levels[(levels.count - 1) * 9 / 10].doubleValue;
    _levelDB = MAX(-96, 20 * log10(MAX(level, 1e-6)));
    if (_levelDB <= -60 || _levelDB >= -24) return self;
    _gainDB = MIN(16, -24 - _levelDB);
    double gain = pow(10, _gainDB / 20);
    NSMutableData *adjusted = [wave mutableCopy];
    int16_t *output = (int16_t *)((uint8_t *)adjusted.mutableBytes + 44);
    for (NSUInteger i = 0; i < count; i++) {
        double magnitude = fabs((double)samples[i]) * gain / 32768.0;
        // Compress only the highest peaks so an isolated click cannot clip.
        if (magnitude > 0.8) magnitude = 0.8 + 0.2 * tanh((magnitude - 0.8) / 0.2);
        output[i] = (int16_t)lrint(copysign(MIN(32767, magnitude * 32768), samples[i]));
    }
    _wave = adjusted;
    return self;
}
@end
