# AGENTS.md — IOSDecryptHubJB

Always respond in Chinese-simplified

ElleKit 把 `IOSDecryptHubLoader.dylib` 装进 UIKit App 后：读 `enabledBundles.plist` → 允许则 `dlopen` `vendor` 里的 `decrypt_helper.dylib`。

不得加入 hook、inline hook、常驻型 daemon。

```bash
make deb
```

- ❌ `MSHookFunction` / `%hook`
- ❌ 常驻 daemon / `dh_server`
- ✅ updater daemon（一次性：launchd 按需拉起，跑完即退；只做更新检查/安装/回滚，不 hook、不常驻、不监听端口）
- ✅ 版本号：`Makefile` 的 `VERSION`
