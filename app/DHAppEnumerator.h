// DHAppEnumerator.h — 已安装应用枚举（bundleID → 显示名）

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 先走 LaunchServices，失败兜底扫 /var/containers/Bundle/Application。
/// 过滤 com.apple.* 与非用户应用；永远返回字典（失败为空），不抛异常。
NSDictionary<NSString *, NSString *> *DHInstalledApps(void);

NS_ASSUME_NONNULL_END
