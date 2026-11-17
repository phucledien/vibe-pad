#import <Foundation/Foundation.h>

// On failure, result holds the tool's error object when it printed one.
typedef void (^HerdrReply)(NSDictionary *result, NSString *error);

// Drives the Herdr app (`herdr-app do`) and herdr-core (`hc`). Calls run in
// order on a private serial queue, never on the HID run loop, and reply on
// the main queue. HERDR_APP_HOME / HC_SOCKET style overrides pass through the
// environment untouched.
@interface Herdr : NSObject
// An app command, e.g. app:@"pane.go" args:@{@"direction": @"left"}.
- (void)app:(NSString *)command args:(NSDictionary *)args reply:(HerdrReply)reply;
// An hc subcommand; --json is added. e.g. hc:@[@"keys", @"t4", @"enter"].
- (void)hc:(NSArray<NSString *> *)args reply:(HerdrReply)reply;
// Window + core state, normalised (see Herdr.m for the shape).
- (void)snapshot:(HerdrReply)reply;
@end
