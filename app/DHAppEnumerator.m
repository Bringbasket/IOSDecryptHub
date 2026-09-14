// DHAppEnumerator.m

#import "DHAppEnumerator.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <stdlib.h>
#import <string.h>
#import <signal.h>
#import <unistd.h>
#import <spawn.h>

extern char **environ;

@implementation DHAppInfo
@end

@interface NSObject (DHLaunchServices)
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
- (NSURL *)bundleURL;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

static NSDictionary<NSString *, id> *dh_collect(void) {
    // bundleID -> @{@"name": ..., @"path": ...}
    NSMutableDictionary<NSString *, NSDictionary *> *apps = [NSMutableDictionary dictionary];
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    static const char *frameworks[] = {
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        NULL,
    };
    for (NSUInteger i = 0; !workspaceClass && frameworks[i]; i++) {
        dlopen(frameworks[i], RTLD_LAZY | RTLD_LOCAL);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }
    @try {
        if (workspaceClass && [workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
            id workspace = [workspaceClass defaultWorkspace];
            NSArray *proxies = [workspace respondsToSelector:@selector(allApplications)]
                ? [workspace allApplications] : nil;
            for (id proxy in proxies) {
                NSString *bundleID = [proxy respondsToSelector:@selector(applicationIdentifier)]
                    ? [proxy applicationIdentifier] : nil;
                if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) continue;
                NSString *type = [proxy respondsToSelector:@selector(applicationType)]
                    ? [proxy applicationType] : nil;
                if (type.length > 0 && ![type isEqualToString:@"User"]) continue;
                NSString *name = [proxy respondsToSelector:@selector(localizedName)]
                    ? [proxy localizedName] : nil;
                NSString *path = nil;
                if ([proxy respondsToSelector:@selector(bundleURL)]) {
                    id url = [proxy bundleURL];
                    if ([url isKindOfClass:[NSURL class]]) path = [url path];
                }
                apps[bundleID] = @{ @"name": name.length ? name : bundleID,
                                    @"path": path ?: @"" };
            }
        }
    } @catch (__unused NSException *e) {
        apps = [NSMutableDictionary dictionary];
    }

    // 越狱安装的 App（Dopamine、Sileo 等）不在 /var/containers 里，而在 <jbroot>/Applications。
    // 不扫这里就会出现"图标不显示"（bundle 路径取不到）。
    {
        const char *home = getenv("HOME");
        (void)home;
        NSMutableArray<NSString *> *jbDirs = [NSMutableArray array];
        // 从主可执行文件路径反推越狱根（App 在 <jbroot>/Applications/*.app/…）
        Dl_info info = {0};
        if (dladdr((const void *)&dh_collect, &info) != 0 && info.dli_fname) {
            NSString *path = [NSString stringWithUTF8String:info.dli_fname];
            for (int i = 0; i < 3; i++) path = [path stringByDeletingLastPathComponent];
            if (path.length > 1) [jbDirs addObject:[path stringByAppendingPathComponent:@"Applications"]];
        }
        [jbDirs addObject:@"/var/jb/Applications"];
        [jbDirs addObject:@"/Applications"];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *dir in jbDirs) {
            for (NSString *entry in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if (![entry.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                NSString *appPath = [dir stringByAppendingPathComponent:entry];
                NSDictionary *info2 = [NSDictionary dictionaryWithContentsOfFile:
                    [appPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleID = info2[@"CFBundleIdentifier"];
                if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) continue;
                if (apps[bundleID]) continue;   // LaunchServices 已给出更完整的名字
                NSString *name = info2[@"CFBundleDisplayName"] ?: info2[@"CFBundleName"];
                apps[bundleID] = @{ @"name": name.length ? name : bundleID, @"path": appPath };
            }
        }
    }

    if (apps.count == 0) {  // 兜底：直接扫容器目录（LaunchServices 不可用时）
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *containers =
            [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
        for (NSString *container in containers) {
            NSString *base = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:container];
            for (NSString *entry in [fm contentsOfDirectoryAtPath:base error:nil]) {
                if (![entry.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                NSString *appPath = [base stringByAppendingPathComponent:entry];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                    [appPath stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleID = info[@"CFBundleIdentifier"];
                if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) continue;
                NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
                apps[bundleID] = @{ @"name": name.length ? name : bundleID, @"path": appPath };
            }
        }
    }
    return apps;
}

NSArray<DHAppInfo *> *DHInstalledApps(void) {
    NSDictionary<NSString *, NSDictionary *> *raw = dh_collect();
    NSMutableArray<DHAppInfo *> *out = [NSMutableArray arrayWithCapacity:raw.count];
    for (NSString *bundleID in raw) {
        DHAppInfo *app = [[DHAppInfo alloc] init];
        app.bundleID = bundleID;
        app.name = raw[bundleID][@"name"];
        NSString *path = raw[bundleID][@"path"];
        app.bundlePath = path.length ? path : nil;
        [out addObject:app];
    }
    [out sortUsingComparator:^NSComparisonResult(DHAppInfo *l, DHAppInfo *r) {
        return [l.name localizedCaseInsensitiveCompare:r.name];
    }];
    return out;
}

UIImage *DHAppIcon(NSString *bundleID, NSString *_Nullable bundlePath) {
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (bundleID.length == 0) return nil;
    if (cache[bundleID]) return cache[bundleID];

    UIImage *icon = nil;
    // 系统图标缓存（越狱环境下可用，尺寸/圆角都由系统给）
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:scale:");
    if ([UIImage respondsToSelector:sel]) {
        @try {
            CGFloat scale = [UIScreen mainScreen].scale;
            id (*msg)(id, SEL, id, CGFloat) = (id (*)(id, SEL, id, CGFloat))objc_msgSend;
            icon = msg([UIImage class], sel, bundleID, scale);
        } @catch (__unused NSException *e) {
            icon = nil;
        }
    }
    // 兜底：读 bundle 内声明的图标文件
    if (!icon && bundlePath.length) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
            [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        id icons = info[@"CFBundleIcons"];
        id primary = [icons isKindOfClass:[NSDictionary class]] ? icons[@"CFBundlePrimaryIcon"] : nil;
        id files = [primary isKindOfClass:[NSDictionary class]] ? primary[@"CFBundleIconFiles"] : nil;
        if ([files isKindOfClass:[NSArray class]]) [names addObjectsFromArray:files];
        id legacy = info[@"CFBundleIconFiles"];
        if ([legacy isKindOfClass:[NSArray class]]) [names addObjectsFromArray:legacy];
        NSString *single = info[@"CFBundleIconFile"];
        if ([single isKindOfClass:[NSString class]]) [names addObject:single];
        for (NSString *name in names) {
            NSString *base = [name stringByDeletingPathExtension];
            for (NSString *suffix in @[ @"@3x", @"@2x", @"" ]) {
                NSString *file = [bundlePath stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@%@.png", base, suffix]];
                UIImage *candidate = [UIImage imageWithContentsOfFile:file];
                if (candidate) { icon = candidate; break; }
            }
            if (icon) break;
        }
    }
    if (icon) cache[bundleID] = icon;
    return icon;
}

#pragma mark - 列表外观

// iOS 图标的连续圆角近似为边长的 22.37%
static CGFloat dh_corner_radius(CGFloat size) { return size * 0.2237; }

static UIImage *dh_letter_icon(NSString *displayName, CGFloat size) {
    NSString *letter = @"?";
    for (NSUInteger i = 0; i < displayName.length; i++) {
        unichar c = [displayName characterAtIndex:i];
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) {
            letter = [[NSString stringWithFormat:@"%C", c] uppercaseString];
            break;
        }
    }
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
        initWithSize:CGSizeMake(size, size)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        const CGFloat radius = dh_corner_radius(size);
        [[UIColor tertiarySystemFillColor] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size) cornerRadius:radius] fill];
        NSDictionary *attrs = @{
            NSFontAttributeName: [UIFont systemFontOfSize:size * 0.44 weight:UIFontWeightSemibold],
            NSForegroundColorAttributeName: [UIColor secondaryLabelColor],
        };
        CGSize textSize = [letter sizeWithAttributes:attrs];
        [letter drawAtPoint:CGPointMake((size - textSize.width) / 2, (size - textSize.height) / 2)
             withAttributes:attrs];
    }];
}

UIImage *DHAppListIcon(NSString *bundleID, NSString *_Nullable bundlePath, NSString *_Nullable displayName) {
    static NSMutableDictionary<NSString *, UIImage *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });

    const CGFloat size = 40;
    NSString *key = [NSString stringWithFormat:@"%.0f|%@|%@", size, bundleID, displayName];
    if (cache[key]) return cache[key];

    UIImage *raw = DHAppIcon(bundleID, bundlePath);
    UIImage *out = nil;
    if (raw) {
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
            initWithSize:CGSizeMake(size, size)];
        out = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size, size)
                                       cornerRadius:dh_corner_radius(size)] addClip];
            [raw drawInRect:CGRectMake(0, 0, size, size)];
        }];
    } else {
        // 取不到图标也要有东西，不留空
        out = dh_letter_icon(displayName.length ? displayName : bundleID, size);
    }
    if (out) cache[key] = out;
    return out;
}

NSString *DHAppIndexLetter(NSString *displayName) {
    if (displayName.length == 0) return @"#";
    NSMutableString *text = [displayName mutableCopy];
    // 中文取拼音首字母（微信 → weixin → W）
    CFStringTransform((__bridge CFMutableStringRef)text, NULL, kCFStringTransformToLatin, false);
    CFStringTransform((__bridge CFMutableStringRef)text, NULL, kCFStringTransformStripDiacritics, false);
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= 'a' && c <= 'z') return [[NSString stringWithFormat:@"%C", c] uppercaseString];
        if (c >= 'A' && c <= 'Z') return [NSString stringWithFormat:@"%C", c];
        if (c >= '0' && c <= '9') return @"#";
    }
    return @"#";
}

#pragma mark - 运行状态

// 与 daemon 相同的匹配规则：p_comm 最长 16 字节，短名精确比、长名比前缀
static BOOL dh_process_running(const char *want) {
    if (!want || !want[0]) return NO;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return NO;
    BOOL found = NO;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        size_t count = len / sizeof(struct kinfo_proc);
        size_t wantLen = strlen(want);
        for (size_t i = 0; i < count; i++) {
            char comm[MAXCOMLEN + 1];
            memcpy(comm, procs[i].kp_proc.p_comm, MAXCOMLEN);
            comm[MAXCOMLEN] = '\0';
            BOOL match = (wantLen <= MAXCOMLEN - 1)
                ? (strcmp(comm, want) == 0)
                : (strncmp(comm, want, MAXCOMLEN - 1) == 0);
            if (match) { found = YES; break; }
        }
    }
    free(procs);
    return found;
}

static NSString *dh_bundle_executable(NSString *bundlePath) {
    static NSMutableDictionary<NSString *, NSString *> *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; });
    if (bundlePath.length == 0) return nil;
    if (cache[bundlePath]) return cache[bundlePath];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
        [bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *exec = info[@"CFBundleExecutable"];
    if (![exec isKindOfClass:[NSString class]] || exec.length == 0) exec = nil;
    if (exec) cache[bundlePath] = exec;
    return exec;
}

BOOL DHAppProcessRunning(DHAppInfo *app) {
    NSString *exec = dh_bundle_executable(app.bundlePath);
    if (exec.length == 0) return NO;      // 拿不到可执行名就当没在跑：宁可不动作，也不误杀/误启
    return dh_process_running(exec.UTF8String);
}

BOOL DHKillAppProcess(DHAppInfo *app) {
    NSString *exec = dh_bundle_executable(app.bundlePath);
    if (exec.length == 0) return NO;
    const char *want = exec.UTF8String;
    if (!want || !want[0]) return NO;
    pid_t selfPid = getpid();
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return NO;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return NO;
    BOOL killed = NO;
    if (sysctl(mib, 4, procs, &len, NULL, 0) == 0) {
        size_t count = len / sizeof(struct kinfo_proc);
        size_t wantLen = strlen(want);
        for (size_t i = 0; i < count; i++) {
            pid_t pid = procs[i].kp_proc.p_pid;
            if (pid <= 1 || pid == selfPid) continue;
            char comm[MAXCOMLEN + 1];
            memcpy(comm, procs[i].kp_proc.p_comm, MAXCOMLEN);
            comm[MAXCOMLEN] = '\0';
            BOOL match = (wantLen <= MAXCOMLEN - 1)
                ? (strcmp(comm, want) == 0)
                : (strncmp(comm, want, MAXCOMLEN - 1) == 0);
            if (match && kill(pid, SIGKILL) == 0) killed = YES;
        }
    }
    free(procs);
    return killed;
}

static NSString *_Nullable dh_manager_jbroot(void) {
    Dl_info info = {0};
    if (dladdr((const void *)&dh_manager_jbroot, &info) == 0 || !info.dli_fname) return nil;
    NSString *root = [NSString stringWithUTF8String:info.dli_fname];
    for (int i = 0; i < 3; i++) root = [root stringByDeletingLastPathComponent];
    return root.length ? root : nil;
}

static BOOL dh_open_with_workspace(NSString *bundleID) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    static const char *frameworks[] = {
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        NULL,
    };
    for (NSUInteger i = 0; !workspaceClass && frameworks[i]; i++) {
        dlopen(frameworks[i], RTLD_LAZY | RTLD_LOCAL);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }
    if (!workspaceClass || ![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) return NO;
    id workspace = [workspaceClass defaultWorkspace];
    if (![workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) return NO;
    @try {
        return [workspace openApplicationWithBundleID:bundleID];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static BOOL dh_open_with_sbs(NSString *bundleID) {
    void *sbs = dlopen(
        "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        RTLD_LAZY | RTLD_LOCAL);
    if (!sbs) return NO;
    typedef int (*SBSLaunchFn)(CFStringRef, Boolean);
    SBSLaunchFn launch = (SBSLaunchFn)dlsym(sbs, "SBSLaunchApplicationWithIdentifier");
    if (!launch) return NO;
    return launch((__bridge CFStringRef)bundleID, false) == 0;
}

static BOOL dh_open_with_uiopen(NSString *bundleID) {
    NSMutableArray<NSString *> *tools = [NSMutableArray array];
    NSString *root = dh_manager_jbroot();
    if (root) [tools addObject:[root stringByAppendingPathComponent:@"usr/bin/uiopen"]];
    [tools addObject:@"/usr/bin/uiopen"];
    [tools addObject:@"/var/jb/usr/bin/uiopen"];
    [tools addObject:@"/usr/local/bin/uiopen"];
    for (NSString *tool in tools) {
        if (access(tool.fileSystemRepresentation, X_OK) != 0) continue;
        pid_t pid = 0;
        const char *argv[] = {
            tool.fileSystemRepresentation, "--bundleid", bundleID.UTF8String, NULL
        };
        if (posix_spawn(&pid, argv[0], NULL, NULL, (char * const *)argv, environ) == 0) {
            return YES;
        }
    }
    return NO;
}

BOOL DHRelaunchApp(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    if (dh_open_with_workspace(bundleID)) return YES;
    if (dh_open_with_sbs(bundleID)) return YES;
    return dh_open_with_uiopen(bundleID);
}
