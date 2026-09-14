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

/// 单个 App 的原始图标：先取系统图标缓存，再退回读 bundle 内的图标文件；都可能失败时返回 nil
UIImage *_Nullable DHAppIcon(NSString *bundleID, NSString *_Nullable bundlePath);

/// 列表用图标：圆角（R 角）、固定尺寸、带缓存；取不到图标时返回"首字母"默认图标，绝不空着
UIImage *DHAppListIcon(NSString *bundleID, NSString *_Nullable bundlePath, NSString *_Nullable displayName);

/// 该 App 当前是否在运行（按可执行名匹配；越狱环境下本 App 未沙盒化，可枚举进程）
BOOL DHAppProcessRunning(DHAppInfo *app);
/// 结束该 App 进程；杀掉至少一个返回 YES。rootHide 下 daemon 写不了锁文件，重启必须由本 App 自己做。
BOOL DHKillAppProcess(DHAppInfo *app);
/// 重新打开 App（LaunchServices / SpringBoardServices / uiopen）。成功返回 YES。
BOOL DHRelaunchApp(NSString *bundleID);

/// 分组用索引字母：中文按拼音首字母（如 微信 → W），非字母归到 "#"
NSString *DHAppIndexLetter(NSString *displayName);

NS_ASSUME_NONNULL_END
