// dh_collector.h - 跨进程事件汇总
// 普通 App 是 host；com.apple.WebKit.Networking 是 producer，仅通过回环上报，不监听端口。

#ifndef DH_COLLECTOR_H
#define DH_COLLECTOR_H

#import <Foundation/Foundation.h>

@class DHLogEntry;

NS_ASSUME_NONNULL_BEGIN

void dh_collector_configure(BOOL producer);
void dh_collector_forward_entry(DHLogEntry *entry, BOOL replacement);
BOOL dh_collector_ingest(id envelopeOrArray, NSString * _Nullable * _Nullable error);
NSDictionary *dh_collector_info(void);
NSDictionary *dh_collector_status(void);

NS_ASSUME_NONNULL_END
#endif
