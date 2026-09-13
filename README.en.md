# IOSDecryptHub

[中文](README.md) | **English**

Add the repo in Sileo / Zebra:

```
https://ios.decrypthub.com
```

Install the deb for your jailbreak (rootless or roothide). An **IOSDecryptHub** icon appears on the home screen (manager app), and **Settings → IOSDecryptHub** is added too — use either to toggle target apps. Force-quit a target app, then reopen it. Open `http://<device-ip>:8088` in a browser to use the live web panel:

<p align="center">
  <img src="./docs/screenshots/webui.png" alt="IOSDecryptHub web panel: crypto event list with UTF-8 / HEX / HEXDUMP detail" width="920">
</p>

No app is injected by default. Depends on ellekit and preferenceloader.

## What's inside

| Component | Role |
|-----------|------|
| Injection loader | Reads the enabled list, `dlopen`s the engine only on a hit; contains no hooks |
| Engine dylib | The closed-source core; every hook lives in its constructor |
| Manager app | Home-screen icon: toggle apps, see engine version and update state, update / roll back |
| Updater daemon | One-shot process (launched on demand by launchd) that checks, downloads, installs and rolls back the engine |

## How updates work

Tap "Check for updates" in the manager app; it writes a request and launchd runs the daemon:

1. Resolve the latest version (reads the 302 of GitHub `releases/latest` first — no API quota; the API is only a fallback)
2. Download the engine, verify size and Mach-O architecture (arm64 family only); anything else is discarded
3. **Back up first** — a failed replace is restored from the backup, and no replace happens without a successful backup
4. After the atomic swap, running target apps are terminated, so the next launch uses the new engine
5. Rollback is a swap: it rolls back, keeps the version it just rolled off, and can roll again

No reinstall and no respring needed.

Build debs (macOS + Xcode + dpkg + ldid):

```bash
make deb
```

Simulated regression test for the update path (runs on macOS, no device needed, needs network):

```bash
make test-updater
```

## Follow

Search **DecryptHub** in WeChat, or scan the QR below.

<p align="center">
  <img src="./wechat-qr.png" alt="WeChat Official Account DecryptHub" width="168">
</p>

- Telegram: https://t.me/decrypthubteam
- X: https://x.com/decrypthub_
