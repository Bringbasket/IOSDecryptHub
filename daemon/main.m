// main.m — IOSDecryptHub updater daemon（一次性进程）
//
// 由 launchd 按需拉起（WatchPaths 请求文件 / StartInterval 12h），跑完即退。
// 不 hook、不常驻、不监听端口。只做四件事：检查更新 / 下载安装引擎 / 回滚 / 写 state。
//
// 安全边界：
//   - request 文件是 mobile 可写的，只取 action；下载地址一律自己重查 GitHub 推导。
//   - 安装前校验：体积 + Mach-O 魔数 + arm64 架构；不对就拒装，绝不半写（先下 .new 再 rename）。
//   - 替换前备份当前版 + 版本元信息，回滚可逆（swap 语义）。
//   - 任何失败只写 state，不 exit 非零（避免 launchd 退避风暴）。

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <syslog.h>
#import <signal.h>
#import <unistd.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/file.h>
#import <fcntl.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>
#import "dh_shared.h"

#define DH_TAG "[IOSDecryptHubUpdated]"
#define DH_CHECK_INTERVAL (12 * 3600.0)
#define DH_MIN_ENGINE_SIZE (1024 * 1024)
#define DH_NET_TIMEOUT 30.0

static NSString *g_engine_dir = nil;
static NSMutableDictionary *g_state = nil;

#pragma mark - log / plist

static void dh_log(const char *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *nsfmt = [NSString stringWithUTF8String:format] ?: @"";
    NSString *msg = [[NSString alloc] initWithFormat:nsfmt arguments:args];
    va_end(args);
    syslog(LOG_INFO, DH_TAG " %s", msg.UTF8String ?: "");
    // 同时写 stderr：launchd 会按 StandardErrorPath 落到 /var/log/iosdecrypthub-updated.log。
    // 只走 syslog 的话那个日志文件永远是空的，出问题时无从下手。
    fputs((msg.UTF8String ?: ""), stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

static NSDictionary *_Nullable dh_read_plist(NSString *path) {
    @try {
        id obj = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([obj isKindOfClass:[NSDictionary class]]) return obj;
    } @catch (__unused NSException *e) {
    }
    return nil;
}

static BOOL dh_write_plist(NSDictionary *dict, NSString *path) {
    @try {
        return [dict writeToFile:path atomically:YES];
    } @catch (__unused NSException *e) {
        return NO;
    }
}

#pragma mark - 路径

static NSString *_Nullable dh_bootstrap_root(void) {
    Dl_info info = {0};
    if (dladdr((const void *)&dh_bootstrap_root, &info) == 0 || !info.dli_fname) {
        return nil;
    }
    // daemon 布局: <bootstrap>/usr/lib/IOSDecryptHub/IOSDecryptHubUpdated，向上四级
    NSString *root = [NSString stringWithUTF8String:info.dli_fname];
    for (int i = 0; i < 4; i++) root = [root stringByDeletingLastPathComponent];
    if (root.length <= 1) return nil;
    return root;
}

static NSString *_Nullable dh_existing_engine_dir(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSString *root = dh_bootstrap_root();
    if (root) [dirs addObject:[root stringByAppendingPathComponent:@"usr/lib/IOSDecryptHub"]];
    [dirs addObject:@"/var/jb/usr/lib/IOSDecryptHub"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    for (NSString *dir in dirs) {
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) return dir;
    }
    return nil;
}

#pragma mark - 单实例锁

// launchd 的 WatchPaths 与 StartInterval 可能叠在一起触发。并发改写引擎 =
// 半写 + 备份互踩，所以第二个实例必须立刻退出（拿不到锁就当作"已有实例在跑"）。
static int dh_acquire_lock(void) {
    if (!g_engine_dir) return -1;
    NSString *path = [g_engine_dir stringByAppendingPathComponent:@".updated.lock"];
    int fd = open(path.fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

#pragma mark - state

static void dh_state_save(void) {
    if (!g_engine_dir || !g_state) return;
    NSString *path = [g_engine_dir stringByAppendingPathComponent:DH_STATE_FILE];
    if (dh_write_plist(g_state, path)) {
        chmod(path.fileSystemRepresentation, 0644);
    }
}

static void dh_record_op(NSString *kind, NSString *_Nullable version,
    NSString *result, NSString *_Nullable error, NSArray *_Nullable restarted) {
    NSMutableDictionary *op = [NSMutableDictionary dictionary];
    op[@"kind"] = kind;
    if (version) op[@"version"] = version;
    op[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    op[@"result"] = result;
    if (error) op[@"error"] = error;
    if (restarted) op[@"restartedApps"] = restarted;
    g_state[@"lastOp"] = op;
    dh_state_save();
}

static void dh_notify_state(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)DH_NOTIFY_STATE, NULL, NULL, TRUE);
}

#pragma mark - 版本比较

static NSString *dh_strip_v(NSString *s) {
    if ([s hasPrefix:@"v"] || [s hasPrefix:@"V"]) return [s substringFromIndex:1];
    return s;
}

static NSComparisonResult dh_compare_versions(NSString *left, NSString *right) {
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

#pragma mark - 网络

static id _Nullable dh_fetch_json(NSString *urlString, NSError **errOut) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (errOut) *errOut = [NSError errorWithDomain:@"DHUpdated" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"URL 无效"}];
        return nil;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = DH_NET_TIMEOUT;
    cfg.timeoutIntervalForResource = DH_NET_TIMEOUT + 10;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    __block NSData *outData = nil;
    __block NSError *outErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[session dataTaskWithURL:url completionHandler:^(NSData *_Nullable data,
        __unused NSURLResponse *_Nullable response, NSError *_Nullable error) {
        outData = data;
        outErr = error;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((DH_NET_TIMEOUT + 15) * NSEC_PER_SEC)));
    if (outErr) {
        if (errOut) *errOut = outErr;
        return nil;
    }
    if (!outData) {
        if (errOut) *errOut = [NSError errorWithDomain:@"DHUpdated" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"响应为空"}];
        return nil;
    }
    @try {
        id json = [NSJSONSerialization JSONObjectWithData:outData options:0 error:errOut];
        if (![json isKindOfClass:[NSDictionary class]]) {
            if (errOut) *errOut = [NSError errorWithDomain:@"DHUpdated" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"响应不是 JSON 对象"}];
            return nil;
        }
        return json;
    } @catch (__unused NSException *e) {
        if (errOut) *errOut = [NSError errorWithDomain:@"DHUpdated" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"JSON 解析失败"}];
        return nil;
    }
}

static BOOL dh_download_to(NSString *urlString, NSString *dstPath, NSString **errMsg) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (errMsg) *errMsg = @"下载地址无效";
        return NO;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = DH_NET_TIMEOUT;
    cfg.timeoutIntervalForResource = 120;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    __block NSData *outData = nil;
    __block NSError *outErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[session dataTaskWithURL:url completionHandler:^(NSData *_Nullable data,
        NSURLResponse *_Nullable response, NSError *_Nullable error) {
        outData = data;
        outErr = error;
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger code = [(NSHTTPURLResponse *)response statusCode];
            if (code < 200 || code >= 300) {
                outData = nil;
                outErr = [NSError errorWithDomain:@"DHUpdated" code:(int)code userInfo:
                    @{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)code]}];
            }
        }
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_SEC));
    if (outErr || !outData) {
        if (errMsg) *errMsg = outErr ? outErr.localizedDescription : @"下载为空";
        return NO;
    }
    NSError *writeErr = nil;
    if (![outData writeToFile:dstPath options:NSDataWritingAtomic error:&writeErr]) {
        if (errMsg) *errMsg = writeErr.localizedDescription ?: @"写入失败";
        return NO;
    }
    return YES;
}

#pragma mark - release 解析

// release 资产里找引擎：decrypt_helper*.dylib（当前 release 只有一个，全变体通用 arm64）
static NSDictionary *_Nullable dh_find_engine_asset(NSDictionary *release) {
    id assets = release[@"assets"];
    if (![assets isKindOfClass:[NSArray class]]) return nil;
    for (id item in (NSArray *)assets) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = item[@"name"];
        NSString *url = item[@"browser_download_url"];
        if (![name isKindOfClass:[NSString class]] || ![url isKindOfClass:[NSString class]]) continue;
        if ([name hasPrefix:@"decrypt_helper"] && [name hasSuffix:@".dylib"]) return item;
    }
    return nil;
}

#pragma mark - 最新版本探测

// 读 https://github.com/<owner>/<repo>/releases/latest 的 302 拿 tag。
// 这个端点不吃 GitHub API 的未认证配额（每 IP 60 次/小时），共享出口或 VPN 的
// 用户不会莫名被 403 掐掉——越狱环境里这很常见，所以它是主路径，API 只兜底。
@interface DHRedirectProbe : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, copy, nullable) NSString *location;
@property (nonatomic, copy, nullable) void (^onRedirect)(void);
@end

@implementation DHRedirectProbe

- (void)URLSession:(__unused NSURLSession *)session
              task:(__unused NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *_Nullable))completionHandler {
    id location = response.allHeaderFields[@"Location"];
    self.location = [location isKindOfClass:[NSString class]]
        ? location : request.URL.absoluteString;
    completionHandler(nil);  // 停在重定向这一步，不必把 tag 页面真拉下来
    if (self.onRedirect) self.onRedirect();
}

@end

static NSString *_Nullable dh_latest_tag_via_redirect(void) {
    NSURL *url = [NSURL URLWithString:DH_RELEASE_LATEST];
    if (!url) return nil;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = DH_NET_TIMEOUT;
    cfg.timeoutIntervalForResource = DH_NET_TIMEOUT + 10;
    DHRedirectProbe *probe = [[DHRedirectProbe alloc] init];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    probe.onRedirect = ^{ dispatch_semaphore_signal(sem); };
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg
                                                          delegate:probe
                                                     delegateQueue:nil];
    [[session dataTaskWithURL:url completionHandler:^(__unused NSData *data,
        __unused NSURLResponse *response, __unused NSError *error) {
        dispatch_semaphore_signal(sem);  // 没重定向（404 / 断网）时也要放行
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)((DH_NET_TIMEOUT + 15) * NSEC_PER_SEC)));
    [session finishTasksAndInvalidate];

    NSString *tag = probe.location.lastPathComponent;
    if (tag.length == 0) return nil;
    NSString *body = ([tag hasPrefix:@"v"] || [tag hasPrefix:@"V"])
        ? [tag substringFromIndex:1] : tag;
    // 版本号形状校验：只允许数字与点，且必须有点，免得把 HTML 路径当版本号
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
    if (body.length == 0) return nil;
    if ([body rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return nil;
    if ([body rangeOfString:@"."].location == NSNotFound) return nil;
    return tag;
}

// 解析「最新版本 + 引擎下载地址」：@{tag, version, url}；失败返回 nil 并给出原因
static NSDictionary *_Nullable dh_resolve_latest(NSString **errOut) {
    NSString *tag = dh_latest_tag_via_redirect();
    if (tag.length) {
        NSString *version = dh_strip_v(tag);
        return @{@"tag": tag,
                 @"version": version,
                 @"url": [NSString stringWithFormat:DH_ASSET_FMT, tag, version]};
    }
    NSError *apiErr = nil;
    NSDictionary *release = dh_fetch_json(DH_GITHUB_LATEST, &apiErr);
    if (release) {
        NSString *apiTag = release[@"tag_name"];
        if ([apiTag isKindOfClass:[NSString class]] && apiTag.length) {
            NSDictionary *asset = dh_find_engine_asset(release);
            if (asset) {
                return @{@"tag": apiTag,
                         @"version": dh_strip_v(apiTag),
                         @"url": asset[@"browser_download_url"]};
            }
            if (errOut) *errOut = @"release 中没有找到引擎文件";
            return nil;
        }
    }
    if (errOut) *errOut = apiErr.localizedDescription ?: @"网络失败（重定向探测与 API 都没取到版本）";
    return nil;
}

#pragma mark - Mach-O 校验（只认 arm64 家族，拒绝 x86_64 等错架构）

static BOOL dh_macho_has_arm64(NSString *path, NSString **archOut) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if ([attrs fileSize] < DH_MIN_ENGINE_SIZE) return NO;
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return NO;
    uint32_t magic = 0;
    BOOL ok = NO;
    NSMutableArray<NSString *> *archs = [NSMutableArray array];
    if (fread(&magic, sizeof(magic), 1, f) == 1) {
        if (magic == MH_MAGIC_64) {
            uint32_t cputype = 0;
            if (fread(&cputype, sizeof(cputype), 1, f) == 1 && cputype == CPU_TYPE_ARM64) {
                ok = YES;
                [archs addObject:@"arm64"];
            }
        } else if (magic == FAT_CIGAM) {
            uint32_t nfat = 0;
            if (fread(&nfat, sizeof(nfat), 1, f) == 1) {
                nfat = OSSwapBigToHostInt32(nfat);
                for (uint32_t i = 0; i < nfat && i < 8; i++) {
                    struct fat_arch arch;
                    if (fread(&arch, sizeof(arch), 1, f) != 1) break;
                    cpu_type_t ct = OSSwapBigToHostInt32(arch.cputype);
                    if (ct == CPU_TYPE_ARM64) {
                        ok = YES;
                        cpu_subtype_t st = OSSwapBigToHostInt32(arch.cpusubtype) & ~CPU_SUBTYPE_MASK;
                        [archs addObject:(st == CPU_SUBTYPE_ARM64E ? @"arm64e" : @"arm64")];
                    }
                }
            }
        }
    }
    fclose(f);
    if (ok && archOut) *archOut = [[archs sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "];
    return ok;
}

#pragma mark - 名单 / 进程

static NSArray<NSString *> *dh_enabled_bundle_ids(void) {
    NSDictionary *domain = dh_read_plist([g_engine_dir stringByAppendingPathComponent:@"config/enabledBundles.plist"]);
    id value = domain[DH_KEY_BUNDLES];
    if ([value isKindOfClass:[NSArray class]]) return value;
    return @[];
}

// bundleID → 可执行名（root 可读全部容器；/Applications 覆盖越狱应用）
static NSDictionary<NSString *, NSString *> *dh_executable_map(void) {
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *bases = [NSMutableArray arrayWithObject:@"/var/containers/Bundle/Application"];
        // 越狱安装的 App 在 <jbroot>/Applications（rootless 是 /private/preboot/...，roothide 是 /），
        // 只扫 /Applications 会漏掉它们 —— 表现为装完"重启 0 个应用"。
        NSString *root = dh_bootstrap_root();
        if (root.length > 1) {
            [bases addObject:[root stringByAppendingPathComponent:@"Applications"]];
        }
        [bases addObject:@"/Applications"];
        for (NSString *base in bases) {
            for (NSString *container in [fm contentsOfDirectoryAtPath:base error:nil]) {
                NSString *containerPath = [base stringByAppendingPathComponent:container];
                BOOL wantApp = [container.pathExtension.lowercaseString isEqualToString:@"app"];
                NSArray<NSString *> *entries = wantApp ? @[@""] : [fm contentsOfDirectoryAtPath:containerPath error:nil];
                for (NSString *entry in entries) {
                    if (!wantApp && ![entry.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                    NSString *appPath = wantApp ? containerPath : [containerPath stringByAppendingPathComponent:entry];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:
                        [appPath stringByAppendingPathComponent:@"Info.plist"]];
                    NSString *bid = info[@"CFBundleIdentifier"];
                    NSString *exec = info[@"CFBundleExecutable"];
                    if (bid.length && exec.length && !map[bid]) map[bid] = exec;
                }
            }
        }
    } @catch (__unused NSException *e) {
    }
    return map;
}

// best-effort：按可执行名 SIGKILL，杀不到不算错；返回实际杀掉的名字
static NSArray<NSString *> *dh_kill_processes_named(NSSet<NSString *> *names) {
    NSMutableArray<NSString *> *killed = [NSMutableArray array];
    if (names.count == 0) return killed;
    pid_t selfPid = getpid();
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return killed;
    struct kinfo_proc *procs = malloc(len);
    if (!procs) return killed;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        return killed;
    }
    size_t n = len / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < n; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 1 || pid == selfPid) continue;
        char comm[MAXCOMLEN + 1];
        memcpy(comm, procs[i].kp_proc.p_comm, MAXCOMLEN);
        comm[MAXCOMLEN] = '\0';
        for (NSString *name in names) {
            const char *want = name.UTF8String;
            if (!want || !want[0]) continue;
            // p_comm 最长 16 字节：短名精确比，长名比前缀
            BOOL match = (strlen(want) <= MAXCOMLEN - 1)
                ? (strcmp(comm, want) == 0)
                : (strncmp(comm, want, MAXCOMLEN - 1) == 0);
            if (match && kill(pid, SIGKILL) == 0) {
                if (![killed containsObject:name]) [killed addObject:name];
            }
        }
    }
    free(procs);
    return killed;
}

#pragma mark - 检查 / 安装 / 回滚

static NSString *dh_local_version(void) {
    NSDictionary *meta = dh_read_plist([g_engine_dir stringByAppendingPathComponent:DH_VERSION_FILE]);
    NSString *v = meta[@"version"];
    return ([v isKindOfClass:[NSString class]] && v.length) ? v : @"0";
}

static void dh_do_check(void) {
    NSString *resolveErr = nil;
    NSDictionary *latest = dh_resolve_latest(&resolveErr);
    g_state[@"lastCheck"] = @([[NSDate date] timeIntervalSince1970]);
    if (!latest) {
        g_state[@"lastCheckError"] = resolveErr ?: @"网络失败";
        dh_state_save();
        dh_log("检查更新失败: %s", ((NSString *)g_state[@"lastCheckError"]).UTF8String);
        return;
    }
    NSString *tag = latest[@"tag"];
    [g_state removeObjectForKey:@"lastCheckError"];
    g_state[@"latestVersion"] = tag;
    // 显式转 BOOL：C 的 == 结果是 int，落盘会变成 <integer>1</integer> 而不是 <true/>
    g_state[@"updateAvailable"] = @((BOOL)(dh_compare_versions(dh_local_version(), latest[@"version"]) == NSOrderedAscending));
    dh_state_save();
    dh_log("检查更新: 本地 %s 最新 %s", dh_local_version().UTF8String, ((NSString *)tag).UTF8String);
}

// requestedVersion 非空时安装指定版本（历史版本功能），否则安装线上最新版
static void dh_do_install(NSString *_Nullable requestedVersion) {
    BOOL explicitVersion = requestedVersion.length > 0;
    NSString *tag = nil;
    NSString *version = nil;
    NSString *downloadURL = nil;

    if (explicitVersion) {
        // 指定版本不查"最新版"：直接按发布命名约定拼地址（与主路径同一约定）
        tag = [requestedVersion hasPrefix:@"v"] ? requestedVersion
                                                : [@"v" stringByAppendingString:requestedVersion];
        version = dh_strip_v(tag);
        downloadURL = [NSString stringWithFormat:DH_ASSET_FMT, tag, version];
    } else {
        NSString *resolveErr = nil;
        NSDictionary *latest = dh_resolve_latest(&resolveErr);
        if (!latest) {
            dh_record_op(@"install", nil, @"error", resolveErr ?: @"网络失败", nil);
            return;
        }
        tag = latest[@"tag"];
        version = latest[@"version"];
        downloadURL = latest[@"url"];
    }

    NSString *local = dh_local_version();
    g_state[@"latestVersion"] = tag;
    // 指定版本：只跳过"已经是这个版本"；最新版路径：不比线上旧就不动
    BOOL skip = explicitVersion ? [local isEqualToString:version]
                                : (dh_compare_versions(local, version) != NSOrderedAscending);
    if (skip) {
        g_state[@"updateAvailable"] = @NO;
        dh_state_save();
        dh_record_op(@"install", version, @"skipped",
                     explicitVersion ? @"已经是这个版本" : @"已是最新，无需安装", nil);
        return;
    }
    NSString *curPath = [g_engine_dir stringByAppendingPathComponent:DH_ENGINE_NAME];
    NSString *newPath = [g_engine_dir stringByAppendingPathComponent:DH_ENGINE_NEW];
    NSString *bakPath = [g_engine_dir stringByAppendingPathComponent:DH_ENGINE_BAK];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *dlErr = nil;
    if (!dh_download_to(downloadURL, newPath, &dlErr)) {
        dh_record_op(@"install", version, @"error", [@"下载失败: " stringByAppendingString:dlErr ?: @""], nil);
        return;
    }
    NSString *arch = nil;
    if (!dh_macho_has_arm64(newPath, &arch)) {
        [fm removeItemAtPath:newPath error:nil];
        dh_record_op(@"install", version, @"error", @"下载文件校验失败（体积/架构异常），已丢弃", nil);
        return;
    }
    // 备份当前版（swap 语义：回滚后备份里是刚换下来的新版，仍可再回滚）。
    // 备份不成功就不替换：没有备份的安装等于放弃回滚，宁可这次不更新。
    NSString *curArch = nil;
    if (![fm fileExistsAtPath:curPath]) {
        [fm removeItemAtPath:newPath error:nil];
        dh_record_op(@"install", version, @"error", @"当前引擎不存在，拒绝安装", nil);
        return;
    }
    if (!dh_macho_has_arm64(curPath, &curArch)) {
        [fm removeItemAtPath:newPath error:nil];
        dh_record_op(@"install", version, @"error", @"当前引擎异常，拒绝安装（请重装插件）", nil);
        return;
    }
    [fm removeItemAtPath:bakPath error:nil];
    NSError *cpErr = nil;
    if (![fm copyItemAtPath:curPath toPath:bakPath error:&cpErr]) {
        [fm removeItemAtPath:newPath error:nil];
        dh_record_op(@"install", version, @"error",
            [@"备份失败，已放弃安装: " stringByAppendingString:cpErr.localizedDescription ?: @""], nil);
        return;
    }
    dh_write_plist(@{@"version": local}, [g_engine_dir stringByAppendingPathComponent:DH_BAK_META]);
    chmod(bakPath.fileSystemRepresentation, 0755);
    g_state[@"backupAvailable"] = @YES;
    g_state[@"backupVersion"] = local;
    dh_state_save();

    // 替换：NSFileManager 的 move 不覆盖已存在的目标，必须先挪走旧文件；
    // 旧文件在 .bak 里已有副本（备份失败上面就中止了），所以这一步是安全的。
    // 落位若失败则立刻用备份恢复——绝不允许出现"引擎不存在"的状态。
    NSError *mvErr = nil;
    [fm removeItemAtPath:curPath error:nil];
    if (![fm moveItemAtPath:newPath toPath:curPath error:&mvErr]) {
        NSError *restoreErr = nil;
        if (![fm copyItemAtPath:bakPath toPath:curPath error:&restoreErr]) {
            dh_record_op(@"install", version, @"error", [NSString stringWithFormat:
                @"替换失败且恢复备份失败: %@ / %@",
                mvErr.localizedDescription, restoreErr.localizedDescription], nil);
        } else {
            chmod(curPath.fileSystemRepresentation, 0755);
            [fm removeItemAtPath:newPath error:nil];
            dh_record_op(@"install", version, @"error", [NSString stringWithFormat:
                @"替换失败，已恢复原引擎: %@", mvErr.localizedDescription], nil);
        }
        return;
    }
    chmod(curPath.fileSystemRepresentation, 0755);
    chown(curPath.fileSystemRepresentation, 0, 0);
    NSMutableDictionary *meta = [(dh_read_plist([g_engine_dir stringByAppendingPathComponent:DH_VERSION_FILE]) ?: @{}) mutableCopy];
    meta[@"version"] = version;
    meta[@"arch"] = arch ?: @"arm64";
    dh_write_plist(meta, [g_engine_dir stringByAppendingPathComponent:DH_VERSION_FILE]);

    // 让已启用的目标 App 下次启动即生效：结束其进程（best-effort）
    NSDictionary<NSString *, NSString *> *execMap = dh_executable_map();
    NSMutableSet<NSString *> *wantExecs = [NSMutableSet set];
    for (NSString *bid in dh_enabled_bundle_ids()) {
        if (execMap[bid]) [wantExecs addObject:execMap[bid]];
    }
    NSArray<NSString *> *killed = dh_kill_processes_named(wantExecs);

    g_state[@"updateAvailable"] = @NO;
    dh_state_save();
    dh_record_op(@"install", version, @"ok", nil, killed);
    dh_log("安装引擎 %s 完成，重启 %lu 个应用", version.UTF8String, (unsigned long)killed.count);
}

static void dh_do_rollback(void) {
    NSString *curPath = [g_engine_dir stringByAppendingPathComponent:DH_ENGINE_NAME];
    NSString *bakPath = [g_engine_dir stringByAppendingPathComponent:DH_ENGINE_BAK];
    NSString *metaPath = [g_engine_dir stringByAppendingPathComponent:DH_VERSION_FILE];
    NSString *bakMetaPath = [g_engine_dir stringByAppendingPathComponent:DH_BAK_META];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *bakArch = nil;
    if (![fm fileExistsAtPath:bakPath] || !dh_macho_has_arm64(bakPath, &bakArch)) {
        dh_record_op(@"rollback", nil, @"error", @"没有可回滚的备份", nil);
        return;
    }
    // swap：当前 ↔ 备份（含版本元信息），回滚本身也可再回滚
    NSString *tmpPath = [curPath stringByAppendingString:@".tmp"];
    [fm removeItemAtPath:tmpPath error:nil];
    NSError *opErr = nil;
    if ([fm fileExistsAtPath:curPath] && ![fm moveItemAtPath:curPath toPath:tmpPath error:&opErr]) {
        dh_record_op(@"rollback", nil, @"error", [@"回滚失败: " stringByAppendingString:opErr.localizedDescription ?: @""], nil);
        return;
    }
    if (![fm moveItemAtPath:bakPath toPath:curPath error:&opErr]) {
        if ([fm fileExistsAtPath:tmpPath]) [fm moveItemAtPath:tmpPath toPath:curPath error:nil];
        dh_record_op(@"rollback", nil, @"error", [@"回滚失败: " stringByAppendingString:opErr.localizedDescription ?: @""], nil);
        return;
    }
    if ([fm fileExistsAtPath:tmpPath]) {
        [fm removeItemAtPath:bakPath error:nil];
        [fm moveItemAtPath:tmpPath toPath:bakPath error:nil];
    }
    chmod(curPath.fileSystemRepresentation, 0755);
    chown(curPath.fileSystemRepresentation, 0, 0);

    NSDictionary *curMeta = dh_read_plist(metaPath) ?: @{};
    NSDictionary *bakMeta = dh_read_plist(bakMetaPath);
    NSString *bakVersion = bakMeta[@"version"];
    if (![bakVersion isKindOfClass:[NSString class]] || !bakVersion.length) {
        bakVersion = g_state[@"backupVersion"];
        if (![bakVersion isKindOfClass:[NSString class]]) bakVersion = @"unknown";
    }
    if (curMeta.count) dh_write_plist(curMeta, bakMetaPath);
    NSMutableDictionary *newMeta = [curMeta mutableCopy];
    newMeta[@"version"] = bakVersion;
    newMeta[@"arch"] = bakArch ?: @"arm64";
    dh_write_plist(newMeta, metaPath);
    g_state[@"backupAvailable"] = @YES;
    g_state[@"backupVersion"] = curMeta[@"version"] ?: @"unknown";
    dh_state_save();

    NSDictionary<NSString *, NSString *> *execMap = dh_executable_map();
    NSMutableSet<NSString *> *wantExecs = [NSMutableSet set];
    for (NSString *bid in dh_enabled_bundle_ids()) {
        if (execMap[bid]) [wantExecs addObject:execMap[bid]];
    }
    NSArray<NSString *> *killed = dh_kill_processes_named(wantExecs);
    dh_record_op(@"rollback", bakVersion, @"ok", nil, killed);
    dh_log("回滚到 %s 完成", ((NSString *)bakVersion).UTF8String);
}

#pragma mark - 请求处理

static void dh_ensure_request_file(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:DH_REQUEST_PATH]) return;
    dh_write_plist(@{@"action": DH_REQ_NONE}, DH_REQUEST_PATH);
    chown(DH_REQUEST_PATH.fileSystemRepresentation, 501, 501); // mobile
    chmod(DH_REQUEST_PATH.fileSystemRepresentation, 0644);
}

static void dh_process_request(void) {
    dh_ensure_request_file();
    NSMutableDictionary *req = [(dh_read_plist(DH_REQUEST_PATH) ?: @{}) mutableCopy];
    NSString *action = req[@"action"];
    if (![action isKindOfClass:[NSString class]] || [action isEqualToString:DH_REQ_NONE]) {
        return;
    }
    // 先清零再执行：本次写入会再次触发 WatchPaths，但下次进来 action=none 直接返回，不会循环
    req[@"action"] = DH_REQ_NONE;
    dh_write_plist(req, DH_REQUEST_PATH);
    dh_log("处理请求: %s", action.UTF8String);
    if ([action isEqualToString:DH_REQ_CHECK]) {
        dh_do_check();
    } else if ([action isEqualToString:DH_REQ_INSTALL]) {
        // 请求可带 version（历史版本）；不带则装线上最新
        id wantVersion = req[@"version"];
        dh_do_install([wantVersion isKindOfClass:[NSString class]] ? wantVersion : nil);
    } else if ([action isEqualToString:DH_REQ_ROLLBACK]) {
        dh_do_rollback();
    } else {
        dh_log("未知请求: %s，已忽略", action.UTF8String);
    }
    req[@"lastAction"] = action;
    req[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    dh_write_plist(req, DH_REQUEST_PATH);
}

static void dh_periodic_check(void) {
    NSTimeInterval last = [g_state[@"lastCheck"] doubleValue];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - last < DH_CHECK_INTERVAL) return;
    dh_do_check();
}

#pragma mark - main

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        dh_log("启动");
        g_engine_dir = dh_existing_engine_dir();
        if (!g_engine_dir) {
            dh_log("引擎目录不存在，退出");
            return 0;
        }
        int lockFd = dh_acquire_lock();
        if (lockFd < 0) {
            dh_log("已有实例在运行，退出");
            return 0;
        }
        g_state = [(dh_read_plist([g_engine_dir stringByAppendingPathComponent:DH_STATE_FILE]) ?: @{}) mutableCopy];
        dh_process_request();
        dh_periodic_check();
        g_state[@"daemonHeartbeat"] = @([[NSDate date] timeIntervalSince1970]);
        dh_state_save();
        dh_notify_state();
        close(lockFd);
        dh_log("结束");
    }
    return 0;
}
