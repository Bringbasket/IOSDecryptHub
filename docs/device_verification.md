# 真机验证清单（管理器 App + updater daemon）

这两个组件在设备上有几件事无法在 Mac 上仿真验证，必须真机走一遍再对外发布。
下面按依赖顺序排列：前面不通过就不要往下测。

前置：装对应环境的 deb（rootless 或 roothide），准备好 SSH（或 Filza）看文件。

## 1. 包与 App 能否起来

| 检查 | 命令 / 观察点 | 期望 |
|------|----------------|------|
| 包已装 | `dpkg -l com.iosdecrypthub` | 版本 1.25.0（测试包为 1.24.11） |
| App 文件在 | `ls /var/jb/Applications/IOSDecryptHubManager.app` | 存在（roothide 去掉 `/var/jb`） |
| 桌面图标 | 主屏出现「IOSDecryptHub」 | 出现；没出现就 `uicache -p <上面那个路径>` |
| 能启动 | 点开 App | 不闪退，看到"状态/软件更新/注入应用/关于"四段 |

> 最大不确定项是 App 的 `platform-application` 提权能否让它读写越狱路径。
> 若闪退，用 `idevicesyslog | grep -i iosdecrypthub` 或 `ls ~/Library/Logs/CrashReporter` 抓崩溃原因。

## 2. 状态页读数是否正确

App「状态」这段应显示：

- 引擎版本 = 包里 version.plist 的版本
- 已启用应用 = 当前名单条数
- 后台更新 = 「活跃（x 分钟前）」← 说明 daemon 至少跑过一次；显示「尚未运行」见第 4 步

## 3. 开关能否写进名单（App → loader）

1. App 里打开某个目标 App 的开关
2. 看文件：`cat /var/jb/usr/lib/IOSDecryptHub/config/enabledBundles.plist` → 应含该 bundle id
3. 打开 **设置 → IOSDecryptHub → 选择要注入的应用** → 同一个 App 的开关应是打开的
4. 反向操作一遍（在设置里关掉）→ 回 App 看开关是否跟着关（App 每次进入页面重新读文件）

> 这一步同时验证了"两处 UI 共用同一份名单"。任一处写不进去，就是权限问题：
> `ls -l /var/jb/usr/lib/IOSDecryptHub/config/` 应为 `mobile:mobile` 且目录 0755。

## 4. daemon 是否被 launchd 拉起

| 检查 | 命令 | 期望 |
|------|------|------|
| 启动配置在位 | `ls -l /var/jb/Library/LaunchDaemons/com.iosdecrypthub.updated.plist` | 存在（roothide 同样在 jbroot 根下） |
| 已被 launchd 认识 | `launchctl list \| grep -i iosdecrypthub` | 出现 `com.iosdecrypthub.updated` |
| 手动触发一次 | `launchctl kickstart -k system/com.iosdecrypthub.updated` | 无报错 |
| 状态文件被写 | `cat /var/jb/usr/lib/IOSDecryptHub/state.plist` | 含 `daemonHeartbeat`、`lastCheck`、`latestVersion` |
| 日志 | `tail -20 /var/log/iosdecrypthub-updated.log` | 有 `[IOSDecryptHubUpdated] 启动 / 检查更新: ...` |

> **roothide 是这一环的最大不确定项**：第三方 LaunchDaemon 能否被其 bootstrap 拉起
> 历史上不保证。若 `launchctl list` 里没有它，先试 `launchctl load` / 重启用户空间，
> 仍不行则记下来——fallback 是 roothide 包只提供 App（开关+状态），
> 更新继续走 Sileo 源升级，不阻塞发布。

## 5. 检查更新（网络链路）

App →「检查更新」：

- 若线上最新版就是当前版本 → 提示「已是最新」
- 若线上有更高版本 → 提示「发现新版本」，且 state.plist 的 `latestVersion` 等于线上 tag

> 这条走的是 `releases/latest` 的 302 探测（不吃 GitHub API 配额）。
> 日志里若出现 `检查更新失败: ...`，把整行原样记下来。

## 6. 安装 / 回滚（真机 OTA，最重要的一环）

前提：线上存在比设备当前版本更高的 release。

1. App 点「下载并安装」→ 确认
2. 观察 state.plist：`lastOp` 的 `result` 应为 `ok`，`version` 为新版本，`backupAvailable` 为 true，
   `backupVersion` 为安装前的版本；`restartedApps` 里应列出被结束进程的已启用 App
3. `ls -l` 引擎目录：`decrypt_helper.dylib` 时间戳已变、owner 为 `root:wheel`；
   `decrypt_helper.dylib.bak` 是安装前那一版
4. 重启目标 App，Web 面板（`:8088`）仍正常出事件 → 新引擎可用
5. App 点「回滚到 x.y.z」→ 引擎应换回备份版本，`lastOp.kind` 为 `rollback`、`result` 为 `ok`；
   且备份里换成刚滚下来的版本（swap，可再滚回去）

> **必须确认的失败路径**：把设备断网后点安装 → 应记为 error 且**引擎文件完全不动**。
> 这是"不许把引擎搞没"这条底线的真机证据。

## 7. 回报内容

- 上面每一节的结论（通过 / 不通过 + 原样错误信息）
- `cat` 出来的 state.plist 全文
- `tail -40 /var/log/iosdecrypthub-updated.log`
- 环境信息：越狱工具与版本、iOS 版本、设备型号
