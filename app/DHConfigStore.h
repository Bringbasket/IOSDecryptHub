// DHConfigStore.h — 管理器 App 的数据层：名单 / 引擎元信息 / 更新状态 / 更新请求
//
// 读写的都是 dh_shared.h 约定的单一事实源。所有文件读取 nil-safe，
// 越狱环境缺失时返回空，由 UI 展示为"未知/未安装"，不崩溃。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 越狱 bootstrap 根目录（dladdr 反推，不硬编码 /var/jb；失败返回 nil）
NSString *_Nullable DHBootstrapRoot(void);

/// 已启用的注入名单
NSSet<NSString *> *DHReadEnabledBundles(void);
/// 写回名单；成功返回 YES（失败时调用方应回滚开关并提示）
BOOL DHWriteEnabledBundles(NSSet<NSString *> *bundleIDs);

/// 引擎元信息 {version, variant, arch}，缺失返回空字典
NSDictionary *DHReadEngineMeta(void);
/// daemon 写的更新状态，缺失返回空字典
NSDictionary *DHReadUpdaterState(void);

/// 向 daemon 提交更新请求（check / install / rollback）；version 非空时安装指定版本
BOOL DHWriteUpdateRequest(NSString *action, NSString *_Nullable version);

/// 请求停止指定 App（只结束进程，不重新打开，由 daemon 执行）
BOOL DHWriteStopRequest(NSString *bundleID);

/// 请求重启指定 App（结束进程并尽量重新打开，由 daemon 执行）
BOOL DHWriteRestartRequest(NSString *bundleID);

/// 拉取历史版本列表；回调在主线程。元素：@{@"tag": @"v1.25.1", @"version": @"1.25.1", @"date": @"2026-09-13"}
void DHFetchReleases(void (^completion)(NSArray<NSDictionary *> *_Nullable releases, NSError *_Nullable error));

/// 前台即时查询 GitHub 最新 release；回调在主线程。
/// 成功：info = @{@"tag": @"v1.24.10", @"version": @"1.24.10"}；失败：error 非空
void DHFetchLatestRelease(void (^completion)(NSDictionary *_Nullable info, NSError *_Nullable error));

/// 版本号比较（去 v 前缀，按数字分段）；返回 NSOrderedAscending 等
NSComparisonResult DHCompareVersions(NSString *left, NSString *right);

NS_ASSUME_NONNULL_END
