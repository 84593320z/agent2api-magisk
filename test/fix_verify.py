#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修复复测：对 E:/AI/tmp/a2a-build30 的 19 项修复逐条跑功能验证。

每个用例在独立沙箱里 source 模块真实函数（不 mock 被测逻辑本身），
只替换 Android 专有依赖（dumpsys / ip / curl 端点 / 子进程存活）。
结果写入 fix_verify.json。
"""
import io
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

_HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.environ.get("A2A_MODULE") or os.path.join(os.path.dirname(_HERE), "module")
ROOT = os.environ.get("A2A_WORK") or _HERE
MOD = MOD.replace("\\", "/")
ROOT = ROOT.replace("\\", "/")
SB = ROOT + "/fixverify"          # Python 侧写文件用（正斜杠）
def _posix(p):                     # msys 的 sh 不认 "E:/..." 这种盘符路径
    return "/" + p[0].lower() + p[2:]
SBX = _posix(SB)
MODX = _posix(MOD)
_BIN = os.environ.get("A2A_SH_BIN") or r"C:\Users\Y-H\.dsh\profiles\desktop\node_modules\@dsh-ops\bash-win32-x64\usr\bin"
SH = os.path.join(_BIN, "sh.exe")
AWK = os.path.join(_BIN, "awk.exe")
CURL = os.environ.get("A2A_CURL") or "/ucrt64/bin/curl"
RESULTS = {}


# ---------------------------------------------------------------- helpers
def w(rel, text, mode=None):
    p = os.path.join(SB, rel)
    d = os.path.dirname(p)
    if d:
        os.makedirs(d, exist_ok=True)
    with io.open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    if mode:
        os.chmod(p, mode)
    return p


PREAMBLE = '''#!/bin/sh
# 沙箱：把模块的硬编码 Android 路径整体重定向到 $SB
MOD="{modx}"
SB="{sbx}"
# 不开 set -u：模块自己在 Magisk/busybox 下没有 nounset，测环境要一致
. "$MOD/libexec/common.sh"
APP_HOME="$SB/app"; PAYLOAD="$APP_HOME/payload"; PLIB="$PAYLOAD/lib"; BINDIR="$APP_HOME/bin"
CFGDIR="$APP_HOME/etc"; DATADIR="$APP_HOME/data"; LOGDIR="$APP_HOME/logs"; RUNDIR="$APP_HOME/run"
TMPD="$APP_HOME/tmp"; HOMEDIR="$APP_HOME/home"; BACKUPDIR="$APP_HOME/backup"; DLDIR="$APP_HOME/download"
SETTINGS="$CFGDIR/settings.conf"; SUPLOG="$LOGDIR/supervisor.log"; SRVLOG="$LOGDIR/server.log"
APPLOG="$LOGDIR/app.log"; UPDLOG="$LOGDIR/update.log"; INSTLOG="$LOGDIR/install.log"
CURL="$BINDIR/curl"; CACERT="$BINDIR/cacert.pem"
SERVER_BIN="$PAYLOAD/agent2api-server"; LOADER="$PLIB/ld-linux-aarch64.so.1"
A2A_LIVE="$SB/live"; DNSFILE="$A2A_LIVE/resolv"; GAIFILE="$A2A_LIVE/gai"
NSSFILE="$A2A_LIVE/nsswitch"; LDSO_LINK="$A2A_LIVE/ld.so"; DNS_CACHE="$RUNDIR/resolv.last"
mkdir -p "$CFGDIR" "$LOGDIR" "$RUNDIR" "$TMPD" "$A2A_LIVE" "$BINDIR" "$PLIB" "$DATADIR" "$HOMEDIR" "$BACKUPDIR" "$DLDIR"
: >"$SUPLOG" 2>/dev/null
PATH="$SB/fakebin:$PATH"
'''

PROBE = '''#!/bin/sh
# 独立进程探针：真实调用 update_lock_acquire，打印身份与结果
MOD="{modx}"
SB="{sbx}"
. "$MOD/libexec/common.sh"
APP_HOME="$SB/app"; PAYLOAD="$APP_HOME/payload"; PLIB="$PAYLOAD/lib"; BINDIR="$APP_HOME/bin"
CFGDIR="$APP_HOME/etc"; DATADIR="$APP_HOME/data"; LOGDIR="$APP_HOME/logs"; RUNDIR="$APP_HOME/run"
TMPD="$APP_HOME/tmp"; HOMEDIR="$APP_HOME/home"; BACKUPDIR="$APP_HOME/backup"; DLDIR="$APP_HOME/download"
SETTINGS="$CFGDIR/settings.conf"; SUPLOG="$LOGDIR/supervisor.log"; SRVLOG="$LOGDIR/server.log"
APPLOG="$LOGDIR/app.log"; UPDLOG="$LOGDIR/update.log"; INSTLOG="$LOGDIR/install.log"
CURL="$BINDIR/curl"; CACERT="$BINDIR/cacert.pem"
SERVER_BIN="$PAYLOAD/agent2api-server"; LOADER="$PLIB/ld-linux-aarch64.so.1"
A2A_LIVE="$SB/live"; DNSFILE="$A2A_LIVE/resolv"; GAIFILE="$A2A_LIVE/gai"
NSSFILE="$A2A_LIVE/nsswitch"; LDSO_LINK="$A2A_LIVE/ld.so"; DNS_CACHE="$RUNDIR/resolv.last"
mkdir -p "$LOGDIR" "$RUNDIR" "$CFGDIR" "$TMPD"
. "$MOD/libexec/payload.sh"
if [ "${{1:-}}" = "deadpid" ]; then
  # 模拟 $$ 指向已经消失的父进程：身份探测必然失败
  proc_start_ticks() {{ return 1; }}
fi
echo "PROBE_PID=$$"
echo "PROBE_TICKS=$(proc_start_ticks $$ 2>/dev/null)"
update_lock_acquire "$RUNDIR/probe.lock.d" 2 >"$RUNDIR/probe.msg" 2>&1
echo "PROBE_RC=$?"
echo "PROBE_MSG=$(tr '
' '|' <"$RUNDIR/probe.msg" 2>/dev/null)"
'''


def run(name, body, timeout=90):
    script = w(os.path.join("cases", name + ".sh"),
               PREAMBLE.format(modx=MODX, sbx=SBX) + body)
    try:
        p = subprocess.run([SH, script], capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        RESULTS[name] = {"timeout": True, "kv": {}}
        return RESULTS[name]
    out = p.stdout.decode("utf-8", "replace")
    err = p.stderr.decode("utf-8", "replace")
    kv = {}
    for line in out.splitlines():
        if "=" in line and not line.startswith(" "):
            k, _, v = line.partition("=")
            kv[k.strip()] = v.strip()
    RESULTS[name] = {"rc": p.returncode, "kv": kv,
                     "stdout": out[-4000:], "stderr": err[-2000:]}
    return RESULTS[name]


def build_elf(path, interp=None, slot=None):
    data = bytearray(4096)
    data[0:4] = b"\x7fELF"
    data[4] = 2          # ELFCLASS64
    data[5] = 1          # little endian
    data[6] = 1
    struct.pack_into("<H", data, 16, 3)      # ET_DYN
    struct.pack_into("<H", data, 18, 0xB7)   # EM_AARCH64
    struct.pack_into("<I", data, 20, 1)
    struct.pack_into("<Q", data, 32, 64)     # e_phoff
    struct.pack_into("<H", data, 52, 64)     # e_ehsize
    struct.pack_into("<H", data, 54, 56)     # e_phentsize
    struct.pack_into("<H", data, 56, 2 if interp else 1)
    struct.pack_into("<I", data, 64, 1)      # PT_LOAD
    blob = bytearray(data)
    if interp:
        istr = interp.encode() + b"\0"
        off = 64 + 2 * 56
        blob[off:off + len(istr)] = istr
        base = 64 + 56
        struct.pack_into("<I", blob, base, 3)             # PT_INTERP
        struct.pack_into("<Q", blob, base + 8, off)       # p_offset
        size = len(istr) if not slot else max(len(istr), slot)
        struct.pack_into("<Q", blob, base + 32, size)     # p_filesz
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with io.open(path, "wb") as f:
        f.write(bytes(blob))


def mkpayload(dirpath, ver, built, static=True, with_lib=True):
    os.makedirs(os.path.join(dirpath, "ui"), exist_ok=True)
    build_elf(os.path.join(dirpath, "agent2api-server"),
              None if static else "/lib/ld-linux-aarch64.so.1")
    with io.open(os.path.join(dirpath, "VERSION"), "w", encoding="utf-8") as f:
        f.write("ver=%s\nbuilt=%s\nsource=test\narch=arm64\n" % (ver, built))
    with io.open(os.path.join(dirpath, "ui", "index.html"), "w", encoding="utf-8") as f:
        f.write("<html>ok</html>\n")
    if with_lib:
        os.makedirs(os.path.join(dirpath, "lib"), exist_ok=True)
        ld = os.path.join(dirpath, "lib", "ld-linux-aarch64.so.1")
        with io.open(ld, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\nexit 0\n")
        os.chmod(ld, 0o755)
        with io.open(os.path.join(dirpath, "lib", "libc.so.6"), "w", encoding="utf-8") as f:
            f.write("fake libc\n")


# ---------------------------------------------------------------- http fixture
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        code = 500 if "500" in self.path else (204 if "204" in self.path else 200)
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *a):
        pass


def start_http():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    srv = HTTPServer(("127.0.0.1", port), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return port


# ---------------------------------------------------------------- setup
def setup():
    if os.path.isdir(SB):
        shutil.rmtree(SB)
    os.makedirs(os.path.join(SB, "fakebin"), exist_ok=True)
    w("fakebin/ip", """#!/bin/sh
case "$*" in
  "-6 route show table all default") echo "default via fe80::1 dev wlan0 metric 1024 pref medium" ;;
  *) exit 0 ;;
esac
exit 0
""", 0o755)
    w("fakebin/unzip", """#!/bin/sh
echo "UNZIP_ARGS:$*"
exit 0
""", 0o755)
    w("probe.sh", PROBE.format(modx=MODX, sbx=SBX), 0o755)
    mkpayload(os.path.join(SB, "pay_static"), "9.9.9", "2026-11-03T00:00:00Z", static=True)
    mkpayload(os.path.join(SB, "pay_dyn"), "9.9.8", "2026-11-03T00:00:00Z", static=False)
    mkpayload(os.path.join(SB, "pay_dyn_nolib"), "9.9.7", "2026-11-03T00:00:00Z",
              static=False, with_lib=False)
    # 解释器夹具：glibc 那个槽放宽到 80 字节，才放得下沙箱里更长的 ld.so 路径
    build_elf(os.path.join(SB, "elf_apex"), "/apex/com.android.runtime/bin/linker64")
    build_elf(os.path.join(SB, "elf_glibc"), "/lib/ld-linux-aarch64.so.1", slot=80)
    # 只有 busybox 的 PATH 目录：验证 update-binary 的 busybox 分支
    os.makedirs(os.path.join(SB, "fakebin_bb"), exist_ok=True)
    w("fakebin_bb/busybox",
      '#!/bin/sh\nif [ "$1" = "unzip" ]; then shift; echo "BUSYBOX_UNZIP_ARGS:$*";'
      ' else echo "BB:$*"; fi\n', 0o755)


PORT = None


# ---------------------------------------------------------------- cases
def t01_startup_pid():
    body = r'''
# ---- 静态：加锁路径不再活在"父进程已经退出的括号子 shell"里
grep -q 'setsid sh "$MODDIR/libexec/boot-start.sh"' "$MOD/service.sh" && echo "STATIC_SETSID=1" || echo "STATIC_SETSID=0"
grep -q '^) >>"$LOGDIR/boot.log" 2>&1 &' "$MOD/service.sh" && echo "STATIC_OLD_BLOCK=1" || echo "STATIC_OLD_BLOCK=0"
[ -f "$MOD/libexec/boot-start.sh" ] && echo "BOOTSTART=1" || echo "BOOTSTART=0"
grep -q 'svc_start' "$MOD/libexec/boot-start.sh" && echo "BOOTSTART_SVC=1" || echo "BOOTSTART_SVC=0"

# ---- 功能 A：独立进程（boot-start.sh 就是这么被拉起的）能拿到锁
rm -f "$SB/new.out"
rm -rf "$RUNDIR/probe.lock.d"
# 沙箱没有 setsid，用普通后台进程模拟 boot-start.sh：父进程立刻退出，子进程自持 $$。
sh -c 'sh "'"$SB"'/probe.sh" >"'"$SB"'/new.out" 2>&1 </dev/null & exit 0'
sleep 3
echo "NEW_RC=$(sed -n 's/^PROBE_RC=//p' "$SB/new.out" | head -1)"
_nt=$(sed -n 's/^PROBE_TICKS=//p' "$SB/new.out" | head -1)
[ -n "$_nt" ] && echo "NEW_TICKS_SET=1" || echo "NEW_TICKS_SET=0"

# ---- 功能 B：身份确认不了时必须拒绝加锁（fail-closed 语义仍然保留）
rm -rf "$RUNDIR/probe.lock.d"
sh "$SB/probe.sh" deadpid >"$SB/dead.out" 2>&1
echo "DEAD_RC=$(sed -n 's/^PROBE_RC=//p' "$SB/dead.out" | head -1)"
grep -q '无法确认当前进程身份' "$SB/dead.out" && echo "DEAD_REASON=1" || echo "DEAD_REASON=0"
echo "DEAD_MSG=$(sed -n 's/^PROBE_MSG=//p' "$SB/dead.out" | head -1)"
'''
    return run("t01_startup_pid", body)


def t02_rollback_keeps_old():
    body = r'''
mkp() { # $1=目录 $2=版本
  rm -rf "$1"
  mkdir -p "$1/ui" "$1/lib"
  cp "$SB/pay_static/agent2api-server" "$1/agent2api-server"
  printf 'ver=%s\nbuilt=b1\nsource=t\narch=arm64\n' "$2" >"$1/VERSION"
  printf '<html>ok</html>\n' >"$1/ui/index.html"
  printf '#!/bin/sh\nexit 0\n' >"$1/lib/ld-linux-aarch64.so.1"; chmod 755 "$1/lib/ld-linux-aarch64.so.1"
  : >"$1/lib/libc.so.6"
}
. "$MOD/libexec/payload.sh"
mkp "$PAYLOAD" 1.0.0
mkp "$SB/stage2" 2.0.0
rm -f "$RUNDIR/update.pending" "$RUNDIR/update.active"

upd_payload_before_move() { printf 'HOOK_BEFORE=%s\n' "$1" >>"$SB/hooks.log"; }
upd_payload_after_move() { printf 'HOOK_AFTER=%s\n' "$1" >>"$SB/hooks.log"; }
upd_payload_commit() { printf 'HOOK_COMMIT=%s\n' "$1" >>"$SB/hooks.log"; }

payload_activate_staged "$SB/stage2" new >"$SB/act.log" 2>&1
echo "ACT_RC=$?"
echo "NOW_VER=$(payload_version)"
_ls=$(ls -d "$APP_HOME"/payload.new.old.* 2>/dev/null | head -1)
[ -n "$_ls" ] && echo "OLD_KEPT=1" || echo "OLD_KEPT=0"
echo "OLD_VER=$(sed -n 's/^ver=//p' "$_ls/VERSION" 2>/dev/null | head -1)"
[ -s "$RUNDIR/update.pending" ] && echo "PENDING=1" || echo "PENDING=0"
echo "PENDING_MATCH=$([ "$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null)" = "$_ls" ] && echo 1 || echo 0)"

# 场景 A：健康通过 → 提交，删掉事务旧载荷
payload_commit_old; echo "COMMIT_RC=$?"
[ -n "$(ls -d "$APP_HOME"/payload.new.old.* 2>/dev/null)" ] && echo "OLD_AFTER_COMMIT=0" || echo "OLD_AFTER_COMMIT=1"
[ -s "$RUNDIR/update.pending" ] && echo "PENDING_AFTER=0" || echo "PENDING_AFTER=1"

# 场景 B：当前载荷不完整 → 拒绝提交，保留旧版本
mkdir -p "$APP_HOME/payload.new.old.777"
printf 'new 777 %s\n' "$APP_HOME/payload.new.old.777" >"$RUNDIR/update.pending"
mv "$PAYLOAD/agent2api-server" "$SB/saved_server" 2>/dev/null
payload_commit_old; echo "COMMIT_BAD_RC=$?"
[ -d "$APP_HOME/payload.new.old.777" ] && echo "BAD_KEPT=1" || echo "BAD_KEPT=0"
mv "$SB/saved_server" "$PAYLOAD/agent2api-server" 2>/dev/null

# 场景 C：marker 指向越界路径 → 不删任何东西
printf 'new 777 /etc\n' >"$RUNDIR/update.pending"
payload_commit_old; echo "COMMIT_EVIL_RC=$?"
[ -s "$RUNDIR/update.pending" ] && echo "EVIL_MARKER_CLEARED=0" || echo "EVIL_MARKER_CLEARED=1"
echo "ACTLOG=[$(cat "$SB/act.log")]"
'''
    return run("t02_rollback_keeps_old", body)


def t03_interp_whitelist():
    body = r'''
. "$MOD/libexec/plugin.sh"
: >"$LDSO_LINK"; chmod 755 "$LDSO_LINK"
cp "$SB/elf_apex" "$SB/w1"; chmod 755 "$SB/w1"
_r1=$(interp_fix "$SB/w1" 2>/dev/null); echo "APEX_RES=$_r1"
cmp -s "$SB/elf_apex" "$SB/w1" && echo "APEX_UNCHANGED=1" || echo "APEX_UNCHANGED=0"
cp "$SB/elf_glibc" "$SB/w2"; chmod 755 "$SB/w2"
_r2=$(interp_fix "$SB/w2" 2>/dev/null); echo "GLIBC_RES=$_r2"
echo "GLIBC_INTERP=$(interp_string "$SB/w2")"
echo "WANT=$LDSO_LINK"
'''
    return run("t03_interp_whitelist", body)


def t04_reaping_stale():
    body = r'''
. "$MOD/libexec/payload.sh"
mkdir -p "$RUNDIR/rl1.d"
printf '999999.100.1700000000.1\n' >"$RUNDIR/rl1.d/owner"
printf '999999.100.1700000000.1\n' >"$RUNDIR/rl1.d/reaping"
update_lock_acquire "$RUNDIR/rl1.d" 4 >/dev/null 2>&1
echo "STALE_RC=$?"
echo "STALE_TOKEN_SET=$([ -n "${UPDATE_LOCK_TOKEN:-}" ] && echo 1 || echo 0)"
update_lock_release "$RUNDIR/rl1.d" >/dev/null 2>&1

# 活着的 reaping 持有者 → 仍然礼让，不抢锁
mkdir -p "$RUNDIR/rl2.d"
printf '999999.100.1700000000.1\n' >"$RUNDIR/rl2.d/owner"
_t=$(proc_start_ticks $$)
printf '%s.%s.1700000000.1\n' "$$" "$_t" >"$RUNDIR/rl2.d/reaping"
update_lock_acquire "$RUNDIR/rl2.d" 0 >/dev/null 2>&1
echo "LIVE_RC=$?"
'''
    return run("t04_reaping_stale", body, timeout=90)


def t05_fastcrash_backoff():
    body = r'''
# 静态：拉起成功分支不许清零 FAILS；清零必须挂 120s 稳定门槛
awk '/if start_child; then/,/^  fi$/' "$MOD/libexec/supervise.sh" | grep -q 'FAILS=0'   && echo "STATIC_START_RESET=1" || echo "STATIC_START_RESET=0"
grep -q 'CHILD_START:-_now})) -ge 120' "$MOD/libexec/supervise.sh" && echo "STATIC_GATE120=1" || echo "STATIC_GATE120=0"
grep -q 'FAILS" -ge 6' "$MOD/libexec/supervise.sh" && echo "STATIC_T6=1" || echo "STATIC_T6=0"
grep -q 'FAILS" -ge 3' "$MOD/libexec/supervise.sh" && echo "STATIC_T3=1" || echo "STATIC_T3=0"

# 动态：把"崩溃记账 + 熔断阈值"整段抽出来，用桩驱动 8 轮快速崩溃
sed -n '/# 5) 子进程已死/,/# 8) 端口被别人占了/p' "$MOD/libexec/supervise.sh" >"$SB/crash.sh"
echo "BLOCK_LINES=$(wc -l <"$SB/crash.sh" | tr -d ' ')"
FAILS=0; GIVEUP=0; CHILD=999999; CHILD_TICKS=0; RUNDIR="$SB/app/run"
log_to() { :; }; svc_kill_stray() { :; }; cfg_get() { echo 1; }
write_state() { echo "STATE=$1" >>"$SB/states.log"; }; sleep() { :; }; release_wake() { :; }
now_epoch() { echo 1700000000; }; wait() { :; }; rm() { :; }
export CHILD_TICKS RUNDIR FAILS GIVEUP
FAILS=0; GIVEUP=0
i=0
while [ "$i" -lt 8 ] && [ "$GIVEUP" = "0" ]; do
  i=$((i + 1))
  CHILD=999999
  CHILD_START=$((1700000000 - 5))     # 只活 5 秒 → 快速崩溃
  . "$SB/crash.sh"
done
echo "ROUNDS=$i"
echo "FAILS=$FAILS"
echo "GIVEUP=$GIVEUP"
'''
    return run("t05_fastcrash_backoff", body, timeout=90)


def t06_cfg_set_backslash():
    body = r'''
: >"$SETTINGS"
cfg_set gateway_key 'abc\nallow_no_key=1'
echo "SET_RC=$?"
echo "LINES=$(grep -c '^gateway_key=' "$SETTINGS")"
grep -q '^allow_no_key=1$' "$SETTINGS" && echo "INJECTED=1" || echo "INJECTED=0"
echo "GET=$(cfg_get gateway_key)"
echo "ALLOW=$(cfg_get allow_no_key NONE)"
echo "RAWLINES=$(wc -l <"$SETTINGS" | tr -d ' ')"
'''
    return run("t06_cfg_set_backslash", body)


def t07_trap_preserved():
    body = r'''
export MODDIR="$MOD"
. "$MOD/libexec/control.sh"
update_lock_acquire() { return 0; }
update_lock_release() { return 0; }
svc_start_impl() { return 0; }
svc_stop_impl() { return 0; }
trap 'echo OUTER_TERM_FIRED; exit 7' TERM
svc_start >/dev/null 2>&1
svc_stop >/dev/null 2>&1
echo "AFTER_CALLS=1"
kill -TERM $$
sleep 2
echo "CONTINUED=1"
'''
    return run("t07_trap_preserved", body)


def t08_version_compare():
    with io.open(os.path.join(MOD, "libexec", "updater.sh"), encoding="utf-8") as f:
        src = f.read()
    start = src.index("function better(")
    end = src.index("\n      }\n", start) + len("\n      }\n")
    fn = src[start:end]
    prog = ("BEGIN {\n"
            '  printf "A=%d\\n", better("v4.0.0-beta.2","v3.3.0-beta.6")\n'
            '  printf "B=%d\\n", better("v3.3.0-beta.10","v3.3.0-beta.6")\n'
            '  printf "C=%d\\n", better("v3.3.0","v3.3.0-beta.6")\n'
            '  printf "D=%d\\n", better("v3.3.1-beta.1","v3.3.0")\n'
            '  printf "E=%d\\n", better("v3.3.0-beta.6","v3.3.0-beta.10")\n'
            '  printf "F=%d\\n", better("v3.3.0","v3.3.0")\n'
            "}\n")
    path = w("cases/better.awk", fn + prog)
    p = subprocess.run([AWK, "-f", path], capture_output=True)
    out = p.stdout.decode("utf-8", "replace")
    kv = {}
    for line in out.splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            kv[k] = v
    RESULTS["t08_version_compare"] = {"rc": p.returncode, "kv": kv, "stdout": out,
                                      "stderr": p.stderr.decode("utf-8", "replace")}
    return RESULTS["t08_version_compare"]


def t09_dns_liveness():
    body = r'''
. "$MOD/libexec/dns.sh"
CURL="{curl}"
cfg_set dns_probe 1 >/dev/null
cfg_set dns_probe_url "http://127.0.0.1:{port}/500" >/dev/null
dns_liveness_ok >/dev/null 2>&1; echo "R500=$?"
cfg_set dns_probe_url "http://127.0.0.1:{port}/204" >/dev/null
dns_liveness_ok >/dev/null 2>&1; echo "R204=$?"
cfg_set dns_probe_url "http://127.0.0.1:{port}/200" >/dev/null
dns_liveness_ok >/dev/null 2>&1; echo "R200=$?"
CURL="$SB/nonexistent-curl"
dns_liveness_ok >/dev/null 2>&1; echo "RNOCURL=$?"
'''.format(curl=CURL, port=PORT)
    return run("t09_dns_liveness", body)


def t10_ipv6_table_all():
    body = r'''
. "$MOD/libexec/dns.sh"
CURL="/bin/true"
dns_ipv6_usable >/dev/null 2>&1; echo "NEW_RC=$?"
# 旧实现只看 main 表
if ip -6 route show default 2>/dev/null | grep -q .; then echo "OLD_RC=0"; else echo "OLD_RC=1"; fi
echo "TABLEALL=$(ip -6 route show table all default 2>/dev/null | wc -l | tr -d ' ')"
'''
    return run("t10_ipv6_table_all", body)


def t11_dns_atomic_rollback():
    body = r'''
. "$MOD/libexec/dns.sh"
CURL="{curl}"
grep -q 'cp -f "\$_at" "\$DNSFILE"' "$MOD/libexec/dns.sh" && echo "STILL_CP=1" || echo "STILL_CP=0"
grep -q 'mv -f "\$DNSFILE.new.\$\$" "\$DNSFILE"' "$MOD/libexec/dns.sh" && echo "USES_MV=1" || echo "USES_MV=0"

: >"$SETTINGS"
dns_apply_list "1.1.1.1 8.8.8.8" >/dev/null 2>&1; echo "APPLY_RC=$?"
echo "NS=$(grep -c '^nameserver ' "$DNSFILE" 2>/dev/null)"
echo "HAS_1111=$(grep -c '^nameserver 1.1.1.1$' "$DNSFILE" 2>/dev/null)"
echo "LEFTOVER=$(ls "$A2A_LIVE" 2>/dev/null | grep -c 'resolv.new')"

# 全失败必须整文件还原（search/options 不能丢）
printf 'search corp.example\noptions ndots:5 timeout:9\nnameserver 10.0.0.1\n' >"$DNSFILE"
cp "$DNSFILE" "$SB/orig.resolv"
cfg_set dns_mode auto >/dev/null
cfg_set dns_probe 1 >/dev/null
cfg_set dns_static "223.5.5.5" >/dev/null
cfg_set dns_probe_url "http://127.0.0.1:{port}/500" >/dev/null
dns_ensure >/dev/null 2>&1; echo "ENSURE_RC=$?"
cmp -s "$SB/orig.resolv" "$DNSFILE" && echo "RESTORED=1" || echo "RESTORED=0"
grep -q '^search corp.example' "$DNSFILE" && echo "SEARCH_KEPT=1" || echo "SEARCH_KEPT=0"
grep -q 'timeout:9' "$DNSFILE" && echo "OPTS_KEPT=1" || echo "OPTS_KEPT=0"
'''.format(curl=CURL, port=PORT)
    return run("t11_dns_atomic_rollback", body)


def t12_health_url_host():
    body = r'''
export MODDIR="$MOD"
. "$MOD/libexec/control.sh"
: >"$SETTINGS"
cfg_set host "::1" >/dev/null;          echo "V6=[$(svc_health_urls 3065 | tr '\n' ' ')]"
cfg_set host "0.0.0.0" >/dev/null;      echo "ANY=[$(svc_health_urls 3065 | tr '\n' ' ')]"
cfg_set host "192.168.1.7" >/dev/null;  echo "LAN=[$(svc_health_urls 3065 | tr '\n' ' ')]"
cfg_set host "127.0.0.1" >/dev/null;    echo "LO=[$(svc_health_urls 3065 | tr '\n' ' ')]"
cfg_set host "[::1]" >/dev/null;        echo "V6B=[$(svc_health_urls 3065 | tr '\n' ' ')]"
'''
    return run("t12_health_url_host", body)


def t13_keep_awake():
    body = r'''
grep -B2 'write_state paused' "$MOD/libexec/supervise.sh" | grep -q release_wake && echo "PAUSED=1" || echo "PAUSED=0"
grep -B3 'write_state disabled' "$MOD/libexec/supervise.sh" | grep -q release_wake && echo "DISABLED=1" || echo "DISABLED=0"
grep -B2 'write_state dead' "$MOD/libexec/supervise.sh" | grep -q release_wake && echo "GIVEUP=1" || echo "GIVEUP=0"
grep -q 'else release_wake; fi' "$MOD/libexec/supervise.sh" && echo "RUNTIME=1" || echo "RUNTIME=0"
'''
    return run("t13_keep_awake", body)


def t14_static_payload():
    body = r'''
. "$MOD/libexec/payload.sh"
payload_validate "$SB/pay_static" >/dev/null 2>&1; echo "STATIC_VALID=$?"
loader_smoke "$SB/pay_static" >/dev/null 2>&1;    echo "STATIC_SMOKE=$?"
payload_validate "$SB/pay_dyn" >/dev/null 2>&1;    echo "DYN_VALID=$?"
loader_smoke "$SB/pay_dyn" >/dev/null 2>&1;        echo "DYN_SMOKE=$?"
payload_validate "$SB/pay_dyn_nolib" >/dev/null 2>&1; echo "DYN_NOLIB=$?"
payload_dir_is_static "$SB/pay_static" && echo "IS_STATIC=1" || echo "IS_STATIC=0"
payload_dir_is_static "$SB/pay_dyn" && echo "IS_STATIC_DYN=1" || echo "IS_STATIC_DYN=0"
grep -q 'payload_dir_is_static "\$_root"' "$MOD/libexec/updater.sh" && echo "UPD_GUARD=1" || echo "UPD_GUARD=0"
grep -q 'payload_is_static && return 0' "$MOD/libexec/payload.sh" && echo "LIBVERIFY=1" || echo "LIBVERIFY=0"
'''
    return run("t14_static_payload", body)


def t15_mirror_prefix():
    body = r'''
. "$MOD/libexec/updater.sh"
U="https://github.com/aimod-cc/Agent2API/releases/download/v1/x.tar.gz"
: >"$SETTINGS"
cfg_set github_mirror "https://mirror.example" >/dev/null
echo "M1=[$(mirror_url "$U")]"
cfg_set github_mirror "https://mirror.example/" >/dev/null
echo "M2=[$(mirror_url "$U")]"
cfg_set github_mirror "ghfast" >/dev/null
echo "M3=[$(mirror_url "$U")]"
cfg_set github_mirror "" >/dev/null
echo "M4=[$(mirror_url "$U")]"
'''
    return run("t15_mirror_prefix", body)


def t16_stop_child_identity():
    body = r'''
# stop_child 定义在 supervise_main 内部（调用时才定义），这里按源码抽出来单独跑
sed -n '/^stop_child() {/,/^}/p' "$MOD/libexec/supervise.sh" >"$SB/sc.sh"
echo "BLOCK_LINES=$(wc -l <"$SB/sc.sh" | tr -d ' ')"
RUNDIR="$SB/app/run"; LOGDIR="$SB/app/logs"; SUPLOG="$LOGDIR/supervisor.log"
mkdir -p "$RUNDIR" "$LOGDIR"
log_to() { :; }
sleep() { :; }
kill() { :; }                     # kill 不生效 → 模拟"杀不掉"
now_epoch() { echo 1700000000; }
. "$SB/sc.sh"

CHILD=999999; CHILD_TICKS=0; CHILD_START=1700000000
printf '999999
' >"$RUNDIR/server.pid"
printf '0
' >"$RUNDIR/server.start"
child_alive() { return 0; }       # 永远"还活着"
stop_child; echo "FAIL_RC=$?"
[ -f "$RUNDIR/server.pid" ] && echo "PID_KEPT=1" || echo "PID_KEPT=0"
[ -f "$RUNDIR/server.start" ] && echo "START_KEPT=1" || echo "START_KEPT=0"

CHILD=999999; CHILD_TICKS=0
child_alive() { return 1; }       # 进程已不在 → 允许清理
stop_child; echo "OK_RC=$?"
[ -f "$RUNDIR/server.pid" ] && echo "PID_GONE=0" || echo "PID_GONE=1"
'''
    return run("t16_stop_child_identity", body, timeout=90)


def t17_signal_terminates():
    body = r'''
: >"$SETTINGS"
. "$MOD/libexec/updater.sh"
upd_transaction_finish() { echo "FINISH_CALLED" >>"$SB/fin.log"; }
upd_recover_activation() { :; }
upd_finish_service() { :; }
payload_rollback() { :; }
trap 'upd_on_signal' TERM
MAIN=$$
( sleep 1; kill -TERM "$MAIN" 2>/dev/null ) &
sleep 6
echo "CONTINUED=1"
'''
    return run("t17_signal_terminates", body)


def t18_zoneinfo_atomic():
    body = r'''
sed -n '/^install_cleanup()/,/^}/p' "$MOD/customize.sh" >"$SB/ic.sh"
echo "FUNC_LINES=$(wc -l <"$SB/ic.sh" | tr -d ' ')"
APP_HOME="$SB/app"; RUNDIR="$APP_HOME/run"; update_lock_release() { :; }
mkdir -p "$APP_HOME" "$RUNDIR"
. "$SB/ic.sh"

# 场景 A：旧库已移开、新库未就位、未提交（旧代码在这里会丢掉整个 zoneinfo）
rm -rf "$APP_HOME/zoneinfo" "$APP_HOME/zoneinfo.old.1"
mkdir -p "$APP_HOME/zoneinfo.old.1/zones"
_ZONE_OLD="$APP_HOME/zoneinfo.old.1"; _ZONE_COMMITTED=0; _ZONE_OLD_PRESENT=1
_INSTALL_SUCCESS=0; _INSTALL_TRANSACTION="$SB/tx1"
install_cleanup
[ -d "$APP_HOME/zoneinfo/zones" ] && echo "A_RESTORED=1" || echo "A_RESTORED=0"

# 场景 B：已提交（新库就位）后失败 → 回退到旧库
rm -rf "$APP_HOME/zoneinfo" "$APP_HOME/zoneinfo.old.2"
mkdir -p "$APP_HOME/zoneinfo" "$APP_HOME/zoneinfo.old.2/oldzones"
: >"$APP_HOME/zoneinfo/NEW_MARKER"
_ZONE_OLD="$APP_HOME/zoneinfo.old.2"; _ZONE_COMMITTED=1; _ZONE_OLD_PRESENT=1
_INSTALL_SUCCESS=0; _INSTALL_TRANSACTION="$SB/tx2"
install_cleanup
[ -d "$APP_HOME/zoneinfo/oldzones" ] && echo "B_ROLLED=1" || echo "B_ROLLED=0"
[ -e "$APP_HOME/zoneinfo/NEW_MARKER" ] && echo "B_NEW_GONE=0" || echo "B_NEW_GONE=1"

# 场景 C：安装成功 → 不动新库
rm -rf "$APP_HOME/zoneinfo" "$APP_HOME/zoneinfo.old.3"
mkdir -p "$APP_HOME/zoneinfo" "$APP_HOME/zoneinfo.old.3"
_ZONE_OLD="$APP_HOME/zoneinfo.old.3"; _ZONE_COMMITTED=1; _ZONE_OLD_PRESENT=1
_INSTALL_SUCCESS=1; _INSTALL_TRANSACTION="$SB/tx3"
install_cleanup
[ -d "$APP_HOME/zoneinfo" ] && echo "C_KEPT=1" || echo "C_KEPT=0"

grep -q 'zoneinfo.old.\*' "$MOD/post-fs-data.sh" && echo "PF_RECOVER=1" || echo "PF_RECOVER=0"
'''
    return run("t18_zoneinfo_atomic", body)


def t19_unzip_selection():
    body = r'''
awk '/^UNZIP=""/,/^done$/' "$MOD/META-INF/com/google/android/update-binary" >"$SB/uz.sh"
echo "BLOCK_LINES=$(wc -l <"$SB/uz.sh" | tr -d ' ')"
abort() { echo "ABORT:$1"; exit 9; }
. "$SB/uz.sh"
echo "UNZIP_VAR=[$UNZIP]"
$UNZIP -o /tmp/z.zip -d /tmp/out
'''
    return run("t19_unzip_selection", body)


def t19b_busybox():
    body = r'''
awk '/^UNZIP=""/,/^done$/' "$MOD/META-INF/com/google/android/update-binary" >"$SB/uz2.sh"
abort() { echo "ABORT:$1"; exit 9; }
PATH="$SB/fakebin_bb"
. "$SB/uz2.sh"
echo "UNZIP_VAR=[$UNZIP]"
$UNZIP -o /tmp/z.zip -d /tmp/out
'''
    return run("t19b_busybox", body)


EXPECT = {
    "t01_startup_pid": {"STATIC_SETSID": "1", "STATIC_OLD_BLOCK": "0", "BOOTSTART": "1",
                        "BOOTSTART_SVC": "1", "NEW_RC": "0", "NEW_TICKS_SET": "1",
                        "DEAD_RC": "1", "DEAD_REASON": "1"},
    "t02_rollback_keeps_old": {"ACT_RC": "0", "NOW_VER": "2.0.0", "OLD_KEPT": "1",
                               "OLD_VER": "1.0.0", "PENDING": "1", "PENDING_MATCH": "1",
                               "COMMIT_RC": "0", "OLD_AFTER_COMMIT": "1", "PENDING_AFTER": "1",
                               "COMMIT_BAD_RC": "1", "BAD_KEPT": "1", "COMMIT_EVIL_RC": "0",
                               "EVIL_MARKER_CLEARED": "1"},
    "t03_interp_whitelist": {"APEX_RES": "other:/apex/com.android.runtime/bin/linker64",
                             "APEX_UNCHANGED": "1", "GLIBC_RES": "fixed",
                             "GLIBC_INTERP": SBX + "/live/ld.so"},
    "t04_reaping_stale": {"STALE_RC": "0", "STALE_TOKEN_SET": "1", "LIVE_RC": "1"},
    "t05_fastcrash_backoff": {"STATIC_START_RESET": "0", "STATIC_GATE120": "1",
                              "STATIC_T6": "1", "STATIC_T3": "1",
                              "ROUNDS": "6", "FAILS": "6", "GIVEUP": "1"},
    "t06_cfg_set_backslash": {"SET_RC": "0", "INJECTED": "0", "LINES": "1",
                              "GET": "abc\\nallow_no_key=1", "ALLOW": "NONE", "RAWLINES": "1"},
    "t07_trap_preserved": {"AFTER_CALLS": "1"},
    "t08_version_compare": {"A": "1", "B": "1", "C": "1", "D": "1", "E": "0", "F": "0"},
    "t09_dns_liveness": {"R500": "1", "R204": "0", "R200": "0", "RNOCURL": "1"},
    "t10_ipv6_table_all": {"NEW_RC": "0", "OLD_RC": "1"},
    "t11_dns_atomic_rollback": {"STILL_CP": "0", "USES_MV": "1", "APPLY_RC": "0",
                                "HAS_1111": "1", "ENSURE_RC": "1", "RESTORED": "1",
                                "SEARCH_KEPT": "1", "OPTS_KEPT": "1"},
    "t12_health_url_host": {"V6": "[http://[::1]:3065/health ]",
                            "ANY": "[http://127.0.0.1:3065/health ]",
                            "LO": "[http://127.0.0.1:3065/health ]",
                            "V6B": "[http://[::1]:3065/health ]"},
    "t13_keep_awake": {"PAUSED": "1", "DISABLED": "1", "GIVEUP": "1", "RUNTIME": "1"},
    "t14_static_payload": {"STATIC_VALID": "0", "STATIC_SMOKE": "0", "DYN_VALID": "0",
                           "DYN_SMOKE": "0", "DYN_NOLIB": "1", "IS_STATIC": "1",
                           "IS_STATIC_DYN": "0", "UPD_GUARD": "1", "LIBVERIFY": "1"},
    "t15_mirror_prefix": {"M1": "[https://mirror.example/https://github.com/aimod-cc/Agent2API/releases/download/v1/x.tar.gz]",
                          "M2": "[https://mirror.example/https://github.com/aimod-cc/Agent2API/releases/download/v1/x.tar.gz]",
                          "M3": "[https://ghfast.top/https://github.com/aimod-cc/Agent2API/releases/download/v1/x.tar.gz]",
                          "M4": "[https://github.com/aimod-cc/Agent2API/releases/download/v1/x.tar.gz]"},
    "t16_stop_child_identity": {"FAIL_RC": "1", "PID_KEPT": "1",
                                "START_KEPT": "1", "OK_RC": "0", "PID_GONE": "1"},
    "t18_zoneinfo_atomic": {"A_RESTORED": "1", "B_ROLLED": "1", "B_NEW_GONE": "1",
                            "C_KEPT": "1", "PF_RECOVER": "1"},
    "t19_unzip_selection": {"UNZIP_VAR": "[unzip]"},
    "t19b_busybox": {"UNZIP_VAR": "[busybox unzip]"},
}


def main():
    global PORT
    if sys.platform == "win32":
        sys.stdout.reconfigure(encoding="utf-8")
    setup()
    PORT = start_http()
    for fn in (t01_startup_pid, t02_rollback_keeps_old, t03_interp_whitelist,
               t04_reaping_stale, t05_fastcrash_backoff, t06_cfg_set_backslash,
               t07_trap_preserved, t08_version_compare, t09_dns_liveness,
               t10_ipv6_table_all, t11_dns_atomic_rollback, t12_health_url_host,
               t13_keep_awake, t14_static_payload, t15_mirror_prefix,
               t16_stop_child_identity, t17_signal_terminates,
               t18_zoneinfo_atomic, t19_unzip_selection, t19b_busybox):
        fn()

    ok = fail = 0
    report = []
    for name, exp in EXPECT.items():
        got = RESULTS.get(name, {}).get("kv", {})
        bad = ["%s: want %r got %r" % (k, v, got.get(k))
               for k, v in exp.items() if got.get(k) != v]
        if bad:
            fail += 1
            report.append("FAIL %s\n    %s" % (name, "\n    ".join(bad)))
        else:
            ok += 1
            report.append("PASS %s" % name)

    # F-017 与 F-007 看退出码/是否继续执行
    sig = RESULTS.get("t17_signal_terminates", {})
    if sig.get("rc") == 1 and "CONTINUED=1" not in sig.get("stdout", ""):
        ok += 1
        report.append("PASS t17_signal_terminates (rc=1, 未继续执行)")
    else:
        fail += 1
        report.append("FAIL t17_signal_terminates rc=%r out=%r"
                      % (sig.get("rc"), sig.get("stdout", "")[-200:]))

    trap = RESULTS.get("t07_trap_preserved", {})
    if "OUTER_TERM_FIRED" in trap.get("stdout", ""):
        ok += 1
        report.append("PASS t07_trap_callback (外层 TERM 处理器仍然生效)")
    else:
        fail += 1
        report.append("FAIL t07_trap_callback rc=%r out=%r"
                      % (trap.get("rc"), trap.get("stdout", "")[-300:]))

    print("\n".join(report))
    print("\n== %d passed, %d failed ==" % (ok, fail))
    with io.open(os.path.join(ROOT, "fix_verify.json"), "w",
                 encoding="utf-8", newline="\n") as f:
        json.dump(RESULTS, f, ensure_ascii=False, indent=1)
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
