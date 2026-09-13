// DHAppEnumerator.h — 已安装 App 的枚举与图标
//
// 只做两件事：列出用户 App（带显示名与 bundle 路径）、给出图标。
// 图标加载带缓存，供列表滚动时调用。

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DHAppInfo : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *bundlePath;
@end

/// 已安装的用户 App（按显示名排序，已过滤系统 App）：先走 LaunchServices，失败兜底扫容器目录
NSArray<DHAppInfo *> *DHInstalledApps(void);

/// 单个 App 的图标：先取系统图标缓存，再退回读 bundle 内的图标文件；都可能失败时返回 nil
UIImage *_Nullable DHAppIcon(NSString *bundleID, NSString *_Nullable bundlePath);

NS_ASSUME_NONNULL_END
