# 真机验证清单（管理器 App + updater daemon）

这两个组件有几件事无法在 Mac 上仿真验证，必须真机走一遍再对外发布。
下面按依赖顺序排列：前面不通过就不要往下测。

前置：装对应环境的 deb（rootless 或 roothide），准备好 SSH（或 Filza）看文件。

> 已知坑（都已修，但排查时先想到它们）：
> - 新装的 tweak 要 **respring** 之后 ElleKit 才会加载；只装包不 respring 会以为"注入坏了"
> - 用 scp 推文件进设备会带上本地权限（本仓在 SMB 卷上全是 700），`mobile` 读不了自己的
>   bundle，uicache 不注册、App 点不开 —— 推送后必须显式 chmod
> - 设备侧没有 curl / find / sysctl / awk / plutil（rootless 的 /usr/bin 是 procursus），
>   脚本不要依赖它们，结构化断言一律走 MCP

## 1. 包与 App 能否起来

| 检查 | 命令 / 观察点 | 期望 |
|------|----------------|------|
| 包已装 | `dpkg -l com.iosdecrypthub` | 版本与包一致 |
| App 文件在 | `ls /var/jb/Applications/IOSDecryptHubManager.app` | 存在（roothide 去掉 `/var/jb`） |
| 无残留面板 | `ls /var/jb/Library/PreferenceBundles/ \| grep -i decrypt` | 无输出（设置面板已移除） |
| 桌面图标 | 主屏出现「IOSDecryptHub」 | 出现；没出现就 `uicache -p <上面那个路径>` |
| 能启动 | 点开 App | 不闪退，看到应用列表与右上角齿轮 |

> App 的沙盒权限必须包含 `no-sandbox` / `no-container`（对齐 Sileo）：只签
> `platform-application` 时会表现为**检查更新/历史版本没网**、读不到更新状态。

## 2. 界面读数

- 主界面就是应用列表：搜索框在顶部、右上角齿轮进设置
- 顶部「全部 / 已启用」可切换；每行图标 + 名称 + 开关
- **设置 → 关于 → 版本** 应等于包版本（全 App 只有这一处版本号）

## 3. 开关能否写进名单（App → loader）

1. 在 App 里打开某个目标 App 的开关
2. `cat /var/jb/usr/lib/IOSDecryptHub/config/enabledBundles.plist` → 应含该 bundle id
3. 关掉开关 → 文件里应随之消失

> 写不进去就是权限问题：`ls -l /var/jb/usr/lib/IOSDecryptHub/config/` 应为
> `mobile:mobile` 且目录 0755。

## 4. daemon 是否被 launchd 拉起

| 检查 | 命令 | 期望 |
|------|------|------|
| 启动配置在位 | `ls -l /var/jb/Library/LaunchDaemons/com.iosdecrypthub.updated.plist` | 存在（roothide 同样在 jbroot 根下） |
| 已被 launchd 认识 | `launchctl list \| grep -i iosdecrypthub` | 出现 `com.iosdecrypthub.updated`，退出码 0 |
| 状态文件被写 | `cat /var/jb/usr/lib/IOSDecryptHub/state.plist` | 含 `daemonHeartbeat`、`lastCheck` |
| **日志可读** | `cat /var/log/iosdecrypthub-updated.log` | 有 `启动 / 结束`（daemon 同时写 stderr，这个文件必须有内容） |

> **roothide 是这一环的历史风险点**：第三方 LaunchDaemon 能否被其 bootstrap 拉起。
> 已实测可拉起；若某环境不行，记下结论，roothide 走「App 版 + Sileo 源升级」的降级路线。

## 5. 检查更新与历史版本（网络链路）

- 设置 →「检查更新」：应给出「已是最新」或「发现新版本」
- 设置 →「历史版本」：应列出线上各版本（带日期，当前版本打勾）
- 两条都走网络。失败时界面会显示带错误码的原因，原样记录下来

## 6. 安装指定版本 / 回滚（真机 OTA）

前提：线上存在与设备不同的版本。

1. 设置 →「历史版本」→ 选一个不同版本 → 安装
2. 观察：`state.plist` 的 `lastOp` 应为 `ok` 且 `version` 是所选版本；
   `backupAvailable` 为 true、`backupVersion` 是切换前的版本
3. 日志应有 `安装引擎 x.y.z 完成，重启 N 个应用`
4. `ls -l` 引擎目录：`decrypt_helper.dylib` owner `root:wheel`、权限 0755，
   `decrypt_helper.dylib.bak` 是切换前那一版
5. **断网后点安装** → 应记为失败且**引擎文件完全不动**（这是"不许把引擎搞没"的底线证据）

## 7. 重启指定 App（越狱环境下替用户完成"退出再打开"）

1. 在 App 的「已启用」列表里左滑某一行 → 出现「重启」
2. 点击后观察：
   - 目标 App 的进程被结束（`ps -A | grep <可执行名>` 数量归零）
   - 设备上若装了 uiopen（uikittools），应被自动重新打开；`state.plist` 的
     `lastOp.relaunched` 为 true
   - 日志有 `重启 <bundle>：结束 N 个进程，relaunched=1`
3. 目标 App 本就没在运行时：`lastOp.result` 应为 `skipped` 且带原因（不该假装成功）

> 没有 uiopen 的环境只结束进程，App 会提示"请手动打开" —— 如实告知，不要静默。

## 8. 注入链路（越狱加载器 → 引擎）

1. 启用一个目标 App 并**完全退出**它
2. 重新打开 → 浏览器访问 `http://<设备IP>:8088` 应能看到面板
3. 悬浮窗应出现，且**不含任何引流内容**（公众号入口在 Web 面板里，不在悬浮窗）

> **注意**：新装 tweak 后必须先 respring，否则 ElleKit 不会加载它。

## 9. 回报内容

- 上面每一节的结论（通过 / 不通过 + 原样错误信息）
- `cat` 出来的 state.plist 全文、`tail -40 /var/log/iosdecrypthub-updated.log`
- 环境信息：越狱工具与版本、iOS 版本、设备型号
