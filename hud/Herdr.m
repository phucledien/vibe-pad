#import "Herdr.h"

static NSString *findTool(NSString *name) {
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:[NSHomeDirectory() stringByAppendingPathComponent:@".local/bin"],
                            @"/opt/homebrew/bin", @"/usr/local/bin", nil];
    [dirs addObjectsFromArray:[NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"]];
    for (NSString *dir in dirs) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) return path;
    }
    return nil;
}

// Runs a tool and parses its JSON output. Both CLIs print {"error": ...} and exit nonzero on failure.
static NSString *runJSON(NSString *tool, NSArray *args, id *json) {
    NSString *path = findTool(tool);
    if (!path) return [NSString stringWithFormat:@"%@ not found. Is the Herdr app installed?", tool];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = args;
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    task.standardOutput = out; task.standardError = err;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    // Act as the person, not as whatever terminal launched this app: hc would
    // otherwise tag sends as <hc from="tN"> notes from that terminal.
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    for (NSString *key in env.allKeys) if ([key hasPrefix:@"HC_"]) [env removeObjectForKey:key];
    task.environment = env;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return error.localizedDescription;
    NSData *data = [out.fileHandleForReading readDataToEndOfFile];
    NSData *errData = [err.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    // hc prints its {"error": ...} object on stderr.
    if (!parsed && errData.length) parsed = [NSJSONSerialization JSONObjectWithData:errData options:0 error:nil];
    *json = parsed;
    id problem = [parsed isKindOfClass:NSDictionary.class] ? parsed[@"error"] : nil;
    if (problem) {
        if ([problem isKindOfClass:NSDictionary.class]) return problem[@"message"] ?: @"Herdr reported an error.";
        return [problem description];
    }
    if (task.terminationStatus) {
        NSString *msg = [[NSString alloc] initWithData:errData.length ? errData : data encoding:NSUTF8StringEncoding];
        msg = [msg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return msg.length ? [msg componentsSeparatedByString:@"\n"].lastObject : [tool stringByAppendingString:@" failed."];
    }
    return nil;
}

static NSInteger urgency(NSString *status) {
    NSArray *order = @[@"idle", @"working", @"done", @"blocked"];
    NSUInteger i = [order indexOfObject:status ?: @""];
    return i == NSNotFound ? -1 : (NSInteger)i;
}
static NSString *mostUrgent(NSArray<NSString *> *statuses) {
    NSString *best = @"unknown";
    for (NSString *s in statuses) if (urgency(s) > urgency(best)) best = s;
    return best;
}

@implementation Herdr {
    dispatch_queue_t _queue;
}

- (instancetype)init {
    if ((self = [super init])) _queue = dispatch_queue_create("herdr.cli", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)finish:(HerdrReply)reply result:(id)result error:(NSString *)error {
    if (!reply) return;
    NSDictionary *dict = [result isKindOfClass:NSDictionary.class] ? result : (result ? @{@"value": result} : nil);
    dispatch_async(dispatch_get_main_queue(), ^{ reply(dict, error); });
}

- (void)app:(NSString *)command args:(NSDictionary *)args reply:(HerdrReply)reply {
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:args ?: @{} options:0 error:nil]
                                           encoding:NSUTF8StringEncoding];
    dispatch_async(_queue, ^{
        id result = nil;
        NSString *error = runJSON(@"herdr-app", @[@"do", command, json], &result);
        [self finish:reply result:result error:error];
    });
}

- (void)hc:(NSArray<NSString *> *)args reply:(HerdrReply)reply {
    dispatch_async(_queue, ^{
        id result = nil;
        NSArray *full = [@[args.firstObject] arrayByAddingObjectsFromArray:[@[@"--json"] arrayByAddingObjectsFromArray:
                         [args subarrayWithRange:NSMakeRange(1, args.count - 1)]]];
        NSString *error = runJSON(@"hc", full, &result);
        [self finish:reply result:result error:error];
    });
}

// Normalised shape (ids are the app's): focused_workspace_id, focused_tab_id, focused_pane_id,
// workspaces[{workspace_id, number, label, agent_status}], tabs[{tab_id, workspace_id, number, label, agent_status}],
// panes[{pane_id, terminal, tab_id, cwd}], layouts[{tab_id, area, panes[{pane_id, rect}], zoomed}],
// agents[{pane_id, terminal, agent, agent_status, terminal_title_stripped}].
- (void)snapshot:(HerdrReply)reply {
    dispatch_async(_queue, ^{
        NSDictionary *ls = nil, *status = nil, *core = nil;
        NSString *error = runJSON(@"herdr-app", @[@"ls"], &ls);
        if (!error) error = runJSON(@"herdr-app", @[@"status"], &status);
        if (error) { [self finish:reply result:nil error:error]; return; }
        runJSON(@"hc", @[@"ls", @"--json"], &core);   // cwd per terminal; optional
        NSMutableDictionary *cwd = [NSMutableDictionary dictionary];
        for (NSDictionary *t in core[@"terminals"]) if (t[@"address"] && t[@"cwd"]) cwd[t[@"address"]] = t[@"cwd"];

        NSMutableArray *workspaces = [NSMutableArray array], *tabs = [NSMutableArray array], *panes = [NSMutableArray array];
        NSMutableArray *layouts = [NSMutableArray array], *agents = [NSMutableArray array];
        NSString *focusedPane = status[@"focused_pane"];
        NSInteger spaceNumber = 0;
        for (NSDictionary *space in ls[@"spaces"]) {
            NSMutableArray *spaceStatuses = [NSMutableArray array];
            NSInteger tabNumber = 0;
            for (NSDictionary *tab in space[@"tabs"]) {
                if ([tab[@"settled"] boolValue]) continue;
                NSMutableArray *tabStatuses = [NSMutableArray array], *rects = [NSMutableArray array];
                NSArray *terms = tab[@"terminals"];
                NSInteger i = 0;
                for (NSDictionary *t in terms) {
                    NSString *pane = t[@"pane"], *address = t[@"terminal"];
                    if (!pane) continue;
                    [panes addObject:@{@"pane_id": pane, @"terminal": address ?: @"", @"tab_id": tab[@"id"],
                                       @"workspace_id": space[@"id"], @"cwd": cwd[address] ?: space[@"folder"] ?: @""}];
                    // The app does not publish geometry; show panes side by side.
                    [rects addObject:@{@"pane_id": pane, @"rect": @{@"x": @(i * 10), @"y": @0, @"width": @10, @"height": @10}}];
                    i++;
                    NSString *s = [t[@"status"] isKindOfClass:NSString.class] ? t[@"status"] : nil;
                    if (s) {
                        [tabStatuses addObject:s];
                        [agents addObject:@{@"pane_id": pane, @"terminal": address ?: @"", @"agent": t[@"app"] ?: t[@"name"] ?: @"agent",
                                            @"agent_status": s, @"terminal_title_stripped": t[@"name"] ?: @""}];
                    }
                }
                [spaceStatuses addObjectsFromArray:tabStatuses];
                [layouts addObject:@{@"tab_id": tab[@"id"], @"area": @{@"width": @(MAX(1, i) * 10), @"height": @10},
                                     @"panes": rects, @"zoomed": @NO}];
                [tabs addObject:@{@"tab_id": tab[@"id"], @"workspace_id": space[@"id"], @"number": @(++tabNumber),
                                  @"label": tab[@"name"] ?: @"", @"agent_status": mostUrgent(tabStatuses)}];
            }
            [workspaces addObject:@{@"workspace_id": space[@"id"], @"number": @(++spaceNumber), @"label": space[@"name"] ?: @"",
                                    @"agent_status": mostUrgent(spaceStatuses)}];
        }
        NSDictionary *snapshot = @{@"focused_workspace_id": status[@"space"] ?: @"", @"focused_tab_id": status[@"tab"] ?: @"",
                                   @"focused_pane_id": focusedPane ?: @"", @"workspaces": workspaces, @"tabs": tabs,
                                   @"panes": panes, @"layouts": layouts, @"agents": agents, @"layout_name": status[@"layout"] ?: @""};
        [self finish:reply result:@{@"snapshot": snapshot} error:nil];
    });
}
@end
