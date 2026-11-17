#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import "HeadsetMic.h"

typedef void (^CommandReply)(NSString *output, NSString *failure);

static void command(NSString *program, NSArray<NSString *> *args, CommandReply reply) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSTask *task = [NSTask new];
            NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
            env[@"PATH"] = [NSString stringWithFormat:@"%@/.local/bin:/opt/homebrew/bin:/usr/local/bin:%@",
                            NSHomeDirectory(),env[@"PATH"] ?: @"/usr/bin:/bin"];
            task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/env"];
            task.arguments = [@[program] arrayByAddingObjectsFromArray:args];
            task.environment = env;
            NSPipe *out = [NSPipe pipe];
            task.standardOutput = out;
            NSString *log = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            [NSFileManager.defaultManager createFileAtPath:log contents:nil attributes:@{NSFilePosixPermissions:@0600}];
            NSFileHandle *errors = [NSFileHandle fileHandleForWritingAtPath:log];
            task.standardError = errors ?: NSFileHandle.fileHandleWithNullDevice;
            NSError *error = nil;
            NSString *result = @"", *failure = nil;
            if ([task launchAndReturnError:&error]) {
                NSData *data = [out.fileHandleForReading readDataToEndOfFile];
                [task waitUntilExit];
                result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
                if (task.terminationStatus) {
                    NSString *msg = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil];
                    NSArray *lines = [[msg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsSeparatedByString:@"\n"];
                    failure = [lines.lastObject length] ? lines.lastObject : [program stringByAppendingString:@" failed."];
                }
            } else failure = error.localizedDescription;
            [errors closeFile];
            [NSFileManager.defaultManager removeItemAtPath:log error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ reply(result,failure); });
        }
    });
}

@interface Playground : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, HeadsetMicDelegate> {
    NSWindow *_window;
    WKWebView *_web;
    IOHIDManagerRef _manager;
    IOHIDDeviceRef _device;
    uint8_t _buffer[1024];
    HeadsetMic *_mic;
    NSDictionary *_bindings;
    NSString *_language;
    NSSet *_targets;
    BOOL _ready, _recognizing, _sending;
    double _lastDraw;
    uint32_t _shownButtons, _shownAxes;
    uint8_t _shownHat;
    NSTimer *_timer;
    NSUInteger _listRevision;
}
- (void)attached:(IOHIDDeviceRef)device;
- (void)detached:(IOHIDDeviceRef)device;
- (void)input:(uint32_t)rid bytes:(uint8_t *)bytes size:(CFIndex)n;
@end

static void added(void *ctx, IOReturn status, void *sender, IOHIDDeviceRef dev) {
    (void)sender;
    if (!status) [(__bridge Playground *)ctx attached:dev];
}
static void gone(void *ctx, IOReturn status, void *sender, IOHIDDeviceRef dev) {
    (void)status; (void)sender;
    [(__bridge Playground *)ctx detached:dev];
}
static void report(void *ctx, IOReturn status, void *sender, IOHIDReportType type, uint32_t rid, uint8_t *buf, CFIndex n) {
    (void)sender; (void)type;
    if (!status) [(__bridge Playground *)ctx input:rid bytes:buf size:n];
}

@implementation Playground
- (void)emit:(NSString *)kind data:(NSDictionary *)data {
    if (!_ready) return;
    NSMutableDictionary *event = [data mutableCopy]; event[@"kind"] = kind;
    [_web callAsyncJavaScript:@"window.playgroundEvent(event)" arguments:@{@"event":event}
                     inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
}
- (void)error:(NSString *)text { [self emit:@"error" data:@{@"text":text}]; }
- (void)phase:(NSString *)phase text:(NSString *)text { [self emit:@"phase" data:@{@"phase":phase,@"text":text}]; }
- (void)connection {
    [self emit:@"connection" data:@{@"connected":@(_device != NULL),@"text":_device ? @"Controller connected" : @"Controller disconnected"}];
}
- (void)resetCapture {
    _mic.talkButton = ds4Button(_bindings[@"talk"]);
    _mic.armed = !(_recognizing || _sending);
}
- (void)headsetPhase:(NSString *)phase text:(NSString *)text { [self phase:phase text:text]; }
- (void)headsetFinished:(HeadsetTake *)take {
    NSMutableDictionary *info = [take.info mutableCopy];
    if (take.original) {
        info[@"original"] = [take.original base64EncodedStringWithOptions:0];
        if ([take.info[@"gain"] doubleValue] > 0) info[@"adjusted"] = [take.wave base64EncodedStringWithOptions:0];
    }
    [self emit:@"take" data:info];
    _recognizing = take.wave && !take.failure;
    [self resetCapture];
    if (!_recognizing) {
        [self phase:@"idle" text:@"Headset idle"];
        [self error:take.failure];
        return;
    }
    NSData *wave = take.wave;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *file = [dir stringByAppendingPathComponent:@"take.wav"];
    NSError *error = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error] ||
        ![wave writeToFile:file options:NSDataWritingAtomic error:&error]) {
        _recognizing = NO; [self resetCapture]; [self phase:@"idle" text:@"Headset idle"]; [self error:error.localizedDescription];
        [fm removeItemAtPath:dir error:nil]; return;
    }
    [self phase:@"transcribing" text:@"Transcribing locally…"];
    NSString *script = [NSBundle.mainBundle pathForResource:@"speech" ofType:@"py"];
    command(@"/usr/bin/python3",@[script,file,_language],^(NSString *out, NSString *failure){
        [fm removeItemAtPath:dir error:nil]; self->_recognizing = NO; [self resetCapture];
        if (failure) { [self phase:@"idle" text:@"Headset idle"]; [self error:failure]; }
        else [self emit:@"transcript" data:@{@"text":[out stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]}];
    });
}
- (void)input:(uint32_t)rid bytes:(uint8_t *)bytes size:(CFIndex)n {
    if (!_device) return;
    [_mic receive:rid bytes:bytes size:n];
    Capture *c = _mic.capture;
    double now = NSProcessInfo.processInfo.systemUptime;
    uint32_t axes = (c.lx << 0) | (c.ly << 8) | (c.rx << 16) | ((uint32_t)c.ry << 24);
    if (c.buttons != _shownButtons || c.hat != _shownHat || (axes != _shownAxes && now-_lastDraw > 0.033)) {
        _shownButtons = c.buttons; _shownHat = c.hat; _shownAxes = axes; _lastDraw = now;
        [self emit:@"input" data:@{@"buttons":@(_shownButtons),@"hat":@(_shownHat),@"axes":@[@(c.lx),@(c.ly),@(c.rx),@(c.ry)]}];
    }
}
- (void)attached:(IOHIDDeviceRef)device {
    if (_device) return;
    _device = (IOHIDDeviceRef)CFRetain(device); _mic.device = _device; [self resetCapture];
    _shownButtons = UINT32_MAX;
    IOHIDDeviceRegisterInputReportCallback(device,_buffer,sizeof(_buffer),report,(__bridge void *)self);
    [self connection];
}
- (void)detached:(IOHIDDeviceRef)device {
    if (_device != device) return;
    [_mic deviceLost];
    CFRelease(_device); _device = NULL;
    [self connection];
}
- (void)listen {
    if (_manager) { [self connection]; return; }
    _manager = IOHIDManagerCreate(kCFAllocatorDefault,0); matchBluetoothPads(_manager);
    IOHIDManagerRegisterDeviceMatchingCallback(_manager,added,(__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(_manager,gone,(__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_manager,CFRunLoopGetMain(),kCFRunLoopCommonModes);
    IOReturn result = IOHIDManagerOpen(_manager,kIOHIDOptionsTypeNone);
    [self connection];
    if (result) [self error:@"Controller access failed. Check Input Monitoring in System Settings and reopen the playground."];
    _timer = [NSTimer timerWithTimeInterval:0.04 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        [self serviceMicrophone];
    }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)serviceMicrophone { [_mic service]; }
- (void)listTargets:(BOOL)explicit {
    NSUInteger revision = ++_listRevision;
    command(@"herdr",@[@"agent",@"list"],^(NSString *out, NSString *failure){
        if (revision != self->_listRevision) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[out dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSMutableArray *rows = [NSMutableArray array]; NSMutableSet *ids = [NSMutableSet set];
        for (NSDictionary *a in json[@"result"][@"agents"]) {
            NSString *pid = a[@"pane_id"]; if (!pid.length) continue;
            NSString *name = [NSString stringWithFormat:@"%@ · %@ (%@)",[a[@"cwd"] lastPathComponent] ?: @"Project",a[@"agent"] ?: @"agent",pid];
            [ids addObject:pid]; [rows addObject:@{@"id":pid,@"name":name}];
        }
        self->_targets = ids;
        NSString *msg = explicit ? (failure ?: (rows.count ? @"Herdr destinations refreshed." : @"No live Herdr agents found.")) : @"";
        [self emit:@"targets" data:@{@"agents":rows,@"message":msg}];
    });
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (!message.frameInfo.isMainFrame || ![message.body isKindOfClass:NSDictionary.class]) return;
    NSDictionary *m = message.body; NSString *action = m[@"action"];
    if ([action isEqual:@"ready"]) {
        _ready = YES; [self emit:@"settings" data:@{@"bindings":_bindings,@"language":_language}]; [self listen]; [self listTargets:NO];
    } else if ([action isEqual:@"bindings"] && !_mic.active) {
        NSDictionary *b = m[@"bindings"];
        if (![b isKindOfClass:NSDictionary.class] || b.count!=3 || [NSSet setWithArray:b.allValues].count!=3) return;
        for (NSString *key in @[@"talk",@"submit",@"clear"]) if (![b[key] isKindOfClass:NSString.class] || !ds4Button(b[key])) return;
        _bindings = b; [NSUserDefaults.standardUserDefaults setObject:b forKey:@"bindings"]; [self resetCapture];
    } else if ([action isEqual:@"language"] && [@[@"en",@"vi",@"auto"] containsObject:m[@"value"]]) {
        _language = m[@"value"]; [NSUserDefaults.standardUserDefaults setObject:_language forKey:@"language"];
    } else if ([action isEqual:@"targets"]) [self listTargets:YES];
    else if ([action isEqual:@"send"]) {
        NSString *target = m[@"target"], *text = m[@"text"];
        if (_sending) return;
        if (![_targets containsObject:target] || ![text isKindOfClass:NSString.class] || !text.length) {
            [self emit:@"sent" data:@{@"ok":@NO,@"text":@"Select a live Herdr target and enter a prompt."}]; return;
        }
        _sending = YES; [self resetCapture];
        command(@"herdr",@[@"agent",@"prompt",target,text],^(NSString *out, NSString *failure){
            (void)out;
            self->_sending = NO; [self resetCapture];
            [self emit:@"sent" data:@{@"ok":@(!failure),@"text":failure ?: text,@"target":target}];
        });
    }
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _bindings = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"bindings"] ?: @{@"talk":@"l1",@"submit":@"cross",@"clear":@"circle"};
    _language = [NSUserDefaults.standardUserDefaults stringForKey:@"language"] ?: @"en";
    _mic = [HeadsetMic new]; _mic.delegate = self;
    NSMenu *menu = [NSMenu new], *app = [NSMenu new], *edit = [NSMenu new];
    [menu addItemWithTitle:@"Playground" action:nil keyEquivalent:@""].submenu=app;
    [app addItemWithTitle:@"Quit DualShock Playground" action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItemWithTitle:@"Edit" action:nil keyEquivalent:@""].submenu=edit;
    for (NSArray *r in @[@[@"Undo",@"undo:",@"z"],@[@"Cut",@"cut:",@"x"],@[@"Copy",@"copy:",@"c"],@[@"Paste",@"paste:",@"v"],@[@"Select All",@"selectAll:",@"a"]])
        [edit addItemWithTitle:r[0] action:NSSelectorFromString(r[1]) keyEquivalent:r[2]];
    NSApp.mainMenu=menu;
    WKWebViewConfiguration *cfg=[WKWebViewConfiguration new];
    [cfg.userContentController addScriptMessageHandler:self name:@"playground"];
    _web=[[WKWebView alloc] initWithFrame:NSZeroRect configuration:cfg]; _web.navigationDelegate=self;
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1000,660) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"DualShock Playground"; _window.contentMinSize=NSMakeSize(790,575); _window.contentView=_web;
    [_window center]; [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    NSURL *url=[NSBundle.mainBundle URLForResource:@"index" withExtension:@"html"];
    [_web loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigation decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    NSURL *index=[NSBundle.mainBundle URLForResource:@"index" withExtension:@"html"];
    decision([navigation.request.URL.path isEqual:index.path] && navigation.request.URL.isFileURL ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    [_timer invalidate]; [_mic cancel];
    if (_manager) { IOHIDManagerClose(_manager,0); CFRelease(_manager); }
    if (_device) CFRelease(_device);
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) Playground *delegate = [Playground new];
        app.delegate=delegate; [app run];
    }
    return 0;
}
