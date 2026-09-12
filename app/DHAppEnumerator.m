// DHAppEnumerator.m — 逻辑与设置面板保持一致（同一份私有 API 最小声明）

#import "DHAppEnumerator.h"
#import <dlfcn.h>

@interface NSObject (DHLaunchServices)
+ (instancetype)defaultWorkspace;
- (NSArray *)allApplications;
- (NSString *)applicationIdentifier;
- (NSString *)localizedName;
- (NSString *)applicationType;
@end

static NSDictionary<NSString *, NSString *> *dh_apps_from_launch_services(void) {
    static const char *frameworks[] = {
        "/System/Library/PrivateFrameworks/MobileCoreServices.framework/MobileCoreServices",
        "/System/Library/Frameworks/CoreServices.framework/CoreServices",
        NULL,
    };
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    for (NSUInteger i = 0; !workspaceClass && frameworks[i]; i++) {
        dlopen(frameworks[i], RTLD_LAZY | RTLD_LOCAL);
        workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    }
    if (!workspaceClass || ![workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        return @{};
    }
    NSMutableDictionary<NSString *, NSString *> *apps = [NSMutableDictionary dictionary];
    @try {
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
            apps[bundleID] = name.length > 0 ? name : bundleID;
        }
    } @catch (__unused NSException *e) {
        return @{};
    }
    return apps;
}

static NSDictionary<NSString *, NSString *> *dh_apps_from_filesystem(void) {
    NSMutableDictionary<NSString *, NSString *> *apps = [NSMutableDictionary dictionary];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *containers =
            [fm contentsOfDirectoryAtPath:@"/var/containers/Bundle/Application" error:nil];
        for (NSString *container in containers) {
            NSString *base = [@"/var/containers/Bundle/Application" stringByAppendingPathComponent:container];
            for (NSString *entry in [fm contentsOfDirectoryAtPath:base error:nil]) {
                if (![entry.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                    [[base stringByAppendingPathComponent:entry] stringByAppendingPathComponent:@"Info.plist"]];
                NSString *bundleID = info[@"CFBundleIdentifier"];
                if (bundleID.length == 0 || [bundleID hasPrefix:@"com.apple."]) continue;
                NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
                apps[bundleID] = name.length > 0 ? name : bundleID;
            }
        }
    } @catch (__unused NSException *e) {
    }
    return apps;
}

NSDictionary<NSString *, NSString *> *DHInstalledApps(void) {
    NSDictionary<NSString *, NSString *> *apps = dh_apps_from_launch_services();
    if (apps.count == 0) apps = dh_apps_from_filesystem();
    return apps ?: @{};
}
