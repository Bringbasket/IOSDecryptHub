// DHConfigStore.m — 见头文件注释

#import "DHConfigStore.h"
#import "dh_shared.h"
#import <dlfcn.h>

NSString *_Nullable DHBootstrapRoot(void) {
    Dl_info info = {0};
    if (dladdr((const void *)&DHBootstrapRoot, &info) == 0 || !info.dli_fname) {
        return nil;
    }
    NSString *binaryPath = [NSString stringWithUTF8String:info.dli_fname];
    // App 布局: <bootstrap>/Applications/IOSDecryptHubManager.app/IOSDecryptHubManager
    // 向上三级回到 <bootstrap>
    NSString *root = binaryPath;
    for (int i = 0; i < 3; i++) {
        root = [root stringByDeletingLastPathComponent];
    }
    if (root.length <= 1) return nil;
    return root;
}

static NSArray<NSString *> *dh_engine_dir_candidates(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *root = DHBootstrapRoot();
    if (root) {
        [dirs addObject:[root stringByAppendingPathComponent:@"usr/lib/IOSDecryptHub"]];
    }
    [dirs addObject:@"/var/jb/usr/lib/IOSDecryptHub"];
    return dirs;
}

static NSString *_Nullable dh_existing_engine_dir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    for (NSString *dir in dh_engine_dir_candidates()) {
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) return dir;
    }
    return nil;
}

static NSString *_Nullable dh_config_path(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *root = DHBootstrapRoot();
    if (root) {
        NSString *configRel = [@"usr/lib" stringByAppendingPathComponent:DH_CONFIG_REL];
        [paths addObject:[root stringByAppendingPathComponent:configRel]];
    }
    [paths addObject:@"/var/jb/usr/lib/IOSDecryptHub/config/enabledBundles.plist"];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        if ([fm fileExistsAtPath:path]) return path;
    }
    return paths.firstObject;
}

NSSet<NSString *> *DHReadEnabledBundles(void) {
    @try {
        NSDictionary *domain = [NSDictionary dictionaryWithContentsOfFile:dh_config_path()];
        id value = domain[DH_KEY_BUNDLES];
        if ([value isKindOfClass:[NSArray class]]) return [NSSet setWithArray:value];
    } @catch (__unused NSException *e) {
    }
    return [NSSet set];
}

BOOL DHWriteEnabledBundles(NSSet<NSString *> *bundleIDs) {
    NSString *path = dh_config_path();
    if (!path) return NO;
    NSArray *values = [[bundleIDs allObjects] sortedArrayUsingSelector:@selector(compare:)];
    NSDictionary *domain = @{DH_KEY_BUNDLES: values};

    @try {
        // loader 认这个文件：权威写入
        if (![domain writeToFile:path atomically:YES]) return NO;
    } @catch (__unused NSException *e) {
        return NO;
    }

    @try {
        // cfprefs 同步一份，兼容旧读取路径；失败不影响结果
        CFPreferencesSetValue((__bridge CFStringRef)DH_KEY_BUNDLES,
            (__bridge CFPropertyListRef)values,
            (__bridge CFStringRef)DH_DOMAIN_LOADER,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize((__bridge CFStringRef)DH_DOMAIN_LOADER,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    } @catch (__unused NSException *e) {
        // 部分越狱环境不支持对 AnyHost 写入 CFPreferences；文件已经写成功即可。
    }
    return YES;
}

NSDictionary *DHReadEngineMeta(void) {
    NSString *dir = dh_existing_engine_dir();
    if (!dir) return @{};
    @try {
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
            [dir stringByAppendingPathComponent:DH_VERSION_FILE]];
        if ([meta isKindOfClass:[NSDictionary class]]) return meta;
    } @catch (__unused NSException *e) {
    }
    return @{};
}

NSDictionary *DHReadUpdaterState(void) {
    NSString *dir = dh_existing_engine_dir();
    if (!dir) return @{};
    @try {
        NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:
            [dir stringByAppendingPathComponent:DH_STATE_FILE]];
        if ([state isKindOfClass:[NSDictionary class]]) return state;
    } @catch (__unused NSException *e) {
    }
    return @{};
}

BOOL DHWriteUpdateRequest(NSString *action, NSString *_Nullable version) {
    NSMutableDictionary *request = [NSMutableDictionary dictionary];
    request[@"action"] = action ?: DH_REQ_NONE;
    request[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    if (version.length) request[@"version"] = version;   // 指定版本安装（历史版本）
    NSDictionary *req = request;
    @try {
        return [req writeToFile:DH_REQUEST_PATH atomically:YES];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static NSString *dh_strip_v(NSString *s) {
    if ([s hasPrefix:@"v"] || [s hasPrefix:@"V"]) return [s substringFromIndex:1];
    return s;
}

NSComparisonResult DHCompareVersions(NSString *left, NSString *right) {
    NSArray<NSString *> *a = [dh_strip_v(left ?: @"") componentsSeparatedByString:@"."];
    NSArray<NSString *> *b = [dh_strip_v(right ?: @"") componentsSeparatedByString:@"."];
    NSUInteger n = MAX(a.count, b.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger x = (i < a.count) ? a[i].integerValue : 0;
        NSInteger y = (i < b.count) ? b[i].integerValue : 0;
        if (x < y) return NSOrderedAscending;
        if (x > y) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

// 必须持有 session：局部变量出作用域即释放，任务会被取消（表现为"没网"）
static NSURLSession *dh_shared_session(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 20;
        cfg.timeoutIntervalForResource = 30;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

// 错误信息带上域与码，便于定位（只说"没网"没法排查）
static NSError *dh_net_error(NSError *error) {
    if (!error) return nil;
    NSString *text = [NSString stringWithFormat:@"%@（%@ %ld）",
        error.localizedDescription, error.domain, (long)error.code];
    return [NSError errorWithDomain:error.domain code:error.code
                           userInfo:@{NSLocalizedDescriptionKey: text}];
}

void DHFetchLatestRelease(void (^completion)(NSDictionary *_Nullable, NSError *_Nullable)) {
    NSURL *url = [NSURL URLWithString:DH_GITHUB_LATEST];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil,
            [NSError errorWithDomain:@"DHManager" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"更新地址无效"}]); });
        return;
    }
    NSURLSession *session = dh_shared_session();
    [[session dataTaskWithURL:url completionHandler:^(NSData *_Nullable data,
        __unused NSURLResponse *_Nullable response, NSError *_Nullable error) {
        NSDictionary *info = nil;
        NSError *err = dh_net_error(error);
        if (!err) {
            @try {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                    options:0 error:&err];
                NSString *tag = json[@"tag_name"];
                if (!err && [tag isKindOfClass:[NSString class]] && tag.length) {
                    info = @{@"tag": tag, @"version": dh_strip_v(tag)};
                } else if (!err) {
                    err = [NSError errorWithDomain:@"DHManager" code:-2 userInfo:
                        @{NSLocalizedDescriptionKey: @" release 信息缺失 tag_name"}];
                }
            } @catch (__unused NSException *e) {
                err = [NSError errorWithDomain:@"DHManager" code:-3 userInfo:
                    @{NSLocalizedDescriptionKey: @"release 信息解析失败"}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(info, err); });
    }] resume];
}

BOOL DHWriteRestartRequest(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    NSDictionary *req = @{
        @"action": DH_REQ_RESTART,
        @"bundle": bundleID,
        @"time": @([[NSDate date] timeIntervalSince1970]),
    };
    @try {
        return [req writeToFile:DH_REQUEST_PATH atomically:YES];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

BOOL DHWriteStopRequest(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    NSDictionary *req = @{
        @"action": DH_REQ_STOP,
        @"bundle": bundleID,
        @"time": @([[NSDate date] timeIntervalSince1970]),
    };
    @try {
        return [req writeToFile:DH_REQUEST_PATH atomically:YES];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

#pragma mark - 历史版本

#define DH_RELEASES_API @"https://api.github.com/repos/decrypthub/IOSDecryptHub/releases?per_page=30"

void DHFetchReleases(void (^completion)(NSArray<NSDictionary *> *_Nullable, NSError *_Nullable)) {
    NSURL *url = [NSURL URLWithString:DH_RELEASES_API];
    NSURLSession *session = dh_shared_session();
    [[session dataTaskWithURL:url completionHandler:^(NSData *_Nullable data,
        __unused NSURLResponse *_Nullable response, NSError *_Nullable error) {
        NSArray<NSDictionary *> *list = nil;
        NSError *err = dh_net_error(error);
        if (!err) {
            @try {
                id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
                if (!err && [json isKindOfClass:[NSArray class]]) {
                    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
                    NSISO8601DateFormatter *parser = [[NSISO8601DateFormatter alloc] init];
                    NSDateFormatter *writer = [[NSDateFormatter alloc] init];
                    writer.dateFormat = @"yyyy-MM-dd";
                    for (id item in (NSArray *)json) {
                        if (![item isKindOfClass:[NSDictionary class]]) continue;
                        NSString *tag = item[@"tag_name"];
                        if (![tag isKindOfClass:[NSString class]] || tag.length == 0) continue;
                        if ([item[@"draft"] boolValue]) continue;
                        NSString *date = @"";
                        NSString *published = item[@"published_at"];
                        if ([published isKindOfClass:[NSString class]]) {
                            NSDate *parsed = [parser dateFromString:published];
                            if (parsed) date = [writer stringFromDate:parsed];
                        }
                        [out addObject:@{ @"tag": tag,
                                          @"version": [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag,
                                          @"date": date }];
                    }
                    list = out;
                } else if (!err) {
                    err = [NSError errorWithDomain:@"DHManager" code:-1 userInfo:
                        @{NSLocalizedDescriptionKey: @"版本列表解析失败"}];
                }
            } @catch (__unused NSException *e) {
                err = [NSError errorWithDomain:@"DHManager" code:-2 userInfo:
                    @{NSLocalizedDescriptionKey: @"版本列表解析失败"}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(list, err); });
    }] resume];
}
