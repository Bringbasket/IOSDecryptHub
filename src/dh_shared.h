// dh_shared.h — 管理器 App 与 updater daemon 的共享约定
//
// 单一事实源（两边只认这些路径与键，不各自发明）：
//   名单: <bootstrap>/usr/lib/IOSDecryptHub/config/enabledBundles.plist  (mobile 可写)
//   引擎: <bootstrap>/usr/lib/IOSDecryptHub/decrypt_helper.dylib         (root 专属，daemon 写)
//   元信息: <bootstrap>/usr/lib/IOSDecryptHub/version.plist              {version, variant, arch}
//   状态: <bootstrap>/usr/lib/IOSDecryptHub/state.plist                  (daemon 写 0644，App 只读)
//   请求: /var/mobile/Library/Preferences/com.iosdecrypthub.updater.request.plist
//         (mobile 可写，daemon 读；launchd 用 WatchPaths 监听它；内容不可信，
//          daemon 只取 action 与可选的 version —— 下载地址一律自己按发布命名约定
//          推导，绝不采用请求里的地址)
//         action: check / install / rollback / none
//         version: 可选，指定要安装的版本（历史版本），如 "1.25.1"

#define DH_DOMAIN_LOADER  @"com.iosdecrypthub.loader"
#define DH_KEY_BUNDLES    @"enabledBundles"

#define DH_CONFIG_REL     @"IOSDecryptHub/config/enabledBundles.plist"
#define DH_ENGINE_NAME    @"decrypt_helper.dylib"
#define DH_ENGINE_BAK     @"decrypt_helper.dylib.bak"
#define DH_ENGINE_NEW     @"decrypt_helper.dylib.new"
#define DH_BAK_META       @"decrypt_helper.dylib.bak.plist"
#define DH_VERSION_FILE   @"version.plist"
#define DH_STATE_FILE     @"state.plist"

#define DH_REQUEST_PATH   @"/var/mobile/Library/Preferences/com.iosdecrypthub.updater.request.plist"
#define DH_NOTIFY_STATE   @"com.iosdecrypthub.updater.state"

// 更新来源：先走 releases/latest 的 302 拿 tag（不耗 GitHub API 配额，共享出口/VPN
// 用户不会莫名被 403 掐掉），资产地址按发布流程的命名约定拼；命名变化时由 API 兜底。
#define DH_RELEASE_LATEST @"https://github.com/decrypthub/IOSDecryptHub/releases/latest"
#define DH_ASSET_FMT      @"https://github.com/decrypthub/IOSDecryptHub/releases/download/%@/decrypt_helper-%@.dylib"
// 兜底：API 能拿到资产列表，容忍引擎改名
#define DH_GITHUB_LATEST  @"https://api.github.com/repos/decrypthub/IOSDecryptHub/releases/latest"

#define DH_REQ_CHECK      @"check"
#define DH_REQ_INSTALL    @"install"
#define DH_REQ_ROLLBACK   @"rollback"
#define DH_REQ_NONE       @"none"
