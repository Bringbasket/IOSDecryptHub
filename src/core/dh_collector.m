// dh_collector.m - WebKit Networking/WIR -> 目标 App 日志中心

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <stdatomic.h>
#import <string.h>
#import "dh_collector.h"
#import "log_store.h"
#import "http_server.h"
#import "hook_network.h"

#define DH_COLLECTOR_PORT_FIRST 8088
#define DH_COLLECTOR_PORT_LAST  8108
#define DH_COLLECTOR_QUEUE_MAX  256
#define DH_COLLECTOR_BATCH_MAX  8
#define DH_COLLECTOR_BLOB_MAX   (64 * 1024)
#define DH_COLLECTOR_RESPONSE_MAX (256 * 1024)

static dispatch_queue_t gCollectorQ;
static NSMutableArray<NSDictionary *> *gPending;
static NSMutableDictionary<NSString *, DHLogEntry *> *gOrigins;
static NSMutableArray<NSString *> *gOriginOrder;
static BOOL gProducer;
static BOOL gFlushScheduled;
static int gTargetPort;
static uint64_t gForwarded;
static uint64_t gReceived;
static uint64_t gDropped;
static uint64_t gFailures;
static NSTimeInterval gRetryDelay = 0.5;
static char gCollectorQueueKey;

static void dh_collector_ensure(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gCollectorQ = dispatch_queue_create("com.decrypthelper.collector", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(gCollectorQ, &gCollectorQueueKey, &gCollectorQueueKey, NULL);
        gPending = [NSMutableArray array];
        gOrigins = [NSMutableDictionary dictionary];
        gOriginOrder = [NSMutableArray array];
    });
}

static NSString *dh_collector_home_token(void) {
    NSString *home = NSHomeDirectory();
    return home.lastPathComponent.length ? home.lastPathComponent : @"unknown";
}

void dh_collector_configure(BOOL producer) {
    dh_collector_ensure();
    dispatch_sync(gCollectorQ, ^{
        gProducer = producer;
        gTargetPort = 0;
    });
}

static NSString *dh_collector_string(id value, NSUInteger maxBytes) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    NSString *s = value;
    NSData *data = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length <= maxBytes) return s;
    NSUInteger n = maxBytes;
    while (n > 0) {
        NSString *cut = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, n)]
                                               encoding:NSUTF8StringEncoding];
        if (cut) return [cut stringByAppendingString:@"…"];
        n--;
    }
    return @"";
}

static NSString *dh_collector_b64(NSData *data, NSMutableDictionary *metadata, NSString *field) {
    if (!data.length) return nil;
    NSData *bounded = data;
    if (bounded.length > DH_COLLECTOR_BLOB_MAX) {
        bounded = [bounded subdataWithRange:NSMakeRange(0, DH_COLLECTOR_BLOB_MAX)];
        metadata[[field stringByAppendingString:@"Length"]] = @(data.length);
        metadata[[field stringByAppendingString:@"Truncated"]] = @YES;
    }
    return [bounded base64EncodedStringWithOptions:0];
}

static NSDictionary *dh_collector_envelope(DHLogEntry *entry, BOOL replacement) {
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    if ([entry.metadata isKindOfClass:[NSDictionary class]]) [metadata addEntriesFromDictionary:entry.metadata];
    if (![metadata[@"source"] isKindOfClass:[NSString class]]) metadata[@"source"] = @"networking";
    metadata[@"originPid"] = @(getpid());
    metadata[@"originSeq"] = @(entry.seq);

    NSMutableDictionary *out = [@{
        @"format": @"iosdecrypthub.collector.v1",
        @"source": metadata[@"source"],
        @"originPid": @(getpid()),
        @"originSeq": @(entry.seq),
        @"replace": replacement ? @YES : @NO,
        @"category": @(entry.category),
        @"algorithm": entry.algorithm ?: @"",
        @"operation": entry.operation ?: @"",
        @"detail": dh_collector_string(entry.detail, 64 * 1024),
        @"timestamp": entry.timestamp ?: @"",
        @"timestampMs": @(entry.timestampMs),
        @"threadId": @(entry.threadId),
        @"publicKeyInfo": dh_collector_string(entry.publicKeyInfo, 2048),
        @"callStack": dh_collector_string(entry.callStack, 16 * 1024),
        @"metadata": metadata,
    } mutableCopy];
    NSString *key = dh_collector_b64(entry.key, metadata, @"key");
    NSString *iv = dh_collector_b64(entry.iv, metadata, @"iv");
    NSString *input = dh_collector_b64(entry.input, metadata, @"input");
    NSString *output = dh_collector_b64(entry.output, metadata, @"output");
    if (key) out[@"keyBase64"] = key;
    if (iv) out[@"ivBase64"] = iv;
    if (input) out[@"inputBase64"] = input;
    if (output) out[@"outputBase64"] = output;
    return out;
}

static NSData *dh_collector_http(int port, NSString *method, NSString *path, NSData *body,
                                 int *statusOut) {
    if (statusOut) *statusOut = 0;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    dh_net_mark_internal_fd(fd);
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));
    struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return nil; }

    NSMutableString *header = [NSMutableString stringWithFormat:
        @"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n", method, path, port];
    if (body) [header appendFormat:@"Content-Type: application/json\r\nContent-Length: %lu\r\n",
               (unsigned long)body.length];
    [header appendString:@"\r\n"];
    NSMutableData *request = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    if (body) [request appendData:body];
    const uint8_t *bytes = request.bytes;
    NSUInteger left = request.length;
    while (left) {
        ssize_t n = send(fd, bytes, left, 0);
        if (n <= 0) { close(fd); return nil; }
        bytes += n;
        left -= (NSUInteger)n;
    }

    NSMutableData *response = [NSMutableData data];
    uint8_t buf[4096];
    while (response.length < DH_COLLECTOR_RESPONSE_MAX) {
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [response appendBytes:buf length:(NSUInteger)n];
    }
    close(fd);
    const uint8_t *raw = response.bytes;
    NSUInteger length = response.length;
    if (length < 12) return nil;
    NSString *head = [[NSString alloc] initWithBytes:raw length:MIN(length, (NSUInteger)4096)
                                            encoding:NSUTF8StringEncoding];
    NSScanner *scanner = [NSScanner scannerWithString:head ?: @""];
    [scanner scanUpToString:@" " intoString:nil];
    NSInteger status = 0;
    [scanner scanInteger:&status];
    if (statusOut) *statusOut = (int)status;
    const void *sep = memmem(raw, length, "\r\n\r\n", 4);
    if (!sep) return nil;
    NSUInteger offset = (const uint8_t *)sep - raw + 4;
    return [response subdataWithRange:NSMakeRange(offset, length - offset)];
}

static NSDictionary *dh_collector_info_at_port(int port) {
    int status = 0;
    NSData *body = dh_collector_http(port, @"GET", @"/api/collector/info", nil, &status);
    if (status != 200 || !body.length) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

static int dh_collector_find_host(void) {
    NSString *wanted = dh_collector_home_token();
    int fallback = 0;
    NSUInteger candidates = 0;
    for (int port = DH_COLLECTOR_PORT_FIRST; port <= DH_COLLECTOR_PORT_LAST; port++) {
        NSDictionary *info = dh_collector_info_at_port(port);
        if (![info[@"format"] isEqual:@"iosdecrypthub.collector.v1"] || [info[@"producer"] boolValue]) continue;
        candidates++;
        if (!fallback) fallback = port;
        if ([info[@"homeToken"] isEqual:wanted]) return port;
    }
    // 无法用容器 token 对上时，只在唯一候选下兜底，避免多 App 同开时串流量。
    return candidates == 1 ? fallback : 0;
}

static void dh_collector_schedule_flush(NSTimeInterval delay);

static void dh_collector_flush_locked(void) {
    gFlushScheduled = NO;
    if (!gProducer || gPending.count == 0) return;
    if (!gTargetPort) gTargetPort = dh_collector_find_host();
    if (!gTargetPort) {
        gFailures++;
        dh_collector_schedule_flush(gRetryDelay);
        gRetryDelay = MIN(gRetryDelay * 2.0, 10.0);
        return;
    }
    NSUInteger n = MIN(gPending.count, (NSUInteger)DH_COLLECTOR_BATCH_MAX);
    NSArray *batch = [gPending subarrayWithRange:NSMakeRange(0, n)];
    NSData *body = [NSJSONSerialization dataWithJSONObject:batch options:0 error:nil];
    int status = 0;
    NSData *response = body ? dh_collector_http(gTargetPort, @"POST", @"/api/collector/ingest", body, &status) : nil;
    if (status >= 200 && status < 300 && response) {
        [gPending removeObjectsInRange:NSMakeRange(0, n)];
        gForwarded += n;
        gRetryDelay = 0.5;
        if (gPending.count) dh_collector_schedule_flush(0.01);
    } else {
        gFailures++;
        gTargetPort = 0;
        dh_collector_schedule_flush(gRetryDelay);
        gRetryDelay = MIN(gRetryDelay * 2.0, 10.0);
    }
}

static void dh_collector_schedule_flush(NSTimeInterval delay) {
    if (gFlushScheduled) return;
    gFlushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), gCollectorQ, ^{
        dh_collector_flush_locked();
    });
}

void dh_collector_forward_entry(DHLogEntry *entry, BOOL replacement) {
    if (!entry) return;
    dh_collector_ensure();
    dispatch_async(gCollectorQ, ^{
        if (!gProducer) return;
        NSDictionary *envelope = dh_collector_envelope(entry, replacement);
        if (gPending.count >= DH_COLLECTOR_QUEUE_MAX) {
            [gPending removeObjectAtIndex:0];
            gDropped++;
        }
        [gPending addObject:envelope];
        dh_collector_schedule_flush(0.02);
    });
}

static NSData *dh_collector_decode(id value) {
    if (![value isKindOfClass:[NSString class]] || [value length] == 0) return nil;
    return [[NSData alloc] initWithBase64EncodedString:value options:0];
}

static BOOL dh_collector_ingest_one(NSDictionary *envelope, NSString **error) {
    if (![envelope[@"format"] isEqual:@"iosdecrypthub.collector.v1"]) {
        if (error) *error = @"unsupported collector format";
        return NO;
    }
    NSNumber *originPid = [envelope[@"originPid"] isKindOfClass:[NSNumber class]] ? envelope[@"originPid"] : nil;
    NSNumber *originSeq = [envelope[@"originSeq"] isKindOfClass:[NSNumber class]] ? envelope[@"originSeq"] : nil;
    if (!originPid || !originSeq) {
        if (error) *error = @"originPid/originSeq required";
        return NO;
    }
    NSInteger category = [envelope[@"category"] integerValue];
    if (category < 0 || category > DHCategoryOther) category = DHCategoryNetwork;
    NSString *source = dh_collector_string(envelope[@"source"], 64);
    if (!source.length) source = @"external";

    DHLogEntry *entry = [DHLogEntry new];
    entry.category = (DHCategory)category;
    entry.algorithm = dh_collector_string(envelope[@"algorithm"], 256);
    entry.operation = dh_collector_string(envelope[@"operation"], 256);
    entry.detail = dh_collector_string(envelope[@"detail"], 64 * 1024);
    entry.timestamp = dh_collector_string(envelope[@"timestamp"], 128);
    if (!entry.timestamp.length) entry.timestamp = DHTimestampNow();
    entry.timestampMs = [envelope[@"timestampMs"] unsignedLongLongValue];
    entry.threadId = [envelope[@"threadId"] unsignedLongLongValue];
    entry.publicKeyInfo = dh_collector_string(envelope[@"publicKeyInfo"], 2048);
    entry.callStack = dh_collector_string(envelope[@"callStack"], 16 * 1024);
    entry.key = dh_collector_decode(envelope[@"keyBase64"]);
    entry.iv = dh_collector_decode(envelope[@"ivBase64"]);
    entry.input = dh_collector_decode(envelope[@"inputBase64"]);
    entry.output = dh_collector_decode(envelope[@"outputBase64"]);
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
    if ([envelope[@"metadata"] isKindOfClass:[NSDictionary class]] &&
        [NSJSONSerialization isValidJSONObject:envelope[@"metadata"]])
        [metadata addEntriesFromDictionary:envelope[@"metadata"]];
    metadata[@"source"] = source;
    metadata[@"originPid"] = originPid;
    metadata[@"originSeq"] = originSeq;
    entry.metadata = metadata;

    NSString *originKey = [NSString stringWithFormat:@"%@:%@", originPid, originSeq];
    DHLogEntry *old = gOrigins[originKey];
    BOOL replace = [envelope[@"replace"] boolValue];
    // producer 超时后会按批重发；相同 origin 的初始事件只接收一次。
    if (old && !replace) {
        gReceived++;
        return YES;
    }
    if (replace && old) [[DHLogStore shared] replaceNetworkEntry:old with:entry];
    else [[DHLogStore shared] append:entry];
    // WIR 事件不会发送 replace，不必额外持有条目；Networking 请求保留有界映射用于响应原位替换。
    if (![source isEqualToString:@"wir"]) {
        if (!old) [gOriginOrder addObject:originKey];
        gOrigins[originKey] = entry;
    }
    if (gOriginOrder.count > 2048) {
        NSUInteger removeCount = MIN((NSUInteger)1024, gOriginOrder.count);
        NSArray *expired = [gOriginOrder subarrayWithRange:NSMakeRange(0, removeCount)];
        [gOriginOrder removeObjectsInRange:NSMakeRange(0, removeCount)];
        for (NSString *key in expired) [gOrigins removeObjectForKey:key];
    }
    gReceived++;
    return YES;
}

BOOL dh_collector_ingest(id object, NSString **error) {
    dh_collector_ensure();
    if (gProducer) {
        if (error) *error = @"producer cannot ingest";
        return NO;
    }
    NSArray *items = [object isKindOfClass:[NSArray class]] ? object : @[object ?: [NSNull null]];
    __block BOOL ok = YES;
    __block NSString *localError = nil;
    void (^work)(void) = ^{
        for (id item in items) {
            if (![item isKindOfClass:[NSDictionary class]] || !dh_collector_ingest_one(item, &localError)) {
                ok = NO;
                break;
            }
        }
    };
    if (dispatch_get_specific(&gCollectorQueueKey)) work(); else dispatch_sync(gCollectorQ, work);
    if (!ok && error) *error = localError ?: @"invalid collector envelope";
    return ok;
}

NSDictionary *dh_collector_status(void) {
    dh_collector_ensure();
    __block NSDictionary *out;
    void (^work)(void) = ^{
        out = @{
            @"producer": gProducer ? @YES : @NO,
            @"targetPort": @(gTargetPort),
            @"pending": @(gPending.count),
            @"forwarded": @(gForwarded),
            @"received": @(gReceived),
            @"dropped": @(gDropped),
            @"failures": @(gFailures),
        };
    };
    if (dispatch_get_specific(&gCollectorQueueKey)) work(); else dispatch_sync(gCollectorQ, work);
    return out;
}

NSDictionary *dh_collector_info(void) {
    NSString *bundle = [NSBundle mainBundle].bundleIdentifier ?: @"";
    return @{
        @"format": @"iosdecrypthub.collector.v1",
        @"producer": gProducer ? @YES : @NO,
        @"pid": @(getpid()),
        @"process": [NSProcessInfo processInfo].processName ?: @"",
        @"bundleId": bundle,
        @"homeToken": dh_collector_home_token(),
        @"port": @(dh_http_port()),
        @"status": dh_collector_status(),
    };
}
