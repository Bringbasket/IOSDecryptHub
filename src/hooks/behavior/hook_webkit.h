// hook_webkit.h — WKWebView 宿主侧观测入口

#ifndef DH_HOOK_WEBKIT_H
#define DH_HOOK_WEBKIT_H

#ifdef __cplusplus
extern "C" {
#endif

// 在 WebKit 已加载或后续加载时安装宿主侧 WKWebView 观测。
// 只使用 ObjC runtime swizzle，不进入 WebContent/Networking 进程。
void dh_install_webkit_hooks(void);

// JS 网络探针配置。enabledByManager 是管理器功能开关的单一启动门控；
// confPath 仅保留脱敏和域名过滤等细项，不会反向覆盖管理器开关。
void dh_webkit_probe_load(NSString *confPath, BOOL enabledByManager);
NSDictionary *dh_webkit_probe_snapshot(void);
void dh_webkit_probe_set_config(NSDictionary *changes);
BOOL dh_webkit_probe_enabled(void);

#ifdef __cplusplus
}
#endif

#endif // DH_HOOK_WEBKIT_H
