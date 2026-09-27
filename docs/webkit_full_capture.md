# WebKit 网络采集

IOSDecryptHub 把以下两类 WebKit 事件汇总到目标 App 的 Web 面板：

1. **WKWebView JS 探针**：在 document-start 观测 fetch、XHR、WebSocket、EventSource、sendBeacon，请求体支持 FormData、Blob、ArrayBuffer 等类型。面板来源显示为 `JS`。
2. **Remote Inspector/CDP**：获取 URL、请求头、响应头、资源类型，并尝试读取请求 postData 与响应 body，来源显示为 `WIR`。

旧版曾向 `com.apple.WebKit.Networking` 注入低层网络 Hook。它是系统进程，可能处理多个 App 的 WebView；高频 Hook 和日志处理会拖慢或阻塞全机网页流量。该路径已停用，旧配置里的 `webkitProcess` 也不会重新启用它。JS 探针和 WIR 能覆盖各自可见的请求，但不能保证拿到所有底层 TLS/连接细节。

## 手机端开关

在 IOSDecryptHub 管理器的功能设置中打开：

- 网络抓包
- WebKit JS 探针

随后完全退出并重新打开目标 App。JS 探针对新建或重新加载的 WKWebView 生效。

## 电脑端 WIR 桥

先安装依赖：

```bash
python -m pip install pymobiledevice3 websocket-client
```

让 `pymobiledevice3` 连接已配对设备并暴露 CDP（不同版本的设备选择参数以其 `--help` 为准）：

```bash
pymobiledevice3 webinspector cdp --host 127.0.0.1 --port 9222
```

另开终端，把 CDP 事件发到目标 App 的实际面板端口：

```bash
python tools/idh_wir_bridge.py \
  --cdp http://127.0.0.1:9222 \
  --collector http://192.168.1.159:8088
```

设备同时存在多个可检查页面时，可用标题或 URL 正则过滤：

```bash
python tools/idh_wir_bridge.py --collector http://192.168.1.159:8088 --target '目标域名|页面标题'
```

桥接器轮询 `/json/list`，自动连接新页面、执行 `Network.enable`，并在请求/响应结束后调用 `Network.getRequestPostData` 与 `Network.getResponseBody`。响应体单条最多保留 512 KiB，超出会写入截断标记，避免页面或目标 App 内存失控。

## 验证

- `GET /api/collector/info`：当前 App collector 身份。
- `GET /api/collector/status`：收到、转发、丢弃和失败计数。
- `GET /api/stats` 的 `collector` 字段：同一状态的面板轮询版本。
- Web 面板网络列表中的 `[JS]`、`[WIR]` 标签：确认事件具体来自哪一层。

旧日志仍可能显示 `[NETWORKING]`，更新后的版本不会再产生新的系统 Networking 事件。

> Web/MCP/collector 仍无认证，只应在可信局域网使用。仅分析你拥有或明确获授权的 App 与流量。
