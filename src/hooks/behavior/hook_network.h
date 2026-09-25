// hook_network.h — 网络 hook 内部协作接口
//
// dylib 自身的 HTTP 服务也使用 socket/send/recv。通用 socket 抓包必须先把这个 fd 标记为
// 内部 fd，否则 MCP/Web 面板自己的请求会被当成目标 App 的业务流量，既污染证据，也可能
// 在日志落盘时形成递归。

#ifndef DH_HOOK_NETWORK_H
#define DH_HOOK_NETWORK_H

#ifdef __cplusplus
extern "C" {
#endif

void dh_net_mark_internal_fd(int fd);

// WebKit Networking 等系统网络进程使用同一主引擎，但只安装低层网络入口，
// 避免在系统 XPC 进程里实例化 NSURLSession/WKWebView 或启动其它分析模块。
void dh_install_network_process_hooks(void);

#ifdef __cplusplus
}
#endif

#endif // DH_HOOK_NETWORK_H
