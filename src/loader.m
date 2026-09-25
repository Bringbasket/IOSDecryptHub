// loader.m — IOSDecryptHub 越狱注入加载器
//
// 由 ElleKit 或 rootful Substitute 加载到 UIKit App，以及可选的
// com.apple.WebKit.Networking（Filter 使用 Mode=Any）。
// 唯一职责：读取偏好设置 → 判断当前 App 是否启用 → dlopen 主 dylib。
// 不包含任何 hook 逻辑。hook 全部由主 dylib 的 constructor 完成。
//
// rootless 路径：
//   /var/jb/usr/lib/IOSDecryptHub/decrypt_helper.dylib

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <syslog.h>
#import "dh_shared.h"

#define LOADER_TAG      "[IOSDecryptHub]"
#define PREFS_PATH      @"/var/mobile/Library/Preferences/com.iosdecrypthub.loader.plist"
#define ENGINE_REL      @"usr/lib/IOSDecryptHub/decrypt_helper.dylib"
#define CONFIG_REL      @"usr/lib/IOSDecryptHub/config/enabledBundles.plist"

// 不依赖 /var/jb，也不用 access()/fileExists 探路（宿主沙盒会谎称不存在）。
// loader 实际可能在：
//   <jb>/Library/MobileSubstrate/DynamicLibraries/  （本包安装位置，向上 4 级到 jbroot）
//   <jb>/usr/lib/TweakInject/                       （ElleKit 加载位置，同样向上 4 级）
// 旧逻辑只向上 2 级再拼 IOSDecryptHub/…，仅 TweakInject 布局碰巧正确。
static void dh_add_unique(NSMutableArray<NSString *> *paths, NSString *path) {
    if (path.length && ![paths containsObject:path]) [paths addObject:path];
}

static NSArray<NSString *> *dh_paths_from_loader(NSString *relativeToJbroot) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    Dl_info info = {0};
    if (dladdr((const void *)&dh_paths_from_loader, &info) != 0 && info.dli_fname) {
        NSString *cur = [NSString stringWithUTF8String:info.dli_fname];
        for (int i = 0; i < 4 && cur.length > 1; i++) {
            cur = [cur stringByDeletingLastPathComponent];
        }
        if (cur.length > 1) {
            dh_add_unique(paths, [cur stringByAppendingPathComponent:relativeToJbroot]);
        }
        // 兼容 TweakInject：向上 2 级 = usr/lib，相对路径去掉 usr/lib/ 前缀
        NSString *loaderPath = [NSString stringWithUTF8String:info.dli_fname];
        NSString *usrLib = [[loaderPath stringByDeletingLastPathComponent]
            stringByDeletingLastPathComponent];
        if ([relativeToJbroot hasPrefix:@"usr/lib/"] && usrLib.length > 1) {
            dh_add_unique(paths, [usrLib stringByAppendingPathComponent:
                [relativeToJbroot substringFromIndex:8]]);
        }
    }
    // rootful Substitute / MobileSubstrate: 主引擎直接位于 /usr/lib。
    dh_add_unique(paths, [@"/" stringByAppendingString:relativeToJbroot]);
    dh_add_unique(paths, [@"/var/jb/" stringByAppendingString:relativeToJbroot]);
    return paths;
}

static NSArray<NSString *> *dh_dylib_candidates(void) {
    return dh_paths_from_loader(ENGINE_REL);
}

static NSArray<NSString *> *dh_config_candidates(void) {
    return dh_paths_from_loader(CONFIG_REL);
}

// 说明：曾短暂加过"我们自己的组件不注入"的特例（想让管理器 App 里不弹悬浮窗），
// 已撤销 —— 用户反馈里看到的悬浮窗真正原因是"开关被打开了"，不是产品行为异常。
// 开关语义保持处处一致：列在名单里的 App 就会被注入，没有例外。
// 相关：管理器 App 与设置面板同样出现在列表里，可以被显式打开（例如当服务宿主用）。

static NSDictionary *dh_read_loader_domain(const char **sourceOut) {
    NSDictionary *domain = nil;
    const char *source = "none";
    @try {
        // prefs 读到完整字典就用。沙盒目标通常读不到这份文件，再回退 jb 配置；
        // 禁止在宿主进程里 Synchronize 此外域，以免阻塞目标 App 的启动路径。
        domain = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
        if ([domain isKindOfClass:[NSDictionary class]]) {
            source = "prefs";
        } else {
            CFPropertyListRef bundlesRef = CFPreferencesCopyAppValue(
                (__bridge CFStringRef)DH_KEY_BUNDLES,
                (__bridge CFStringRef)DH_DOMAIN_LOADER);
            CFPropertyListRef featuresRef = CFPreferencesCopyAppValue(
                (__bridge CFStringRef)DH_KEY_FEATURES,
                (__bridge CFStringRef)DH_DOMAIN_LOADER);
            id bundles = CFBridgingRelease(bundlesRef);
            id features = CFBridgingRelease(featuresRef);
            if ([bundles isKindOfClass:[NSArray class]] ||
                [features isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
                if ([bundles isKindOfClass:[NSArray class]]) prefs[DH_KEY_BUNDLES] = bundles;
                if ([features isKindOfClass:[NSDictionary class]]) prefs[DH_KEY_FEATURES] = features;
                domain = prefs;
                source = "cfprefs";
            } else {
                for (NSString *configPath in dh_config_candidates()) {
                    NSDictionary *candidate = [NSDictionary dictionaryWithContentsOfFile:configPath];
                    if ([candidate isKindOfClass:[NSDictionary class]]) {
                        domain = candidate;
                        source = "jb";
                        break;
                    }
                }
            }
        }
    } @catch (__unused NSException *exception) {
        domain = nil;
    }
    if (sourceOut) *sourceOut = source;
    return domain;
}

static BOOL dh_feature_enabled(NSDictionary *domain, NSString *key, BOOL defaultValue) {
    id features = domain[DH_KEY_FEATURES];
    id value = [features isKindOfClass:[NSDictionary class]] ? features[key] : nil;
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : defaultValue;
}

static BOOL dh_is_webkit_networking(NSString *bundleID, NSString *processName) {
    return [processName isEqualToString:@"com.apple.WebKit.Networking"] ||
           [bundleID isEqualToString:@"com.apple.WebKit.Networking"];
}

// 读取偏好：普通 App 按启用名单；WebKit Networking 由独立全局开关控制。
static BOOL dh_should_inject(NSString *bundleID, NSString *processName) {
    const char *source = "none";
    NSDictionary *domain = dh_read_loader_domain(&source);
    if (![domain isKindOfClass:[NSDictionary class]]) return NO;
    if (!dh_feature_enabled(domain, DH_FEATURE_MASTER, YES)) return NO;

    if (dh_is_webkit_networking(bundleID, processName)) {
        BOOL enabled = dh_feature_enabled(domain, DH_FEATURE_WEBKIT_PROCESS, NO);
        if (enabled) {
            syslog(LOG_NOTICE, LOADER_TAG " 将主引擎注入 WebKit Networking source=%s", source);
        }
        return enabled;
    }

    if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) return NO;
    id raw = domain[DH_KEY_BUNDLES];
    if (![raw isKindOfClass:[NSArray class]]) return NO;
    NSArray *enabled = raw;
    BOOL hit = [enabled containsObject:bundleID];
    if (hit) {
        syslog(LOG_NOTICE, LOADER_TAG " 将注入 %s source=%s",
               bundleID.UTF8String, source);
    }
    return hit;
}

__attribute__((constructor))
static void dh_loader_init(void) {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSString *processName = [NSProcessInfo processInfo].processName;

        // 默认不注入任何 App —— 只有用户在设置中明确开启的才注入
        if (!dh_should_inject(bundleID, processName)) {
            return;
        }

        // 不先用 access() 探测：宿主沙盒可能拒绝路径查询，但 dyld 仍可加载由越狱
        // 注入框架授权的镜像。逐个 dlopen 才能得到真实结果。
        for (NSString *dylibPath in dh_dylib_candidates()) {
            syslog(LOG_INFO, LOADER_TAG " 注入 %s → %s",
                   (bundleID.length ? bundleID : processName).UTF8String,
                   dylibPath.UTF8String);
            void *handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_NOW);
            if (handle) return;
        }
        syslog(LOG_ERR, LOADER_TAG " 主 dylib 加载失败 (%s): %s",
               (bundleID.length ? bundleID : processName).UTF8String,
               dlerror() ?: "unknown error");
    }
}
