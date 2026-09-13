# IOSDecryptHub

**中文** | [English](README.en.md)

Sileo / Zebra 添加源：

```
https://ios.decrypthub.com
```

按环境安装：

- rootless（Dopamine、palera1n）：rootless.deb
- roothide：roothide.deb

装好后桌面上会多一个 **IOSDecryptHub** 图标：在这里开关要注入的 App、检查更新、看历史版本。打开目标 App 前先完全退出，再启动即可注入。浏览器打开 `http://<设备IP>:8088`，即可看到实时 Web 面板：

<p align="center">
  <img src="./docs/screenshots/webui.png" alt="IOSDecryptHub Web 面板：加解密事件列表与输入明文 / HEX / HEXDUMP 详情" width="920">
</p>

默认不注入任何 App。依赖 ellekit。

## 包内组件

| 组件 | 作用 |
|------|------|
| 注入加载器 | 读启用名单，命中才 `dlopen` 引擎；不含任何 hook |
| 引擎 dylib | 闭源核心，所有 hook 都在它的 constructor 里 |
| 管理器 App | 桌面图标：开关应用、看引擎版本与更新状态、一键更新 / 回滚 |
| updater daemon | 一次性进程（launchd 按需拉起），负责检查、下载、安装、回滚引擎 |

## 更新机制

管理器 App 里点「检查更新」→ 写入请求 → daemon 被 launchd 拉起执行：

1. 取最新版本号（先读 GitHub `releases/latest` 的 302，不吃 API 配额；失败才退回 API）
2. 下载引擎 → 校验体积与 Mach-O 架构（只认 arm64 家族），不合格直接丢弃
3. **先备份**当前引擎，替换失败立刻用备份恢复；没有备份成功就绝不替换
4. 原子落位后，结束已启用 App 的进程 —— 下次打开就是新引擎
5. 回滚是 swap 语义：滚回去，备份里留着刚滚下来的版本，还能再滚回来

不用卸装重装，也不用 respring。

从源码打 deb（macOS + Xcode + dpkg + ldid）：

```bash
make deb
```

更新链路的仿真回归测试（macOS 本机即可，不需要真机，需要网络）：

```bash
make test-updater
```

## 关注

微信搜一搜 **DecryptHub**，点下面二维码也能加公众号。

<p align="center">
  <img src="./wechat-qr.png" alt="微信公众号 DecryptHub" width="168">
</p>

- Telegram：https://t.me/decrypthubteam
- X：https://x.com/decrypthub_
