#import <Cocoa/Cocoa.h>

#ifndef APP_STORE_BUILD
#define APP_STORE_BUILD 0
#endif

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#if !APP_STORE_BUILD
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>
#endif
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <sys/sysctl.h>
#if !APP_STORE_BUILD
#import <libproc.h>
#endif
#import <mach/mach.h>
#import <mach/processor_info.h>
#import <mach/mach_host.h>
#import <math.h>

static NSString *FormatBytes(double bytes) {
    if (bytes >= 1e9) return [NSString stringWithFormat:@"%.1f GB", bytes / 1e9];
    if (bytes >= 1e6) return [NSString stringWithFormat:@"%.1f MB", bytes / 1e6];
    if (bytes >= 1e3) return [NSString stringWithFormat:@"%.0f KB", bytes / 1e3];
    return [NSString stringWithFormat:@"%.0f B", bytes];
}

static NSString *FormatRate(double bytes) {
    return [FormatBytes(bytes) stringByAppendingString:@"/s"];
}

static NSString *CompactRemainingTime(NSString *time) {
    if (!time.length) return nil;
    return [[[time stringByReplacingOccurrencesOfString:@" h " withString:@"h"]
             stringByReplacingOccurrencesOfString:@" min" withString:@"m"]
            stringByReplacingOccurrencesOfString:@" " withString:@""];
}

static NSColor *PanelTextPrimary(void) { return [NSColor colorWithWhite:0.96 alpha:1.0]; }
static NSColor *PanelTextSecondary(void) { return [NSColor colorWithWhite:0.80 alpha:1.0]; }
#if !APP_STORE_BUILD
static NSColor *PanelTextTertiary(void) { return [NSColor colorWithWhite:0.65 alpha:1.0]; }
#endif

typedef struct { uint64_t user, system, idle, nice; } CPUState;

@interface MonitorSnapshot : NSObject
@property NSInteger cpu, memoryPercent, batteryPercent, batteryHealth, cycles;
@property NSInteger thermalState;
@property double memoryUsed, memoryTotal, memoryActive, memoryWired, memoryCompressed, swapUsed;
@property double diskUsed, diskTotal, networkDown, networkUp, batteryWatts;
@property BOOL hasBattery, charging, onAC;
@property(copy) NSString *timeRemaining;
#if !APP_STORE_BUILD
@property NSArray *processes;
#endif
@end
@implementation MonitorSnapshot @end

#if !APP_STORE_BUILD
@interface ProcessSample : NSObject
@property(copy) NSString *name;
@property NSInteger pid;
@property double cpu, memory;
@end
@implementation ProcessSample @end
#endif

@interface SystemMonitor : NSObject
@property CPUState previousCPU;
@property BOOL hasPreviousCPU, hasNetwork;
@property uint64_t previousDown, previousUp;
@property NSTimeInterval previousNetworkTime;
#if !APP_STORE_BUILD
@property NSMutableDictionary<NSNumber *, NSNumber *> *processTimes;
@property NSTimeInterval previousProcessTime;
#endif
- (MonitorSnapshot *)snapshot;
@end

@implementation SystemMonitor
- (NSInteger)cpuUsage {
    processor_info_array_t info = NULL;
    mach_msg_type_number_t count = 0;
    natural_t cpuCount = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &count) != KERN_SUCCESS || !info) return 0;
    CPUState now = {0,0,0,0};
    for (natural_t cpu = 0; cpu < cpuCount; cpu++) {
        NSInteger base = cpu * CPU_STATE_MAX;
        now.user += info[base + CPU_STATE_USER]; now.system += info[base + CPU_STATE_SYSTEM];
        now.idle += info[base + CPU_STATE_IDLE]; now.nice += info[base + CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, count * sizeof(integer_t));
    NSInteger value = 0;
    if (self.hasPreviousCPU) {
        uint64_t total = (now.user + now.system + now.idle + now.nice) -
                         (self.previousCPU.user + self.previousCPU.system + self.previousCPU.idle + self.previousCPU.nice);
        uint64_t busy = (now.user + now.system + now.nice) -
                        (self.previousCPU.user + self.previousCPU.system + self.previousCPU.nice);
        if (total) value = llround((double)busy / total * 100.0);
    }
    self.previousCPU = now; self.hasPreviousCPU = YES;
    return MIN(100, MAX(0, value));
}

- (void)fillMemory:(MonitorSnapshot *)s {
    vm_statistics64_data_t st; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&st, &count) != KERN_SUCCESS) return;
    double page = vm_kernel_page_size;
    s.memoryActive = st.active_count * page;
    s.memoryWired = st.wire_count * page;
    s.memoryCompressed = st.compressor_page_count * page;
    s.memoryUsed = s.memoryActive + s.memoryWired + s.memoryCompressed;
    s.memoryTotal = NSProcessInfo.processInfo.physicalMemory;
    s.memoryPercent = s.memoryTotal ? llround(s.memoryUsed / s.memoryTotal * 100.0) : 0;
    struct xsw_usage swap = {0}; size_t size = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &size, NULL, 0) == 0) s.swapUsed = swap.xsu_used;
}

- (void)fillDisk:(MonitorSnapshot *)s {
    NSDictionary *a = [NSFileManager.defaultManager attributesOfFileSystemForPath:@"/" error:nil];
    s.diskTotal = [a[NSFileSystemSize] doubleValue];
    double free = [a[NSFileSystemFreeSize] doubleValue];
    s.diskUsed = MAX(0, s.diskTotal - free);
}

- (void)fillNetwork:(MonitorSnapshot *)s {
    struct ifaddrs *list = NULL; uint64_t down = 0, up = 0;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *p = list; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK || (p->ifa_flags & IFF_LOOPBACK)) continue;
            struct if_data *d = (struct if_data *)p->ifa_data;
            if (d) { down += d->ifi_ibytes; up += d->ifi_obytes; }
        }
        freeifaddrs(list);
    }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.hasNetwork) {
        double dt = MAX(.1, now - self.previousNetworkTime);
        s.networkDown = down >= self.previousDown ? (down - self.previousDown) / dt : 0;
        s.networkUp = up >= self.previousUp ? (up - self.previousUp) / dt : 0;
    }
    self.previousDown = down; self.previousUp = up; self.previousNetworkTime = now; self.hasNetwork = YES;
}

- (void)fillBattery:(MonitorSnapshot *)s {
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    CFArrayRef sources = info ? IOPSCopyPowerSourcesList(info) : NULL;
    if (sources && CFArrayGetCount(sources)) {
        CFDictionaryRef d = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(sources, 0));
        NSDictionary *b = (__bridge NSDictionary *)d;
        NSInteger cur = [b[@kIOPSCurrentCapacityKey] integerValue], max = [b[@kIOPSMaxCapacityKey] integerValue];
        s.hasBattery = YES; s.batteryPercent = max > 0 ? llround((double)cur / max * 100.0) : cur;
        NSString *state = b[@kIOPSPowerSourceStateKey];
        s.onAC = [state isEqualToString:@kIOPSACPowerValue];
        s.charging = [b[@kIOPSIsChargingKey] boolValue];
        NSNumber *minutes = b[@kIOPSTimeToEmptyKey];
        s.timeRemaining = minutes.integerValue > 0 ? [NSString stringWithFormat:@"%ld h %02ld min", (long)(minutes.integerValue/60), (long)(minutes.integerValue%60)] : nil;
    }
    if (sources) CFRelease(sources); if (info) CFRelease(info);

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            NSDictionary *p = CFBridgingRelease(props);
            double amps = fabs([p[@"Amperage"] doubleValue]);
            double volts = [p[@"Voltage"] doubleValue];
            if (amps > 0 && volts > 0) s.batteryWatts = amps * volts / 1000000.0;
            NSInteger design = [p[@"DesignCapacity"] integerValue], maximum = [p[@"AppleRawMaxCapacity"] integerValue];
            if (!maximum) maximum = [p[@"MaxCapacity"] integerValue];
            if (design > 0 && maximum > 0) s.batteryHealth = MIN(100, llround((double)maximum / design * 100.0));
            s.cycles = [p[@"CycleCount"] integerValue];
        }
        IOObjectRelease(service);
    }
}

#if !APP_STORE_BUILD
- (void)fillProcesses:(MonitorSnapshot *)s {
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) { s.processes = @[]; return; }
    pid_t *pids = calloc(1, bytes);
    int count = proc_listpids(PROC_ALL_PIDS, 0, pids, bytes) / sizeof(pid_t);
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    double interval = self.previousProcessTime > 0 ? MAX(.1, now - self.previousProcessTime) : 0;
    NSMutableDictionary *newTimes = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, ProcessSample *> *grouped = [NSMutableDictionary dictionary];
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i]; if (pid <= 0) continue;
        struct proc_taskinfo ti = {0};
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) != sizeof(ti)) continue;
        char name[PROC_PIDPATHINFO_MAXSIZE] = {0}; proc_name(pid, name, sizeof(name));
        if (!name[0]) continue;
        char pathBuffer[PROC_PIDPATHINFO_MAXSIZE] = {0}; proc_pidpath(pid, pathBuffer, sizeof(pathBuffer));
        NSString *path = pathBuffer[0] ? [NSString stringWithUTF8String:pathBuffer] : @"";
        NSString *displayName = [NSString stringWithUTF8String:name];
        NSRange appRange = [path rangeOfString:@".app/Contents/"];
        if (appRange.location != NSNotFound) {
            NSString *appPath = [path substringToIndex:appRange.location + 4];
            displayName = appPath.lastPathComponent.stringByDeletingPathExtension;
        } else if ([path containsString:@"/.vscode/"] && [displayName.lowercaseString containsString:@"claude"]) {
            displayName = @"Claude (VS Code)";
        }
        if ([displayName isEqualToString:@"com.apple.WebKit.WebContent"]) displayName = @"WebKit — websites/apps";
        else if ([displayName isEqualToString:@"peopled"]) displayName = @"Contacts & Suggestions (system)";
        else if ([displayName isEqualToString:@"CallHistorySyncHelper"]) displayName = @"Call History (system)";
        else if ([displayName isEqualToString:@"node"]) displayName = @"Node.js — developer tools";
        uint64_t total = ti.pti_total_user + ti.pti_total_system;
        NSNumber *key = @(pid); newTimes[key] = @(total);
        ProcessSample *p = grouped[displayName];
        if (!p) { p = [ProcessSample new]; p.pid = pid; p.name = displayName; grouped[displayName] = p; }
        p.memory += ti.pti_resident_size;
        NSNumber *old = self.processTimes[key];
        if (old && interval > 0 && total >= old.unsignedLongLongValue) p.cpu += (double)(total - old.unsignedLongLongValue) / 1e9 / interval * 100.0;
    }
    free(pids); self.processTimes = newTimes; self.previousProcessTime = now;
    NSMutableArray *samples = [grouped.allValues mutableCopy];
    [samples sortUsingComparator:^NSComparisonResult(ProcessSample *a, ProcessSample *b) {
        double scoreA = a.cpu * 1e9 + a.memory, scoreB = b.cpu * 1e9 + b.memory;
        return scoreA > scoreB ? NSOrderedAscending : scoreA < scoreB ? NSOrderedDescending : NSOrderedSame;
    }];
    s.processes = [samples subarrayWithRange:NSMakeRange(0, MIN(30, samples.count))];
}
#endif

- (MonitorSnapshot *)snapshot {
    MonitorSnapshot *s = [MonitorSnapshot new];
    s.cpu = [self cpuUsage]; [self fillMemory:s]; [self fillDisk:s]; [self fillNetwork:s]; [self fillBattery:s];
#if !APP_STORE_BUILD
    [self fillProcesses:s];
#endif
    s.thermalState = NSProcessInfo.processInfo.thermalState;
    return s;
}
@end

@interface DashboardView : NSView
@property MonitorSnapshot *data;
@property NSMutableArray<NSNumber *> *cpuHistory, *ramHistory, *downHistory, *upHistory;
#if !APP_STORE_BUILD
@property NSInteger processSortMode;
#endif
#if !APP_STORE_BUILD
@property(copy) void (^optimizeHandler)(void);
#endif
@property(copy) void (^languageChangedHandler)(BOOL polish);
#if !APP_STORE_BUILD
@property BOOL optimizing;
#endif
@property BOOL polish, languageAnimating;
@property NSInteger theme;
@property BOOL themePickerOpen;
@property double themeToastStart;
@property double languageThumb, languageFrom, languageTo, languageAnimationStart;
@property NSTimer *languageTimer;
#if !APP_STORE_BUILD
@property double optimizedBytes, animationStart, animationSeed;
@property NSTimer *animationTimer;
#endif
- (void)accept:(MonitorSnapshot *)data;
#if !APP_STORE_BUILD
- (void)startOptimization;
- (void)finishOptimization:(double)bytes;
#endif
- (void)setPolishAnimated:(BOOL)polish;
- (void)setThemeAnimated:(NSInteger)theme;
@end

@implementation DashboardView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.wantsLayer = YES; self.layer.cornerRadius = 14;
        self.cpuHistory = [NSMutableArray array]; self.ramHistory = [NSMutableArray array];
        self.downHistory = [NSMutableArray array]; self.upHistory = [NSMutableArray array];
#if !APP_STORE_BUILD
        self.processSortMode = 1;
#endif
        self.polish = [[[NSUserDefaults standardUserDefaults] stringForKey:@"MacUsageBarLanguage"] isEqualToString:@"pl"];
        self.languageThumb = self.polish ? 1.0 : 0.0;
        self.theme = MIN(3, MAX(0, [[NSUserDefaults standardUserDefaults] integerForKey:@"MacUsageBarTheme"]));
    } return self;
}
- (BOOL)isFlipped { return YES; }
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
#if APP_STORE_BUILD
    if (p.x >= 264 && p.x <= 334 && p.y >= 10 && p.y <= 56) {
#else
    if (self.themePickerOpen) {
        if (p.x >= 148 && p.x <= 404 && p.y >= 94 && p.y < 246) {
            NSInteger selected = MIN(3, MAX(0, (NSInteger)((p.y-94)/38)));
            self.themePickerOpen = NO; [self setThemeAnimated:selected];
        } else {
            self.themePickerOpen = NO; [self setNeedsDisplay:YES];
        }
        return;
    }
    if (p.x >= 156 && p.x <= 220 && p.y >= 10 && p.y <= 56 && !self.optimizing) {
#endif
        self.themePickerOpen = YES; [self setNeedsDisplay:YES];
        return;
    }
#if APP_STORE_BUILD
    if (self.themePickerOpen) {
        if (p.x >= 148 && p.x <= 404 && p.y >= 94 && p.y < 246) {
            NSInteger selected = MIN(3, MAX(0, (NSInteger)((p.y-94)/38)));
            self.themePickerOpen = NO; [self setThemeAnimated:selected];
        } else {
            self.themePickerOpen = NO; [self setNeedsDisplay:YES];
        }
        return;
    }
    if (p.x >= 340 && p.x <= 405 && p.y >= 10 && p.y <= 56) {
#else
    if (p.x >= 226 && p.x <= 290 && p.y >= 10 && p.y <= 56) {
#endif
#if APP_STORE_BUILD
        BOOL wantsPolish = p.x >= 373;
#else
        BOOL wantsPolish = p.x >= 258;
#endif
        [self setPolishAnimated:wantsPolish];
        return;
    }
#if !APP_STORE_BUILD
    if (p.x >= 296 && p.x <= 405 && p.y >= 10 && p.y <= 56 && !self.optimizing) {
        if (self.optimizeHandler) self.optimizeHandler();
        return;
    }
#endif
#if !APP_STORE_BUILD
    if (p.y >= 602 && p.y <= 632) {
        if (p.x >= 275 && p.x < 345) self.processSortMode = 0;
        else if (p.x >= 345 && p.x <= 415) self.processSortMode = 1;
        [self setNeedsDisplay:YES];
    }
#endif
}
- (void)setThemeAnimated:(NSInteger)theme {
    if (self.languageAnimating) return;
    NSInteger nextTheme = MIN(3, MAX(0, theme));
    if (nextTheme == self.theme) { [self setNeedsDisplay:YES]; return; }
    CATransition *transition = [CATransition animation]; transition.type = kCATransitionFade; transition.duration = .38;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:transition forKey:@"themeTransition"];
    self.theme = nextTheme; self.themeToastStart = NSProcessInfo.processInfo.systemUptime;
    [[NSUserDefaults standardUserDefaults] setInteger:nextTheme forKey:@"MacUsageBarTheme"];
    [self setNeedsDisplay:YES];
    __weak DashboardView *weakSelf = self;
    [NSTimer scheduledTimerWithTimeInterval:1.7 repeats:NO block:^(NSTimer *timer) { [weakSelf setNeedsDisplay:YES]; }];
}
- (void)setPolishAnimated:(BOOL)polish {
    if (self.polish == polish || self.languageAnimating) return;
    self.languageAnimating = YES;
    self.languageFrom = self.languageThumb; self.languageTo = polish ? 1.0 : 0.0;
    self.languageAnimationStart = NSProcessInfo.processInfo.systemUptime; self.polish = polish;
    [[NSUserDefaults standardUserDefaults] setObject:(polish ? @"pl" : @"en") forKey:@"MacUsageBarLanguage"];
    CATransition *transition = [CATransition animation]; transition.type = kCATransitionFade; transition.duration = .32;
    transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.layer addAnimation:transition forKey:@"languageTransition"];
    if (self.languageChangedHandler) self.languageChangedHandler(polish);
    [self.languageTimer invalidate];
    self.languageTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 target:self selector:@selector(languageTick) userInfo:nil repeats:YES];
    [self setNeedsDisplay:YES];
}
- (void)languageTick {
    double t = MIN(1.0, (NSProcessInfo.processInfo.systemUptime-self.languageAnimationStart)/.36);
    double eased = t*t*(3.0-2.0*t);
    self.languageThumb = self.languageFrom + (self.languageTo-self.languageFrom)*eased;
    [self setNeedsDisplay:YES];
    if (t >= 1.0) { [self.languageTimer invalidate]; self.languageTimer=nil; self.languageAnimating=NO; }
}
#if !APP_STORE_BUILD
- (void)startOptimization {
    self.optimizing = YES; self.optimizedBytes = 0; self.animationStart = NSProcessInfo.processInfo.systemUptime;
    self.animationSeed = arc4random_uniform(10000) / 10000.0;
    [self.animationTimer invalidate];
    self.animationTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 target:self selector:@selector(animationTick) userInfo:nil repeats:YES];
    [self setNeedsDisplay:YES];
}
- (void)finishOptimization:(double)bytes {
    self.optimizing = NO; self.optimizedBytes = MAX(0, bytes); self.animationStart = NSProcessInfo.processInfo.systemUptime;
    self.animationSeed = arc4random_uniform(10000) / 10000.0;
    [self setNeedsDisplay:YES];
}
- (void)animationTick {
    double elapsed = NSProcessInfo.processInfo.systemUptime - self.animationStart;
    if (!self.optimizing && elapsed > 3.2) { [self.animationTimer invalidate]; self.animationTimer = nil; }
    [self setNeedsDisplay:YES];
}
#endif
- (void)add:(NSNumber *)n to:(NSMutableArray *)a { [a addObject:n]; if (a.count > 60) [a removeObjectAtIndex:0]; }
- (void)accept:(MonitorSnapshot *)d {
    self.data = d; [self add:@(d.cpu) to:self.cpuHistory]; [self add:@(d.memoryPercent) to:self.ramHistory];
    [self add:@(d.networkDown) to:self.downHistory]; [self add:@(d.networkUp) to:self.upHistory]; [self setNeedsDisplay:YES];
}
- (void)text:(NSString *)text x:(CGFloat)x y:(CGFloat)y size:(CGFloat)size color:(NSColor *)color weight:(NSFontWeight)weight {
    [text drawAtPoint:NSMakePoint(x,y) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:size weight:weight], NSForegroundColorAttributeName:color}];
}
- (NSString *)en:(NSString *)english pl:(NSString *)polish { return self.polish ? polish : english; }
- (NSString *)thermalText:(NSInteger)state {
    switch (state) {
        case NSProcessInfoThermalStateFair: return [self en:@"Elevated" pl:@"Podwyższony"];
        case NSProcessInfoThermalStateSerious: return [self en:@"High" pl:@"Wysoki"];
        case NSProcessInfoThermalStateCritical: return [self en:@"Critical" pl:@"Krytyczny"];
        default: return [self en:@"Normal" pl:@"Normalny"];
    }
}
- (NSString *)batteryStateText:(MonitorSnapshot *)d {
    if (d.charging) return [self en:@"Charging" pl:@"Ładowanie"];
    if (d.onAC) return [self en:@"Power adapter connected" pl:@"Zasilacz podłączony"];
    return [self en:@"On battery" pl:@"Praca na baterii"];
}
#if !APP_STORE_BUILD
- (NSString *)processName:(NSString *)name {
    if (!self.polish) return name;
    if ([name isEqualToString:@"WebKit — websites/apps"]) return @"WebKit — strony/aplikacje";
    if ([name isEqualToString:@"Contacts & Suggestions (system)"]) return @"Kontakty i sugestie (system)";
    if ([name isEqualToString:@"Call History (system)"]) return @"Historia połączeń (system)";
    if ([name isEqualToString:@"Node.js — developer tools"]) return @"Node.js — narzędzia deweloperskie";
    return name;
}
#endif
- (NSString *)themeName {
    switch (self.theme) {
        case 1: return @"Graphite";
        case 2: return @"Aurora";
        case 3: return @"Liquid Glass";
        default: return @"Midnight";
    }
}
- (NSColor *)accentColor {
    switch (self.theme) {
        case 1: return [NSColor colorWithRed:.22 green:.78 blue:.76 alpha:1];
        case 2: return [NSColor colorWithRed:.66 green:.38 blue:1 alpha:1];
        case 3: return [NSColor colorWithRed:.32 green:.76 blue:1 alpha:1];
        default: return [NSColor colorWithRed:.42 green:.48 blue:1 alpha:1];
    }
}
- (NSColor *)secondaryAccentColor {
    switch (self.theme) {
        case 1: return [NSColor colorWithRed:1 green:.64 blue:.26 alpha:1];
        case 2: return [NSColor colorWithRed:.18 green:.88 blue:.82 alpha:1];
        case 3: return [NSColor colorWithRed:.72 green:.54 blue:1 alpha:1];
        default: return [NSColor colorWithRed:.70 green:.38 blue:1 alpha:1];
    }
}
- (NSColor *)cardBackgroundColor {
    switch (self.theme) {
        case 1: return [NSColor colorWithRed:.118 green:.145 blue:.173 alpha:.98];
        case 2: return [NSColor colorWithRed:.071 green:.102 blue:.165 alpha:.94];
        case 3: return [NSColor colorWithRed:.04 green:.118 blue:.18 alpha:.84];
        default: return [NSColor colorWithRed:.067 green:.102 blue:.169 alpha:.98];
    }
}
- (NSColor *)cardStrokeColor {
    switch (self.theme) {
        case 1: return [NSColor colorWithWhite:1 alpha:.11];
        case 2: return [[self accentColor] colorWithAlphaComponent:.16];
        case 3: return [NSColor colorWithWhite:1 alpha:.28];
        default: return [[self accentColor] colorWithAlphaComponent:.12];
    }
}
- (void)spark:(NSArray<NSNumber *> *)values rect:(NSRect)r color:(NSColor *)color max:(double)fixedMax {
    if (values.count < 2) return; double maximum = fixedMax;
    if (maximum <= 0) for (NSNumber *n in values) maximum = MAX(maximum, n.doubleValue);
    maximum = MAX(1, maximum); NSBezierPath *p = [NSBezierPath bezierPath]; p.lineWidth = 2;
    for (NSInteger i=0;i<values.count;i++) { CGFloat x=NSMinX(r)+i*NSWidth(r)/(values.count-1); CGFloat y=NSMaxY(r)-values[i].doubleValue/maximum*NSHeight(r); if(i==0)[p moveToPoint:NSMakePoint(x,y)];else[p lineToPoint:NSMakePoint(x,y)]; }
    [color setStroke]; [p stroke];
}
- (void)card:(NSRect)r title:(NSString *)title value:(NSString *)value detail1:(NSString *)d1 detail2:(NSString *)d2 history:(NSArray *)history color:(NSColor *)color max:(double)max {
    NSBezierPath *bg=[NSBezierPath bezierPathWithRoundedRect:r xRadius:(self.theme==3?16:10) yRadius:(self.theme==3?16:10)];
    [NSGraphicsContext saveGraphicsState]; NSShadow *shadow=[NSShadow new]; shadow.shadowColor=[NSColor colorWithWhite:0 alpha:(self.theme==3?.34:.24)];shadow.shadowBlurRadius=self.theme==3?16:10;shadow.shadowOffset=NSMakeSize(0,-2);[shadow set];[[self cardBackgroundColor] setFill];[bg fill];[NSGraphicsContext restoreGraphicsState];
    [[self cardStrokeColor] setStroke]; bg.lineWidth = self.theme==3 ? 1.2 : .6; [bg stroke];
    [self text:title x:r.origin.x+14 y:r.origin.y+12 size:12 color:[[self accentColor] colorWithAlphaComponent:.88] weight:NSFontWeightSemibold];
    [self text:value x:r.origin.x+14 y:r.origin.y+32 size:24 color:PanelTextPrimary() weight:NSFontWeightSemibold];
    [self text:d1 ?: @"" x:r.origin.x+14 y:r.origin.y+68 size:11 color:PanelTextSecondary() weight:NSFontWeightRegular];
    [self text:d2 ?: @"" x:r.origin.x+14 y:r.origin.y+87 size:11 color:PanelTextSecondary() weight:NSFontWeightRegular];
    [self spark:history rect:NSMakeRect(r.origin.x+14,r.origin.y+112,r.size.width-28,44) color:color max:max];
}
- (void)drawRect:(NSRect)dirty {
    if (self.theme == 0) {
        NSGradient *midnight = [[NSGradient alloc] initWithColors:@[[NSColor colorWithRed:.025 green:.035 blue:.085 alpha:1], [NSColor colorWithRed:.075 green:.045 blue:.14 alpha:1], [NSColor colorWithRed:.025 green:.055 blue:.095 alpha:1]]];
        [midnight drawInRect:self.bounds angle:-62];
        NSGradient *midnightGlow = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:.40 green:.38 blue:1 alpha:.16] endingColor:[NSColor colorWithRed:.12 green:.18 blue:.42 alpha:0]];
        [midnightGlow drawInRect:self.bounds angle:-25];
    } else if (self.theme == 1) {
        NSGradient *graphite = [[NSGradient alloc] initWithColors:@[[NSColor colorWithRed:.075 green:.085 blue:.10 alpha:1], [NSColor colorWithRed:.13 green:.145 blue:.17 alpha:1], [NSColor colorWithRed:.07 green:.08 blue:.095 alpha:1]]];
        [graphite drawInRect:self.bounds angle:-86];
        NSGradient *graphiteGlow = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:.16 green:.66 blue:.64 alpha:.12] endingColor:[NSColor colorWithWhite:0 alpha:0]];
        [graphiteGlow drawInRect:self.bounds angle:-35];
    } else if (self.theme == 2) {
        NSGradient *aurora = [[NSGradient alloc] initWithColors:@[[NSColor colorWithRed:.035 green:.05 blue:.13 alpha:1], [NSColor colorWithRed:.20 green:.055 blue:.27 alpha:1], [NSColor colorWithRed:.035 green:.17 blue:.18 alpha:1], [NSColor colorWithRed:.055 green:.045 blue:.13 alpha:1]]];
        [aurora drawInRect:self.bounds angle:-52];
        NSGradient *auroraGlow = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithRed:.64 green:.26 blue:1 alpha:.18] endingColor:[NSColor colorWithRed:.12 green:.90 blue:.76 alpha:0]];
        [auroraGlow drawInRect:self.bounds angle:-20];
    } else {
        [[NSColor colorWithRed:.027 green:.071 blue:.122 alpha:.90] setFill]; NSRectFill(self.bounds);
        NSGradient *glassGlow = [[NSGradient alloc] initWithColors:@[[NSColor colorWithRed:.26 green:.66 blue:1 alpha:.24], [NSColor colorWithRed:.48 green:.30 blue:.88 alpha:.12], [NSColor colorWithRed:.02 green:.05 blue:.10 alpha:.04]]];
        [glassGlow drawInRect:self.bounds angle:-68];
        NSBezierPath *glassHighlight=[NSBezierPath bezierPath]; [glassHighlight moveToPoint:NSMakePoint(18,1)]; [glassHighlight lineToPoint:NSMakePoint(self.bounds.size.width-18,1)]; glassHighlight.lineWidth=1;
        [[NSColor colorWithWhite:1 alpha:.34]setStroke];[glassHighlight stroke];
    }
    MonitorSnapshot *d=self.data; if(!d)return;
    [self text:@"Mac Usage Bar" x:20 y:16 size:18 color:PanelTextPrimary() weight:NSFontWeightSemibold];
    [self text:[self en:@"Live • refresh 2s" pl:@"Na żywo • odśw. 2 s"] x:20 y:42 size:11 color:PanelTextSecondary() weight:NSFontWeightRegular];

#if APP_STORE_BUILD
    NSRect themeRect = NSMakeRect(264,12,70,40);
#else
    NSRect themeRect = NSMakeRect(156,12,64,40);
#endif
    NSBezierPath *themeButton = [NSBezierPath bezierPathWithRoundedRect:themeRect xRadius:12 yRadius:12];
    [[self cardBackgroundColor] setFill]; [themeButton fill]; [[self cardStrokeColor] setStroke]; themeButton.lineWidth=1; [themeButton stroke];
    NSString *themeButtonText = [self en:@"◐ THEME" pl:@"◐ MOTYW"];
    NSSize themeButtonTextSize = [themeButtonText sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:9 weight:NSFontWeightBold]}];
    [self text:themeButtonText x:NSMidX(themeRect)-themeButtonTextSize.width/2 y:26 size:9 color:[self accentColor] weight:NSFontWeightBold];

#if APP_STORE_BUILD
    NSRect languageRect = NSMakeRect(340,12,64,40);
#else
    NSRect languageRect = NSMakeRect(226,12,64,40);
#endif
    NSBezierPath *languageBackground = [NSBezierPath bezierPathWithRoundedRect:languageRect xRadius:12 yRadius:12];
    [[NSColor colorWithWhite:.20 alpha:1] setFill]; [languageBackground fill];
#if APP_STORE_BUILD
    NSRect selectedLanguage = NSMakeRect(343 + 29*self.languageThumb,15,29,34);
#else
    NSRect selectedLanguage = NSMakeRect(229 + 29*self.languageThumb,15,29,34);
#endif
    NSBezierPath *selectedLanguagePath = [NSBezierPath bezierPathWithRoundedRect:selectedLanguage xRadius:9 yRadius:9];
    [[self accentColor] setFill]; [selectedLanguagePath fill];
    [self text:@"EN" x:(APP_STORE_BUILD?349:235) y:25 size:10 color:[NSColor colorWithWhite:.96-.26*self.languageThumb alpha:1] weight:NSFontWeightBold];
    [self text:@"PL" x:(APP_STORE_BUILD?380:266) y:25 size:10 color:[NSColor colorWithWhite:.70+.26*self.languageThumb alpha:1] weight:NSFontWeightBold];

#if !APP_STORE_BUILD
    NSRect optimizeRect = NSMakeRect(296,12,108,40);
    NSBezierPath *optimizeButton = [NSBezierPath bezierPathWithRoundedRect:optimizeRect xRadius:12 yRadius:12];
    [[NSColor colorWithWhite:1 alpha:(self.theme==3?.075:.055)] setFill]; [optimizeButton fill];
    [[[self accentColor] colorWithAlphaComponent:(self.optimizing?.28:.55)] setStroke]; optimizeButton.lineWidth=1; [optimizeButton stroke];
    NSString *buttonText = self.optimizing ? [self en:@"Optimizing" pl:@"Optymalizacja"] : [self en:@"Optimize" pl:@"Optymalizuj"];
    CGFloat buttonFontSize = self.polish ? 9.7 : 10.5;
    NSSize buttonTextSize = [buttonText sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:buttonFontSize weight:NSFontWeightBold]}];
    CGFloat iconX = NSMidX(optimizeRect)-(buttonTextSize.width+18)/2;
    if (self.optimizing) {
        double spinnerPhase=fmod(NSProcessInfo.processInfo.systemUptime*1.7,1.0);
        NSBezierPath *spinner=[NSBezierPath bezierPath]; spinner.lineWidth=1.8;
        [spinner appendBezierPathWithArcWithCenter:NSMakePoint(iconX+7,32) radius:6 startAngle:spinnerPhase*360 endAngle:spinnerPhase*360+255 clockwise:NO];
        [[self accentColor] setStroke]; [spinner stroke];
    } else {
        NSColor *iconColor=[self accentColor];
        NSRect chipRect=NSMakeRect(iconX+2,27,10,10);
        NSBezierPath *chip=[NSBezierPath bezierPathWithRoundedRect:chipRect xRadius:2 yRadius:2];
        [[iconColor colorWithAlphaComponent:.16]setFill];[chip fill];[iconColor setStroke];chip.lineWidth=1.35;[chip stroke];
        NSBezierPath *pins=[NSBezierPath bezierPath];pins.lineWidth=1.25;
        for(NSInteger i=0;i<3;i++){
            CGFloat offset=29+i*3;
            [pins moveToPoint:NSMakePoint(iconX,offset)];[pins lineToPoint:NSMakePoint(iconX+2,offset)];
            [pins moveToPoint:NSMakePoint(iconX+12,offset)];[pins lineToPoint:NSMakePoint(iconX+14,offset)];
        }
        [pins moveToPoint:NSMakePoint(iconX+5,25)];[pins lineToPoint:NSMakePoint(iconX+5,27)];
        [pins moveToPoint:NSMakePoint(iconX+9,25)];[pins lineToPoint:NSMakePoint(iconX+9,27)];
        [pins moveToPoint:NSMakePoint(iconX+5,37)];[pins lineToPoint:NSMakePoint(iconX+5,39)];
        [pins moveToPoint:NSMakePoint(iconX+9,37)];[pins lineToPoint:NSMakePoint(iconX+9,39)];
        [iconColor setStroke];[pins stroke];
    }
    [self text:buttonText x:iconX+18 y:26 size:buttonFontSize color:PanelTextPrimary() weight:NSFontWeightSemibold];
#endif
    CGFloat w=190,h=170; NSColor *blue=[self accentColor], *purple=[self secondaryAccentColor];
    [self card:NSMakeRect(16,68,w,h) title:[self en:@"PROCESSOR" pl:@"PROCESOR"] value:[NSString stringWithFormat:@"%ld%%",(long)d.cpu] detail1:[NSString stringWithFormat:[self en:@"Thermal state: %@" pl:@"Stan termiczny: %@"],[self thermalText:d.thermalState]] detail2:[self en:@"Graph: last 2 minutes" pl:@"Wykres: ostatnie 2 minuty"] history:self.cpuHistory color:blue max:100];
    [self card:NSMakeRect(214,68,w,h) title:[self en:@"MEMORY" pl:@"PAMIĘĆ RAM"] value:[NSString stringWithFormat:@"%ld%%",(long)d.memoryPercent] detail1:[NSString stringWithFormat:[self en:@"%@ of %@" pl:@"%@ z %@"],FormatBytes(d.memoryUsed),FormatBytes(d.memoryTotal)] detail2:[NSString stringWithFormat:@"Swap: %@",FormatBytes(d.swapUsed)] history:self.ramHistory color:purple max:100];
    NSString *batteryTime = d.timeRemaining ?: [self en:@"Calculating…" pl:@"Obliczanie…"];
    NSString *batteryDetail = d.hasBattery ? ([NSString stringWithFormat:@"%@%@", [self batteryStateText:d], (d.onAC && !d.charging ? @"" : [NSString stringWithFormat:@" • %@",batteryTime])]) : [self en:@"Desktop Mac" pl:@"Mac stacjonarny"];
    NSString *batteryStats = @"";
    if (d.batteryHealth > 0 && d.cycles > 0) batteryStats=[NSString stringWithFormat:[self en:@"Health: %ld%% • Cycles: %ld" pl:@"Kondycja: %ld%% • Cykle: %ld"],(long)d.batteryHealth,(long)d.cycles];
    else if (d.batteryHealth > 0) batteryStats=[NSString stringWithFormat:[self en:@"Health: %ld%%" pl:@"Kondycja: %ld%%"],(long)d.batteryHealth];
    else if (d.cycles > 0) batteryStats=[NSString stringWithFormat:[self en:@"Cycles: %ld" pl:@"Cykle: %ld"],(long)d.cycles];
    [self card:NSMakeRect(16,246,w,h) title:[self en:@"BATTERY & POWER" pl:@"BATERIA I MOC"] value:(d.hasBattery?[NSString stringWithFormat:@"%ld%% • %.1f W",(long)d.batteryPercent,d.batteryWatts]:[self en:@"No battery" pl:@"Brak baterii"]) detail1:batteryDetail detail2:batteryStats history:@[] color:[NSColor systemGreenColor] max:100];
    NSInteger diskPct=d.diskTotal?llround(d.diskUsed/d.diskTotal*100):0;
    [self card:NSMakeRect(214,246,w,h) title:[self en:@"DISK" pl:@"DYSK"] value:[NSString stringWithFormat:@"%ld%%",(long)diskPct] detail1:[NSString stringWithFormat:[self en:@"Used: %@" pl:@"Zajęte: %@"],FormatBytes(d.diskUsed)] detail2:[NSString stringWithFormat:[self en:@"Free: %@" pl:@"Wolne: %@"],FormatBytes(d.diskTotal-d.diskUsed)] history:@[] color:[NSColor systemOrangeColor] max:100];
    NSRect nr=NSMakeRect(16,424,388,120); NSBezierPath *nb=[NSBezierPath bezierPathWithRoundedRect:nr xRadius:(self.theme==3?16:10) yRadius:(self.theme==3?16:10)]; [[self cardBackgroundColor]setFill];[nb fill]; [[self cardStrokeColor]setStroke]; nb.lineWidth=self.theme==3?1.2:.6;[nb stroke];
    [self text:[self en:@"NETWORK" pl:@"SIEĆ"] x:30 y:438 size:12 color:[[self accentColor] colorWithAlphaComponent:.88] weight:NSFontWeightSemibold];
    [self text:[NSString stringWithFormat:@"↓ %@     ↑ %@",FormatRate(d.networkDown),FormatRate(d.networkUp)] x:30 y:460 size:18 color:PanelTextPrimary() weight:NSFontWeightSemibold];
    [self spark:self.downHistory rect:NSMakeRect(30,493,360,36) color:blue max:0]; [self spark:self.upHistory rect:NSMakeRect(30,493,360,36) color:purple max:0];
    [self text:[NSString stringWithFormat:[self en:@"RAM: active %@  •  wired %@  •  compressed %@" pl:@"RAM: aktywna %@  •  przewodowa %@  •  skompresowana %@"],FormatBytes(d.memoryActive),FormatBytes(d.memoryWired),FormatBytes(d.memoryCompressed)] x:20 y:556 size:11 color:PanelTextSecondary() weight:NSFontWeightRegular];
#if !APP_STORE_BUILD
    [self text:[self en:@"TOP RESOURCE-CONSUMING APPS" pl:@"NAJBARDZIEJ OBCIĄŻAJĄCE APLIKACJE"] x:20 y:590 size:12 color:[[self accentColor] colorWithAlphaComponent:.88] weight:NSFontWeightSemibold];
    [self text:[self en:@"App / process" pl:@"Aplikacja / proces"] x:20 y:614 size:10 color:PanelTextTertiary() weight:NSFontWeightRegular];
    [self text:(self.processSortMode==0 ? @"CPU ▼" : @"CPU") x:292 y:614 size:10 color:(self.processSortMode==0 ? blue : PanelTextTertiary()) weight:NSFontWeightSemibold];
    [self text:(self.processSortMode==1 ? @"RAM ▼" : @"RAM") x:346 y:614 size:10 color:(self.processSortMode==1 ? purple : PanelTextTertiary()) weight:NSFontWeightSemibold];
    NSArray *sorted = [d.processes sortedArrayUsingComparator:^NSComparisonResult(ProcessSample *a, ProcessSample *b) {
        double va = self.processSortMode == 0 ? a.cpu : a.memory;
        double vb = self.processSortMode == 0 ? b.cpu : b.memory;
        return va > vb ? NSOrderedAscending : va < vb ? NSOrderedDescending : [a.name localizedCaseInsensitiveCompare:b.name];
    }];
    CGFloat py = 636;
    NSInteger shown = 0;
    for (ProcessSample *p in sorted) {
        if (shown++ >= 8) break;
        NSString *localizedName = [self processName:p.name];
        NSString *name = localizedName.length > 29 ? [[localizedName substringToIndex:28] stringByAppendingString:@"…"] : localizedName;
        [self text:name x:20 y:py size:11 color:PanelTextPrimary() weight:NSFontWeightRegular];
        [self text:[NSString stringWithFormat:@"%.1f%%",p.cpu] x:298 y:py size:11 color:blue weight:NSFontWeightMedium];
        [self text:FormatBytes(p.memory) x:350 y:py size:11 color:purple weight:NSFontWeightMedium];
        py += 21;
    }
#endif

    double themeToastElapsed = NSProcessInfo.processInfo.systemUptime - self.themeToastStart;
    if (self.themeToastStart > 0 && themeToastElapsed < 1.7) {
        NSString *themeLabel = [NSString stringWithFormat:@"◐  %@", [self themeName]];
        NSSize ts = [themeLabel sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]}];
        NSRect toast = NSMakeRect(NSMidX(self.bounds)-ts.width/2-16, 62, ts.width+32, 34);
        NSBezierPath *toastPath=[NSBezierPath bezierPathWithRoundedRect:toast xRadius:17 yRadius:17];
        [[[self accentColor] colorWithAlphaComponent:.96] setFill]; [toastPath fill];
        [self text:themeLabel x:NSMidX(toast)-ts.width/2 y:72 size:12 color:NSColor.whiteColor weight:NSFontWeightSemibold];
    }

#if !APP_STORE_BUILD
    double elapsed = NSProcessInfo.processInfo.systemUptime - self.animationStart;
    if (self.optimizing || (self.animationStart > 0 && elapsed < 3.2)) {
        double mb = self.optimizedBytes / 1e6;
        double intensity = self.optimizing ? .32 : MIN(1.0, log1p(MAX(1, mb)) / log1p(5000.0));
        double fade = self.optimizing ? .72 : MAX(0, 1.0 - elapsed / 3.2);
        NSRect overlay = NSInsetRect(self.bounds, 12, 12);
        NSBezierPath *overlayPath = [NSBezierPath bezierPathWithRoundedRect:overlay xRadius:18 yRadius:18];
        [[NSColor colorWithWhite:.03 alpha:.78*fade] setFill]; [overlayPath fill];
        NSPoint center = NSMakePoint(NSMidX(self.bounds), 325);
        NSInteger rings = self.optimizing ? 2 : (2 + llround(intensity * 5));
        for (NSInteger i=0;i<rings;i++) {
            double phase = self.optimizing ? fmod(elapsed*1.5+i/(double)rings,1.0) : MIN(1,elapsed/1.4);
            CGFloat radius = 35 + phase*(70+intensity*95) + i*7;
            NSRect rr=NSMakeRect(center.x-radius,center.y-radius,radius*2,radius*2);
            NSBezierPath *ring=[NSBezierPath bezierPathWithOvalInRect:rr]; ring.lineWidth=2+intensity*3;
            NSColor *c=[NSColor colorWithCalibratedHue:fmod(.62+self.animationSeed*.25+i*.07,1) saturation:.85 brightness:1 alpha:(1-phase)*fade]; [c setStroke]; [ring stroke];
        }
        if (!self.optimizing && intensity > .18) {
            NSInteger particles = 6 + llround(intensity*28);
            srand48((long)(self.animationSeed*100000));
            for(NSInteger i=0;i<particles;i++) {
                double angle=drand48()*M_PI*2, distance=(45+drand48()*150*intensity)*MIN(1,elapsed*1.4);
                CGFloat size=3+drand48()*7*intensity; NSRect dot=NSMakeRect(center.x+cos(angle)*distance-size/2,center.y+sin(angle)*distance-size/2,size,size);
                NSBezierPath *particle=[NSBezierPath bezierPathWithOvalInRect:dot]; [[NSColor colorWithCalibratedHue:fmod(self.animationSeed+drand48()*.45,1) saturation:.8 brightness:1 alpha:fade]setFill];[particle fill];
            }
        }
        NSString *result = self.optimizing ? [self en:@"Freeing memory…" pl:@"Zwalniam pamięć…"] : [NSString stringWithFormat:[self en:@"Recovered %@" pl:@"Odzyskano %@"], FormatBytes(self.optimizedBytes)];
        NSSize rs=[result sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:26 weight:NSFontWeightBold]}];
        [self text:result x:center.x-rs.width/2 y:center.y-18 size:26 color:PanelTextPrimary() weight:NSFontWeightBold];
        NSString *sub = self.optimizing ? [self en:@"macOS is safely clearing system caches" pl:@"macOS porządkuje bezpieczne pamięci podręczne"] : (mb >= 1000 ? [self en:@"A big boost of free memory!" pl:@"Duży zastrzyk wolnej pamięci!"] : mb >= 100 ? [self en:@"Memory load noticeably reduced" pl:@"Pamięć wyraźnie odciążona"] : [self en:@"Light, safe optimization" pl:@"Lekka, bezpieczna optymalizacja"]);
        NSSize ss=[sub sizeWithAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]}];
        [self text:sub x:center.x-ss.width/2 y:center.y+24 size:12 color:PanelTextSecondary() weight:NSFontWeightMedium];
    }
#endif

    if (self.themePickerOpen
#if !APP_STORE_BUILD
        && !self.optimizing
#endif
    ) {
        NSRect picker = NSMakeRect(148,58,256,196);
        NSBezierPath *pickerPath=[NSBezierPath bezierPathWithRoundedRect:picker xRadius:16 yRadius:16];
        [[NSColor colorWithRed:.075 green:.085 blue:.12 alpha:.985] setFill]; [pickerPath fill];
        [[NSColor colorWithWhite:1 alpha:.18] setStroke]; pickerPath.lineWidth=1.2; [pickerPath stroke];
        [self text:[self en:@"CHOOSE THEME" pl:@"WYBIERZ MOTYW"] x:164 y:70 size:10 color:PanelTextSecondary() weight:NSFontWeightBold];
        NSArray<NSString *> *themes=@[@"Midnight",@"Graphite",@"Aurora",@"Liquid Glass"];
        NSArray<NSColor *> *swatches=@[[NSColor colorWithWhite:.11 alpha:1],[NSColor colorWithWhite:.32 alpha:1],[NSColor colorWithRed:.53 green:.22 blue:.91 alpha:1],[NSColor colorWithRed:.28 green:.68 blue:1 alpha:.72]];
        for (NSInteger i=0;i<4;i++) {
            NSRect row=NSMakeRect(156,94+i*38,240,34);
            if (i==self.theme) { NSBezierPath *selected=[NSBezierPath bezierPathWithRoundedRect:row xRadius:9 yRadius:9]; [[[self accentColor] colorWithAlphaComponent:.20]setFill];[selected fill]; }
            NSRect swatch=NSMakeRect(168,104+i*38,14,14); NSBezierPath *dot=[NSBezierPath bezierPathWithOvalInRect:swatch];[swatches[i]setFill];[dot fill];
            [self text:themes[i] x:194 y:102+i*38 size:12 color:PanelTextPrimary() weight:(i==self.theme?NSFontWeightSemibold:NSFontWeightRegular)];
            if(i==self.theme)[self text:@"✓" x:366 y:101+i*38 size:13 color:[self accentColor] weight:NSFontWeightBold];
        }
    }
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property SystemMonitor *monitor; @property NSStatusItem *statusItem; @property NSButton *menuBarButton; @property NSPopover *popover;
@property DashboardView *dashboard; @property NSTimer *timer; @property NSWindow *previewWindow;
@property id globalMouseMonitor; @property id localMouseMonitor;
@property CGFloat cachedAvailableMenuBarWidth;
@property NSTimeInterval lastMenuBarWidthCalculation;
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)n {
#if !APP_STORE_BUILD
    // There must never be two menu-bar items for this app. Launch Services
    // normally enforces that for one bundle, but older builds used a different
    // bundle identifier and could remain alive at the same time.
    pid_t ownPID=NSProcessInfo.processInfo.processIdentifier;
    for (NSRunningApplication *running in NSWorkspace.sharedWorkspace.runningApplications) {
        if (running.processIdentifier==ownPID) continue;
        NSString *bundleID=running.bundleIdentifier ?: @"";
        if ([bundleID isEqualToString:@"pl.marcin.macusagebar.final"]) {
            [NSApp terminate:nil];
            return;
        }
        if ([bundleID hasPrefix:@"pl.marcin.macusagebar"]) {
            [running terminate];
        }
    }
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSDictionary *adaptive=[defaults persistentDomainForName:@"pl.marcin.macusagebar.adaptive"];
    NSDictionary *legacy=[defaults persistentDomainForName:@"pl.marcin.macusagebar"];
    if (![defaults objectForKey:@"MacUsageBarLanguage"]) {
        id language=adaptive[@"MacUsageBarLanguage"] ?: legacy[@"MacUsageBarLanguage"];
        if (language) [defaults setObject:language forKey:@"MacUsageBarLanguage"];
    }
    if (![defaults objectForKey:@"MacUsageBarTheme"]) {
        id theme=adaptive[@"MacUsageBarTheme"] ?: legacy[@"MacUsageBarTheme"];
        if (theme) [defaults setObject:theme forKey:@"MacUsageBarTheme"];
    }
#else
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
#endif
    self.monitor=[SystemMonitor new];
    // A real status item is positioned and hidden with the rest of the macOS
    // menu bar. The previous custom all-spaces panel could overlap system
    // items and stayed above full-screen video.
    [defaults removeObjectForKey:@"NSStatusItem Preferred Position Item-0"];
    [defaults removeObjectForKey:@"NSStatusItem Preferred Position pl.marcin.macusagebar.adaptive-status-v3"];
    self.statusItem=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.menuBarButton=self.statusItem.button;
    self.menuBarButton.target=self;
    self.menuBarButton.action=@selector(toggle:);
    self.menuBarButton.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    CGFloat dashboardHeight=APP_STORE_BUILD ? 590.0 : 820.0;
    self.dashboard=[[DashboardView alloc]initWithFrame:NSMakeRect(0,0,420,dashboardHeight)];
    self.menuBarButton.toolTip=self.dashboard.polish ? @"Kliknij, aby zobaczyć szczegóły użycia Maca" : @"Click to see detailed Mac usage";
    __weak AppDelegate *weakSelf = self;
#if !APP_STORE_BUILD
    self.dashboard.optimizeHandler = ^{ [weakSelf runOptimization]; };
#endif
    self.dashboard.languageChangedHandler = ^(BOOL polish) { weakSelf.menuBarButton.toolTip = polish ? @"Kliknij, aby zobaczyć szczegóły użycia Maca" : @"Click to see detailed Mac usage"; };
    NSVisualEffectView *glassContainer = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0,0,420,dashboardHeight)];
    glassContainer.material = NSVisualEffectMaterialHUDWindow; glassContainer.blendingMode = NSVisualEffectBlendingModeBehindWindow; glassContainer.state = NSVisualEffectStateActive;
    self.dashboard.frame = glassContainer.bounds; self.dashboard.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; [glassContainer addSubview:self.dashboard];
    NSViewController *vc=[NSViewController new]; vc.view=glassContainer; self.popover=[NSPopover new]; self.popover.contentViewController=vc; self.popover.contentSize=NSMakeSize(420,dashboardHeight); self.popover.behavior=NSPopoverBehaviorTransient;
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview"]) {
        self.previewWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,420,dashboardHeight) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.previewWindow.title=@"Mac Usage Bar — App Store Preview";
        self.previewWindow.contentView=glassContainer;
        [self.previewWindow center];
        [NSApp activateIgnoringOtherApps:YES];
        [self.previewWindow makeKeyAndOrderFront:nil];
    }
    NSEventMask outsideClickMask=NSEventMaskLeftMouseDown|NSEventMaskRightMouseDown|NSEventMaskOtherMouseDown;
    self.localMouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:outsideClickMask handler:^NSEvent *(NSEvent *event) {
        AppDelegate *strongSelf=weakSelf;
        if (!strongSelf || !strongSelf.popover.shown) return event;
        NSWindow *popoverWindow=strongSelf.popover.contentViewController.view.window;
        if (event.window!=strongSelf.menuBarButton.window && event.window!=popoverWindow) [strongSelf.popover close];
        return event;
    }];
    self.globalMouseMonitor=[NSEvent addGlobalMonitorForEventsMatchingMask:outsideClickMask handler:^(NSEvent *event) {
        dispatch_async(dispatch_get_main_queue(),^{
            AppDelegate *strongSelf=weakSelf;
            if (strongSelf.popover.shown) [strongSelf.popover close];
        });
    }];
    // Let AppKit place the guaranteed-small item first. Only then measure the
    // actual right-hand menu-bar area and grow to the richest fitting variant.
    [self.monitor cpuUsage];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.35*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self update];
    });
    self.timer=[NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(update) userInfo:nil repeats:YES];
}
- (void)applicationDidChangeScreenParameters:(NSNotification *)notification {
    self.cachedAvailableMenuBarWidth=0;
    self.lastMenuBarWidthCalculation=0;
    [self update];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    self.timer=nil;
    if (self.localMouseMonitor) [NSEvent removeMonitor:self.localMouseMonitor];
    if (self.globalMouseMonitor) [NSEvent removeMonitor:self.globalMouseMonitor];
    self.localMouseMonitor=nil;
    self.globalMouseMonitor=nil;
    if (self.statusItem) [NSStatusBar.systemStatusBar removeStatusItem:self.statusItem];
    self.statusItem=nil;
    self.menuBarButton=nil;
}
#if !APP_STORE_BUILD
- (void)runOptimization {
    if (self.dashboard.optimizing) return;
    double before = self.dashboard.data.memoryUsed;
    [self.dashboard startOptimization];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *source = @"do shell script \"/usr/sbin/purge\" with administrator privileges";
        NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source]; NSDictionary *error = nil;
        [script executeAndReturnError:&error];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            MonitorSnapshot *after = [self.monitor snapshot];
            [self.dashboard accept:after]; [self.dashboard finishOptimization:MAX(0, before-after.memoryUsed)];
        });
    });
}
#endif
- (BOOL)activeSpaceIsFullscreen {
#if !APP_STORE_BUILD
    typedef int (*MainConnectionProc)(void);
    typedef CFArrayRef (*CopyManagedDisplaySpacesProc)(int);
    static MainConnectionProc mainConnection=NULL;
    static CopyManagedDisplaySpacesProc copyManagedDisplaySpaces=NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken,^{
        void *skyLight=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
        if (skyLight) {
            mainConnection=(MainConnectionProc)dlsym(skyLight,"CGSMainConnectionID");
            copyManagedDisplaySpaces=(CopyManagedDisplaySpacesProc)dlsym(skyLight,"CGSCopyManagedDisplaySpaces");
        }
    });
    if (mainConnection && copyManagedDisplaySpaces) {
        NSArray *displays=CFBridgingRelease(copyManagedDisplaySpaces(mainConnection()));
        for (NSDictionary *display in displays) {
            NSNumber *currentID=display[@"Current Space"][@"id"];
            if (currentID == nil) continue;
            for (NSDictionary *space in display[@"Spaces"]) {
                if ([space[@"id"] isEqual:currentID] && [space[@"type"] integerValue]==4) return YES;
            }
        }
    }
#endif
    return NO;
}

- (BOOL)frontmostApplicationHasFullscreenWindow {
    NSRunningApplication *frontmost=NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!frontmost || frontmost.processIdentifier==NSProcessInfo.processInfo.processIdentifier) return NO;
    if ([self activeSpaceIsFullscreen]) return YES;
    NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    for (NSDictionary *window in windows) {
        if ([window[(__bridge NSString *)kCGWindowOwnerPID] intValue]!=frontmost.processIdentifier) continue;
        if ([window[(__bridge NSString *)kCGWindowLayer] integerValue]!=0) continue;
        NSDictionary *boundsDictionary=window[(__bridge NSString *)kCGWindowBounds];
        CGRect bounds=CGRectZero;
        if (!boundsDictionary || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDictionary,&bounds)) continue;
        for (NSScreen *screen in NSScreen.screens) {
            NSNumber *screenNumber=screen.deviceDescription[@"NSScreenNumber"];
            if (screenNumber == nil) continue;
            CGRect displayBounds=CGDisplayBounds((CGDirectDisplayID)screenNumber.unsignedIntValue);
            BOOL coversWidth=CGRectGetWidth(bounds)>=CGRectGetWidth(displayBounds)-2.0;
            BOOL coversHeight=CGRectGetHeight(bounds)>=CGRectGetHeight(displayBounds)-2.0;
            BOOL sameOrigin=fabs(CGRectGetMinX(bounds)-CGRectGetMinX(displayBounds))<=2.0 &&
                            fabs(CGRectGetMinY(bounds)-CGRectGetMinY(displayBounds))<=2.0;
            if (coversWidth && coversHeight && sameOrigin) return YES;
        }
    }
    return NO;
}

- (CGFloat)measureAvailableMenuBarWidth {
    NSScreen *screen=self.menuBarButton.window.screen ?: NSScreen.screens.firstObject;
    if (!screen) return 90.0;
#if !APP_STORE_BUILD
    NSRect rightArea=screen.auxiliaryTopRightArea;
    CGFloat regionWidth=NSWidth(rightArea)>0 ? NSWidth(rightArea) : NSWidth(screen.frame)*0.46;
    NSNumber *screenNumber=screen.deviceDescription[@"NSScreenNumber"];
    if (screenNumber) {
        CGRect displayBounds=CGDisplayBounds((CGDirectDisplayID)screenNumber.unsignedIntValue);
        NSArray *windows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
        CGFloat occupied=0;
        pid_t ownPID=NSProcessInfo.processInfo.processIdentifier;
        NSInteger ownWindowNumber=self.menuBarButton.window.windowNumber;
        for (NSDictionary *window in windows) {
            if ([window[(__bridge NSString *)kCGWindowLayer] integerValue]!=NSStatusWindowLevel) continue;
            NSDictionary *boundsDictionary=window[(__bridge NSString *)kCGWindowBounds];
            CGRect bounds=CGRectZero;
            if (!boundsDictionary || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDictionary,&bounds)) continue;
            BOOL onThisScreen=fabs(CGRectGetMinY(bounds)-CGRectGetMinY(displayBounds))<2.0;
            BOOL inRightArea=NSWidth(rightArea)<=0 || CGRectGetMinX(bounds)>=NSMinX(rightArea)-1.0;
            BOOL statusSized=CGRectGetWidth(bounds)>1.0 && CGRectGetWidth(bounds)<=320.0 &&
                             CGRectGetHeight(bounds)<=NSStatusBar.systemStatusBar.thickness+4.0;
            if (!onThisScreen || !inRightArea || !statusSized) continue;
            pid_t ownerPID=[window[(__bridge NSString *)kCGWindowOwnerPID] intValue];
            NSInteger windowNumber=[window[(__bridge NSString *)kCGWindowNumber] integerValue];
            if (ownerPID==ownPID && (ownWindowNumber<=0 || windowNumber==ownWindowNumber)) continue;
            occupied+=CGRectGetWidth(bounds);
        }
        if (occupied>0) return MAX(52.0,regionWidth-occupied-10.0);
    }
#endif
    CGFloat screenWidth=NSWidth(screen.frame);
    return screenWidth>=1800 ? 360.0 : screenWidth>=1300 ? 250.0 : 150.0;
}

- (CGFloat)availableMenuBarWidth {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if (self.cachedAvailableMenuBarWidth>0 && now-self.lastMenuBarWidthCalculation<4.0) return self.cachedAvailableMenuBarWidth;
    self.cachedAvailableMenuBarWidth=[self measureAvailableMenuBarWidth];
    self.lastMenuBarWidthCalculation=now;
    return self.cachedAvailableMenuBarWidth;
}

- (void)update {
    BOOL preview=[NSProcessInfo.processInfo.arguments containsObject:@"--preview"];
    BOOL fullscreen=preview ? NO : [self frontmostApplicationHasFullscreenWindow];
    self.statusItem.visible=!fullscreen;
    if (fullscreen) {
        if (self.popover.shown) [self.popover close];
        return;
    }
    MonitorSnapshot *d=[self.monitor snapshot];
    NSString *power = d.batteryWatts > 0.05 ? [NSString stringWithFormat:@"%.1fW", d.batteryWatts] : @"—W";
    NSString *remaining=(!d.onAC ? d.timeRemaining : nil);
    NSString *shortRemaining=CompactRemainingTime(remaining);
    NSString *full=d.hasBattery
        ? [NSString stringWithFormat:@"CPU %ld%%  %@  RAM %ld%%  BAT %ld%%%@",(long)d.cpu,power,(long)d.memoryPercent,(long)d.batteryPercent,remaining.length?[NSString stringWithFormat:@"  %@",remaining]:@""]
        : [NSString stringWithFormat:@"CPU %ld%%  %@  RAM %ld%%",(long)d.cpu,power,(long)d.memoryPercent];
    NSString *balanced=d.hasBattery
        ? [NSString stringWithFormat:@"C%ld%%  %@  R%ld%%  B%ld%%%@",(long)d.cpu,power,(long)d.memoryPercent,(long)d.batteryPercent,shortRemaining.length?[NSString stringWithFormat:@"  %@",shortRemaining]:@""]
        : [NSString stringWithFormat:@"C%ld%%  %@  R%ld%%",(long)d.cpu,power,(long)d.memoryPercent];
    NSString *compact=d.hasBattery
        ? [NSString stringWithFormat:@"C%ld%%  %@  R%ld%%  B%ld%%",(long)d.cpu,power,(long)d.memoryPercent,(long)d.batteryPercent]
        : [NSString stringWithFormat:@"C%ld%%  %@  R%ld%%",(long)d.cpu,power,(long)d.memoryPercent];
    NSString *small=d.hasBattery
        ? [NSString stringWithFormat:@"C%ld%%  %@  B%ld%%",(long)d.cpu,power,(long)d.batteryPercent]
        : [NSString stringWithFormat:@"C%ld%%  %@",(long)d.cpu,power];
    NSString *tiny=[NSString stringWithFormat:@"C%ld%%  %@",(long)d.cpu,power];
    NSString *minimal=[NSString stringWithFormat:@"C%ld%%",(long)d.cpu];
    NSArray<NSString *> *candidates=@[full,balanced,compact,small,tiny,minimal];
    NSDictionary *attributes=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.labelColor};
    CGFloat available=[self availableMenuBarWidth];
    NSString *title=minimal;
    for (NSString *candidate in candidates) {
        CGFloat width=ceil([candidate sizeWithAttributes:attributes].width)+16.0;
        if (width<=available) { title=candidate; break; }
    }
    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] initWithString:title attributes:attributes];
    self.menuBarButton.attributedTitle=styled;
    NSString *batteryDetail = d.hasBattery ? [NSString stringWithFormat:@"%ld%%%@%@", (long)d.batteryPercent, d.onAC ? @" · AC" : @"", (!d.onAC && d.timeRemaining.length) ? [@" · " stringByAppendingString:d.timeRemaining] : @""] : @"—";
    self.menuBarButton.toolTip = self.dashboard.polish
        ? [NSString stringWithFormat:@"CPU: %ld%% · RAM: %ld%% (%.1f z %.1f GB) · Moc: %@ · Bateria: %@", (long)d.cpu, (long)d.memoryPercent, d.memoryUsed/1e9, d.memoryTotal/1e9, power, batteryDetail]
        : [NSString stringWithFormat:@"CPU: %ld%% · RAM: %ld%% (%.1f of %.1f GB) · Power: %@ · Battery: %@", (long)d.cpu, (long)d.memoryPercent, d.memoryUsed/1e9, d.memoryTotal/1e9, power, batteryDetail];
    [self.dashboard accept:d];
}
- (void)toggle:(id)sender { if(self.popover.shown)[self.popover close]; else [self.popover showRelativeToRect:self.menuBarButton.bounds ofView:self.menuBarButton preferredEdge:NSRectEdgeMinY]; }
@end

int main(int argc,const char *argv[]){ @autoreleasepool {
#if !APP_STORE_BUILD
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--unregister-login"]) {
        NSError *error=nil;
        BOOL removed=[SMAppService.mainAppService unregisterAndReturnError:&error];
        if (!removed && error) NSLog(@"Could not remove login item: %@",error.localizedDescription);
        return removed || !error ? 0 : 1;
    }
#endif
    NSApplication *app=NSApplication.sharedApplication; static AppDelegate *delegate; delegate=[AppDelegate new]; app.delegate=delegate; [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; [app run];
} return 0; }
