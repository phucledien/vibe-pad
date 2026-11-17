#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import "HeadsetMic.h"
#import "Herdr.h"
#import "SystemMic.h"
#import "VoiceLevel.h"
#import <AVFoundation/AVFoundation.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <sys/file.h>

// Herdr Pad: drive Herdr from a DualShock 4 like a game. A click-through HUD
// floats over the Herdr app; actions go through `herdr-app do` and herdr-core (`hc`).

static NSArray<NSString *> *buttonNames(void) {
    return @[@"square", @"cross", @"circle", @"triangle", @"l1", @"r1", @"l2", @"r2",
             @"share", @"options", @"l3", @"r3", @"ps", @"touchpad"];
}
static const double holdSeconds = 0.6;
static const double stickOn = 0.55, stickOff = 0.35;
static const double repeatDelay = 0.35, repeatEvery = 0.12;

static NSString *configPath(void) { return [@"~/.config/herdr-pad/config.json" stringByExpandingTildeInPath]; }
static NSString *padDir(void) { return [@"~/.config/herdr-pad" stringByExpandingTildeInPath]; }

static NSString *executablePath(void) {
    char path[4096]; uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) return nil;
    char resolved[PATH_MAX];
    return realpath(path, resolved) ? @(resolved) : @(path);
}

// Inside an .app the bundle holds the files; a bare `herdr-pad` binary keeps
// them in `herdr-pad.resources/` beside itself.
static NSURL *resource(NSString *name, NSString *ext) {
    NSURL *url = [NSBundle.mainBundle URLForResource:name withExtension:ext];
    if (url) return url;
    NSString *dir = [executablePath().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"herdr-pad.resources"];
    NSString *file = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:ext]];
    return [NSFileManager.defaultManager fileExistsAtPath:file] ? [NSURL fileURLWithPath:file] : nil;
}

static NSDictionary *defaultConfig(void) {
    return @{
        @"language": @"en",
        @"talk": @"l1",
        @"mic": @"system",          // "system": the Mac's default input; "controller": the DS4 headset jack
        @"buttons": @{
            @"r1": @"handsfree",
            @"cross": @"confirm",
            @"circle": @"back",
            @"square": @{@"tap": @"mode", @"hold": @"interrupt"},
            @"triangle": @"zoom",
            @"l2": @"prev_tab", @"r2": @"next_tab",
            @"share": @"prev_workspace", @"options": @"next_workspace",
            @"touchpad": @"attention",
            @"l3": @"toggle_hud", @"r3": @"language",
        },
        @"sounds": @YES, @"haptics": @YES, @"lightbar": @YES,
        @"hud": @{@"corner": @"bottom-right", @"mode": @"full"},
    };
}

static void runProcess(NSString *program, NSArray<NSString *> *args, void (^reply)(NSString *out, NSString *failure)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
        env[@"PATH"] = [NSString stringWithFormat:@"%@/.local/bin:/opt/homebrew/bin:/usr/local/bin:%@",
                        NSHomeDirectory(), env[@"PATH"] ?: @"/usr/bin:/bin"];
        task.executableURL = [NSURL fileURLWithPath:program];
        task.arguments = args;
        task.environment = env;
        NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
        task.standardOutput = out; task.standardError = err;
        NSError *error = nil;
        NSString *text = @"", *failure = nil;
        if ([task launchAndReturnError:&error]) {
            NSData *data = [out.fileHandleForReading readDataToEndOfFile];
            NSData *errData = [err.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            if (task.terminationStatus) {
                NSString *msg = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding];
                NSArray *lines = [[msg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"];
                failure = [lines.lastObject length] ? lines.lastObject : @"Transcription failed.";
            }
        } else failure = error.localizedDescription;
        dispatch_async(dispatch_get_main_queue(), ^{ reply(text, failure); });
    });
}

// Whisper emits markers such as [BLANK_AUDIO] or (music) for non-speech.
static NSString *cleanTranscript(NSString *text) {
    NSRegularExpression *markers = [NSRegularExpression regularExpressionWithPattern:@"\\[[^\\]]*\\]|\\([^)]*\\)|\\*[^*]*\\*" options:0 error:nil];
    text = [markers stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    NSArray *words = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    text = [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    return [text rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound ? @"" : text;
}

@interface HUDPanel : NSPanel
@end
@implementation HUDPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface Pad : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, HeadsetMicDelegate> {
    HUDPanel *_panel;
    WKWebView *_web;
    BOOL _webReady;
    NSStatusItem *_status;
    IOHIDManagerRef _manager;
    IOHIDDeviceRef _device;
    uint8_t _buffer[1024];
    HeadsetMic *_mic;
    SystemMic *_sys;
    NSArray *_light;
    NSDictionary *_lastPress, *_lastSentInfo, *_lastToast;
    NSString *_padStateJSON;
    NSArray *_heldInfo;                 // [names, hat, [lx, ly, rx, ry] quantised]
    NSMutableArray<NSNumber *> *_levels; // recent loudness columns for the panel meter
    double _lastLevel, _pausedAt, _pausedTotal;
    NSInteger _score, _combo; double _lastSendAt;
    BOOL _overlaySuppressed;
    BOOL _useSystem, _sysHandsFree, _sysStopping;
    uint32_t _talkMask;
    double _sysStarted;
    Herdr *_herdr;
    NSDictionary *_config;
    NSString *_language, *_hudMode;
    BOOL _inject, _sawInput;
    NSTimer *_tick, *_poll;
    BOOL _polling;
    // Herdr state
    NSDictionary *_snapshot;
    NSDictionary<NSString *, NSString *> *_agentStatus;   // pane -> status, for transitions
    BOOL _herdrUp;
    // Controller state
    uint32_t _buttons;
    uint8_t _hatDir;                // 0 up, 1 right, 2 down, 3 left, 8 none
    double _lx, _ly, _rx, _ry;      // -1..1
    NSMutableDictionary<NSString *, NSNumber *> *_pressedAt;
    NSMutableSet<NSString *> *_holdFired;
    NSString *_stickKey; double _stickNext; BOOL _stickRepeating;
    double _scrollCarry, _lastScroll;
    NSString *_scrollPane; NSUInteger _scrollOffset, _scrollMax;
    // Voice
    NSString *_phase, *_phaseText, *_takeTarget;
    double _takeStarted;
    BOOL _transcribing, _sending;
    NSString *_draft, *_draftTarget, *_lastSent;
}
@end

@implementation Pad

#pragma mark - Logging and feedback

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list args; va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (_inject || getenv("HERDR_PAD_DEBUG")) { printf("LOG %s\n", line.UTF8String); fflush(stdout); }
}

- (void)emit:(NSString *)kind data:(NSDictionary *)data {
    // The in-app pad panel (mods/pad) reads the same events from state.json.
    double now = NSDate.date.timeIntervalSince1970 * 1000;
    if ([kind isEqual:@"press"]) { _lastPress = @{@"button": data[@"button"] ?: @"", @"at": @(now)}; [self writePadState]; }
    else if ([kind isEqual:@"sent"]) { _lastSentInfo = @{@"text": data[@"text"] ?: @"", @"target": data[@"target"] ?: @"", @"typed": data[@"typed"] ?: @NO, @"at": @(now)}; [self writePadState]; }
    else if ([kind isEqual:@"toast"]) { _lastToast = @{@"text": data[@"text"] ?: @"", @"type": data[@"type"] ?: @"info", @"at": @(now)}; [self writePadState]; }
    if (!_webReady) return;
    NSMutableDictionary *event = [data mutableCopy] ?: [NSMutableDictionary dictionary];
    event[@"kind"] = kind;
    [_web callAsyncJavaScript:@"window.padEvent && window.padEvent(event)" arguments:@{@"event": event}
                      inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
}

- (void)toast:(NSString *)text kind:(NSString *)kind {
    [self log:@"toast[%@] %@", kind, text];
    [self emit:@"toast" data:@{@"text": text ?: @"", @"type": kind}];
}

- (void)sound:(NSString *)name {
    if (![_config[@"sounds"] boolValue] || _inject) return;
    NSSound *sound = [NSSound soundNamed:name];
    [sound stop]; sound.volume = 0.35; [sound play];
}

- (void)buzz:(uint8_t)strong weak:(uint8_t)weak seconds:(double)seconds {
    if (![_config[@"haptics"] boolValue]) return;
    [_mic rumble:strong weak:weak seconds:seconds];
}

#pragma mark - Config

- (void)loadConfig {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:configPath()]) {
        [fm createDirectoryAtPath:configPath().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [NSJSONSerialization dataWithJSONObject:defaultConfig() options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
        [data writeToFile:configPath() atomically:YES];
    }
    NSMutableDictionary *config = [defaultConfig() mutableCopy];
    NSData *data = [NSData dataWithContentsOfFile:configPath()];
    NSDictionary *user = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (data && ![user isKindOfClass:NSDictionary.class]) {
        user = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ [self toast:@"config.json is not valid JSON. Using defaults." kind:@"error"]; });
    }
    for (NSString *key in user) {
        if ([key isEqual:@"buttons"] && [user[key] isKindOfClass:NSDictionary.class]) {
            NSMutableDictionary *buttons = [config[@"buttons"] mutableCopy];
            [buttons addEntriesFromDictionary:user[key]];
            config[key] = buttons;
        } else config[key] = user[key];
    }
    _config = config;
    _language = _language ?: config[@"language"];
    _hudMode = _hudMode ?: config[@"hud"][@"mode"] ?: @"full";
    uint32_t talk = ds4Button(config[@"talk"]) ?: ds4Button(@"l1");
    _talkMask = talk;
    _useSystem = ![config[@"mic"] isEqual:@"controller"];
    // In system mode the headset path never arms; the talk button drives SystemMic.
    _mic.talkButton = _useSystem ? 0 : talk;
    [self pushState];
}

#pragma mark - Herdr state

- (NSArray *)sorted:(NSArray *)items { return [items sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"number" ascending:YES]]]; }

- (NSDictionary *)agentForPane:(NSString *)pane {
    for (NSDictionary *a in _snapshot[@"agents"]) if ([a[@"pane_id"] isEqual:pane]) return a;
    return nil;
}

- (NSString *)describePane:(NSString *)pane {
    if (!pane) return @"no pane";
    NSDictionary *agent = [self agentForPane:pane];
    NSString *cwd = nil;
    for (NSDictionary *p in _snapshot[@"panes"]) if ([p[@"pane_id"] isEqual:pane]) cwd = p[@"foreground_cwd"] ?: p[@"cwd"];
    NSString *place = [cwd lastPathComponent] ?: pane;
    return agent ? [NSString stringWithFormat:@"%@ · %@", agent[@"agent"], place] : [NSString stringWithFormat:@"shell · %@", place];
}

// The Herdr panel (and `herdr-pad --send <action>`) queue actions here.
- (void)readCommands {
    NSString *path = [padDir() stringByAppendingPathComponent:@"command"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSSet *allowed = [NSSet setWithArray:@[@"handsfree", @"pause", @"confirm", @"back", @"language", @"attention", @"zoom",
                                           @"next_tab", @"prev_tab", @"next_workspace", @"prev_workspace", @"quit",
                                           @"mic:system", @"mic:controller", @"lang:en", @"lang:vi", @"lang:auto",
                                           @"hud:full", @"hud:compact", @"hud:hidden", @"sounds", @"haptics", @"config", @"reload"]];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *action = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![allowed containsObject:action]) continue;
        [self log:@"command %@", action];
        if ([action isEqual:@"quit"]) { [NSApp terminate:nil]; return; }
        // Settings from the panel go through the same path as the menu-bar menu.
        if ([action containsString:@":"] || [@[@"sounds", @"haptics", @"config", @"reload"] containsObject:action]) {
            NSMenuItem *item = [NSMenuItem new]; item.representedObject = action; [self menuAction:item]; [self pushState];
        }
        else [self perform:action];
    }
}

- (void)poll {
    [self readCommands];
    if (_polling) return;
    _polling = YES;
    [_herdr snapshot:^(NSDictionary *result, NSString *error) {
        self->_polling = NO;
        BOOL was = self->_herdrUp;
        self->_herdrUp = !error;
        if (error) {
            if (was) [self toast:[@"Lost Herdr: " stringByAppendingString:error] kind:@"error"];
            [self pushState]; [self updateLight];
            return;
        }
        [self absorb:result[@"snapshot"]];
    }];
}

- (void)absorb:(NSDictionary *)snapshot {
    if (![snapshot isKindOfClass:NSDictionary.class]) return;
    NSDictionary *old = _agentStatus;
    _snapshot = snapshot;
    NSMutableDictionary *now = [NSMutableDictionary dictionary];
    for (NSDictionary *a in snapshot[@"agents"]) {
        NSString *pane = a[@"pane_id"], *status = a[@"agent_status"] ?: @"unknown";
        if (!pane) continue;
        now[pane] = status;
        NSString *before = old[pane];
        if (!old || [before isEqual:status]) continue;
        NSString *who = [self describePane:pane];
        if ([status isEqual:@"blocked"]) {
            [self toast:[NSString stringWithFormat:@"%@ needs you — press the touchpad to jump there", who] kind:@"alert"];
            [self sound:@"Sosumi"];
            [self buzz:200 weak:0 seconds:0.18];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self buzz:200 weak:0 seconds:0.18]; });
        } else if ([before isEqual:@"working"] && ([status isEqual:@"done"] || [status isEqual:@"idle"])) {
            [self toast:[NSString stringWithFormat:@"%@ finished ✓", who] kind:@"done"];
            [self sound:@"Glass"];
            [self buzz:0 weak:120 seconds:0.12];
        }
    }
    _agentStatus = now;
    NSString *focused = snapshot[@"focused_pane_id"];
    if (![focused isEqual:_scrollPane]) {
        _scrollPane = focused;
        _scrollOffset = 0; _scrollMax = 0;
        for (NSDictionary *p in snapshot[@"panes"]) if ([p[@"pane_id"] isEqual:focused]) {
            _scrollOffset = [p[@"scroll"][@"offset_from_bottom"] unsignedIntegerValue];
            _scrollMax = [p[@"scroll"][@"max_offset_from_bottom"] unsignedIntegerValue];
        }
    }
    [self pushState];
    [self updateLight];
}

- (void)refreshSoon { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self poll]; }); }

static NSString *padStatePath(void) { return [@"~/.config/herdr-pad/state.json" stringByExpandingTildeInPath]; }

- (void)writePadState {
    NSDictionary *state = @{
        @"version": @1, @"pid": @(NSProcessInfo.processInfo.processIdentifier),
        @"controller": @(_device != NULL), @"herdr": @(_herdrUp),
        @"mic": _useSystem ? @"system" : @"controller",
        @"source": _useSystem ? (_sys.deviceName ?: @"Mac microphone") : @"Controller headset",
        @"micPermission": @[@"unknown", @"restricted", @"denied", @"granted"][MIN(3, (NSInteger)[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio])],
        @"binary": executablePath() ?: @"",
        @"held": _heldInfo ?: @[@[], @8, @[@0, @0, @0, @0]],
        @"sounds": @([_config[@"sounds"] boolValue]), @"haptics": @([_config[@"haptics"] boolValue]), @"hud": _hudMode ?: @"full",
        @"levels": _levels ?: @[], @"paused": @(_pausedAt > 0), @"pausedAt": @(_pausedAt), @"pausedTotal": @(_pausedTotal),
        @"score": @(_score), @"combo": @(_combo),
        @"phase": _phase ?: @"idle", @"phaseText": _phaseText ?: @"", @"handsFree": @([self handsFreeOn]),
        @"target": _takeTarget ? [self describePane:_takeTarget] : @"", @"started": @(_takeStarted),
        @"draft": _draft ?: @"", @"draftTarget": _draftTarget ? [self describePane:_draftTarget] : @"",
        @"language": _language ?: @"en", @"talk": _config[@"talk"] ?: @"l1", @"bindings": _config[@"buttons"] ?: @{},
        @"light": _light ?: @[@0, @0, @48, @NO],
        @"lastPress": _lastPress ?: [NSNull null], @"lastSent": _lastSentInfo ?: [NSNull null], @"toast": _lastToast ?: [NSNull null],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingSortedKeys error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([json isEqual:_padStateJSON]) return;
    _padStateJSON = json;
    NSString *path = padStatePath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:YES];
}

// The floating HUD duplicates the in-app pad panel, so it steps aside while
// Herdr is frontmost on a layout that shows that panel.
- (void)syncOverlay {
    NSString *front = NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier;
    BOOL suppress = [front isEqual:@"dev.herdr.app"] && [_snapshot[@"layout_name"] hasPrefix:@"pad-arcade"];
    if (suppress == _overlaySuppressed) return;
    _overlaySuppressed = suppress;
    if (suppress) [_panel orderOut:nil];
    else if (![_hudMode isEqual:@"hidden"]) [_panel orderFrontRegardless];
}

- (void)pushState {
    [self writePadState];
    [self syncOverlay];
    NSDictionary *s = _snapshot ?: @{};
    NSString *focusedWs = s[@"focused_workspace_id"], *focusedTab = s[@"focused_tab_id"], *focusedPane = s[@"focused_pane_id"];
    NSMutableArray *workspaces = [NSMutableArray array];
    for (NSDictionary *w in [self sorted:s[@"workspaces"] ?: @[]])
        [workspaces addObject:@{@"id": w[@"workspace_id"] ?: @"", @"number": w[@"number"] ?: @0, @"label": w[@"label"] ?: @"",
                                @"status": w[@"agent_status"] ?: @"unknown", @"focused": @([w[@"workspace_id"] isEqual:focusedWs])}];
    NSMutableArray *tabs = [NSMutableArray array];
    for (NSDictionary *t in [self sorted:s[@"tabs"] ?: @[]]) {
        if (![t[@"workspace_id"] isEqual:focusedWs]) continue;
        [tabs addObject:@{@"id": t[@"tab_id"] ?: @"", @"number": t[@"number"] ?: @0, @"label": t[@"label"] ?: @"",
                          @"status": t[@"agent_status"] ?: @"unknown", @"focused": @([t[@"tab_id"] isEqual:focusedTab])}];
    }
    NSDictionary *layout = nil;
    for (NSDictionary *l in s[@"layouts"]) if ([l[@"tab_id"] isEqual:focusedTab]) layout = l;
    NSMutableArray *panes = [NSMutableArray array];
    for (NSDictionary *p in layout[@"panes"]) {
        NSDictionary *agent = [self agentForPane:p[@"pane_id"]];
        [panes addObject:@{@"id": p[@"pane_id"], @"rect": p[@"rect"] ?: @{}, @"focused": @([p[@"pane_id"] isEqual:focusedPane]),
                           @"agent": agent[@"agent"] ?: @"", @"status": agent[@"agent_status"] ?: @"none",
                           @"title": agent[@"terminal_title_stripped"] ?: @""}];
    }
    NSMutableArray *attention = [NSMutableArray array];
    for (NSDictionary *a in s[@"agents"]) if ([a[@"agent_status"] isEqual:@"blocked"]) [attention addObject:a[@"pane_id"]];
    NSDictionary *agent = [self agentForPane:focusedPane];
    [self emit:@"state" data:@{
        @"herdr": @(_herdrUp), @"controller": @(_device != NULL || _inject),
        @"workspaces": workspaces, @"tabs": tabs,
        @"layout": @{@"area": layout[@"area"] ?: @{@"width": @1, @"height": @1}, @"panes": panes, @"zoomed": layout[@"zoomed"] ?: @NO},
        @"focus": @{@"pane": focusedPane ?: @"", @"label": [self describePane:focusedPane], @"agent": agent[@"agent"] ?: @"",
                    @"status": agent[@"agent_status"] ?: @"none"},
        @"blocked": @(attention.count),
        @"voice": @{@"phase": _phase ?: @"idle", @"text": _phaseText ?: @"", @"handsFree": @([self handsFreeOn]), @"source": _useSystem ? (_sys.deviceName ?: @"Mac microphone") : @"controller headset",
                    @"target": _takeTarget ? [self describePane:_takeTarget] : @"", @"started": @(_takeStarted),
                    @"draft": _draft ?: @"", @"draftTarget": _draftTarget ? [self describePane:_draftTarget] : @"",
                    @"language": _language ?: @"en"},
        @"mode": _hudMode ?: @"full",
        @"bindings": _config[@"buttons"] ?: @{}, @"talk": _config[@"talk"] ?: @"l1",
    }];
}

- (void)light:(int)r :(int)g :(int)b flash:(BOOL)flash {
    _light = @[@(r), @(g), @(b), @(flash)];
    [_mic setLightRed:(uint8_t)r green:(uint8_t)g blue:(uint8_t)b flash:flash];
    [self writePadState];
}

- (void)updateLight {
    if (![_config[@"lightbar"] boolValue]) return;
    NSString *focused = [self agentForPane:_snapshot[@"focused_pane_id"]][@"agent_status"];
    BOOL anyBlocked = NO;
    for (NSDictionary *a in _snapshot[@"agents"]) if ([a[@"agent_status"] isEqual:@"blocked"]) anyBlocked = YES;
    if ([self recording]) [self light:255 :0 :40 flash:NO];          // on air
    else if (_transcribing || _sending) [self light:150 :0 :255 flash:NO];
    else if (!_herdrUp) [self light:40 :40 :40 flash:NO];
    else if ([focused isEqual:@"blocked"]) [self light:255 :120 :0 flash:YES];
    else if (anyBlocked) [self light:255 :90 :0 flash:NO];
    else if ([focused isEqual:@"working"]) [self light:0 :90 :255 flash:NO];
    else if ([focused isEqual:@"done"] || [focused isEqual:@"idle"]) [self light:0 :220 :80 flash:NO];
    else [self light:60 :60 :80 flash:NO];
}

#pragma mark - Actions

- (NSString *)terminalForPane:(NSString *)pane {
    for (NSDictionary *p in _snapshot[@"panes"]) if ([p[@"pane_id"] isEqual:pane]) return [p[@"terminal"] length] ? p[@"terminal"] : nil;
    return nil;
}

// An app command. quiet: failures only rumble (e.g. no pane in that direction).
- (void)call:(NSString *)command params:(NSDictionary *)params quiet:(BOOL)quiet done:(void (^)(NSDictionary *result))done {
    [self log:@"call %@ %@", command, [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:params options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding]];
    [_herdr app:command args:params reply:^(NSDictionary *result, NSString *error) {
        if (error) {
            [self log:@"error %@: %@", command, error];
            if (quiet) [self buzz:0 weak:90 seconds:0.06];
            else { [self toast:error kind:@"error"]; [self sound:@"Funk"]; }
        } else if (done) done(result);
        [self refreshSoon];
    }];
}
- (void)call:(NSString *)command params:(NSDictionary *)params done:(void (^)(NSDictionary *result))done {
    [self call:command params:params quiet:NO done:done];
}

- (void)keys:(NSArray *)keys {
    NSString *terminal = [self terminalForPane:_snapshot[@"focused_pane_id"]];
    if (!terminal) { [self toast:@"The focused pane has no terminal." kind:@"error"]; return; }
    [self log:@"call hc keys %@ %@", terminal, [keys componentsJoinedByString:@","]];
    [_herdr hc:[@[@"keys", terminal] arrayByAddingObjectsFromArray:keys] reply:^(NSDictionary *r, NSString *error) {
        (void)r;
        if (error) { [self toast:error kind:@"error"]; [self sound:@"Funk"]; }
    }];
}

- (void)cycle:(NSString *)kind step:(NSInteger)step {
    BOOL tabs = [kind isEqual:@"tab"];
    NSString *current = tabs ? _snapshot[@"focused_tab_id"] : _snapshot[@"focused_workspace_id"];
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *item in [self sorted:_snapshot[tabs ? @"tabs" : @"workspaces"] ?: @[]]) {
        if (tabs && ![item[@"workspace_id"] isEqual:_snapshot[@"focused_workspace_id"]]) continue;
        [items addObject:item];
    }
    if (items.count < 2) { [self buzz:0 weak:60 seconds:0.05]; return; }
    NSString *key = tabs ? @"tab_id" : @"workspace_id";
    NSUInteger index = [[items valueForKey:key] indexOfObject:current];
    if (index == NSNotFound) index = 0;
    NSDictionary *next = items[(index + items.count + step) % items.count];
    [self sound:@"Tink"];
    [self buzz:0 weak:50 seconds:0.04];
    (void)next;
    NSString *command = tabs ? (step > 0 ? @"tab.next" : @"tab.prev") : (step > 0 ? @"space.next" : @"space.prev");
    [self call:command params:@{} done:nil];
}

- (void)jumpToAttention {
    NSMutableArray *candidates = [NSMutableArray array];
    for (NSString *wanted in @[@"blocked", @"done"]) {
        for (NSDictionary *a in _snapshot[@"agents"]) if ([a[@"agent_status"] isEqual:wanted]) [candidates addObject:a[@"pane_id"]];
        if (candidates.count) break;
    }
    if (!candidates.count) { [self toast:@"No agent is waiting for you." kind:@"info"]; [self buzz:0 weak:60 seconds:0.05]; return; }
    [candidates sortUsingSelector:@selector(compare:)];
    NSUInteger index = [candidates indexOfObject:_snapshot[@"focused_pane_id"]];
    NSString *target = candidates[index == NSNotFound ? 0 : (index + 1) % candidates.count];
    [self sound:@"Morse"];
    NSString *terminal = [self terminalForPane:target];
    if (terminal) [self call:@"agent.focus" params:@{@"terminal": terminal} done:nil];
    else [self call:@"pane.focus" params:@{@"pane": target} done:nil];
}

- (void)perform:(NSString *)action {
    [self log:@"action %@", action];
    if ([action isEqual:@"handsfree"]) {
        if ([self handsFreeOn]) { if (_useSystem) [self stopSystemTake]; else [_mic stopHandsFree]; }
        else if ([self recording]) return;
        else if (_transcribing || _sending) [self toast:@"Still working on the last take." kind:@"info"];
        else if (_useSystem) [self startSystemTake:YES];
        else if (!_device) [self toast:@"Controller not connected." kind:@"error"];
        else { _takeTarget = _snapshot[@"focused_pane_id"]; [_mic startHandsFree]; }
    } else if ([action isEqual:@"pause"]) {
        if (!_useSystem || !_sys.recording) return;
        double now = NSDate.date.timeIntervalSince1970 * 1000;
        if (_pausedAt > 0) { _pausedTotal += now - _pausedAt; _pausedAt = 0; _sys.paused = NO; }
        else { _pausedAt = now; _sys.paused = YES; }
        [self sound:@"Tink"]; [self pushState];
    } else if ([action isEqual:@"confirm"]) {
        if (_sending) return;
        if (_draft) [self deliver:_draft to:_draftTarget confirmed:YES];
        else [self keys:@[@"enter"]];
    } else if ([action isEqual:@"back"]) {
        if ([self recording]) { if (_useSystem) [self cancelSystemTake]; else [_mic cancel]; [self sound:@"Pop"]; }
        else if (_draft) { _draft = nil; _draftTarget = nil; [self toast:@"Draft discarded." kind:@"info"]; [self pushState]; }
        else [self keys:@[@"esc"]];
    } else if ([action isEqual:@"mode"]) [self keys:@[@"shift+tab"]];
    else if ([action isEqual:@"interrupt"]) { [self buzz:255 weak:0 seconds:0.25]; [self keys:@[@"ctrl+c"]]; [self toast:@"Interrupt sent (Ctrl-C)." kind:@"alert"]; }
    else if ([action isEqual:@"zoom"]) { [self sound:@"Tink"]; [self call:@"pane.zoom" params:@{} done:nil]; }
    else if ([action isEqual:@"next_tab"]) [self cycle:@"tab" step:1];
    else if ([action isEqual:@"prev_tab"]) [self cycle:@"tab" step:-1];
    else if ([action isEqual:@"next_workspace"]) [self cycle:@"workspace" step:1];
    else if ([action isEqual:@"prev_workspace"]) [self cycle:@"workspace" step:-1];
    else if ([action isEqual:@"attention"]) [self jumpToAttention];
    else if ([action isEqual:@"toggle_hud"] && [_snapshot[@"layout_name"] hasPrefix:@"pad-arcade"]) [self call:@"layout.toggle" params:@{@"id": @"padbar"} done:nil];
    else if ([action isEqual:@"toggle_hud"]) [self setHudMode:[_hudMode isEqual:@"full"] ? @"compact" : [_hudMode isEqual:@"compact"] ? @"hidden" : @"full"];
    else if ([action isEqual:@"language"]) {
        NSArray *langs = @[@"en", @"vi", @"auto"];
        NSUInteger i = [langs indexOfObject:_language];
        _language = langs[(i == NSNotFound ? 0 : i + 1) % langs.count];
        [self toast:[NSString stringWithFormat:@"Voice language: %@", _language] kind:@"info"];
        [self pushState]; [self rebuildMenu];
    } else if ([action hasPrefix:@"keys:"]) {
        [self keys:[[action substringFromIndex:5] componentsSeparatedByString:@","]];
    } else if ([action hasPrefix:@"text:"]) {
        NSString *pane = _snapshot[@"focused_pane_id"];
        if (pane) [self hold:[action substringFromIndex:5] for:pane reason:@"Press ✕ to send it."];
    }
}

#pragma mark - Controller mapping

- (id)bindingFor:(NSString *)button {
    id b = _config[@"buttons"][button];
    return [b isKindOfClass:NSString.class] && [b isEqual:@"none"] ? nil : b;
}

- (void)buttonDown:(NSString *)name {
    [self emit:@"press" data:@{@"button": name}];
    id binding = [self bindingFor:name];
    if ([binding isKindOfClass:NSString.class]) [self perform:binding];
    else if ([binding isKindOfClass:NSDictionary.class]) {
        _pressedAt[name] = @(NSProcessInfo.processInfo.systemUptime);
        [_holdFired removeObject:name];
    }
}

- (void)buttonUp:(NSString *)name {
    id binding = [self bindingFor:name];
    if (![binding isKindOfClass:NSDictionary.class] || !_pressedAt[name]) return;
    [_pressedAt removeObjectForKey:name];
    if (![_holdFired containsObject:name] && binding[@"tap"]) [self perform:binding[@"tap"]];
    [_holdFired removeObject:name];
}

- (void)checkHolds {
    double t = NSProcessInfo.processInfo.systemUptime;
    for (NSString *name in _pressedAt.allKeys) {
        id binding = [self bindingFor:name];
        if ([_holdFired containsObject:name] || ![binding isKindOfClass:NSDictionary.class] || !binding[@"hold"]) continue;
        if (t - _pressedAt[name].doubleValue >= holdSeconds) { [_holdFired addObject:name]; [self perform:binding[@"hold"]]; }
    }
}

static double axis(uint8_t v) { double x = ((double)v - 128.0) / 127.0; return fabs(x) < 0.12 ? 0 : MAX(-1, MIN(1, x)); }

- (void)controllerButtons:(uint32_t)buttons hat:(uint8_t)hat lx:(uint8_t)lx ly:(uint8_t)ly rx:(uint8_t)rx ry:(uint8_t)ry {
    uint32_t talk = _talkMask;
    uint32_t down = buttons & ~_buttons, up = _buttons & ~buttons;
    _buttons = buttons;
    NSArray *names = buttonNames();
    for (NSUInteger i = 0; i < names.count; i++) {
        uint32_t mask = 1u << (4 + i);
        if (mask == talk) {
            if (down & mask) [self emit:@"press" data:@{@"button": names[i]}];
            if (_useSystem) {
                if ((down & mask) && ![self recording]) [self startSystemTake:NO];
                else if ((up & mask) && [self recording] && !_sysHandsFree) [self stopSystemTake];
            }
            continue;   // In controller mode HeadsetMic owns push-to-talk.
        }
        if (down & mask) [self buttonDown:names[i]];
        if (up & mask) [self buttonUp:names[i]];
    }
    uint8_t dir = (hat < 8 && hat % 2 == 0) ? hat / 2 : 8;
    if (dir != _hatDir) {
        _hatDir = dir;
        if (dir < 4) {
            NSString *direction = @[@"up", @"right", @"down", @"left"][dir];
            [self emit:@"press" data:@{@"button": [@"dpad-" stringByAppendingString:direction]}];
            [self buzz:0 weak:40 seconds:0.03];
            [self call:@"pane.go" params:@{@"direction": direction} quiet:YES done:nil];
        }
    }
    _lx = axis(lx); _ly = axis(ly); _rx = axis(rx); _ry = axis(ry);
    // The panel draws the controller live: held buttons, D-pad, sticks in 5 steps.
    NSMutableArray *held = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) if (buttons & (1u << (4 + i))) [held addObject:names[i]];
    NSNumber *(^q)(double) = ^(double v) { return @((NSInteger)lround(v * 2)); };
    NSArray *info = @[held, @(hat), @[q(_lx), q(_ly), q(_rx), q(_ry)]];
    if (![info isEqual:_heldInfo]) { _heldInfo = info; [self writePadState]; }
}

- (void)serviceSticks {
    double t = NSProcessInfo.processInfo.systemUptime;
    // Left stick: arrow keys with key-repeat, for agent menus and pickers.
    NSString *key = nil;
    double mag = MAX(fabs(_lx), fabs(_ly));
    double threshold = _stickKey ? stickOff : stickOn;
    if (mag >= threshold) key = fabs(_lx) > fabs(_ly) ? (_lx > 0 ? @"right" : @"left") : (_ly > 0 ? @"down" : @"up");
    if (!key) { _stickKey = nil; }
    else if (![key isEqual:_stickKey]) { _stickKey = key; _stickNext = t + repeatDelay; [self keys:@[key]]; }
    else if (t >= _stickNext) { _stickNext = t + repeatEvery; [self keys:@[key]]; }
    // Right stick: scroll the focused pane's history.
    if (fabs(_ry) > 0.2 && _scrollPane && t - _lastScroll >= 0.06) {
        _lastScroll = t;
        _scrollCarry += -_ry * _ry * _ry * 6.0 - (_ry > 0 ? 0.5 : -0.5);
        NSInteger lines = (NSInteger)_scrollCarry;
        if (!lines) return;
        _scrollCarry -= lines;
        // Positive carry means up (toward history); terminal.scroll takes negative lines for up.
        [_herdr app:@"terminal.scroll" args:@{@"lines": @(-lines)} reply:nil];
    } else if (fabs(_ry) <= 0.2) _scrollCarry = 0;
}

- (void)sampleLevel {
    double t = NSProcessInfo.processInfo.systemUptime;
    if (![self recording]) { if (_levels.count) { [_levels removeAllObjects]; [self writePadState]; } return; }
    if (t - _lastLevel < 0.08) return;
    _lastLevel = t;
    float level = 0;
    if (_useSystem) level = _pausedAt > 0 ? 0 : _sys.level;
    else level = _mic.capture.frames ? 0.25f + 0.5f * (float)arc4random_uniform(100) / 100.0f : 0.02f;
    if (!_levels) _levels = [NSMutableArray array];
    [_levels addObject:@(round(level * 100) / 100)];
    while (_levels.count > 40) [_levels removeObjectAtIndex:0];
    [self writePadState];
}

- (void)tick {
    [self sampleLevel];
    [_mic service];
    if (_sys.recording && !_sysStopping && NSProcessInfo.processInfo.systemUptime - _sysStarted >= (_sysHandsFree ? 300 : 60)) [self stopSystemTake];
    [self checkHolds];
    [self serviceSticks];
}

#pragma mark - Mac microphone

- (BOOL)recording { return _useSystem ? (_sys.recording || _sysStopping) : _mic.active; }
- (BOOL)handsFreeOn { return _useSystem ? (_sys.recording && _sysHandsFree) : _mic.handsFree; }

- (void)startSystemTake:(BOOL)handsFree {
    if (_transcribing || _sending || _sys.recording || _sysStopping) return;
    _takeTarget = _snapshot[@"focused_pane_id"];
    _sysHandsFree = handsFree;
    [SystemMic requestAccess:^(BOOL granted) {
        if (!granted) {
            self->_takeTarget = nil;
            [self toast:@"Microphone access is off. Allow Herdr Pad in System Settings → Privacy & Security → Microphone." kind:@"error"];
            [self sound:@"Funk"];
            return;
        }
        // Push-to-talk released while the permission prompt was up: nothing to record.
        if (!handsFree && !(self->_buttons & self->_talkMask) && !self->_inject) { self->_takeTarget = nil; return; }
        NSString *error = nil;
        if (![self->_sys start:&error]) {
            self->_takeTarget = nil;
            [self toast:error kind:@"error"]; [self sound:@"Funk"];
            return;
        }
        self->_sysStarted = NSProcessInfo.processInfo.systemUptime;
        [self log:@"system mic on: %@", self->_sys.deviceName];
        NSString *target = self->_takeTarget;
        [self headsetPhase:@"opening" text:@"Opening mic…"];
        self->_takeTarget = target;
        [self headsetPhase:@"recording" text:@"● Recording"];
    }];
}

- (void)stopSystemTake {
    if (!_sys.recording || _sysStopping) return;
    _sysStopping = YES;
    [self headsetPhase:@"finishing" text:@"Finishing recording…"];
    // Keep listening briefly so the last syllable is not cut off.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self->_sysStopping = NO;
        double held = NSProcessInfo.processInfo.systemUptime - self->_sysStarted;
        NSData *original = [self->_sys stop];
        HeadsetTake *take = [HeadsetTake new];
        take.handsFree = self->_sysHandsFree;
        take.original = original;
        VoiceLevel *level = [[VoiceLevel alloc] initWithCaptureWave:original];
        take.wave = level.wave ?: original;
        take.info = @{@"held": @(held), @"seconds": @(original.length > 44 ? (original.length - 44) / 32000.0 : 0),
                      @"level": @(level.levelDB), @"gain": @(level.gainDB)};
        if (!original) take.failure = @"The microphone captured no audio. Check System Settings → Sound → Input.";
        self->_sysHandsFree = NO;
        [self headsetFinished:take];
    });
}

- (void)cancelSystemTake {
    [_sys cancel];
    _sysStopping = NO; _sysHandsFree = NO;
    [self headsetPhase:@"idle" text:@"Recording cancelled"];
}

#pragma mark - Voice

- (void)headsetPhase:(NSString *)phase text:(NSString *)text {
    if ([phase isEqual:@"opening"] && ![_phase isEqual:@"opening"]) {
        _takeTarget = _takeTarget ?: _snapshot[@"focused_pane_id"];
        _takeStarted = NSDate.date.timeIntervalSince1970 * 1000;
        _pausedAt = 0; _pausedTotal = 0;
        [self sound:@"Pop"];
        [self buzz:0 weak:90 seconds:0.06];
    }
    if ([phase isEqual:@"idle"]) { _takeTarget = nil; _pausedAt = 0; _sys.paused = NO; }
    _phase = phase; _phaseText = text;
    [self log:@"phase %@", phase];
    [self pushState]; [self updateLight];
}

- (void)headsetFinished:(HeadsetTake *)take {
    NSString *target = _takeTarget;
    _takeTarget = nil;
    if (take.failure) {
        _phase = @"idle"; _phaseText = @"";
        [self toast:take.failure kind:@"error"]; [self sound:@"Funk"];
        [self pushState]; [self updateLight];
        return;
    }
    if ([take.info[@"seconds"] doubleValue] < 0.35) {
        _phase = @"idle"; [self toast:@"Too short — hold the button while you talk." kind:@"info"];
        [self pushState]; [self updateLight];
        return;
    }
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *file = [dir stringByAppendingPathComponent:@"take.wav"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions: @0700} error:nil] ||
        ![take.wave writeToFile:file atomically:YES]) {
        [self toast:@"Could not save the recording." kind:@"error"]; return;
    }
    _transcribing = YES; _mic.armed = NO;
    _phase = @"transcribing"; _phaseText = @"Transcribing…";
    [self pushState]; [self updateLight];
    NSString *script = resource(@"speech", @"py").path;
    [self transcribe:file script:script then:^(NSString *text, NSString *failure) {
        [fm removeItemAtPath:dir error:nil];
        self->_transcribing = NO; self->_mic.armed = YES;
        self->_phase = @"idle"; self->_phaseText = @"";
        if (failure) { [self toast:failure kind:@"error"]; [self sound:@"Funk"]; [self pushState]; [self updateLight]; return; }
        NSString *clean = cleanTranscript(text);
        if (!clean.length) { [self toast:@"Didn't catch any words. Try again." kind:@"info"]; [self pushState]; [self updateLight]; return; }
        [self deliver:clean to:target ?: self->_snapshot[@"focused_pane_id"]];
    }];
}

- (void)transcribe:(NSString *)file script:(NSString *)script then:(void (^)(NSString *, NSString *))then {
    runProcess(@"/usr/bin/python3", @[script, file, _language ?: @"en"], then);
}

// Agents get the prompt submitted. Shell text is only held as a draft: ✕ runs it.
- (void)deliver:(NSString *)text to:(NSString *)pane {
    [self deliver:text to:pane confirmed:NO];
}

- (void)deliver:(NSString *)text to:(NSString *)pane confirmed:(BOOL)confirmed {
    if (_sending) return;
    [self log:@"deliver %@ -> %@", text, pane];
    NSString *terminal = [self terminalForPane:pane];
    if (!pane || !terminal) { [self hold:text for:pane reason:@"No terminal to send to. Focus one, then press ✕."]; return; }
    NSDictionary *agent = [self agentForPane:pane];
    if ([agent[@"agent_status"] isEqual:@"blocked"]) {
        [self hold:text for:pane reason:@"Agent is waiting on a question. Answer it, then press ✕ to send the draft."];
        return;
    }
    if (!agent && !confirmed) {
        [self hold:text for:pane reason:@"Shell command held. ✕ runs it, ○ drops it."];
        return;
    }
    _sending = YES; _mic.armed = NO;
    [self updateLight];
    [self log:@"call hc send %@", terminal];
    [_herdr hc:@[@"send", @"--timeout", @"10", terminal, text] reply:^(NSDictionary *result, NSString *error) {
        (void)result;
        self->_sending = NO; self->_mic.armed = YES;
        if (error) {
            [self hold:text for:pane reason:[NSString stringWithFormat:@"%@ ✕ retries, ○ discards.", error]];
        } else {
            self->_draft = nil; self->_draftTarget = nil; self->_lastSent = text;
            double now = NSProcessInfo.processInfo.systemUptime;
            self->_combo = (self->_lastSendAt && now - self->_lastSendAt < 600) ? self->_combo + 1 : 1;
            self->_lastSendAt = now;
            self->_score += 100 * self->_combo;
            [self emit:@"sent" data:@{@"text": text, @"target": [self describePane:pane], @"typed": @(!agent)}];
            [self log:@"sent %@", text];
            [self sound:@"Hero"];
            [self buzz:0 weak:140 seconds:0.08];
        }
        [self pushState]; [self updateLight]; [self refreshSoon];
    }];
}

- (void)hold:(NSString *)text for:(NSString *)pane reason:(NSString *)reason {
    _draft = text; _draftTarget = pane;
    [self toast:reason kind:@"alert"];
    [self sound:@"Funk"];
    [self pushState]; [self updateLight];
}

#pragma mark - HID

static void added(void *ctx, IOReturn status, void *sender, IOHIDDeviceRef dev) { (void)sender; if (!status) [(__bridge Pad *)ctx attached:dev]; }
static void gone(void *ctx, IOReturn status, void *sender, IOHIDDeviceRef dev) { (void)status; (void)sender; [(__bridge Pad *)ctx detached:dev]; }
static void report(void *ctx, IOReturn status, void *sender, IOHIDReportType type, uint32_t rid, uint8_t *buf, CFIndex n) {
    (void)sender; (void)type;
    if (!status) [(__bridge Pad *)ctx input:rid bytes:buf size:n];
}

- (void)attached:(IOHIDDeviceRef)device {
    if (_device) return;
    _device = (IOHIDDeviceRef)CFRetain(device);
    _mic.device = _device;
    [_mic resetCapture];
    IOHIDDeviceRegisterInputReportCallback(device, _buffer, sizeof _buffer, report, (__bridge void *)self);
    [self toast:@"Controller connected. Player 1 ready." kind:@"done"];
    [self log:@"attached %@", IOHIDDeviceGetProperty(device, CFSTR(kIOHIDProductIDKey))];
    [self sound:@"Purr"];
    [self buzz:120 weak:120 seconds:0.15];
    [self updateLight]; [self pushState];
}

- (void)detached:(IOHIDDeviceRef)device {
    if (device != _device) return;
    [_mic deviceLost];
    CFRelease(_device); _device = NULL;
    _buttons = 0; _hatDir = 8; _lx = _ly = _rx = _ry = 0;
    [_pressedAt removeAllObjects];
    [self toast:@"Controller disconnected." kind:@"error"];
    [self pushState];
}

- (void)input:(uint32_t)rid bytes:(uint8_t *)bytes size:(CFIndex)n {
    if (!_device) return;
    [_mic receive:rid bytes:bytes size:n];
    Capture *c = _mic.capture;
    if (!c.haveButtons) return;   // a fresh Capture has no button state yet
    if (!_sawInput) { _sawInput = YES; [self log:@"first input report 0x%02x buttons=0x%x hat=%u sticks=%u,%u,%u,%u", rid, c.rawButtons, c.hat, c.lx, c.ly, c.rx, c.ry]; }
    // rawButtons ignores waitForNeutral, so swapping Captures never fakes a release/press.
    [self controllerButtons:c.rawButtons hat:c.hat lx:c.lx ly:c.ly rx:c.rx ry:c.ry];
}

- (void)listen {
    _manager = IOHIDManagerCreate(kCFAllocatorDefault, 0);
    matchBluetoothPads(_manager);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager, added, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager, gone, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn opened = IOHIDManagerOpen(_manager, kIOHIDOptionsTypeNone);
    NSSet *present = CFBridgingRelease(IOHIDManagerCopyDevices(_manager));
    [self log:@"hid open=0x%x devices=%lu", opened, (unsigned long)present.count];
    if (opened != kIOReturnSuccess)
        [self toast:@"Controller access denied. Allow Herdr Pad under Privacy & Security → Input Monitoring." kind:@"error"];
}

#pragma mark - Inject (testing without hardware)

- (void)readInjectedLines {
    _inject = YES;
    __block uint32_t buttons = 0; __block uint8_t hat = 8, lx = 128, ly = 128, rx = 128, ry = 128;
    NSFileHandle *input = NSFileHandle.fileHandleWithStandardInput;
    __block NSMutableString *pending = [NSMutableString string];
    input.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; }); return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            [pending appendString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""];
            NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [pending substringToIndex:nl.location];
                [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                NSArray *w = [line componentsSeparatedByString:@" "];
                NSString *cmd = w.firstObject;
                if ([cmd isEqual:@"press"]) buttons |= ds4Button(w[1]);
                else if ([cmd isEqual:@"release"]) buttons &= ~ds4Button(w[1]);
                else if ([cmd isEqual:@"hat"]) hat = (uint8_t)[w[1] intValue];
                else if ([cmd isEqual:@"stick"] && w.count == 5) { lx = [w[1] intValue]; ly = [w[2] intValue]; rx = [w[3] intValue]; ry = [w[4] intValue]; }
                else if ([cmd isEqual:@"say"]) { [self deliver:[line substringFromIndex:4] to:self->_snapshot[@"focused_pane_id"]]; continue; }
                else if ([cmd isEqual:@"talk"]) { if ([w[1] isEqual:@"on"]) [self startSystemTake:YES]; else [self stopSystemTake]; continue; }
                else if ([cmd isEqual:@"wav"]) {
                    // Run a recorded WAV through the real transcription and delivery path.
                    HeadsetTake *take = [HeadsetTake new];
                    take.original = take.wave = [NSData dataWithContentsOfFile:[line substringFromIndex:4]];
                    if (!take.wave) take.failure = @"WAV not found.";
                    take.info = @{@"seconds": @((take.wave.length > 44 ? take.wave.length - 44 : 0) / 32000.0)};
                    self->_takeTarget = self->_snapshot[@"focused_pane_id"];
                    [self headsetFinished:take];
                    continue;
                }
                else if ([cmd isEqual:@"transcript"]) { [self log:@"clean '%@'", cleanTranscript([line substringFromIndex:11])]; continue; }
                else if ([cmd isEqual:@"state"]) {
                    [self log:@"state ws=%@ tab=%@ pane=%@ zoomed=%@ draft=%@", self->_snapshot[@"focused_workspace_id"], self->_snapshot[@"focused_tab_id"],
                     self->_snapshot[@"focused_pane_id"], [self focusedLayoutZoomed] ? @"yes" : @"no", self->_draft ?: @"-"];
                    continue;
                } else if ([cmd isEqual:@"poll"]) { [self poll]; continue; }
                else if ([cmd isEqual:@"quit"]) { [NSApp terminate:nil]; return; }
                else continue;
                [self controllerButtons:buttons hat:hat lx:lx ly:ly rx:rx ry:ry];
            }
        });
    };
}

- (BOOL)focusedLayoutZoomed {
    for (NSDictionary *l in _snapshot[@"layouts"]) if ([l[@"tab_id"] isEqual:_snapshot[@"focused_tab_id"]]) return [l[@"zoomed"] boolValue];
    return NO;
}

#pragma mark - HUD window and menu

- (void)placePanel {
    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSSize size = NSMakeSize(420, 780);
    NSString *corner = _config[@"hud"][@"corner"] ?: @"bottom-right";
    CGFloat x = [corner hasSuffix:@"left"] ? NSMinX(visible) + 16 : NSMaxX(visible) - size.width - 16;
    CGFloat y = [corner hasPrefix:@"top"] ? NSMaxY(visible) - size.height - 16 : NSMinY(visible) + 16;
    [_panel setFrame:NSMakeRect(x, y, size.width, size.height) display:YES];
}

- (void)setHudMode:(NSString *)mode {
    _hudMode = mode;
    if ([mode isEqual:@"hidden"] || _overlaySuppressed) [_panel orderOut:nil]; else [_panel orderFrontRegardless];
    [self pushState]; [self rebuildMenu];
}

- (void)menuAction:(NSMenuItem *)item {
    NSString *what = item.representedObject;
    if ([what hasPrefix:@"hud:"]) [self setHudMode:[what substringFromIndex:4]];
    else if ([what hasPrefix:@"mic:"]) {
        if ([self recording]) return;
        NSMutableDictionary *c = [_config mutableCopy]; c[@"mic"] = [what substringFromIndex:4]; _config = c;
        _useSystem = [c[@"mic"] isEqual:@"system"];
        _mic.talkButton = _useSystem ? 0 : _talkMask;
        [self toast:_useSystem ? @"Using the Mac's default microphone." : @"Using the controller headset mic." kind:@"info"];
        [self pushState]; [self rebuildMenu];
    }
    else if ([what hasPrefix:@"lang:"]) { _language = [what substringFromIndex:5]; [self pushState]; [self rebuildMenu]; }
    else if ([what isEqual:@"sounds"] || [what isEqual:@"haptics"]) {
        NSMutableDictionary *c = [_config mutableCopy]; c[what] = @(![c[what] boolValue]); _config = c; [self rebuildMenu];
    } else if ([what isEqual:@"config"]) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:configPath()]];
    else if ([what isEqual:@"reload"]) { [self loadConfig]; [self placePanel]; [self toast:@"Config reloaded." kind:@"info"]; [self rebuildMenu]; }
}

- (void)rebuildMenu {
    if (!_status) return;
    NSMenu *menu = [NSMenu new];
    NSMenuItem *(^add)(NSMenu *, NSString *, NSString *, BOOL) = ^(NSMenu *m, NSString *title, NSString *what, BOOL on) {
        NSMenuItem *i = [m addItemWithTitle:title action:@selector(menuAction:) keyEquivalent:@""];
        i.target = self; i.representedObject = what; i.state = on ? NSControlStateValueOn : NSControlStateValueOff;
        return i;
    };
    [menu addItemWithTitle:_device ? @"Controller connected" : @"Controller not connected" action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    for (NSArray *m in @[@[@"Full HUD", @"full"], @[@"Compact HUD", @"compact"], @[@"Hide HUD", @"hidden"]])
        add(menu, m[0], [@"hud:" stringByAppendingString:m[1]], [_hudMode isEqual:m[1]]);
    [menu addItem:NSMenuItem.separatorItem];
    NSMenu *langs = [NSMenu new];
    for (NSArray *l in @[@[@"English", @"en"], @[@"Vietnamese", @"vi"], @[@"Auto-detect", @"auto"]])
        add(langs, l[0], [@"lang:" stringByAppendingString:l[1]], [_language isEqual:l[1]]);
    [menu addItemWithTitle:@"Voice language" action:nil keyEquivalent:@""].submenu = langs;
    NSMenu *mics = [NSMenu new];
    add(mics, @"Mac microphone (default input)", @"mic:system", _useSystem);
    add(mics, @"Controller headset", @"mic:controller", !_useSystem);
    [menu addItemWithTitle:@"Microphone" action:nil keyEquivalent:@""].submenu = mics;
    add(menu, @"Sounds", @"sounds", [_config[@"sounds"] boolValue]);
    add(menu, @"Rumble", @"haptics", [_config[@"haptics"] boolValue]);
    [menu addItem:NSMenuItem.separatorItem];
    add(menu, @"Edit button map…", @"config", NO);
    add(menu, @"Reload config", @"reload", NO);
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit Herdr Pad" action:@selector(terminate:) keyEquivalent:@"q"];
    _status.menu = menu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // One controller owner, whichever build: the first copy holds a lock and
    // any later one exits at once, touching nothing the running copy owns.
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--inject"]) {
        [NSFileManager.defaultManager createDirectoryAtPath:padDir() withIntermediateDirectories:YES attributes:nil error:nil];
        int fd = open([padDir() stringByAppendingPathComponent:@"lock"].fileSystemRepresentation, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0) exit(0);
        // fd stays open for the life of the process; the kernel drops the lock on exit.
    }
    NSArray *args = NSProcessInfo.processInfo.arguments;
    _pressedAt = [NSMutableDictionary dictionary];
    _holdFired = [NSMutableSet set];
    _hatDir = 8;
    _mic = [HeadsetMic new];
    _mic.delegate = self;
    _sys = [SystemMic new];
    [self loadConfig];
    _herdr = [Herdr new];

    _status = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    _status.button.image = [NSImage imageWithSystemSymbolName:@"gamecontroller.fill" accessibilityDescription:@"Herdr Pad"];
    [self rebuildMenu];

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    [cfg.userContentController addScriptMessageHandler:self name:@"pad"];
    _web = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:cfg];
    _web.navigationDelegate = self;
    [_web setValue:@NO forKey:@"drawsBackground"];
    _panel = [[HUDPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 780)
                                         styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered defer:NO];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = NO;
    _panel.level = NSStatusWindowLevel;
    _panel.ignoresMouseEvents = YES;
    _panel.hidesOnDeactivate = NO;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary |
                                NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    _panel.contentView = _web;
    [self placePanel];
    if (![_hudMode isEqual:@"hidden"]) [_panel orderFrontRegardless];
    NSURL *url = resource(@"hud", @"html");
    [_web loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];

    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; [self syncOverlay]; }];
    if ([args containsObject:@"--inject"]) [self readInjectedLines];
    else [self listen];
    _tick = [NSTimer timerWithTimeInterval:0.04 repeats:YES block:^(NSTimer *t) { (void)t; [self tick]; }];
    [NSRunLoop.mainRunLoop addTimer:_tick forMode:NSRunLoopCommonModes];
    _poll = [NSTimer timerWithTimeInterval:0.35 repeats:YES block:^(NSTimer *t) { (void)t; [self poll]; }];
    [NSRunLoop.mainRunLoop addTimer:_poll forMode:NSRunLoopCommonModes];
    [self poll];
    [self log:@"ready"];
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (!message.frameInfo.isMainFrame || ![message.body isKindOfClass:NSDictionary.class]) return;
    if ([message.body[@"action"] isEqual:@"ready"]) { _webReady = YES; [self pushState]; }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigation decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    NSURL *index = resource(@"hud", @"html");
    decision(navigation.request.URL.isFileURL && [navigation.request.URL.path isEqual:index.path] ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [NSFileManager.defaultManager removeItemAtPath:padStatePath() error:nil];
    [_mic cancel];
    [_sys cancel];
    [_mic setLightRed:0 green:0 blue:0x30 flash:NO];
    if (_manager) { IOHIDManagerClose(_manager, 0); CFRelease(_manager); }
    if (_device) CFRelease(_device);
}
@end

static int queueCommand(const char *action) {
    NSString *dir = padDir();
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open([dir stringByAppendingPathComponent:@"command"].fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0600);
    if (fd < 0) return 1;
    dprintf(fd, "%s\n", action);
    close(fd);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 3 && !strcmp(argv[1], "--send")) return queueCommand(argv[2]);
        if (argc >= 2 && !strcmp(argv[1], "--detach")) {
            // Start a background copy in its own session so it outlives
            // whoever launched it (a Herdr mod reload, a closed terminal).
            pid_t child = fork();
            if (child < 0) return 1;
            if (child > 0) return 0;
            setsid();
            NSString *log = [padDir() stringByAppendingPathComponent:@"herdr-pad.log"];
            [NSFileManager.defaultManager createDirectoryAtPath:padDir() withIntermediateDirectories:YES attributes:nil error:nil];
            int out = open(log.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC, 0600), in = open("/dev/null", O_RDONLY);
            if (in >= 0) dup2(in, 0);
            if (out >= 0) { dup2(out, 1); dup2(out, 2); }
            NSString *me = executablePath();
            char *args[] = {(char *)me.fileSystemRepresentation, NULL};
            execv(args[0], args);
            _exit(1);
        }
        setlinebuf(stdout);
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        __attribute__((objc_precise_lifetime)) Pad *delegate = [Pad new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
