#!/bin/bash
# updater_sim_test.sh — updater daemon 的 macOS 仿真回归测试
#
# 不需要真机：把 daemon 编成 macOS 二进制，按真机布局放进仿造的 bootstrap
# （<work>/home/usr/lib/IOSDecryptHub/），用真的 GitHub release 走完整链路：
#
#   T1 检查更新        T2 安装（备份+替换+版本元信息）  T3 已是最新则跳过
#   T4 回滚（swap）    T5 坏文件必须拒装且不半写        T6 无备份时拒绝回滚
#   T7 并发实例必须退出 T8 只结束已启用 App，未启用不动
#
# 需要: macOS + Xcode (xcrun) + 网络（读 decrypthub/IOSDecryptHub 的 latest release）
# 用法: ./tests/updater_sim_test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dhupd.XXXXXX")"
# 仿真 bootstrap：daemon 二进制就住在这里，dladdr 反推出来的路径才与真机一致
SIM_ROOT="${WORK}/home"
ENGINE_DIR="${SIM_ROOT}/usr/lib/IOSDecryptHub"
REQUEST="${WORK}/request.plist"
APPS_DIR="${WORK}/Applications"
OLD_ENGINE="${ROOT}/vendor/dylib/roothide/decrypt_helper.dylib"
CC="$(xcrun --find clang)"
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"

PASS=0
FAIL=0
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
ng(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
eq(){ if [ "$1" = "$2" ]; then ok "$3"; else ng "$3 (期望=$2 实得=$1)"; fi; }
neq(){ if [ "$1" != "$2" ]; then ok "$3"; else ng "$3 (不应等于 $2)"; fi; }
sha(){ shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }

# 文件不存在时 PlistBuddy 会往 stdout 打印 "File Doesn't Exist"，必须先挡掉
plist_get(){
    if [ ! -f "$1" ]; then echo ""; return; fi
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}
has_err(){ plist_get "$1" lastOp:error | grep -q "$2"; }
# PlistBuddy 对 <true/> 打 true，对 <integer>1</integer> 打 1 —— 断言一律归一化
plist_bool(){ local v; v=$(plist_get "$1" "$2"); case "${v}" in true|1) echo true ;; false|0) echo false ;; *) echo "${v}" ;; esac; }

cleanup(){
    [ -n "${VICTIM_PID:-}" ] && kill -9 "${VICTIM_PID}" 2>/dev/null
    [ -n "${CTRL_PID:-}" ] && kill -9 "${CTRL_PID}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

echo "[setup] 仿真 bootstrap: ${SIM_ROOT}"
mkdir -p "${ENGINE_DIR}/config" "${APPS_DIR}"

write_plist(){ # write_plist <path> <body>
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        "<plist version=\"1.0\">$2</plist>" > "$1"
}

# 常量定义在 src/dh_shared.h 里（请求路径在真机上是 /var/mobile/...，非 root 写不进去），
# 所以把头文件也一起改写到临时目录：main.m 与它同目录，#import "dh_shared.h" 会优先命中。
REQ_LITERAL='/var/mobile/Library/Preferences/com.iosdecrypthub.updater.request.plist'
RELEASE_LITERAL='https://github.com/decrypthub/IOSDecryptHub/releases/latest'
API_LITERAL='https://api.github.com/repos/decrypthub/IOSDecryptHub/releases/latest'
make_headers(){ # make_headers [额外 sed 表达式 ...]
    sed -e "s#${REQ_LITERAL}#${REQUEST}#" "${ROOT}/src/dh_shared.h" > "${WORK}/dh_shared.h"
    local EXTRA
    for EXTRA in "$@"; do
        sed -i '' -e "${EXTRA}" "${WORK}/dh_shared.h"
    done
    grep -q "${REQUEST}" "${WORK}/dh_shared.h" || { echo "头文件改写失败"; exit 2; }
}
make_headers

build_daemon(){
    local OUT="$1"; shift
    local SRC="${WORK}/main.m"
    cp "${ROOT}/daemon/main.m" "${SRC}"
    local EXTRA
    for EXTRA in "$@"; do
        sed -i '' -e "${EXTRA}" "${SRC}"
    done
    "${CC}" -arch "$(uname -m)" -isysroot "${MAC_SDK}" -mmacosx-version-min=12.0 \
        -ObjC -fobjc-arc -Wall -O1 -framework Foundation \
        "${SRC}" -o "${OUT}"
}

reset_env(){ # reset_env <version 或 ->：'-' 表示不装引擎（测无引擎场景）
    rm -rf "${ENGINE_DIR}/config" "${ENGINE_DIR}/version.plist" "${ENGINE_DIR}/state.plist" \
           "${ENGINE_DIR}/.updated.lock" "${ENGINE_DIR}/decrypt_helper.dylib" \
           "${ENGINE_DIR}/decrypt_helper.dylib.bak" "${ENGINE_DIR}/decrypt_helper.dylib.bak.plist" \
           "${ENGINE_DIR}/decrypt_helper.dylib.new"
    mkdir -p "${ENGINE_DIR}/config"
    [ "$1" = "-" ] || cp "${OLD_ENGINE}" "${ENGINE_DIR}/decrypt_helper.dylib"
    write_plist "${ENGINE_DIR}/config/enabledBundles.plist" '<dict><key>enabledBundles</key><array/></dict>'
    write_plist "${ENGINE_DIR}/version.plist" \
        "<dict><key>version</key><string>$1</string><key>variant</key><string>rootless</string><key>arch</key><string>arm64</string></dict>"
    write_plist "${REQUEST}" '<dict><key>action</key><string>none</string></dict>'
}

request(){ write_plist "${REQUEST}" "<dict><key>action</key><string>$1</string></dict>"; }
# 历史版本：请求可带 version
request_version(){ # request_version <action> <version>
    write_plist "${REQUEST}" "<dict><key>action</key><string>$1</string><key>version</key><string>$2</string></dict>"
}

echo "[build] 编译 macOS 版 daemon（按真机布局放进仿真 bootstrap）"
build_daemon "${ENGINE_DIR}/daemon" || { echo "daemon 编译失败"; exit 2; }
# T5: 最小体积阈值抬到 1TB，让真实 dylib 必然校验失败
build_daemon "${ENGINE_DIR}/daemon-strict" \
    's/#define DH_MIN_ENGINE_SIZE (1024 \* 1024)/#define DH_MIN_ENGINE_SIZE (1024ULL * 1024 * 1024 * 1024)/' \
    || { echo "strict 编译失败"; exit 2; }
# T8: 让可执行名映射扫我们造的 Applications 目录
build_daemon "${ENGINE_DIR}/daemon-kill" "s#@\"/Applications\"#@\"${APPS_DIR}\"#" \
    || { echo "kill 编译失败"; exit 2; }
DAEMON="${ENGINE_DIR}/daemon"
DAEMON_STRICT="${ENGINE_DIR}/daemon-strict"
DAEMON_KILL="${ENGINE_DIR}/daemon-kill"

echo "[fetch] 取线上 release 元信息（优先 gh api，兜底 curl）"
LATEST_JSON="${WORK}/api.json"
if command -v gh >/dev/null 2>&1 && \
   gh api repos/decrypthub/IOSDecryptHub/releases/latest > "${LATEST_JSON}" 2>/dev/null; then
    echo "  来源: gh api"
else
    curl -sf --max-time 30 \
        https://api.github.com/repos/decrypthub/IOSDecryptHub/releases/latest \
        -o "${LATEST_JSON}" || { echo "取 release 失败（需要网络或 gh 登录）"; exit 2; }
    echo "  来源: curl"
fi
LATEST_TAG=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "${LATEST_JSON}")
ASSET_URL=$(python3 -c 'import json,sys
r=json.load(open(sys.argv[1]))
print([a["browser_download_url"] for a in r["assets"]
       if a["name"].startswith("decrypt_helper") and a["name"].endswith(".dylib")][0])' "${LATEST_JSON}")
# daemon 主路径不查 API，靠发布命名约定拼地址——测试就替这个约定站岗
CONVENTION_URL="https://github.com/decrypthub/IOSDecryptHub/releases/download/${LATEST_TAG}/decrypt_helper-${LATEST_TAG#v}.dylib"
EXPECTED="${WORK}/expected.dylib"
curl -sfL --max-time 120 "${ASSET_URL}" -o "${EXPECTED}" || { echo "下载基准资产失败"; exit 2; }
echo "  线上最新 ${LATEST_TAG}  基准 sha=$(sha "${EXPECTED}" | cut -c1-12)"
OLD_SHA=$(sha "${OLD_ENGINE}")

echo
echo "--- T0 发布命名约定与 release 资产一致（daemon 主路径按约定拼地址）"
eq "${CONVENTION_URL}" "${ASSET_URL}" "约定地址 == release 实际资产地址"
# 约定成立的前提：引擎仓的 dist 目标产出的文件名就是 decrypt_helper-<version>.dylib
ENGINE_MAKEFILE="${ROOT}/../IOSDecryptHub/Makefile"
if [ -f "${ENGINE_MAKEFILE}" ]; then
    grep -q 'decrypt_helper-\$(VERSION).dylib' "${ENGINE_MAKEFILE}" \
        && ok "引擎仓发布产物命名与约定一致" || ng "引擎仓产物命名与约定不符"
else
    echo "  [SKIP] 引擎仓不在旁边，跳过产物命名检查"
fi

echo
echo "--- T1 检查更新（本地 1.0.0 vs 线上 ${LATEST_TAG}）"
reset_env 1.0.0
request check
"${DAEMON}"
eq "$(plist_get "${ENGINE_DIR}/state.plist" latestVersion)" "${LATEST_TAG}" "state 记下线上版本"
eq "$(plist_bool "${ENGINE_DIR}/state.plist" updateAvailable)" "true" "标记有可用更新"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "${OLD_SHA}" "检查不动引擎"

echo
echo "--- T2 安装（备份旧版 + 替换 + 更新版本元信息）"
request install
"${DAEMON}"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "$(sha "${EXPECTED}")" "引擎已换成线上版本"
neq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "${OLD_SHA}" "引擎确实变了"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib.bak")" "${OLD_SHA}" "备份是安装前那一版"
eq "$(plist_get "${ENGINE_DIR}/decrypt_helper.dylib.bak.plist" version)" "1.0.0" "备份带版本元信息"
eq "$(plist_get "${ENGINE_DIR}/version.plist" version)" "${LATEST_TAG#v}" "version.plist 已更新"
eq "$(plist_bool "${ENGINE_DIR}/state.plist" backupAvailable)" "true" "state 标记可回滚"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "ok" "上次安装结果 ok"
eq "$(plist_get "${REQUEST}" action)" "none" "请求已消费清零"
[ -f "${ENGINE_DIR}/decrypt_helper.dylib.new" ] && ng "临时文件应被清理" || ok "临时文件已清理"

echo
echo "--- T3 已是最新时再装一次：跳过，不折腾引擎"
INSTALLED_SHA=$(sha "${ENGINE_DIR}/decrypt_helper.dylib")
request install
"${DAEMON}"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "${INSTALLED_SHA}" "引擎未被改写"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "skipped" "结果为 skipped"
eq "$(plist_bool "${ENGINE_DIR}/state.plist" updateAvailable)" "false" "清除可更新标记"

echo
echo "--- T4 回滚（swap：滚回去，且还能再滚回来）"
request rollback
"${DAEMON}"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "${OLD_SHA}" "引擎回到 1.0.0"
eq "$(plist_get "${ENGINE_DIR}/version.plist" version)" "1.0.0" "version.plist 跟着回滚"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib.bak")" "${INSTALLED_SHA}" "备份换成刚滚下来的新版"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:kind)" "rollback" "上次动作是回滚"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "ok" "回滚结果 ok"

echo
echo "--- T5 坏文件必须拒装，且绝不能半写（阈值 1TB 模拟校验失败）"
BEFORE_SHA=$(sha "${ENGINE_DIR}/decrypt_helper.dylib")
BEFORE_BAK=$(sha "${ENGINE_DIR}/decrypt_helper.dylib.bak")
request install
"${DAEMON_STRICT}"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "${BEFORE_SHA}" "引擎保持原样"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib.bak")" "${BEFORE_BAK}" "备份未被破坏"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "error" "记为失败"
[ -f "${ENGINE_DIR}/decrypt_helper.dylib.new" ] && ng "坏文件应被丢弃" || ok "坏文件已丢弃"
has_err "${ENGINE_DIR}/state.plist" '校验失败' && ok "错误信息说明了原因" || ng "错误信息缺失"

echo
echo "--- T6 没有备份时拒绝回滚（不能把引擎搞没）"
reset_env 1.0.0
request rollback
"${DAEMON}"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "${OLD_SHA}" "引擎原样保留"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "error" "记为失败"
has_err "${ENGINE_DIR}/state.plist" '没有可回滚' && ok "错误信息说明了原因" || ng "错误信息缺失"

echo
echo "--- T6b 当前引擎缺失时拒绝安装（宁可不动）"
reset_env -
request install
"${DAEMON}"
[ -f "${ENGINE_DIR}/decrypt_helper.dylib" ] && ng "不该凭空装出引擎" || ok "引擎仍不存在"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "error" "记为失败"
has_err "${ENGINE_DIR}/state.plist" '不存在' && ok "错误信息说明了原因" || ng "错误信息缺失"

echo
echo "--- T7 并发实例必须退出（launchd 触发叠加时不许两个一起改引擎）"
reset_env 1.0.0
request check
export LOCK_PATH="${ENGINE_DIR}/.updated.lock"
python3 - <<'PY' &
import fcntl, os, time, sys
fd = os.open(os.environ["LOCK_PATH"], os.O_CREAT | os.O_RDWR, 0o644)
fcntl.flock(fd, fcntl.LOCK_EX)
sys.stdout.write("locked\n"); sys.stdout.flush()
time.sleep(8)
PY
LOCK_HOLDER=$!
sleep 1
"${DAEMON}"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastCheck)" "" "拿不到锁 = 什么都没做"
eq "$(plist_get "${REQUEST}" action)" "check" "请求保持未消费（留给下一轮）"
kill "${LOCK_HOLDER}" 2>/dev/null
wait "${LOCK_HOLDER}" 2>/dev/null

echo
echo "--- T8 安装后只结束已启用 App 的进程"
reset_env 1.0.0
mkdir -p "${APPS_DIR}/SimVictim.app" "${APPS_DIR}/SimBystander.app"
write_plist "${APPS_DIR}/SimVictim.app/Info.plist" \
    '<dict><key>CFBundleIdentifier</key><string>com.sim.victim</string><key>CFBundleExecutable</key><string>DHSimVictim</string></dict>'
write_plist "${APPS_DIR}/SimBystander.app/Info.plist" \
    '<dict><key>CFBundleIdentifier</key><string>com.sim.bystander</string><key>CFBundleExecutable</key><string>DHSimBystander</string></dict>'
write_plist "${ENGINE_DIR}/config/enabledBundles.plist" \
    '<dict><key>enabledBundles</key><array><string>com.sim.victim</string></array></dict>'

# 替身进程：macOS 上直接 cp /bin/sleep 会被 AMFI 拒（改名即签名失效），从源码编一个最省事
printf '#include <unistd.h>\nint main(void){sleep(300);return 0;}\n' > "${WORK}/victim.c"
# 注意 stdout/stderr 必须重定向走：否则后台子进程会一直握着命令替换的管道，
# $(start_proc ...) 要等替身进程自己退出（300 秒）才返回。
start_proc(){
    "${CC}" -O0 -isysroot "${MAC_SDK}" -mmacosx-version-min=12.0 "${WORK}/victim.c" -o "${WORK}/$1" || return 1
    "${WORK}/$1" >/dev/null 2>&1 &
    echo $!
}
VICTIM_PID=$(start_proc DHSimVictim)
CTRL_PID=$(start_proc DHSimBystander)
sleep 1
kill -0 "${VICTIM_PID}" 2>/dev/null && ok "已启用应用进程就绪" || ng "已启用应用进程没起来"
kill -0 "${CTRL_PID}" 2>/dev/null && ok "未启用应用进程就绪" || ng "未启用应用进程没起来"
request install
"${DAEMON_KILL}"
sleep 1
kill -0 "${VICTIM_PID}" 2>/dev/null && ng "已启用 App 的进程未被结束" || ok "已启用 App 的进程被结束"
kill -0 "${CTRL_PID}" 2>/dev/null && ok "未启用 App 的进程不受影响" || ng "未启用 App 被误杀"
plist_get "${ENGINE_DIR}/state.plist" lastOp:restartedApps | grep -q 'DHSimVictim' \
    && ok "state 记录了被重启的应用" || ng "state 未记录被重启的应用"
plist_get "${ENGINE_DIR}/state.plist" lastOp:restartedApps | grep -q 'DHSimBystander' \
    && ng "state 不该记录未启用的应用" || ok "state 未记录未启用的应用"
kill -9 "${VICTIM_PID}" 2>/dev/null; VICTIM_PID=""
kill -9 "${CTRL_PID}" 2>/dev/null; CTRL_PID=""

echo
echo "--- T9 重定向探测失败时退回 API（资产改名等场景的唯一兜路）"
reset_env 1.0.0
# 主路径指向一个必然连不上的地址（秒失败，不等超时）；API 指向本地 fixture
make_headers \
    "s#${RELEASE_LITERAL}#https://127.0.0.1:9/nope#" \
    "s#${API_LITERAL}#file://${LATEST_JSON}#"
if build_daemon "${ENGINE_DIR}/daemon-api"; then
    request install
    "${ENGINE_DIR}/daemon-api"
    eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "$(sha "${EXPECTED}")" "兜底路径也能装上（地址取自 API）"
    eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "ok" "兜底路径结果 ok"
    eq "$(plist_get "${ENGINE_DIR}/version.plist" version)" "${LATEST_TAG#v}" "兜底路径版本元信息正确"
else
    ng "兜底路径版 daemon 编译失败"
fi
make_headers  # 还原头文件

echo
echo "--- T10 安装指定版本（历史版本：从最新版降级到旧版）"
OLD_VER="1.24.8"
OLD_URL="https://github.com/decrypthub/IOSDecryptHub/releases/download/v${OLD_VER}/decrypt_helper-${OLD_VER}.dylib"
OLD_BASE="${WORK}/old.dylib"
reset_env "${LATEST_TAG#v}"        # 本地装作最新版，验证"降级"确实被允许
if curl -sfL --max-time 120 "${OLD_URL}" -o "${OLD_BASE}"; then
    request_version install "${OLD_VER}"
    "${DAEMON}"
    eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "$(sha "${OLD_BASE}")" "引擎已切到指定旧版"
    neq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "$(sha "${EXPECTED}")" "确实不是最新版了"
    eq "$(plist_get "${ENGINE_DIR}/version.plist" version)" "${OLD_VER}" "版本元信息 = 指定版本"
    eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:version)" "${OLD_VER}" "state 记录了指定版本"
    eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "ok" "结果 ok"
    eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib.bak")" "${OLD_SHA}"         "备份是切换前的最新版（可再切回来）"
else
    ng "无法下载 ${OLD_VER} 的基准 dylib（网络）"
fi

echo
echo "--- T11 重启指定 App（结束进程 + 尝试重新打开）"
reset_env "${LATEST_TAG#v}"
mkdir -p "${APPS_DIR}/SimVictim.app"
write_plist "${APPS_DIR}/SimVictim.app/Info.plist" \
    '<dict><key>CFBundleIdentifier</key><string>com.sim.victim</string><key>CFBundleExecutable</key><string>DHSimVictim</string></dict>'
write_plist "${ENGINE_DIR}/config/enabledBundles.plist" \
    '<dict><key>enabledBundles</key><array><string>com.sim.victim</string></array></dict>'
ENGINE_BEFORE=$(sha "${ENGINE_DIR}/decrypt_helper.dylib")

# 负例：App 没在运行时 → skipped
request_restart(){ write_plist "${REQUEST}" "<dict><key>action</key><string>restart</string><key>bundle</key><string>$1</string></dict>"; }
request_restart com.sim.victim
"${DAEMON_KILL}"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "skipped" "没在运行时记为 skipped"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:kind)" "restart" "记录的动作是 restart"

# 正例：进程在跑 → 结束它（macOS 上没有 uiopen，relaunched 应为 false）
VICTIM_PID=$(start_proc DHSimVictim)
sleep 1
kill -0 "${VICTIM_PID}" 2>/dev/null && ok "目标进程就绪" || ng "目标进程没起来"
request_restart com.sim.victim
"${DAEMON_KILL}"
sleep 0.5
kill -0 "${VICTIM_PID}" 2>/dev/null && ng "进程未被结束" || ok "进程已被结束"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "ok" "结果 ok"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:bundle)" "com.sim.victim" "记录了目标 bundle"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:relaunched)" "false" "无 uiopen 时如实记为未自动打开"
eq "$(sha "${ENGINE_DIR}/decrypt_helper.dylib")" "${ENGINE_BEFORE}" "重启不碰引擎"
kill -9 "${VICTIM_PID}" 2>/dev/null; VICTIM_PID=""

echo
echo "--- T12 停止指定 App（只结束，不重新打开）"
reset_env "${LATEST_TAG#v}"
mkdir -p "${APPS_DIR}/SimVictim.app"
write_plist "${APPS_DIR}/SimVictim.app/Info.plist" \
    '<dict><key>CFBundleIdentifier</key><string>com.sim.victim</string><key>CFBundleExecutable</key><string>DHSimVictim</string></dict>'
VICTIM_PID=$(start_proc DHSimVictim)
sleep 1
kill -0 "${VICTIM_PID}" 2>/dev/null && ok "目标进程就绪" || ng "目标进程没起来"
write_plist "${REQUEST}" "<dict><key>action</key><string>stop</string><key>bundle</key><string>com.sim.victim</string></dict>"
"${DAEMON_KILL}"
sleep 0.5
kill -0 "${VICTIM_PID}" 2>/dev/null && ng "进程未被结束" || ok "进程已被结束"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:kind)" "stop" "记录的动作是 stop"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:result)" "ok" "结果 ok"
eq "$(plist_get "${ENGINE_DIR}/state.plist" lastOp:relaunched)" "" "stop 不写 relaunched（没重开）"
kill -9 "${VICTIM_PID}" 2>/dev/null; VICTIM_PID=""

echo
printf 'updater 仿真结果: PASS=%d FAIL=%d\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
