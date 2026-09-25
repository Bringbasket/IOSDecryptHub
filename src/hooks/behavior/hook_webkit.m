// hook_webkit.m — WKWebView 宿主 App 侧观测 (TrollStore / Jailbreak 共用)
//
// 边界:
//   - 这里只 swizzle 宿主进程能看到的 WebKit Objective-C API。
//   - WKWebView 的页面内容和网络实际运行在 com.apple.WebKit.WebContent /
//     com.apple.WebKit.Networking 进程，本文件不承诺看到这两个进程内部的对象。
//   - 管理器开启 WebKit JS 探针后，在 document-start 注入只读网络观测脚本；
//     其它 ObjC API 仍只记录导航、evaluateJavaScript、Cookie / WebsiteDataStore 等行为。

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <pthread.h>
#include <stdatomic.h>
#import "log_store.h"
#import "dh_capture.h"
#import "dh_health.h"
#import "hook_webkit.h"
#import "webkit_probe_js.h"

#define DH_WK_MAX_BODY (256 * 1024)

static _Thread_local int g_dh_wk_log_depth = 0;

// ---- P1 可选 JS 网络探针 (默认关闭) ----
static NSString *const kDHWKProbeName = @"__iosdecrypthub_net_probe_v1";
static const void *kDHWKProbeMarker = &kDHWKProbeMarker;
static _Atomic int g_dh_wk_probe_enabled = 0;
static _Atomic int g_dh_wk_probe_redact = 1;
static NSArray<NSString *> *g_dh_wk_probe_allow = nil;
static NSArray<NSString *> *g_dh_wk_probe_deny = nil;
static NSString *g_dh_wk_probe_conf_path = nil;
static NSRecursiveLock *g_dh_wk_probe_lock = nil;

// ============================================================
// 数据转换 / 记录
// ============================================================

static NSData *dh_wk_data(id object) {
    if (!object) return nil;
    NSData *data = nil;
    @try {
        if ([object isKindOfClass:[NSData class]]) {
            data = object;
        } else if ([object isKindOfClass:[NSString class]]) {
            data = [(NSString *)object dataUsingEncoding:NSUTF8StringEncoding];
        } else if ([NSJSONSerialization isValidJSONObject:object]) {
            data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
        } else {
            data = [[object description] dataUsingEncoding:NSUTF8StringEncoding];
        }
    } @catch (__unused NSException *e) {
        data = nil;
    }
    if (data.length > DH_WK_MAX_BODY)
        data = [data subdataWithRange:NSMakeRange(0, DH_WK_MAX_BODY)];
    return data;
}

static void dh_wk_log_event(NSString *algorithm, NSString *operation, NSString *detail,
                            id body, NSDictionary *metadata, uint64_t timestampMs) {
    if (g_dh_wk_log_depth || !dh_capture_sub_enabled(DH_CAP_NETWORK)) return;
    g_dh_wk_log_depth++;
    @try {
        DHLogEntry *entry = [DHLogEntry new];
        entry.category = DHCategoryNetwork;
        entry.algorithm = algorithm ?: @"WEBKIT";
        entry.operation = operation ?: @"";
        entry.detail = detail ?: @"";
        entry.input = dh_wk_data(body);
        entry.metadata = metadata;
        entry.timestamp = DHTimestampNow();
        entry.timestampMs = timestampMs;
        entry.callStack = DHCallStackFiltered();
        [[DHLogStore shared] append:entry];
    } @finally {
        g_dh_wk_log_depth--;
    }
}

static void dh_wk_log_algo(NSString *algorithm, NSString *operation, NSString *detail, id body) {
    dh_wk_log_event(algorithm, operation, detail, body, nil, 0);
}

static void dh_wk_log(NSString *operation, NSString *detail, id body) {
    dh_wk_log_algo(@"WEBKIT", operation, detail, body);
}

static void dh_wk_probe_ensure_lock(void) {
    if (!g_dh_wk_probe_lock) g_dh_wk_probe_lock = [NSRecursiveLock new];
}

// 必须在锁内调用。
static void dh_wk_probe_save_locked(void) {
    if (!g_dh_wk_probe_conf_path) return;
    NSDictionary *root = @{
        @"redact":  atomic_load_explicit(&g_dh_wk_probe_redact, memory_order_relaxed) != 0 ? @YES : @NO,
        @"allow":   g_dh_wk_probe_allow ?: @[],
        @"deny":    g_dh_wk_probe_deny ?: @[],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return;
    int saved = dh_in_hook; dh_in_hook = 1;
    [data writeToFile:g_dh_wk_probe_conf_path atomically:YES];
    dh_in_hook = saved;
}

static void dh_wk_probe_apply_locked(NSDictionary *root) {
    if (![root isKindOfClass:[NSDictionary class]]) return;
    if (root[@"redact"])  atomic_store(&g_dh_wk_probe_redact,  [root[@"redact"] boolValue] ? 1 : 0);
    if ([root[@"allow"] isKindOfClass:[NSArray class]]) g_dh_wk_probe_allow = [root[@"allow"] copy];
    if ([root[@"deny"]  isKindOfClass:[NSArray class]]) g_dh_wk_probe_deny  = [root[@"deny"] copy];
}

void dh_webkit_probe_load(NSString *confPath, BOOL enabledByManager) {
    dh_wk_probe_ensure_lock();
    [g_dh_wk_probe_lock lock];
    atomic_store(&g_dh_wk_probe_enabled, enabledByManager ? 1 : 0);
    atomic_store(&g_dh_wk_probe_redact, 1);
    g_dh_wk_probe_allow = @[];
    g_dh_wk_probe_deny  = @[];
    g_dh_wk_probe_conf_path = [confPath copy];
    if (g_dh_wk_probe_conf_path) {
        int saved = dh_in_hook; dh_in_hook = 1;
        NSData *data = [NSData dataWithContentsOfFile:g_dh_wk_probe_conf_path];
        dh_in_hook = saved;
        if (data.length) {
            NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            // 管理器开关是唯一的持久启动门控；旧配置中的 enabled 不再制造第二个开关。
            dh_wk_probe_apply_locked(root);
        }
    }
    // 仅供自动化测试/临时诊断使用: 环境变量优先于持久化配置。
    const char *env = getenv("DH_WEBKIT_PROBE");
    if (env && *env) atomic_store(&g_dh_wk_probe_enabled, (strcmp(env, "0") != 0) ? 1 : 0);
    [g_dh_wk_probe_lock unlock];
}

BOOL dh_webkit_probe_enabled(void) {
    return atomic_load_explicit(&g_dh_wk_probe_enabled, memory_order_relaxed) != 0;
}

NSDictionary *dh_webkit_probe_snapshot(void) {
    dh_wk_probe_ensure_lock();
    [g_dh_wk_probe_lock lock];
    NSDictionary *out = @{
        @"enabled": dh_webkit_probe_enabled() ? @YES : @NO,
        @"redact":  atomic_load_explicit(&g_dh_wk_probe_redact, memory_order_relaxed) != 0 ? @YES : @NO,
        @"allow":   g_dh_wk_probe_allow ?: @[],
        @"deny":    g_dh_wk_probe_deny ?: @[],
        @"note":    @"管理器的 WebKit JS 探针开关是启动门控；域名/脱敏修改后需重新加载页面或重建 WKWebView。",
    };
    [g_dh_wk_probe_lock unlock];
    return out;
}

void dh_webkit_probe_set_config(NSDictionary *changes) {
    if (![changes isKindOfClass:[NSDictionary class]]) return;
    dh_wk_probe_ensure_lock();
    [g_dh_wk_probe_lock lock];
    // enabled 只由管理器的全局功能开关决定；MCP 只调整过滤/脱敏细项。
    dh_wk_probe_apply_locked(changes);
    dh_wk_probe_save_locked();
    [g_dh_wk_probe_lock unlock];
}

static NSString *dh_wk_url_of(id object) {
    if (!object) return nil;
    @try {
        SEL urlSel = NSSelectorFromString(@"URL");
        if ([object respondsToSelector:urlSel]) {
            id url = ((id (*)(id, SEL))objc_msgSend)(object, urlSel);
            if ([url isKindOfClass:[NSURL class]]) return [(NSURL *)url absoluteString];
        }
        if ([object isKindOfClass:[NSURL class]]) return [(NSURL *)object absoluteString];
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *dh_wk_request_summary(id request) {
    if (!request) return @"(nil)";
    NSString *url = dh_wk_url_of(request);
    NSString *method = nil;
    @try {
        SEL methodSel = NSSelectorFromString(@"HTTPMethod");
        if ([request respondsToSelector:methodSel])
            method = ((id (*)(id, SEL))objc_msgSend)(request, methodSel);
    } @catch (__unused NSException *e) {}
    return [NSString stringWithFormat:@"url=%@ method=%@", url ?: @"(nil)", method ?: @"(nil)"];
}

static NSDictionary *dh_wk_cookie_dict(id cookie) {
    if (!cookie) return nil;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    NSArray<NSString *> *keys = @[@"name", @"value", @"domain", @"path", @"secure",
                                  @"HTTPOnly", @"expiresDate", @"version"];
    for (NSString *key in keys) {
        @try {
            id value = [cookie valueForKey:key];
            dict[key] = value ?: [NSNull null];
        } @catch (__unused NSException *e) {}
    }
    return dict;
}

// ============================================================
// P1 可选 JS 网络探针
// ============================================================

static BOOL dh_wk_probe_host_matches(NSString *host, NSArray<NSString *> *patterns) {
    if (!host.length || !patterns.count) return NO;
    host = [host lowercaseString];
    for (NSString *raw in patterns) {
        NSString *pattern = [[raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
        if (!pattern.length) continue;
        if ([host isEqualToString:pattern] ||
            [host hasSuffix:[@"." stringByAppendingString:pattern]]) return YES;
    }
    return NO;
}

static BOOL dh_wk_probe_should_report(NSString *urlString) {
    if (!urlString.length) return YES;
    dh_wk_probe_ensure_lock();
    [g_dh_wk_probe_lock lock];
    NSArray *allow = [g_dh_wk_probe_allow copy];
    NSArray *deny = [g_dh_wk_probe_deny copy];
    [g_dh_wk_probe_lock unlock];
    NSString *host = nil;
    @try { host = [NSURL URLWithString:urlString].host; }
    @catch (__unused NSException *e) {}
    if (dh_wk_probe_host_matches(host, deny)) return NO;
    if (allow.count) return dh_wk_probe_host_matches(host, allow);
    return YES;
}

static BOOL dh_wk_probe_is_sensitive_header(NSString *key) {
    NSString *k = [key lowercaseString];
    NSArray<NSString *> *needles = @[@"cookie", @"authorization", @"token", @"sign",
                                     @"password", @"secret", @"x-token", @"x-sign"];
    for (NSString *n in needles) if ([k containsString:n]) return YES;
    return NO;
}

static id dh_wk_probe_sanitize_object(id object, BOOL insideHeaders) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, __unused BOOL *stop) {
            NSString *name = [key isKindOfClass:[NSString class]] ? key : [key description];
            BOOL nextHeaders = insideHeaders || [[name lowercaseString] containsString:@"headers"];
            if (insideHeaders && dh_wk_probe_is_sensitive_header(name)) out[name] = @"<redacted>";
            else out[name] = dh_wk_probe_sanitize_object(value, nextHeaders) ?: [NSNull null];
        }];
        return out;
    }
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray arrayWithCapacity:[(NSArray *)object count]];
        for (id value in (NSArray *)object)
            [out addObject:dh_wk_probe_sanitize_object(value, insideHeaders) ?: [NSNull null]];
        return out;
    }
    return object;
}

static NSDictionary *dh_wk_probe_sanitize(NSDictionary *payload) {
    if (!payload || atomic_load_explicit(&g_dh_wk_probe_redact, memory_order_relaxed) == 0)
        return payload;
    return dh_wk_probe_sanitize_object(payload, NO);
}

@interface DHWKProbeBridge : NSObject
+ (instancetype)shared;
@end

@implementation DHWKProbeBridge
+ (instancetype)shared {
    static DHWKProbeBridge *bridge = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bridge = [DHWKProbeBridge new]; });
    return bridge;
}

- (void)userContentController:(id)userContentController
      didReceiveScriptMessage:(id)message {
    (void)userContentController;
    NSString *name = nil;
    NSDictionary *body = nil;
    @try {
        name = [message valueForKey:@"name"];
        id payload = [message valueForKey:@"body"];
        if ([payload isKindOfClass:[NSDictionary class]]) body = payload;
    } @catch (__unused NSException *e) {}
    if (![name isEqualToString:kDHWKProbeName] || !body) return;

    NSDictionary *params = [body[@"params"] isKindOfClass:[NSDictionary class]] ? body[@"params"] : @{};
    NSDictionary *request = [params[@"request"] isKindOfClass:[NSDictionary class]] ? params[@"request"] : @{};
    NSDictionary *response = [params[@"response"] isKindOfClass:[NSDictionary class]] ? params[@"response"] : @{};
    NSString *url = [body[@"url"] isKindOfClass:[NSString class]] ? body[@"url"] : nil;
    if (!url.length && [request[@"url"] isKindOfClass:[NSString class]]) url = request[@"url"];
    if (!url.length && [response[@"url"] isKindOfClass:[NSString class]]) url = response[@"url"];
    if (!dh_wk_probe_should_report(url)) return;
    NSString *method = [body[@"method"] isKindOfClass:[NSString class]] ? body[@"method"] : nil;
    if (!method.length) method = [body[@"kind"] isKindOfClass:[NSString class]] ? body[@"kind"] : @"unknown";
    NSString *requestId = [params[@"requestId"] description] ?: @"";
    NSString *httpMethod = [request[@"method"] isKindOfClass:[NSString class]] ? request[@"method"] : nil;
    NSNumber *status = [response[@"status"] isKindOfClass:[NSNumber class]] ? response[@"status"] : nil;
    NSMutableString *detail = [NSMutableString string];
    if (httpMethod.length) [detail appendString:httpMethod];
    else [detail appendString:method];
    if (url.length) [detail appendFormat:@" %@", url];
    if (status) [detail appendFormat:@" status=%@", status];
    NSMutableDictionary *metadata = [@{
        @"source": @"js",
        @"eventName": method,
        @"requestId": requestId,
        @"url": url ?: @"",
        @"schema": [body[@"schema"] isKindOfClass:[NSString class]] ? body[@"schema"] : @"iosdecrypthub.cdp.v1",
    } mutableCopy];
    NSNumber *ts = [body[@"ts"] isKindOfClass:[NSNumber class]] ? body[@"ts"] : nil;
    dh_wk_log_event(@"WEBKIT-CDP", method, detail, dh_wk_probe_sanitize(body), metadata,
                    ts ? ts.unsignedLongLongValue : 0);
}
@end

static _Thread_local int g_dh_wk_probe_installing = 0;

static NSString *dh_wk_probe_js(void) {
    NSArray *allow = nil, *deny = nil;
    dh_wk_probe_ensure_lock();
    [g_dh_wk_probe_lock lock];
    allow = [g_dh_wk_probe_allow copy] ?: @[];
    deny  = [g_dh_wk_probe_deny copy] ?: @[];
    [g_dh_wk_probe_lock unlock];
    NSData *allowData = [NSJSONSerialization dataWithJSONObject:allow options:0 error:nil];
    NSData *denyData = [NSJSONSerialization dataWithJSONObject:deny options:0 error:nil];
    NSData *nameData = [NSJSONSerialization dataWithJSONObject:@[kDHWKProbeName] options:0 error:nil];
    NSString *allowJSON = allowData ? [[NSString alloc] initWithData:allowData encoding:NSUTF8StringEncoding] : @"[]";
    NSString *denyJSON = denyData ? [[NSString alloc] initWithData:denyData encoding:NSUTF8StringEncoding] : @"[]";
    NSString *nameJSON = nameData ? [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] : @"[\"probe\"]";
    if (nameJSON.length >= 2) nameJSON = [nameJSON substringWithRange:NSMakeRange(1, nameJSON.length - 2)];

    NSString *body = [[NSString alloc] initWithBytes:kDHWebKitProbeJS
                                              length:kDHWebKitProbeJS_len
                                            encoding:NSUTF8StringEncoding] ?: @"";
    return [NSString stringWithFormat:@"(function(){var ALLOW=%@;var DENY=%@;var NAME=%@;%@})();",
            allowJSON, denyJSON, nameJSON, body];
}

static void dh_wk_probe_install_configuration(id configuration) {
    if (!configuration || !dh_webkit_probe_enabled()) return;
    id controller = nil;
    @try { controller = [configuration valueForKey:@"userContentController"]; }
    @catch (__unused NSException *e) {}
    if (!controller || objc_getAssociatedObject(controller, kDHWKProbeMarker)) return;

    Protocol *proto = objc_getProtocol("WKScriptMessageHandler");
    if (proto) class_addProtocol([DHWKProbeBridge class], proto);
    g_dh_wk_probe_installing++;
    @try {
        SEL addHandler = @selector(addScriptMessageHandler:name:);
        if ([controller respondsToSelector:addHandler])
            ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler,
                                                      [DHWKProbeBridge shared], kDHWKProbeName);
        Class scriptClass = NSClassFromString(@"WKUserScript");
        SEL initScript = @selector(initWithSource:injectionTime:forMainFrameOnly:);
        if (scriptClass && [scriptClass instancesRespondToSelector:initScript]) {
            id script = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(
                [scriptClass alloc], initScript, dh_wk_probe_js(), (NSInteger)0, NO);
            SEL addScript = @selector(addUserScript:);
            if (script && [controller respondsToSelector:addScript])
                ((void (*)(id, SEL, id))objc_msgSend)(controller, addScript, script);
        }
        objc_setAssociatedObject(controller, kDHWKProbeMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } @finally {
        g_dh_wk_probe_installing--;
    }
}

// ============================================================
// 通用 swizzle 注册表
//
// WebKit 的 delegate / JS message handler / URL scheme handler 都是 App 自己实现的类，
// 同一个方法可能被多个实例使用。这里按 (Class, SEL) 做一次性 record-only swizzle，
// 所有 wrapper 记录后都调用原 IMP。
// ============================================================

typedef struct {
    Class cls;
    SEL sel;
    IMP original;
} DHWebKitSwizzle;

#define DH_WK_SWIZZLE_MAX 128
static DHWebKitSwizzle g_dh_wk_swizzles[DH_WK_SWIZZLE_MAX];
static size_t g_dh_wk_swizzle_count = 0;
static pthread_mutex_t g_dh_wk_swizzle_lock = PTHREAD_MUTEX_INITIALIZER;

static Class dh_wk_impl_class(Class start, SEL sel) {
    for (Class cls = start; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        BOOL found = NO;
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == sel) { found = YES; break; }
        }
        if (methods) free(methods);
        if (found) return cls;
    }
    return nil;
}

static IMP dh_wk_original_imp(id receiver, SEL sel) {
    if (!receiver) return NULL;
    pthread_mutex_lock(&g_dh_wk_swizzle_lock);
    IMP result = NULL;
    for (Class cls = object_getClass(receiver); cls && !result; cls = class_getSuperclass(cls)) {
        for (size_t i = 0; i < g_dh_wk_swizzle_count; i++) {
            if (g_dh_wk_swizzles[i].cls == cls && sel_isEqual(g_dh_wk_swizzles[i].sel, sel)) {
                result = g_dh_wk_swizzles[i].original;
                break;
            }
        }
    }
    pthread_mutex_unlock(&g_dh_wk_swizzle_lock);
    return result;
}

// ---- 系统镜像判定(反递归叠加用) ----
// 系统框架/库都在 dyld 共享缓存路径下；宿主 App、第三方 framework、越狱插件分别
// 落在 /var/containers、/var/jb、/usr/lib/TweakInject 等路径，据此区分。
static BOOL dh_wk_path_is_system(NSString *path) {
    if (!path.length) return NO;
    // 真机系统路径: /System/Library/...、/usr/lib/...
    // 模拟器系统路径: <Xcode>/.../RuntimeRoot/System/Library/...，所以用「包含」而不是前缀。
    return [path rangeOfString:@"/System/Library/"].location != NSNotFound ||
           [path rangeOfString:@"/usr/lib/"].location != NSNotFound;
}

static BOOL dh_wk_class_is_system(Class cls) {
    const char *image = cls ? class_getImageName(cls) : NULL;
    if (!image) return NO;
    NSString *path = [NSString stringWithUTF8String:image];
    return path ? dh_wk_path_is_system(path) : NO;
}

static BOOL dh_wk_imp_is_system(IMP imp) {
    Dl_info info = {0};
    if (!imp || dladdr((const void *)imp, &info) == 0 || !info.dli_fname) return NO;
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    return path ? dh_wk_path_is_system(path) : NO;
}

// 这些是 WebKit 自己实现的 API。即使宿主用自定义 WKWebView 子类覆写/二次 swizzle，
// 只要当前 IMP 不是系统实现，就绝不能再叠加 —— 否则会形成
// 「我们 → 宿主实现 → objc_msgSend(_cmd) → 我们」的无限递归。
static BOOL dh_wk_selector_requires_system_imp(SEL sel) {
    SEL apis[] = {
        @selector(loadRequest:),
        @selector(loadHTMLString:baseURL:),
        @selector(loadFileURL:allowingReadAccessToURL:),
        @selector(loadData:MIMEType:characterEncodingName:baseURL:),
        @selector(evaluateJavaScript:completionHandler:),
        @selector(evaluateJavaScript:inFrame:inContentWorld:completionHandler:),
        @selector(callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:),
        @selector(setNavigationDelegate:),
        @selector(setInspectable:),
        @selector(initWithFrame:configuration:),
        @selector(addScriptMessageHandler:name:),
        @selector(addScriptMessageHandler:contentWorld:name:),
        @selector(addUserScript:),
        @selector(getAllCookies:),
        @selector(setCookie:completionHandler:),
        @selector(deleteCookie:completionHandler:),
        @selector(fetchDataRecordsOfTypes:completionHandler:),
        @selector(removeDataOfTypes:modifiedSince:completionHandler:),
        @selector(setURLSchemeHandler:forURLScheme:),
    };
    for (size_t i = 0; i < sizeof(apis) / sizeof(apis[0]); i++) {
        if (sel_isEqual(sel, apis[i])) return YES;
    }
    return NO;
}

static BOOL dh_wk_swizzle_once(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement) return NO;
    Class implClass = dh_wk_impl_class(cls, sel);
    if (!implClass) {
        return NO;
    }

    pthread_mutex_lock(&g_dh_wk_swizzle_lock);
    for (size_t i = 0; i < g_dh_wk_swizzle_count; i++) {
        if (g_dh_wk_swizzles[i].cls == implClass && sel_isEqual(g_dh_wk_swizzles[i].sel, sel)) {
            pthread_mutex_unlock(&g_dh_wk_swizzle_lock);
            return NO;
        }
    }
    Method method = class_getInstanceMethod(implClass, sel);
    if (!method) {
        pthread_mutex_unlock(&g_dh_wk_swizzle_lock);
        return NO;
    }
    IMP original = method_getImplementation(method);
    // 反递归叠加 —— 系统类(WebKit/UIKit 等)上的方法如果已经被宿主或第三方 swizzle，
    // 此时 IMP 落在 App/插件镜像里。我们再叠加会把链路变成
    //   我们的 hook → 宿主实现 → objc_msgSend(_cmd) → 我们的 hook → …
    // 形成无限递归，主线程栈溢出(SIGSEGV KERN_PROTECTION_FAILURE)。
    // 实测 bilibili + TrollFools(注入晚于宿主 swizzle) 100% 复现。
    // 遇到这种已占用的系统方法直接跳过，把行为完整交还给宿主自己的实现。
    // App 自定义类(URL scheme handler / delegate)不受此限制，我们本来就该挂它们。
    BOOL requireSystemIMP = dh_wk_selector_requires_system_imp(sel);
    if ((requireSystemIMP || dh_wk_class_is_system(implClass)) && !dh_wk_imp_is_system(original)) {
        const char *clsName = class_getName(implClass);
        const char *selName = sel_getName(sel);
        NSString *msg = [NSString stringWithFormat:
            @"skip swizzle on system class %s %s: IMP already owned by non-system image (anti-recursion)",
            clsName ?: "?", selName ?: "?"];
        dh_diag_append(DH_BOARD, "WARN", msg.UTF8String);
        pthread_mutex_unlock(&g_dh_wk_swizzle_lock);
        return NO;
    }
    method_setImplementation(method, replacement);
    if (originalOut) *originalOut = original;
    if (g_dh_wk_swizzle_count < DH_WK_SWIZZLE_MAX) {
        DHWebKitSwizzle *slot = &g_dh_wk_swizzles[g_dh_wk_swizzle_count++];
        slot->cls = implClass;
        slot->sel = sel;
        slot->original = original;
    }
    pthread_mutex_unlock(&g_dh_wk_swizzle_lock);
    return YES;
}

// ============================================================
// WKWebView 导航 / JavaScript
// ============================================================

static id (*orig_wk_loadRequest)(id, SEL, id) = NULL;
static id swz_wk_loadRequest(id self, SEL _cmd, id request) {
    dh_wk_log(@"navigate", [NSString stringWithFormat:@"loadRequest %@", dh_wk_request_summary(request)],
              nil);
    return orig_wk_loadRequest ? orig_wk_loadRequest(self, _cmd, request) : nil;
}

static id (*orig_wk_loadHTML)(id, SEL, id, id) = NULL;
static id swz_wk_loadHTML(id self, SEL _cmd, id html, id baseURL) {
    dh_wk_log(@"navigate",
              [NSString stringWithFormat:@"loadHTMLString base=%@ len=%lu",
               dh_wk_url_of(baseURL) ?: @"(nil)", (unsigned long)[html length]],
              html);
    return orig_wk_loadHTML ? orig_wk_loadHTML(self, _cmd, html, baseURL) : nil;
}

static id (*orig_wk_loadFileURL)(id, SEL, id, id) = NULL;
static id swz_wk_loadFileURL(id self, SEL _cmd, id fileURL, id readAccessURL) {
    dh_wk_log(@"navigate",
              [NSString stringWithFormat:@"loadFileURL file=%@ read=%@",
               dh_wk_url_of(fileURL) ?: @"(nil)", dh_wk_url_of(readAccessURL) ?: @"(nil)"],
              nil);
    return orig_wk_loadFileURL ? orig_wk_loadFileURL(self, _cmd, fileURL, readAccessURL) : nil;
}

static id (*orig_wk_loadData)(id, SEL, id, id, id, id) = NULL;
static id swz_wk_loadData(id self, SEL _cmd, id data, id mime, id encoding, id baseURL) {
    dh_wk_log(@"navigate",
              [NSString stringWithFormat:@"loadData mime=%@ encoding=%@ base=%@ len=%lu",
               mime ?: @"(nil)", encoding ?: @"(nil)", dh_wk_url_of(baseURL) ?: @"(nil)",
               (unsigned long)[data length]],
              data);
    return orig_wk_loadData ? orig_wk_loadData(self, _cmd, data, mime, encoding, baseURL) : nil;
}

typedef void (^DHWKJSEvalCompletion)(id, NSError *);
static void (*orig_wk_evalJS)(id, SEL, id, DHWKJSEvalCompletion) = NULL;
static void swz_wk_evalJS(id self, SEL _cmd, id script, DHWKJSEvalCompletion completion) {
    dh_wk_log(@"evaluateJavaScript", [NSString stringWithFormat:@"len=%lu", (unsigned long)[script length]], script);
    DHWKJSEvalCompletion wrapped = ^(id result, NSError *error) {
        dh_wk_log(@"evaluateJavaScript.result",
                  [NSString stringWithFormat:@"resultClass=%@ error=%@",
                   NSStringFromClass([result class]) ?: @"(nil)", error.localizedDescription ?: @"(nil)"],
                  result ?: error);
        if (completion) completion(result, error);
    };
    if (orig_wk_evalJS) orig_wk_evalJS(self, _cmd, script, wrapped);
}

static void (*orig_wk_evalJSInWorld)(id, SEL, id, id, id, DHWKJSEvalCompletion) = NULL;
static void swz_wk_evalJSInWorld(id self, SEL _cmd, id script, id frame, id world,
                                 DHWKJSEvalCompletion completion) {
    dh_wk_log(@"evaluateJavaScript",
              [NSString stringWithFormat:@"inContentWorld len=%lu frame=%@",
               (unsigned long)[script length], dh_wk_url_of(frame) ?: @"(nil)"], script);
    DHWKJSEvalCompletion wrapped = ^(id result, NSError *error) {
        dh_wk_log(@"evaluateJavaScript.result",
                  [NSString stringWithFormat:@"inContentWorld error=%@", error.localizedDescription ?: @"(nil)"],
                  result ?: error);
        if (completion) completion(result, error);
    };
    if (orig_wk_evalJSInWorld) orig_wk_evalJSInWorld(self, _cmd, script, frame, world, wrapped);
}

static void (*orig_wk_callAsyncJS)(id, SEL, id, id, id, id, DHWKJSEvalCompletion) = NULL;
static void swz_wk_callAsyncJS(id self, SEL _cmd, id script, id arguments, id frame, id world,
                               DHWKJSEvalCompletion completion) {
    dh_wk_log(@"evaluateJavaScript",
              [NSString stringWithFormat:@"callAsyncJavaScript len=%lu frame=%@",
               (unsigned long)[script length], dh_wk_url_of(frame) ?: @"(nil)"], script);
    DHWKJSEvalCompletion wrapped = ^(id result, NSError *error) {
        dh_wk_log(@"evaluateJavaScript.result",
                  [NSString stringWithFormat:@"callAsyncJavaScript error=%@", error.localizedDescription ?: @"(nil)"],
                  result ?: error);
        if (completion) completion(result, error);
    };
    if (orig_wk_callAsyncJS)
        orig_wk_callAsyncJS(self, _cmd, script, arguments, frame, world, wrapped);
}

// ============================================================
// WKNavigationDelegate
// ============================================================

static void dh_wk_log_navigation(NSString *phase, id webView, id navigation, NSError *error) {
    NSString *url = dh_wk_url_of(webView);
    dh_wk_log(@"delegate",
              [NSString stringWithFormat:@"%@ url=%@ error=%@", phase, url ?: @"(nil)",
               error.localizedDescription ?: @"(nil)"], nil);
}

static void swz_wk_didStart(id self, SEL _cmd, id webView, id navigation) {
    dh_wk_log_navigation(@"didStartProvisionalNavigation", webView, navigation, nil);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id))original)(self, _cmd, webView, navigation);
}

static void swz_wk_didCommit(id self, SEL _cmd, id webView, id navigation) {
    dh_wk_log_navigation(@"didCommitNavigation", webView, navigation, nil);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id))original)(self, _cmd, webView, navigation);
}

static void swz_wk_didFinish(id self, SEL _cmd, id webView, id navigation) {
    dh_wk_log_navigation(@"didFinishNavigation", webView, navigation, nil);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id))original)(self, _cmd, webView, navigation);
}

static void swz_wk_didFail(id self, SEL _cmd, id webView, id navigation, NSError *error) {
    dh_wk_log_navigation(@"didFailNavigation", webView, navigation, error);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id, id))original)(self, _cmd, webView, navigation, error);
}

static void swz_wk_didFailProvisional(id self, SEL _cmd, id webView, id navigation, NSError *error) {
    dh_wk_log_navigation(@"didFailProvisionalNavigation", webView, navigation, error);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id, id))original)(self, _cmd, webView, navigation, error);
}

static void swz_wk_decidePolicy(id self, SEL _cmd, id webView, id action, id decisionHandler) {
    id request = nil;
    @try {
        SEL requestSel = NSSelectorFromString(@"request");
        if ([action respondsToSelector:requestSel])
            request = ((id (*)(id, SEL))objc_msgSend)(action, requestSel);
    } @catch (__unused NSException *e) {}
    dh_wk_log(@"delegate",
              [NSString stringWithFormat:@"decidePolicyForNavigationAction %@",
               dh_wk_request_summary(request)], nil);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id, id))original)(self, _cmd, webView, action, decisionHandler);
}

static void (*orig_wk_setNavigationDelegate)(id, SEL, id) = NULL;
static void swz_wk_setNavigationDelegate(id self, SEL _cmd, id delegate) {
    if (orig_wk_setNavigationDelegate) orig_wk_setNavigationDelegate(self, _cmd, delegate);
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    dh_wk_swizzle_once(cls, @selector(webView:didStartProvisionalNavigation:), (IMP)swz_wk_didStart, NULL);
    dh_wk_swizzle_once(cls, @selector(webView:didCommitNavigation:), (IMP)swz_wk_didCommit, NULL);
    dh_wk_swizzle_once(cls, @selector(webView:didFinishNavigation:), (IMP)swz_wk_didFinish, NULL);
    dh_wk_swizzle_once(cls, @selector(webView:didFailNavigation:withError:), (IMP)swz_wk_didFail, NULL);
    dh_wk_swizzle_once(cls, @selector(webView:didFailProvisionalNavigation:withError:),
                       (IMP)swz_wk_didFailProvisional, NULL);
    dh_wk_swizzle_once(cls, @selector(webView:decidePolicyForNavigationAction:decisionHandler:),
                       (IMP)swz_wk_decidePolicy, NULL);
    dh_wk_log(@"delegate", [NSString stringWithFormat:@"setNavigationDelegate class=%@",
                            NSStringFromClass(cls) ?: @"(nil)"], nil);
}

// ============================================================
// WKUserContentController / WKScriptMessage
// ============================================================

static void swz_wk_scriptMessage(id self, SEL _cmd, id userContentController, id message) {
    NSString *name = nil;
    id body = nil;
    @try {
        SEL nameSel = NSSelectorFromString(@"name");
        SEL bodySel = NSSelectorFromString(@"body");
        if ([message respondsToSelector:nameSel])
            name = ((id (*)(id, SEL))objc_msgSend)(message, nameSel);
        if ([message respondsToSelector:bodySel])
            body = ((id (*)(id, SEL))objc_msgSend)(message, bodySel);
    } @catch (__unused NSException *e) {}
    dh_wk_log(@"message",
              [NSString stringWithFormat:@"name=%@ class=%@", name ?: @"(nil)",
               NSStringFromClass([self class]) ?: @"(nil)"], body);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id))original)(self, _cmd, userContentController, message);
}

static void (*orig_wk_addScriptHandler)(id, SEL, id, id) = NULL;
static void swz_wk_addScriptHandler(id self, SEL _cmd, id handler, id name) {
    if (g_dh_wk_probe_installing ||
        [NSStringFromClass([handler class]) isEqualToString:@"DHWKProbeBridge"]) {
        if (orig_wk_addScriptHandler) orig_wk_addScriptHandler(self, _cmd, handler, name);
        return;
    }
    dh_wk_log(@"jsBridge", [NSString stringWithFormat:@"addScriptMessageHandler name=%@ class=%@",
                            name ?: @"(nil)", NSStringFromClass([handler class]) ?: @"(nil)"], nil);
    if (handler)
        dh_wk_swizzle_once(object_getClass(handler),
                           @selector(userContentController:didReceiveScriptMessage:),
                           (IMP)swz_wk_scriptMessage, NULL);
    if (orig_wk_addScriptHandler) orig_wk_addScriptHandler(self, _cmd, handler, name);
}

static void (*orig_wk_addScriptHandlerWorld)(id, SEL, id, id, id) = NULL;
static void swz_wk_addScriptHandlerWorld(id self, SEL _cmd, id handler, id world, id name) {
    if (g_dh_wk_probe_installing ||
        [NSStringFromClass([handler class]) isEqualToString:@"DHWKProbeBridge"]) {
        if (orig_wk_addScriptHandlerWorld) orig_wk_addScriptHandlerWorld(self, _cmd, handler, world, name);
        return;
    }
    dh_wk_log(@"jsBridge", [NSString stringWithFormat:@"addScriptMessageHandler(contentWorld) name=%@ class=%@",
                            name ?: @"(nil)", NSStringFromClass([handler class]) ?: @"(nil)"], nil);
    if (handler)
        dh_wk_swizzle_once(object_getClass(handler),
                           @selector(userContentController:didReceiveScriptMessage:),
                           (IMP)swz_wk_scriptMessage, NULL);
    if (orig_wk_addScriptHandlerWorld) orig_wk_addScriptHandlerWorld(self, _cmd, handler, world, name);
}

static void (*orig_wk_addUserScript)(id, SEL, id) = NULL;
static void swz_wk_addUserScript(id self, SEL _cmd, id userScript) {
    if (g_dh_wk_probe_installing) {
        if (orig_wk_addUserScript) orig_wk_addUserScript(self, _cmd, userScript);
        return;
    }
    NSString *source = nil;
    NSNumber *injectionTime = nil;
    NSNumber *mainFrameOnly = nil;
    @try {
        // KVC 会把 NSInteger/BOOL 自动装箱成 NSNumber；直接 objc_msgSend 成 id
        // 会让 ARC 去 retain 0x1，模拟器上会直接 SIGSEGV。
        source = [userScript valueForKey:@"source"];
        injectionTime = [userScript valueForKey:@"injectionTime"];
        mainFrameOnly = [userScript valueForKey:@"isForMainFrameOnly"];
    } @catch (__unused NSException *e) {}
    dh_wk_log(@"userScript",
              [NSString stringWithFormat:@"injectionTime=%@ mainFrameOnly=%@ len=%lu",
               injectionTime ?: @"(nil)", mainFrameOnly ?: @"(nil)",
               (unsigned long)source.length], source);
    if (orig_wk_addUserScript) orig_wk_addUserScript(self, _cmd, userScript);
}

// ============================================================
// Cookie / WebsiteDataStore
// ============================================================

typedef void (^DHWKCookieListCompletion)(NSArray *);
static void (*orig_wk_getAllCookies)(id, SEL, DHWKCookieListCompletion) = NULL;
static void swz_wk_getAllCookies(id self, SEL _cmd, DHWKCookieListCompletion completion) {
    DHWKCookieListCompletion wrapped = ^(NSArray *cookies) {
        NSMutableArray *rows = [NSMutableArray array];
        for (id cookie in cookies) [rows addObject:dh_wk_cookie_dict(cookie) ?: @{}];
        dh_wk_log(@"cookie.get",
                  [NSString stringWithFormat:@"count=%lu", (unsigned long)cookies.count], rows);
        if (completion) completion(cookies);
    };
    if (orig_wk_getAllCookies) orig_wk_getAllCookies(self, _cmd, wrapped);
}

typedef void (^DHWKVoidCompletion)(void);
static void (*orig_wk_setCookie)(id, SEL, id, DHWKVoidCompletion) = NULL;
static void swz_wk_setCookie(id self, SEL _cmd, id cookie, DHWKVoidCompletion completion) {
    dh_wk_log(@"cookie.set", @"setCookie", dh_wk_cookie_dict(cookie));
    DHWKVoidCompletion wrapped = ^{
        dh_wk_log(@"cookie.set.result", @"setCookie completion", nil);
        if (completion) completion();
    };
    if (orig_wk_setCookie) orig_wk_setCookie(self, _cmd, cookie, wrapped);
}

static void (*orig_wk_deleteCookie)(id, SEL, id, DHWKVoidCompletion) = NULL;
static void swz_wk_deleteCookie(id self, SEL _cmd, id cookie, DHWKVoidCompletion completion) {
    dh_wk_log(@"cookie.delete", @"deleteCookie", dh_wk_cookie_dict(cookie));
    DHWKVoidCompletion wrapped = ^{
        dh_wk_log(@"cookie.delete.result", @"deleteCookie completion", nil);
        if (completion) completion();
    };
    if (orig_wk_deleteCookie) orig_wk_deleteCookie(self, _cmd, cookie, wrapped);
}

typedef void (^DHWKDataRecordsCompletion)(NSArray *);
static void (*orig_wk_fetchDataRecords)(id, SEL, id, DHWKDataRecordsCompletion) = NULL;
static void swz_wk_fetchDataRecords(id self, SEL _cmd, id types, DHWKDataRecordsCompletion completion) {
    DHWKDataRecordsCompletion wrapped = ^(NSArray *records) {
        dh_wk_log(@"websiteData.fetch",
                  [NSString stringWithFormat:@"types=%@ count=%lu", types ?: @"(nil)",
                   (unsigned long)records.count], records);
        if (completion) completion(records);
    };
    if (orig_wk_fetchDataRecords) orig_wk_fetchDataRecords(self, _cmd, types, wrapped);
}

static void (*orig_wk_removeData)(id, SEL, id, id, DHWKVoidCompletion) = NULL;
static void swz_wk_removeData(id self, SEL _cmd, id types, id date, DHWKVoidCompletion completion) {
    dh_wk_log(@"websiteData.remove",
              [NSString stringWithFormat:@"types=%@ since=%@", types ?: @"(nil)", date ?: @"(nil)"], nil);
    DHWKVoidCompletion wrapped = ^{
        dh_wk_log(@"websiteData.remove.result", @"removeData completion", nil);
        if (completion) completion();
    };
    if (orig_wk_removeData) orig_wk_removeData(self, _cmd, types, date, wrapped);
}

// ============================================================
// WKURLSchemeHandler / 配置
// ============================================================

static void swz_wk_schemeStart(id self, SEL _cmd, id webView, id task) {
    id request = nil;
    @try {
        SEL requestSel = NSSelectorFromString(@"request");
        if ([task respondsToSelector:requestSel])
            request = ((id (*)(id, SEL))objc_msgSend)(task, requestSel);
    } @catch (__unused NSException *e) {}
    dh_wk_log(@"scheme.start",
              [NSString stringWithFormat:@"handler=%@ %@", NSStringFromClass([self class]) ?: @"(nil)",
               dh_wk_request_summary(request)], nil);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id))original)(self, _cmd, webView, task);
}

static void swz_wk_schemeStop(id self, SEL _cmd, id webView, id task) {
    id request = nil;
    @try {
        SEL requestSel = NSSelectorFromString(@"request");
        if ([task respondsToSelector:requestSel])
            request = ((id (*)(id, SEL))objc_msgSend)(task, requestSel);
    } @catch (__unused NSException *e) {}
    dh_wk_log(@"scheme.stop",
              [NSString stringWithFormat:@"handler=%@ %@", NSStringFromClass([self class]) ?: @"(nil)",
               dh_wk_request_summary(request)], nil);
    IMP original = dh_wk_original_imp(self, _cmd);
    if (original) ((void (*)(id, SEL, id, id))original)(self, _cmd, webView, task);
}

static void (*orig_wk_setSchemeHandler)(id, SEL, id, id) = NULL;
static void swz_wk_setSchemeHandler(id self, SEL _cmd, id handler, id scheme) {
    dh_wk_log(@"scheme.register",
              [NSString stringWithFormat:@"scheme=%@ handler=%@", scheme ?: @"(nil)",
               NSStringFromClass([handler class]) ?: @"(nil)"], nil);
    if (handler) {
        Class cls = object_getClass(handler);
        dh_wk_swizzle_once(cls, @selector(webView:startURLSchemeTask:), (IMP)swz_wk_schemeStart, NULL);
        dh_wk_swizzle_once(cls, @selector(webView:stopURLSchemeTask:), (IMP)swz_wk_schemeStop, NULL);
    }
    if (orig_wk_setSchemeHandler) orig_wk_setSchemeHandler(self, _cmd, handler, scheme);
}

static void (*orig_wk_setInspectable)(id, SEL, BOOL) = NULL;
static void swz_wk_setInspectable(id self, SEL _cmd, BOOL inspectable) {
    BOOL effective = dh_webkit_probe_enabled() ? YES : inspectable;
    dh_wk_log(@"inspectable", [NSString stringWithFormat:@"requested=%d effective=%d", inspectable, effective], nil);
    if (orig_wk_setInspectable) orig_wk_setInspectable(self, _cmd, effective);
}

// WKWebView / WKHTTPCookieStore 的真实方法经常落在私有具体子类上。
// 公共类上的 swizzle 只覆盖部分方法，实例创建后再对 object_getClass(instance) 补一次。
static void dh_wk_install_webview_methods(Class webView) {
    if (!webView) return;
    dh_wk_swizzle_once(webView, @selector(loadRequest:), (IMP)swz_wk_loadRequest,
                       (IMP *)&orig_wk_loadRequest);
    dh_wk_swizzle_once(webView, @selector(loadHTMLString:baseURL:), (IMP)swz_wk_loadHTML,
                       (IMP *)&orig_wk_loadHTML);
    dh_wk_swizzle_once(webView, @selector(loadFileURL:allowingReadAccessToURL:), (IMP)swz_wk_loadFileURL,
                       (IMP *)&orig_wk_loadFileURL);
    dh_wk_swizzle_once(webView, @selector(loadData:MIMEType:characterEncodingName:baseURL:),
                       (IMP)swz_wk_loadData, (IMP *)&orig_wk_loadData);
    dh_wk_swizzle_once(webView, @selector(evaluateJavaScript:completionHandler:), (IMP)swz_wk_evalJS,
                       (IMP *)&orig_wk_evalJS);
    dh_wk_swizzle_once(webView, @selector(evaluateJavaScript:inFrame:inContentWorld:completionHandler:),
                       (IMP)swz_wk_evalJSInWorld, (IMP *)&orig_wk_evalJSInWorld);
    dh_wk_swizzle_once(webView,
                       @selector(callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:),
                       (IMP)swz_wk_callAsyncJS, (IMP *)&orig_wk_callAsyncJS);
    dh_wk_swizzle_once(webView, @selector(setNavigationDelegate:), (IMP)swz_wk_setNavigationDelegate,
                       (IMP *)&orig_wk_setNavigationDelegate);
    dh_wk_swizzle_once(webView, @selector(setInspectable:), (IMP)swz_wk_setInspectable,
                       (IMP *)&orig_wk_setInspectable);
}

static void dh_wk_install_cookie_methods(Class cookieStore) {
    if (!cookieStore) return;
    dh_wk_swizzle_once(cookieStore, @selector(getAllCookies:), (IMP)swz_wk_getAllCookies,
                       (IMP *)&orig_wk_getAllCookies);
    dh_wk_swizzle_once(cookieStore, @selector(setCookie:completionHandler:), (IMP)swz_wk_setCookie,
                       (IMP *)&orig_wk_setCookie);
    dh_wk_swizzle_once(cookieStore, @selector(deleteCookie:completionHandler:), (IMP)swz_wk_deleteCookie,
                       (IMP *)&orig_wk_deleteCookie);
}

static void dh_wk_install_data_store_methods(Class dataStore) {
    if (!dataStore) return;
    dh_wk_swizzle_once(dataStore, @selector(fetchDataRecordsOfTypes:completionHandler:),
                       (IMP)swz_wk_fetchDataRecords, (IMP *)&orig_wk_fetchDataRecords);
    dh_wk_swizzle_once(dataStore,
                       @selector(removeDataOfTypes:modifiedSince:completionHandler:),
                       (IMP)swz_wk_removeData, (IMP *)&orig_wk_removeData);
}

static id (*orig_wk_initWithFrameConfiguration)(id, SEL, CGRect, id) = NULL;
static id swz_wk_initWithFrameConfiguration(id self, SEL _cmd, CGRect frame, id configuration) {
    // WKWebView 初始化时会读取 configuration；document-start 脚本必须在调用原 init 前加入。
    dh_wk_probe_install_configuration(configuration);
    id result = orig_wk_initWithFrameConfiguration
        ? orig_wk_initWithFrameConfiguration(self, _cmd, frame, configuration) : nil;
    if (result) {
        dh_wk_install_webview_methods(object_getClass(result));
        @try {
            id dataStore = [configuration valueForKey:@"websiteDataStore"];
            if (dataStore) {
                dh_wk_install_data_store_methods(object_getClass(dataStore));
                id cookieStore = [dataStore valueForKey:@"httpCookieStore"];
                if (cookieStore) dh_wk_install_cookie_methods(object_getClass(cookieStore));
            }
        } @catch (__unused NSException *e) {}
        if (dh_webkit_probe_enabled() && [result respondsToSelector:@selector(setInspectable:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(result, @selector(setInspectable:), YES);
        }
    }
    return result;
}

// ============================================================
// 安装：WebKit 可能晚于 dylib 加载，使用 dyld image 回调按需安装
// ============================================================

static pthread_mutex_t g_dh_wk_install_lock = PTHREAD_MUTEX_INITIALIZER;
static BOOL g_dh_wk_installed = NO;

static void dh_wk_install_now(void) {
    Class webView = NSClassFromString(@"WKWebView");
    Class contentController = NSClassFromString(@"WKUserContentController");
    Class cookieStore = NSClassFromString(@"WKHTTPCookieStore");
    Class dataStore = NSClassFromString(@"WKWebsiteDataStore");
    Class configuration = NSClassFromString(@"WKWebViewConfiguration");
    if (!webView || !contentController || !configuration) return;

    pthread_mutex_lock(&g_dh_wk_install_lock);
    if (g_dh_wk_installed) {
        pthread_mutex_unlock(&g_dh_wk_install_lock);
        return;
    }

    dh_wk_install_webview_methods(webView);
    dh_wk_swizzle_once(webView, @selector(initWithFrame:configuration:),
                       (IMP)swz_wk_initWithFrameConfiguration,
                       (IMP *)&orig_wk_initWithFrameConfiguration);

    dh_wk_swizzle_once(contentController, @selector(addScriptMessageHandler:name:),
                       (IMP)swz_wk_addScriptHandler, (IMP *)&orig_wk_addScriptHandler);
    dh_wk_swizzle_once(contentController, @selector(addScriptMessageHandler:contentWorld:name:),
                       (IMP)swz_wk_addScriptHandlerWorld, (IMP *)&orig_wk_addScriptHandlerWorld);
    dh_wk_swizzle_once(contentController, @selector(addUserScript:), (IMP)swz_wk_addUserScript,
                       (IMP *)&orig_wk_addUserScript);

    dh_wk_install_cookie_methods(cookieStore);
    dh_wk_install_data_store_methods(dataStore);
    dh_wk_swizzle_once(configuration, @selector(setURLSchemeHandler:forURLScheme:),
                       (IMP)swz_wk_setSchemeHandler, (IMP *)&orig_wk_setSchemeHandler);

    g_dh_wk_installed = YES;
    pthread_mutex_unlock(&g_dh_wk_install_lock);
}

static void dh_wk_image_added(const struct mach_header *header, intptr_t slide) {
    (void)header;
    (void)slide;
    dh_wk_install_now();
}

void dh_install_webkit_hooks(void) {
    dh_wk_install_now();
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _dyld_register_func_for_add_image(dh_wk_image_added);
    });
}
