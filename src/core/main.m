// main.m - IOSDecryptHub (Decrypt Helper)
// 注入入口：普通 App 按管理器功能开关安装模块并初始化悬浮窗；
// com.apple.WebKit.Networking 复用同一引擎，但只启动低层网络采集并汇总到目标 App 服务。

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <unistd.h>
#if __has_include(<UIKit/UIKit.h>)
#import <UIKit/UIKit.h>
#endif
#import "../dh_shared.h"
#import "log_store.h"
#import "ui_float.h"
#import "http_server.h"
#import "dh_health.h"
#import "dh_capture.h"
#import "dh_noise.h"
#import "dh_spoof.h"
#import "hook_network.h"
#import "hook_webkit.h"
#import "dh_collector.h"

extern void dh_install_digest_hooks(void);
extern void dh_install_hmac_hooks(void);
extern void dh_install_symmetric_hooks(void);
extern void dh_install_asymmetric_hooks(void);
extern void dh_install_kdf_hooks(void);
extern void dh_install_evp_hooks(void);
extern void dh_install_file_hooks(void);
extern void dh_install_system_hooks(void);
extern void dh_install_keychain_hooks(void);
extern void dh_install_env_hooks(void);
extern void dh_install_spoof_objc_hooks(void);
extern void dh_install_dyld_hooks(void);
extern void dh_install_network_hooks(void);
extern void dh_install_webkit_hooks(void);

static NSDictionary<NSString *, NSNumber *> *dh_global_feature_defaults(void) {
    return @{
        DH_FEATURE_MASTER: @YES,
        DH_FEATURE_WEBKIT_PROCESS: @NO,
        DH_FEATURE_NETWORK: @YES,
        DH_FEATURE_WEBKIT_JS: @NO,
        DH_FEATURE_DIGEST: @YES,
        DH_FEATURE_HMAC: @YES,
        DH_FEATURE_SYMMETRIC: @YES,
        DH_FEATURE_EVP: @YES,
        DH_FEATURE_ASYMMETRIC: @YES,
        DH_FEATURE_KDF: @YES,
        DH_FEATURE_KEYCHAIN: @YES,
        DH_FEATURE_FILE: @YES,
        DH_FEATURE_ENVIRONMENT: @YES,
    };
}

static NSDictionary<NSString *, NSNumber *> *dh_read_global_features(void) {
    NSMutableDictionary *features = [dh_global_feature_defaults() mutableCopy];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];

    Dl_info info = {0};
    if (dladdr((const void *)&dh_read_global_features, &info) != 0 && info.dli_fname) {
        NSString *engine = [NSString stringWithUTF8String:info.dli_fname];
        NSString *engineDir = [engine stringByDeletingLastPathComponent];
        if (engineDir.length) {
            [paths addObject:[engineDir stringByAppendingPathComponent:@"config/enabledBundles.plist"]];
        }
    }
    [paths addObject:DH_LOADER_PREFS];
    [paths addObject:@"/var/jb/usr/lib/IOSDecryptHub/config/enabledBundles.plist"];

    NSDictionary *rawFeatures = nil;
    for (NSString *path in paths) {
        NSDictionary *domain = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([domain[DH_KEY_FEATURES] isKindOfClass:[NSDictionary class]]) {
            rawFeatures = domain[DH_KEY_FEATURES];
            break;
        }
    }
    if (!rawFeatures) {
        CFPropertyListRef raw = CFPreferencesCopyAppValue(
            (__bridge CFStringRef)DH_KEY_FEATURES,
            (__bridge CFStringRef)DH_DOMAIN_LOADER);
        id value = CFBridgingRelease(raw);
        if ([value isKindOfClass:[NSDictionary class]]) rawFeatures = value;
    }
    [rawFeatures enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
        if ([features[key] isKindOfClass:[NSNumber class]] &&
            [value isKindOfClass:[NSNumber class]]) {
            features[key] = @([value boolValue]);
        }
    }];
    return features;
}

static BOOL dh_feature(NSDictionary *features, NSString *key) {
    id value = features[key];
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

static BOOL dh_is_webkit_networking_process(void) {
    NSString *processName = [NSProcessInfo processInfo].processName;
    NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
    return [processName isEqualToString:@"com.apple.WebKit.Networking"] ||
           [bundleID isEqualToString:@"com.apple.WebKit.Networking"];
}

static void dh_apply_capture_gates(NSDictionary *features) {
    dh_capture_set_global_master(dh_feature(features, DH_FEATURE_MASTER));
    dh_capture_set_global_sub(DH_CAP_DIGEST, dh_feature(features, DH_FEATURE_DIGEST));
    dh_capture_set_global_sub(DH_CAP_HMAC, dh_feature(features, DH_FEATURE_HMAC));
    dh_capture_set_global_sub(DH_CAP_SYMMETRIC, dh_feature(features, DH_FEATURE_SYMMETRIC));
    dh_capture_set_global_sub(DH_CAP_EVP, dh_feature(features, DH_FEATURE_EVP));
    dh_capture_set_global_sub(DH_CAP_ASYMMETRIC, dh_feature(features, DH_FEATURE_ASYMMETRIC));
    dh_capture_set_global_sub(DH_CAP_KDF, dh_feature(features, DH_FEATURE_KDF));
    dh_capture_set_global_sub(DH_CAP_KEYCHAIN, dh_feature(features, DH_FEATURE_KEYCHAIN));
    dh_capture_set_global_sub(DH_CAP_NETWORK, dh_feature(features, DH_FEATURE_NETWORK));

    BOOL file = dh_feature(features, DH_FEATURE_FILE);
    dh_capture_set_global_sub(DH_CAP_FILE_OPEN, file);
    dh_capture_set_global_sub(DH_CAP_FILE_WRITE, file);
    dh_capture_set_global_sub(DH_CAP_FILE_READ, file);
    dh_capture_set_global_sub(DH_CAP_FILE_MMAP, file);
    dh_capture_set_global_sub(DH_CAP_FILE_UNLINK, file);
    dh_capture_set_global_sub(DH_CAP_FILE_RENAME, file);

    BOOL environment = dh_feature(features, DH_FEATURE_ENVIRONMENT);
    dh_capture_set_global_sub(DH_CAP_SYS_DLOPEN, environment);
    dh_capture_set_global_sub(DH_CAP_SYS_DLSYM, environment);
    dh_capture_set_global_sub(DH_CAP_ENV_PROBE, environment);
}

static void dh_install_selected_hooks(NSDictionary *features) {
    if (dh_feature(features, DH_FEATURE_DIGEST)) dh_install_digest_hooks();
    if (dh_feature(features, DH_FEATURE_HMAC)) dh_install_hmac_hooks();
    if (dh_feature(features, DH_FEATURE_SYMMETRIC)) dh_install_symmetric_hooks();
    if (dh_feature(features, DH_FEATURE_ASYMMETRIC)) dh_install_asymmetric_hooks();
    if (dh_feature(features, DH_FEATURE_KDF)) dh_install_kdf_hooks();
    if (dh_feature(features, DH_FEATURE_EVP)) dh_install_evp_hooks();
    if (dh_feature(features, DH_FEATURE_FILE)) dh_install_file_hooks();
    if (dh_feature(features, DH_FEATURE_ENVIRONMENT)) {
        dh_install_system_hooks();
        dh_install_env_hooks();
        dh_install_spoof_objc_hooks();
        dh_install_dyld_hooks();
    }
    if (dh_feature(features, DH_FEATURE_KEYCHAIN)) dh_install_keychain_hooks();
    if (dh_feature(features, DH_FEATURE_NETWORK)) dh_install_network_hooks();
    if (dh_feature(features, DH_FEATURE_WEBKIT_JS)) dh_install_webkit_hooks();
}

static NSString *dh_runtime_data_dir(BOOL webKitProcess) {
    if (!webKitProcess) {
        NSString *documents = [NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        if (documents.length) return documents;
    }
    NSString *base = NSTemporaryDirectory();
    if (base.length == 0) base = @"/tmp";
    NSString *dir = [base stringByAppendingPathComponent:
        [NSString stringWithFormat:@"IOSDecryptHub-%d", getpid()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
        withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

__attribute__((constructor))
static void dh_bootstrap(void) {
    @autoreleasepool {
        NSDictionary *features = dh_read_global_features();
        BOOL webKitProcess = dh_is_webkit_networking_process();
        if (!dh_feature(features, DH_FEATURE_MASTER)) return;
        // 直接手动注入主引擎时也遵守管理器开关；越狱 loader 已在 dlopen 前做第一层门控。
        if (webKitProcess && !dh_feature(features, DH_FEATURE_WEBKIT_PROCESS)) return;

        NSString *docsDir = dh_runtime_data_dir(webKitProcess);
        dh_collector_configure(webKitProcess);
        if (webKitProcess && docsDir.length) {
            // LogStore 初始化前指定独立目录，避免多个 WebKit Network 进程争用同一日志文件。
            setenv("DH_LOG_DIR", docsDir.fileSystemRepresentation, 1);
        }
    // 预热 Foundation 的 locale / NSDateFormatter / backtrace, 避免 hook 安装后首次时间格式化
    // 在 hooked_open 内部触发 open/dlopen 递归(与 dh_in_hook 标志双保险).
        (void)DHTimestampNow();
        (void)DHCallStackFiltered();
    // 诊断落盘目录 + 捕获配置, 都在装 hook 前就绪(持久化的开关/诊断从一开始生效)。
        dh_diag_set_dir(docsDir.fileSystemRepresentation);
        dh_diag_append(DH_DIAG_GENERAL, "INFO", webKitProcess
            ? "IOSDecryptHub WebKit 轻量模式启动"
            : "IOSDecryptHub 启动, 开始安装 hook");
        dh_capture_load([docsDir stringByAppendingPathComponent:@".dh_capture.conf"].fileSystemRepresentation);
        dh_noise_load([docsDir stringByAppendingPathComponent:@".dh_noise.conf"]);
        dh_apply_capture_gates(features);

        if (webKitProcess) {
        // 同一主引擎、不同启动档位：系统网络进程只装低层网络 hook。
        // 不加载浮窗、Dump、ObjC/文件/环境/加密 hook，尽量缩小系统进程影响面。
            if (dh_feature(features, DH_FEATURE_NETWORK)) {
                dh_install_network_process_hooks();
                dh_diag_append(DH_DIAG_GENERAL, "INFO",
                    "WebKit Networking hooks installed (SSL/SecureTransport/socket/Network.framework)");
            }
            NSLog(@"[IOSDecryptHub] WebKit Networking 轻量采集已启动，事件将汇总到目标 App 面板");
            return;
        }

        dh_spoof_load([docsDir stringByAppendingPathComponent:@".dh_spoof.conf"]);
        dh_webkit_probe_load([docsDir stringByAppendingPathComponent:@".dh_webkit_probe.conf"],
                             dh_feature(features, DH_FEATURE_WEBKIT_JS));
    // 安装 hook —— 尽早完成, 否则早期发生的加解密会漏抓.
        dh_install_selected_hooks(features);
        dh_diag_append(DH_DIAG_GENERAL, "INFO", "按管理器功能开关安装 hook 完成");
        NSLog(@"[IOSDecryptHub] 已按功能开关安装 hook");

    // 本地 HTTP 服务放到后台起: constructor 处在宿主 launch 的看门狗预算里
    // (实测 B站 launch 阶段被 0x8badf00d 杀掉), 起 socket/线程不该抢这段时间。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dh_http_start();
        });

#if __has_include(<UIKit/UIKit.h>)
    // UI 必须等 UIApplication 实例化后再做; 用 didFinishLaunching 通知做后置初始化.
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                       object:nil queue:nil usingBlock:^(NSNotification *_) {
        dh_ui_install_floating();
    }];
    // 进入后台/退出前把批量缓冲刷盘, 避免 App 被挂起/终止时丢掉最后一批低价值事件。
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                       object:nil queue:nil usingBlock:^(NSNotification *_) {
        [[DHLogStore shared] flush];
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                       object:nil queue:nil usingBlock:^(NSNotification *_) {
        [[DHLogStore shared] flush];
    }];
    // 一些 app 加载 dylib 时 UIApplication 已经存在, 直接尝试创建一次, 失败也无所谓.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        dh_ui_install_floating();
    });
#endif

        NSLog(@"[IOSDecryptHub] 日志文件: %@", [[DHLogStore shared] logFilePath]);
    }
}
