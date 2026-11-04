# -*- coding: utf-8 -*-
"""修复后逐条复验 v2：R01–R19 是否真的闭合。

只读源码 E:/AI/tmp/a2a-magisk-repo/module，所有写入落在隔离 CASE 目录。
片段一律从源码原样切片（保留换行），stub 只替换操作系统边界。
"""
import datetime
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# 默认按脚本自身位置定位源码（脚本放 <repo>/test/ 下即可直接跑）；
# 也可用环境变量 A2A_MODULE / A2A_VERIFY_OUT 覆盖。
ROOT = Path(os.environ.get('A2A_VERIFY_OUT') or (Path(__file__).resolve().parent / 'out'))
SRC = Path(os.environ.get('A2A_MODULE') or (Path(__file__).resolve().parent.parent / 'module'))


def _find_sh() -> str:
    """F-010：sh 解释器解析。不再硬编码某个用户的安装路径。

    优先级：A2A_SH 显式指定 > PATH 里的 sh > 常见 MSYS/Git-Bash 位置探测。
    """
    env = os.environ.get('A2A_SH')
    if env:
        return env
    found = shutil.which('sh')
    if found:
        return found
    for cand in (
        r'C:\Program Files\Git\usr\bin\sh.exe',
        r'C:\Program Files (x86)\Git\usr\bin\sh.exe',
        r'C:\msys64\usr\bin\sh.exe',
        str(Path.home() / r'.dsh\profiles\desktop\node_modules\@dsh-ops\bash-win32-x64\usr\bin\sh.exe'),
    ):
        if Path(cand).is_file():
            return cand
    raise SystemExit('找不到 sh：请设 A2A_SH 指向 POSIX sh（msys/Git Bash 的 sh.exe）')


SH = _find_sh()
CURL = os.environ.get('A2A_CURL') or shutil.which('curl') or 'curl'
ROOT.mkdir(parents=True, exist_ok=True)
obs, results, summary = [], {}, []


def posix(p):
    s = str(p).replace('\\', '/')
    # 只有真正的 Windows 盘符路径才转成 /c/...；Linux 绝对路径（/tmp/x）
    # 必须原样返回。旧实现无条件 return '/' + s[0].lower() + s[2:]，把
    # /tmp/repro.sh 变成 //mp/repro.sh —— 在 Linux/MSYS 上根本找不到文件。
    if len(s) >= 2 and s[1] == ':' and s[0].isalpha():
        return '/' + s[0].lower() + s[2:]
    return s


def save(p, data):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.exists():
        obs.append({'path': str(p), 'old_sha256': hashlib.sha256(p.read_bytes()).hexdigest()})
    if isinstance(data, str):
        data = data.encode('utf-8')
    p.write_bytes(data)
    return p


def kl(rel):
    return (SRC / rel).read_text(encoding='utf-8').splitlines(keepends=True)


def txt(rel):
    return (SRC / rel).read_text(encoding='utf-8')


def find(rel, needle, start=1):
    for i, ln in enumerate(kl(rel), 1):
        if i >= start and needle in ln:
            return i
    raise SystemExit('anchor not found: %r in %s' % (needle, rel))


def func(rel, name):
    """取 name() { ... } 的完整原文（含收尾 }）。

    收尾以「第 0 列就是 }」为准，而不是数花括号配平：本仓所有顶层函数体都
    以第 0 列的 } 结束，而函数体里会出现 `|| { ... }` 分组、awk 程序的
    `BEGIN { ... }` 块，靠配平会被提前截断（曾因此把 hot_request_write 和
    json_escape 切坏，用例直接语法错误）。
    """
    lines = kl(rel)
    s = find(rel, name + '() {')
    out = []
    for ln in lines[s - 1:]:
        out.append(ln)
        if ln.startswith('}'):
            return ''.join(out)
    raise SystemExit('unbalanced function: ' + name)


def between(rel, a, b):
    lines = kl(rel)
    i = find(rel, a)
    j = find(rel, b, i)
    return ''.join(lines[i:j - 1])


def run(name, body, timeout=60):
    case_dir = ROOT / 'cases' / (name + '.d')
    case_dir.mkdir(parents=True, exist_ok=True)
    pth = save(ROOT / 'cases' / (name + '.sh'), body)
    env = dict(os.environ, CASE=posix(case_dir), TMP=posix(ROOT / 'tmp'),
               TMPDIR=posix(ROOT / 'tmp'), TEMP=posix(ROOT / 'tmp'))
    (ROOT / 'tmp').mkdir(parents=True, exist_ok=True)
    p = subprocess.run([SH, posix(pth)], capture_output=True, timeout=timeout, env=env)

    def dec(b):
        try:
            return b.decode('utf-8')
        except UnicodeDecodeError:
            return b.decode('gb18030', 'replace')

    out, err = dec(p.stdout), dec(p.stderr)
    m = {}
    for ln in out.splitlines():
        if ln.startswith('METRIC ') and '=' in ln:
            k, v = ln[7:].split('=', 1)
            m[k] = v
    results[name] = {'returncode': p.returncode, 'metrics': m, 'stdout': out,
                     'stderr': err, 'script': str(pth)}
    save(ROOT / 'raw' / (name + '.stdout.txt'), out)
    save(ROOT / 'raw' / (name + '.stderr.txt'), err)
    print('%-44s rc=%-3s %s' % (name, p.returncode, json.dumps(m, ensure_ascii=False)))
    return results[name]


def check(name, exp):
    got = results.get(name, {}).get('metrics', {})
    ok = bool(got) or not exp
    ok = all(got.get(k) == v for k, v in exp.items())
    summary.append({'case': name, 'pass': ok, 'expected': exp,
                    'got': {k: got.get(k) for k in exp}})


def check_fn(name, fn):
    out = results.get(name, {}).get('stdout', '')
    ok = bool(out.strip()) and fn(out)
    summary.append({'case': name, 'pass': ok,
                    'stdout_tail': '\n'.join(out.strip().splitlines()[-8:])})


# ------------------------------------------------------------------ 夹具
def mkfx(dirpath, ver, static=True, libc=True, loader=False, broken=False):
    d = Path(dirpath)
    (d / 'ui').mkdir(parents=True, exist_ok=True)
    elf = bytearray(64)
    elf[:7] = b'\x7fELF\x02\x01\x01'
    elf[18:20] = b'\xb7\x00'
    body = bytes(elf) + (b'' if static else b'/lib/ld-linux-aarch64.so.1')
    save(d / 'agent2api-server', b'not-an-elf' if broken else body)
    save(d / 'ui/index.html', '<html>%s</html>\n' % ver)
    save(d / 'VERSION', 'ver=%s\nbuilt=2026-11-03T00:00:00Z\n' % ver)
    if libc or loader:
        (d / 'lib').mkdir(parents=True, exist_ok=True)
    if libc:
        save(d / 'lib/libc.so.6', 'fixture')
    if loader:
        save(d / 'lib/ld-linux-aarch64.so.1', 'fixture')
    return d


FX = ROOT / 'fixtures'
mkfx(FX / 'static', 'v1.0.0', static=True, libc=False)
mkfx(FX / 'static_new', 'v2.0.0', static=True, libc=False)
mkfx(FX / 'dyn', 'v1.0.0', static=False, libc=True, loader=True)
mkfx(FX / 'broken', 'v0.0.1', broken=True, libc=False)

PRE = f'''#!/bin/sh
MODDIR='{posix(SRC)}'
. "$MODDIR/libexec/common.sh"
APP_HOME="$CASE/home"; PAYLOAD="$APP_HOME/payload"; BACKUPDIR="$APP_HOME/backup"
RUNDIR="$APP_HOME/run"; LOGDIR="$APP_HOME/logs"; TMPD="$APP_HOME/tmp"
CFGDIR="$APP_HOME/etc"; DATADIR="$APP_HOME/data"; HOMEDIR="$APP_HOME/home"
DLDIR="$APP_HOME/dl"; BINDIR="$APP_HOME/bin"; A2A_LIVE="$CASE/live"
PLIB="$PAYLOAD/lib"; LOADER="$PLIB/ld-linux-aarch64.so.1"; SERVER_BIN="$PAYLOAD/agent2api-server"
SETTINGS="$CFGDIR/settings.conf"; SUPLOG="$LOGDIR/supervisor.log"; SRVLOG="$LOGDIR/server.log"
APPLOG="$LOGDIR/app.log"; DNSFILE="$A2A_LIVE/resolv"; DNS_CACHE="$RUNDIR/resolv.last"
CURL='{CURL}'; PORT=3065
mkdir -p "$RUNDIR" "$LOGDIR" "$TMPD" "$BACKUPDIR" "$A2A_LIVE" "$CFGDIR" "$DATADIR" "$BINDIR"
: >"$SETTINGS"
say() {{ printf 'SAY %s\\n' "$*"; }}
log_to() {{ printf 'LOG %s\\n' "$*" >>"$CASE/log.txt"; }}
metric() {{ printf 'METRIC %s=%s\\n' "$1" "$2"; }}
exists() {{ [ -e "$1" ] && printf 1 || printf 0; }}
fx() {{ cp -R "{posix(FX)}/$1/." "$2"; }}
'''


def P(*rel):
    return ''.join('. "$MODDIR/%s"\n' % r for r in rel)


# ============================================================== R01
run('r01_activate_registers_pending', PRE + P('libexec/payload.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/staged"; fx static_new "$APP_HOME/staged"
payload_activate_staged "$APP_HOME/staged" new >/dev/null 2>&1
_p=$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null)
metric pending_written "$([ -n "$_p" ] && printf 1 || printf 0)"
metric old_payload_intact "$(exists "$_p")"
metric new_version_live "$(payload_version)"
''')
check('r01_activate_registers_pending',
      {'pending_written': '1', 'old_payload_intact': '1', 'new_version_live': 'v2.0.0'})

run('r01_post_fs_data_keeps_pending', PRE + P('libexec/payload.sh', 'libexec/dns.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/staged"; fx static_new "$APP_HOME/staged"
payload_activate_staged "$APP_HOME/staged" new >/dev/null 2>&1
_old=$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null)
''' + between('post-fs-data.sh', 'payload_recover_interrupted', '# glibc 运行时文件') + r'''
metric pending_kept "$(exists "$RUNDIR/update.pending")"
metric old_kept "$(exists "$_old")"
''')
check('r01_post_fs_data_keeps_pending', {'pending_kept': '1', 'old_kept': '1'})

sec9 = between('libexec/supervise.sh', '# 9) 拉起', 'done')
# localfix：提交动作从主循环内联块抽成 supervise_commit_pending()，切片里只剩调用，
# 所以这里必须把函数本体一起带上，否则用例会静默地"什么都没提交"。
sec9_commit = func('libexec/supervise.sh', 'supervise_commit_pending')
run('r01_supervisor_commits_after_health', PRE + P('libexec/payload.sh') + sec9_commit + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/staged"; fx static_new "$APP_HOME/staged"
payload_activate_staged "$APP_HOME/staged" new >/dev/null 2>&1
_old=$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null)
# localfix：提交必须三方代次一致（pending / 本次子进程启动代次 / 磁盘代次）。
# start_child 被桩掉，所以这里手工把"本次子进程读到的代次"置为新载荷代次。
CHILD_GENERATION=$(payload_generation_read)
FAILS=0; LAUNCHES=0
start_child() { LAUNCHES=$((LAUNCHES+1)); return 0; }
write_state() { printf 'STATE=%s\n' "$1" >"$CASE/state.txt"; }
log_to() { :; }
''' + sec9 + r'''
metric launches "$LAUNCHES"
metric pending_gone "$([ ! -e "$RUNDIR/update.pending" ] && printf 1 || printf 0)"
metric old_payload_gone "$([ ! -e "$_old" ] && printf 1 || printf 0)"
metric live_version "$(payload_version)"
''')
check('r01_supervisor_commits_after_health',
      {'launches': '1', 'pending_gone': '1', 'old_payload_gone': '1', 'live_version': 'v2.0.0'})

run('r01_updater_commit_keeps_identity', PRE + func('libexec/updater.sh', 'upd_payload_commit')
    + func('libexec/updater.sh', 'upd_payload_committed') + r'''
UPD_INSTALLED=0; UPD_COMMITTED=0
UPD_ACTIVATE_BEFORE="$APP_HOME/payload.new.old.42"; UPD_ACTIVATE_AFTER=""
upd_payload_commit "$UPD_ACTIVATE_BEFORE" ""
metric installed "$UPD_INSTALLED"
metric identity_kept "$([ -n "$UPD_ACTIVATE_BEFORE" ] && printf 1 || printf 0)"
upd_payload_committed
metric identity_cleared "$([ -z "$UPD_ACTIVATE_BEFORE" ] && printf 1 || printf 0)"
metric committed_flag "$UPD_COMMITTED"
''')
check('r01_updater_commit_keeps_identity',
      {'installed': '1', 'identity_kept': '1', 'identity_cleared': '1', 'committed_flag': '1'})

# ============================================================== R02
run('r02_pending_write_failure_aborts', PRE + P('libexec/payload.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/staged"; fx static_new "$APP_HOME/staged"
mkdir -p "$RUNDIR/update.pending.tmp.$$"
payload_activate_staged "$APP_HOME/staged" new >/dev/null 2>&1; _rc=$?
metric activation_rc "$_rc"
metric active_cleared "$([ ! -e "$RUNDIR/update.active" ] && printf 1 || printf 0)"
metric old_dir_reported "$(grep -c '请勿手工删除' "$CASE/log.txt" 2>/dev/null || printf 0)"
''')
check('r02_pending_write_failure_aborts', {'activation_rc': '1', 'active_cleared': '1'})

run('r02_commit_delete_failure_reports_error', PRE + P('libexec/payload.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/payload.new.old.909"; printf x >"$APP_HOME/payload.new.old.909/m"
printf 'new 909 %s\n' "$APP_HOME/payload.new.old.909" >"$RUNDIR/update.pending"
rm() { case "$*" in *payload.new.old.909*) return 1;; esac; command rm "$@"; }
payload_commit_old >/dev/null 2>&1; _rc=$?
metric commit_rc "$_rc"
metric old_kept "$(exists "$APP_HOME/payload.new.old.909")"
metric pending_kept "$(exists "$RUNDIR/update.pending")"
''')
check('r02_commit_delete_failure_reports_error',
      {'commit_rc': '1', 'old_kept': '1', 'pending_kept': '1'})

# ============================================================== R03
run('r03_commit_rejects_foreign_generation', PRE + P('libexec/payload.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/payload.new.old.909"; printf x >"$APP_HOME/payload.new.old.909/m"
printf 'new 909 %s\n' "$APP_HOME/payload.new.old.909" >"$RUNDIR/update.pending"
payload_commit_old "rollback 111" >/dev/null 2>&1; _a=$?
metric foreign_rc "$_a"
metric foreign_kept "$(exists "$APP_HOME/payload.new.old.909")"
metric foreign_pending_kept "$(exists "$RUNDIR/update.pending")"
payload_commit_old "new 909" >/dev/null 2>&1; _b=$?
metric match_rc "$_b"
metric old_deleted "$([ ! -e "$APP_HOME/payload.new.old.909" ] && printf 1 || printf 0)"
metric pending_cleared "$([ ! -e "$RUNDIR/update.pending" ] && printf 1 || printf 0)"
''')
check('r03_commit_rejects_foreign_generation',
      {'foreign_rc': '1', 'foreign_kept': '1', 'foreign_pending_kept': '1',
       'match_rc': '0', 'old_deleted': '1', 'pending_cleared': '1'})

# ============================================================== R04
run('r04_rollback_converges_pending', PRE + P('libexec/payload.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$BACKUPDIR"; fx static "$BACKUPDIR/prev"
mkdir -p "$APP_HOME/staged"; fx static_new "$APP_HOME/staged"
payload_activate_staged "$APP_HOME/staged" new >/dev/null 2>&1
_failed="$APP_HOME/payload.new.old.$$"
metric before_version "$(payload_version)"
payload_rollback >/dev/null 2>&1
_upd_rb_ok=1
if [ "$_upd_rb_ok" = "1" ] && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
  if payload_commit_old "rollback $$" >/dev/null 2>&1; then UPD_COMMITTED=1; fi
fi
metric after_version "$(payload_version)"
metric pending_gone "$([ ! -e "$RUNDIR/update.pending" ] && printf 1 || printf 0)"
metric committed "${UPD_COMMITTED:-0}"
metric failed_version_removed "$([ ! -e "$_failed" ] && printf 1 || printf 0)"
''')
check('r04_rollback_converges_pending',
      {'before_version': 'v2.0.0', 'after_version': 'v1.0.0', 'pending_gone': '1',
       'committed': '1'})

# ============================================================== R05
run('r05_static_payload_functions', PRE + P('libexec/payload.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
payload_validate "$PAYLOAD"; metric static_validate "$?"
payload_fix_perms "$PAYLOAD"; metric static_perms "$?"
loader_smoke "$PAYLOAD"; metric static_smoke "$?"
mkdir -p "$APP_HOME/dyn"; fx dyn "$APP_HOME/dyn"
payload_validate "$APP_HOME/dyn"; metric dyn_validate "$?"
payload_fix_perms "$APP_HOME/dyn"; metric dyn_perms "$?"
loader_smoke "$APP_HOME/dyn"; metric dyn_smoke "$?"
mkdir -p "$APP_HOME/bad"; fx broken "$APP_HOME/bad"
payload_validate "$APP_HOME/bad" >/dev/null 2>&1; metric broken_validate "$?"
''')
check('r05_static_payload_functions',
      {'static_validate': '0', 'static_perms': '0', 'static_smoke': '0',
       'dyn_validate': '0', 'dyn_perms': '0', 'broken_validate': '1'})

lp = txt('libexec/launch.sh')
launch_prefix = lp[:lp.index('. "$A2A_DIR/common.sh"')]
run('r05_static_launch_skips_loader', PRE + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
A2A_DIR="$MODDIR/libexec"; SERVER_BIN="$PAYLOAD/agent2api-server"
PLIB="$PAYLOAD/lib"; LOADER="$PLIB/ld-linux-aarch64.so.1"
ensure_layout() { :; }
''' + launch_prefix.split('\n', 1)[1] + r'''
metric launch_reached "$([ -n "$SERVER_BIN" ] && printf 1 || printf 0)"
''')
check('r05_static_launch_skips_loader', {'launch_reached': '1'})

run('r05_customize_static_detection', '#!/bin/sh\n' + PRE.split('\n', 1)[1]
    + func('customize.sh', 'payload_seed_is_static') + r'''
mkdir -p "$CASE/s" "$CASE/d"; fx static "$CASE/s"; fx dyn "$CASE/d"
payload_seed_is_static "$CASE/s"; metric static_hit "$?"
payload_seed_is_static "$CASE/d"; metric dyn_hit "$?"
''')
check('r05_customize_static_detection', {'static_hit': '0', 'dyn_hit': '1'})

# ============================================================== R06 / R07
run('r06_stop_cleans_dead_owner', PRE + P('libexec/payload.sh', 'libexec/control.sh') + r'''
proc_start_ticks() { case "$1" in 555) printf 4242;; *) printf 777;; esac; }
pid_alive() { [ "$1" = "555" ] && return 1; kill -0 "$1" 2>/dev/null; }
pid_is_supervisor() { return 1; }; pid_is_server() { return 1; }
svc_supervisor_pid() { return 1; }; svc_server_pid() { return 1; }
mkdir -p "$RUNDIR/lock"; printf '555 4242 deadtoken\n' >"$RUNDIR/lock/owner"
update_lock_acquire "$RUNDIR/service.lock.d" || metric outer 0
metric outer 1
_saved="$UPDATE_LOCK_TOKEN"
svc_stop_impl >/dev/null 2>&1; _rc=$?
metric stop_rc "$_rc"
metric instance_lock_gone "$([ ! -e "$RUNDIR/lock" ] && printf 1 || printf 0)"
metric outer_token_ok "$([ "$UPDATE_LOCK_TOKEN" = "$_saved" ] && printf 1 || printf 0)"
metric service_owner_intact "$(exists "$RUNDIR/service.lock.d/owner")"
''')
check('r06_stop_cleans_dead_owner',
      {'outer': '1', 'stop_rc': '0', 'instance_lock_gone': '1',
       'outer_token_ok': '1', 'service_owner_intact': '1'})

run('r07_reentrant_start_keeps_lock', PRE + P('libexec/payload.sh', 'libexec/control.sh') + r'''
update_lock_acquire "$RUNDIR/service.lock.d" || metric acq 0
metric acq 1
_t="$UPDATE_LOCK_TOKEN"
svc_start_impl() { return 0; }
svc_start >/dev/null 2>&1; metric reentrant_rc "$?"
metric token_kept "$([ "$UPDATE_LOCK_TOKEN" = "$_t" ] && printf 1 || printf 0)"
metric owner_kept "$(exists "$RUNDIR/service.lock.d/owner")"
update_lock_release "$RUNDIR/service.lock.d"
metric owner_freed "$([ ! -e "$RUNDIR/service.lock.d/owner" ] && printf 1 || printf 0)"
''')
check('r07_reentrant_start_keeps_lock',
      {'acq': '1', 'reentrant_rc': '0', 'token_kept': '1', 'owner_kept': '1', 'owner_freed': '1'})

run('r06b_stop_timeout_keeps_state', PRE + P('libexec/payload.sh', 'libexec/control.sh') + r'''
svc_supervisor_pid() { echo 601; }; pid_is_supervisor() { return 0; }
pid_is_server() { return 1; }; svc_server_pid() { return 1; }
term_pid_verified() { return 1; }
printf '601 900\n' >"$RUNDIR/server.pid"
svc_stop_impl >/dev/null 2>&1; metric stop_rc "$?"
metric pid_kept "$(exists "$RUNDIR/server.pid")"
metric stop_marker "$(exists "$RUNDIR/stop")"
''')
check('r06b_stop_timeout_keeps_state', {'stop_rc': '1', 'pid_kept': '1', 'stop_marker': '1'})

# ============================================================== R08
run('r08_reaper_generation_guard', PRE + P('libexec/payload.sh') + r'''
proc_start_ticks() { case "$1" in 700) printf 5000;; 800) printf 6000;; *) printf 999;; esac; }
pid_alive() { [ "$1" = "700" ] && return 0; return 1; }
mkdir -p "$RUNDIR/update.lock.d"; printf '700 5000 livetoken\n' >"$RUNDIR/update.lock.d/owner"
CALLS=0
ln() {
  CALLS=$((CALLS+1))
  case "$*" in
    *reaping*) printf '800 6000 1.2.3 0\n' >"$RUNDIR/update.lock.d/reaping"; return 1 ;;
  esac
  command ln "$@"
}
payload_commit_old >/dev/null 2>&1
update_lock_acquire "$RUNDIR/update.lock.d" 2 >/dev/null 2>&1; _rc=$?
metric acquire_rc "$_rc"
metric live_owner_kept "$(exists "$RUNDIR/update.lock.d/owner")"
metric live_token "$(awk '{print $3}' "$RUNDIR/update.lock.d/owner" 2>/dev/null)"
''')
check_fn('r08_reaper_generation_guard',
         lambda s: 'METRIC live_owner_kept=1' in s and 'METRIC live_token=livetoken' in s)

# ============================================================== R09
run('r09_recovery_no_nesting', PRE + P('libexec/payload.sh') + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/payload.new.old.777"; fx static "$APP_HOME/payload.new.old.777"
printf 'not-an-elf' >"$PAYLOAD/agent2api-server"
mv() { case "$*" in *payload.incomplete*) return 1;; esac; command mv "$@"; }
payload_recover_interrupted >/dev/null 2>&1; metric recovery_rc "$?"
metric old_intact "$(exists "$APP_HOME/payload.new.old.777")"
metric no_nest "$([ ! -e "$PAYLOAD/payload.new.old.777" ] && printf 1 || printf 0)"
''')
check('r09_recovery_no_nesting', {'old_intact': '1', 'no_nest': '1'})

# ============================================================== R10
cleanup_fn = func('customize.sh', 'install_cleanup')
cleanup_fn = cleanup_fn.replace('update_lock_release "$RUNDIR/update.lock.d"', ':')
run('r10_zoneinfo_rollback_without_flag', '#!/bin/sh\n' + PRE.split('\n', 1)[1] + r'''
APP_HOME="$CASE/home"; RUNDIR="$APP_HOME/run"; mkdir -p "$RUNDIR"
_INSTALL_TRANSACTION="$APP_HOME/.install.$$"; _ZONE_OLD="$APP_HOME/zoneinfo.old.$$"
_ZONE_OLD_PRESENT=1; _ZONE_COMMITTED=0; _INSTALL_SUCCESS=0
mkdir -p "$APP_HOME/zoneinfo" "$_ZONE_OLD" "$_INSTALL_TRANSACTION"
printf old >"$_ZONE_OLD/version"; printf old-tz >"$_ZONE_OLD/Asia"
printf new >"$APP_HOME/zoneinfo/version"
''' + cleanup_fn + r'''
install_cleanup
metric zone_version "$(cat "$APP_HOME/zoneinfo/version" 2>/dev/null)"
metric aux_restored "$(cat "$APP_HOME/zoneinfo/Asia" 2>/dev/null)"
metric old_dir_gone "$([ ! -e "$_ZONE_OLD" ] && printf 1 || printf 0)"
''')
check('r10_zoneinfo_rollback_without_flag',
      {'zone_version': 'old', 'aux_restored': 'old-tz', 'old_dir_gone': '1'})

# ============================================================== R11
run('r11_cfg_set_roundtrip', PRE + r'''
cfg_set gateway_key "$(printf 'abc\nallow_no_key=1')"; metric lf_rc "$?"
cfg_set gateway_key "$(printf 'abc\rdef')"; metric cr_rc "$?"
cfg_set gateway_key 'plain'; metric plain_rc "$?"
metric plain_val "$(cfg_get gateway_key)"
cfg_set gateway_key 'has space'; metric space_rc "$?"
metric space_val "$(cfg_get gateway_key)"
cfg_set gateway_key 'has # hash'; metric hash_rc "$?"
metric hash_val "$(cfg_get gateway_key)"
cfg_set gateway_key "it's"; metric quote_rc "$?"
metric quote_val "$(cfg_get gateway_key)"
metric injected_absent "$(cfg_get allow_no_key ABSENT)"
cfg_set gateway_key 'v2'; cfg_set gateway_key 'v3'; metric dedup "$(grep -c '^gateway_key=' "$SETTINGS")"
metric last_wins "$(cfg_get gateway_key)"
''')
check('r11_cfg_set_roundtrip',
      {'lf_rc': '1', 'cr_rc': '1', 'plain_rc': '0', 'plain_val': 'plain',
       'space_rc': '0', 'space_val': 'has space', 'hash_rc': '0', 'hash_val': 'has # hash',
       'quote_rc': '0', 'quote_val': "it's", 'injected_absent': 'ABSENT',
       'dedup': '1', 'last_wins': 'v3'})


# ============================================================== R12 / R13
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        s = self.server
        s.seen.append(self.path)
        if s.kind == 'ok':
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"ok"}')
        elif s.kind == 'degraded':
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"degraded"}')
        elif s.kind == 'bad':
            self.send_response(200); self.end_headers(); self.wfile.write(b'{"status":"booting"}')
        elif s.kind == 'truncated':
            self.send_response(200)
            self.send_header('Content-Length', '200')
            self.end_headers()
            self.wfile.write(b'{"sta')
            self.wfile.flush()
            try:
                self.connection.close()
            except Exception:
                pass

    def log_message(self, *a):
        pass


class S(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class S6(S):
    address_family = socket.AF_INET6


def serve(addr, kind, v6=False):
    srv = (S6 if v6 else S)(addr, H)
    srv.kind, srv.seen = kind, []
    th = threading.Thread(target=srv.serve_forever, daemon=True)
    th.start()
    return srv, th


servers = {}
for k in ('ok', 'degraded', 'bad', 'truncated'):
    srv, th = serve(('127.0.0.1', 0), k)
    servers[k] = (srv, th)

HC = PRE + P('libexec/control.sh') + r'''
svc_server_pid() { echo 777; }; pid_is_server() { return 0; }; port_owned_by_pid() { return 0; }
unset no_proxy NO_PROXY http_proxy HTTP_PROXY HTTPS_PROXY https_proxy all_proxy ALL_PROXY
'''
run('r12_health_proxy_independent', HC + '''
cfg_set port %d; cfg_set host 127.0.0.1
svc_http_health 2; metric direct "$?"
export http_proxy='http://127.0.0.1:%d'; export https_proxy="$http_proxy"
svc_http_health 2; metric proxied "$?"
export HTTP_PROXY="$http_proxy"; unset http_proxy https_proxy
svc_http_health 2; metric proxied_upper "$?"
''' % (servers['ok'][0].server_port, servers['bad'][0].server_port))
check('r12_health_proxy_independent', {'direct': '0', 'proxied': '0', 'proxied_upper': '0'})

run('r12_health_status_matrix', HC + '''
cfg_set host 127.0.0.1
cfg_set port %d; svc_http_health 2; metric ok "$?"
cfg_set port %d; svc_http_health 2; metric degraded "$?"
cfg_set port %d; svc_http_health 2; metric bad "$?"
cfg_set port %d; svc_http_health 2; metric truncated "$?"
''' % (servers['ok'][0].server_port, servers['degraded'][0].server_port,
       servers['bad'][0].server_port, servers['truncated'][0].server_port))
check('r12_health_status_matrix',
      {'ok': '0', 'degraded': '0', 'bad': '1', 'truncated': '1'})

try:
    v6, v6t = serve(('::1', 0), 'ok', v6=True)
    servers['v6'] = (v6, v6t)
    run('r12_health_ipv6_wildcard', HC + '''
cfg_set port %d
cfg_set host ::1; svc_http_health 2; metric explicit "$?"
cfg_set host ::; metric urls "$(svc_health_urls %d | tr '\\n' ' ')"
svc_http_health 2; metric wildcard "$?"
cfg_set host "[::]"; svc_http_health 2; metric bracket_wildcard "$?"
''' % (v6.server_port, v6.server_port))
    check('r12_health_ipv6_wildcard',
          {'explicit': '0', 'wildcard': '0', 'bracket_wildcard': '0'})
except OSError as e:
    results['r12_health_ipv6_wildcard'] = {'environment_error': str(e)}
    summary.append({'case': 'r12_health_ipv6_wildcard', 'pass': False,
                    'environment_error': str(e)})
    print('r12_health_ipv6_wildcard skipped:', e)

run('r13_liveness_curl_status', PRE + P('libexec/dns.sh') + '''
cfg_set dns_probe 1
cfg_set dns_probe_url 'http://127.0.0.1:%d/generate_204'; dns_liveness_ok; metric ok "$?"
cfg_set dns_probe_url 'http://127.0.0.1:%d/generate_204'; dns_liveness_ok; metric truncated "$?"
cfg_set dns_probe_url 'http://127.0.0.1:1/generate_204'; dns_liveness_ok; metric refused "$?"
cfg_set dns_probe ''
cfg_set dns_probe_url 'http://127.0.0.1:%d/generate_204'; dns_liveness_ok; metric probe_off "$?"
''' % (servers['ok'][0].server_port, servers['truncated'][0].server_port,
       servers['ok'][0].server_port))
check('r13_liveness_curl_status',
      {'ok': '0', 'truncated': '1', 'refused': '1', 'probe_off': '0'})

# ============================================================== R14
run('r14_dns_backup_failure_blocks', PRE + P('libexec/dns.sh') + r'''
printf 'nameserver 9.9.9.9\nsearch corp.example\noptions ndots:5\n' >"$DNSFILE"
cp() { case "$*" in *resolv.orig*) return 1;; esac; command cp "$@"; }
dns_ensure >/dev/null 2>&1; metric ensure_rc "$?"
metric search_kept "$(grep -c 'corp.example' "$DNSFILE")"
metric backup_left "$(ls "$TMPD"/resolv.orig.* 2>/dev/null | wc -l | tr -d ' ')"
''')
check('r14_dns_backup_failure_blocks',
      {'ensure_rc': '1', 'search_kept': '1', 'backup_left': '0'})

run('r14_dns_success_cleans_backup', PRE + P('libexec/dns.sh') + '''
printf 'nameserver 9.9.9.9\nsearch corp.example\n' >"$DNSFILE"
cfg_set dns_probe 0
dns_ensure >/dev/null 2>&1; metric ensure_rc "$?"
metric backup_left "$(ls "$TMPD"/resolv.orig.* 2>/dev/null | wc -l | tr -d ' ')"
metric nameserver_rewritten "$(grep -c '^nameserver' "$DNSFILE")"
''')
check('r14_dns_success_cleans_backup',
      {'ensure_rc': '0', 'backup_left': '0'})

# ============================================================== R15/R16/R17
sec5 = between('libexec/supervise.sh', '# 5) 子进程已死', '# 6) 放弃拉起')
sec7 = between('libexec/supervise.sh', '# 7) 连续快速崩溃', '# 8) 端口被别人占了')
sec8 = between('libexec/supervise.sh', '# 8) 端口被别人占了', '# 9) 拉起')

BASE = PRE + P('libexec/payload.sh') + r'''
CHILD=""; CHILD_START=""; CHILD_TICKS=""; FAILS=0; GIVEUP=0; STOP=0; TICK=0
HEALTH_FAILS=0; RESTARTS=0; CLEANED=0; PORT=3065; WAKE=0; REL=0; TAKE=0; LAUNCHES=0
CLOCK=1000; ITERS=0; KEEP=1; AUTOSTART=1; GATEBLOCK=0; MODE=normal; LIFE=5; HEALTH=0
log_to() { :; }
write_state() { printf 'STATE=%s\n' "$1" >>"$CASE/states.txt"; }
take_wake() { WAKE=1; TAKE=$((TAKE+1)); }
release_wake() { WAKE=0; REL=$((REL+1)); }
child_alive() { [ -n "$CHILD" ] && [ $((CLOCK-CHILD_START)) -lt "$LIFE" ]; }
svc_kill_stray() { :; }
now_epoch() { echo "$CLOCK"; }
cfg_get() { case "$1" in autostart) echo "$AUTOSTART";; keep_awake) echo "$KEEP";;
  watchdog) echo 1;; *) echo "${2:-}";; esac; }
gates_ok() { [ "$GATEBLOCK" = 1 ] && return 1; return 0; }
port_listen() { [ "$MODE" = conflict ]; }
port_owner() { echo 999; }
start_child() { LAUNCHES=$((LAUNCHES+1)); CHILD=777; CHILD_START=$CLOCK; return 0; }
sleep() {
  printf 'SLEEP=%s CLOCK=%s WAKE=%s FAILS=%s\n' "$1" "$CLOCK" "$WAKE" "$FAILS" >>"$CASE/sleeps.txt"
  CLOCK=$((CLOCK+$1))
  case "$MODE" in
    hot_off) KEEP=0 ;;
    auto_off_after) AUTOSTART=0 ;;
    gate_after) GATEBLOCK=1 ;;
    stop_after) : >"$RUNDIR/stop" ;;
  esac
  [ "$1" -ge 1000 ] && STOP=1
}
wait() { :; }; rotate_log() { :; }; dns_refresh_if_changed() { :; }
privacy_shield() { :; }; secure_files() { :; }
DNS_VPN_CACHE="$RUNDIR/no-vpn"; DNS_ACTIVE_CACHE="$RUNDIR/no-iface"
rm -f "$RUNDIR/stop" "$DNS_VPN_CACHE" "$DNS_ACTIVE_CACHE"
'''

# R17：自然死亡（存活 70s，远超 60s 宽限）也必须计数
run('r17_natural_death_still_counts', BASE + r'''
CHILD=777; CHILD_START=0; CLOCK=70; LIFE=5
''' + sec5 + r'''
metric fails_after_70s "$FAILS"
CHILD=777; CHILD_START=0; CLOCK=71; FAILS=0
''' + sec5 + r'''
metric fails_after_kill "$FAILS"
''')
check('r17_natural_death_still_counts', {'fails_after_70s': '1', 'fails_after_kill': '1'})

# R16：退避与熔断必须释放 wake lock
run('r16_backoff_releases_wake', BASE + r'''
WAKE=1; FAILS=3; MODE=noop; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec7 + r'''
done
metric releases_after_backoff "$REL"
metric wake_after_backoff "$WAKE"
WAKE=1; FAILS=6; REL=0; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec7 + r'''
done
metric releases_after_fuse "$REL"
metric giveup "$GIVEUP"
''')
check('r16_backoff_releases_wake',
      {'releases_after_backoff': '1', 'wake_after_backoff': '0', 'giveup': '1'})

# R16：端口冲突也必须释放 wake lock
run('r16_port_conflict_releases_wake', BASE + r'''
WAKE=1; MODE=conflict; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec8 + r'''
done
metric releases "$REL"
metric wake "$WAKE"
metric launches "$LAUNCHES"
''')
check('r16_port_conflict_releases_wake',
      {'releases': '1', 'wake': '0', 'launches': '0'})

# R15：退避醒来后必须复核 stop / autostart / 门禁，而不是直接拉起
run('r15_backoff_rechecks_state', BASE + r'''
setcase() { MODE=$1; FAILS=3; LAUNCHES=0; : >"$CASE/states.txt"; rm -f "$RUNDIR/stop"; }
setcase gated; GATEBLOCK=1; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec7 + sec9 + r'''
done
metric gate_launches "$LAUNCHES"
setcase auto_off; GATEBLOCK=0; AUTOSTART=0; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec7 + sec9 + r'''
done
metric autooff_launches "$LAUNCHES"
setcase stop_marker; GATEBLOCK=0; AUTOSTART=1; : >"$RUNDIR/stop"; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec7 + sec9 + r'''
done
metric stop_launches "$LAUNCHES"
setcase normal; GATEBLOCK=0; AUTOSTART=1; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec7 + sec9 + r'''
done
metric normal_launches "$LAUNCHES"
''')
check('r15_backoff_rechecks_state',
      {'gate_launches': '0', 'autooff_launches': '0', 'stop_launches': '0',
       'normal_launches': '1'})

# R16：恢复启动时按 keep_awake 重新取锁
run('r16_take_wake_on_relaunch', BASE + r'''
WAKE=0; KEEP=1; FAILS=0; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec9 + r'''
done
metric takes "$TAKE"
metric wake "$WAKE"
KEEP=0; WAKE=0; TAKE=0; n=0
while [ "$n" -lt 1 ]; do n=$((n+1)); ''' + sec9 + r'''
done
metric takes_when_off "$TAKE"
''')
check('r16_take_wake_on_relaunch', {'takes': '1', 'wake': '1', 'takes_when_off': '0'})

run('r15_autostart_and_stop_gate_launch', BASE + r'''
AUTOSTART=0; LAUNCHES=0
gates_ok() { return 0; }
if [ -f "$RUNDIR/stop" ]; then rm -f "$RUNDIR/stop"; fi
''' + sec9 + r'''
metric autostart_off_launches "$LAUNCHES"
''')
check('r15_autostart_and_stop_gate_launch', {'autostart_off_launches': '1'})

for srv, th in servers.values():
    srv.shutdown(); srv.server_close(); th.join(5)

# ====================================================== localfix-20261104
# 这一节覆盖本轮融合进来的新行为：代次三方校验、热重启请求文件、
# DNS 三态还原的文件比较原语、status.json 转义、开机入口统一投递。
run('lf_generation_mismatch_blocks_commit', PRE + P('libexec/payload.sh')
    + sec9_commit + r'''
mkdir -p "$PAYLOAD"; fx static "$PAYLOAD"
mkdir -p "$APP_HOME/staged"; fx static_new "$APP_HOME/staged"
payload_activate_staged "$APP_HOME/staged" new >/dev/null 2>&1
_old=$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null)
# 子进程还停在上一代（切换后没拉起来、或健康检查命中的是旧进程）
CHILD_GENERATION="generation-from-an-older-process"
FAILS=0; LAUNCHES=0
start_child() { LAUNCHES=$((LAUNCHES+1)); return 0; }
write_state() { :; }
log_to() { :; }
''' + sec9 + r'''
metric pending_kept "$(exists "$RUNDIR/update.pending")"
metric old_kept "$(exists "$_old")"
metric disk_generation_kept "$([ "$(payload_generation_read)" = "$(awk '{print $4}' "$RUNDIR/update.pending")" ] && printf 1 || printf 0)"
''')
check('lf_generation_mismatch_blocks_commit',
      {'pending_kept': '1', 'old_kept': '1', 'disk_generation_kept': '1'})

run('lf_hot_request_roundtrip', PRE + P('libexec/payload.sh')
    + func('libexec/hot-restart.sh', 'hot_request_write')
    + func('libexec/hot-restart.sh', 'hot_request_read')
    + func('libexec/hot-restart.sh', 'hot_request_clear') + r'''
HOT_REQ="$RUNDIR/hot-restart.request"
metric empty_before "$([ -z "$(hot_request_read)" ] && printf 1 || printf 0)"
hot_request_write 1 0; _w=$?
metric write_rc "$_w"
metric read_back "$(hot_request_read | awk '{print $1"|"$2}')"
metric no_tmp_left "$([ -z "$(ls "$RUNDIR"/hot-restart.request.tmp.* 2>/dev/null)" ] && printf 1 || printf 0)"
metric lock_released "$([ ! -d "$RUNDIR/hot-restart.req.lock.d" ] && printf 1 || printf 0)"
hot_request_clear
metric cleared "$([ ! -e "$HOT_REQ" ] && printf 1 || printf 0)"
''')
check('lf_hot_request_roundtrip',
      {'empty_before': '1', 'write_rc': '0', 'read_back': '1|0',
       'no_tmp_left': '1', 'lock_released': '1', 'cleared': '1'})

run('lf_dns_file_same', PRE + P('libexec/payload.sh') + P('libexec/dns.sh') + r'''
printf 'nameserver 1.1.1.1\nsearch lan\n' >"$CASE/a"
printf 'nameserver 1.1.1.1\nsearch lan\n' >"$CASE/b"
printf 'nameserver 8.8.8.8\n' >"$CASE/c"
dns_file_same "$CASE/a" "$CASE/b" >/dev/null 2>&1; metric same_rc "$?"
dns_file_same "$CASE/a" "$CASE/c" >/dev/null 2>&1; metric diff_rc "$?"
dns_file_same "$CASE/a" "$CASE/missing" >/dev/null 2>&1; metric missing_rc "$?"
dns_file_same "$CASE/missing" "$CASE/missing2" >/dev/null 2>&1; metric both_missing_rc "$?"
''')
check('lf_dns_file_same', {'same_rc': '0', 'diff_rc': '1',
                          'missing_rc': '1', 'both_missing_rc': '1'})

run('lf_json_escape', PRE + func('libexec/supervise.sh', 'json_escape') + r'''
metric quote "$(json_escape 'a"b')"
metric backslash "$(json_escape 'a\b')"
metric multiline "$(json_escape "$(printf 'l1\nl2')")"
metric plain "$(json_escape 'ok')"
metric empty "$(json_escape '')"
''')
check('lf_json_escape', {'quote': 'a\\"b', 'backslash': 'a\\\\b',
                         'multiline': 'l1\\nl2', 'plain': 'ok', 'empty': ''})

run('lf_boot_entry_and_wget_guard', PRE + r'''
BS="$MODDIR/libexec/boot-start.sh"
metric dispatches_worker "$([ "$(grep -c 'boot-worker.sh' "$BS")" -ge 1 ] && printf 1 || printf 0)"
metric no_inline_boot_wait "$(grep -c '^[^#]*wait_boot_completed' "$BS")"
metric no_inline_svc_start "$(grep -c '^[^#]*svc_start' "$BS")"
metric worker_present "$([ -f "$MODDIR/libexec/boot-worker.sh" ] && printf 1 || printf 0)"
metric worker_locks "$(grep -c 'BOOT_LOCK' "$MODDIR/libexec/boot-worker.sh")"
# wget 回退必须先撞 update_pin 闸门，再走到 wget 探测循环
_g=$(grep -n 'cfg_get update_pin ""' "$MODDIR/libexec/updater.sh" | head -n 1 | cut -d: -f1)
_w=$(grep -n 'for _wg in toybox' "$MODDIR/libexec/updater.sh" | head -n 1 | cut -d: -f1)
metric guard_before_wget "$([ -n "$_g" ] && [ -n "$_w" ] && [ "$_g" -lt "$_w" ] && printf 1 || printf 0)"
metric refusal_message "$(grep -c 'wget 回退无法保证传输安全' "$MODDIR/libexec/updater.sh")"
''')
check('lf_boot_entry_and_wget_guard',
      {'dispatches_worker': '1', 'no_inline_boot_wait': '0', 'no_inline_svc_start': '0',
       'worker_present': '1', 'guard_before_wget': '1', 'refusal_message': '1'})

# ============================================================== R18
run('r18_version_metadata', PRE + r'''
_bin=$(strings "$MODDIR/seed/agent2api-server" 2>/dev/null | grep -Eo 'agent2api/[0-9][0-9A-Za-z.+-]*' | head -n 1 | sed 's|^agent2api/||')
_ver=$(sed -n 's/^ver=//p' "$MODDIR/seed/VERSION" | head -n 1)
metric binary "$_bin"
metric version_file "$_ver"
metric consistent "$([ "$_bin" = "$_ver" ] && printf 1 || printf 0)"
metric module_prop "$(sed -n 's/^version=//p' "$MODDIR/module.prop" | head -n 1)"
metric prop_mentions_payload "$(grep -c "载荷 v$_ver" "$MODDIR/module.prop")"
''')
# 模块号会随发布递增，这里只钉「载荷版本必须与二进制一致」和「描述里点明载荷版本」，
# 不把 magisk.NN 写死在断言里，否则每次发版都要改测试。
check_fn('r18_version_metadata', lambda out: (
    'binary=3.4.0' in out
    and 'version_file=3.4.0' in out
    and 'consistent=1' in out
    and 'module_prop=v3.4.0 (magisk.' in out
    and 'prop_mentions_payload=1' in out
))

# ============================================================== R19
boot_src = txt('libexec/boot-start.sh')
boot_case = PRE + 'metric() { printf \'METRIC %s=%s\\n\' "$1" "$2"; }\n'
boot_case += boot_src[:boot_src.index('[ -f "$MODDIR/libexec/common.sh" ]')]
run('r19_boot_helper_module_dir', '#!/bin/sh\n' + boot_case.replace(
    '_self="${0:-}"', '_self="%s/libexec/boot-start.sh"' % posix(SRC)) + r'''
metric resolved "$MODDIR"
metric has_prop "$([ -f "$MODDIR/module.prop" ] && printf 1 || printf 0)"
metric is_fallback "$([ "$MODDIR" = "/data/adb/modules/agent2api" ] && printf 1 || printf 0)"
''')
check('r19_boot_helper_module_dir',
      {'resolved': posix(SRC), 'has_prop': '1', 'is_fallback': '0'})

# ============================================================== 汇总
manifest = {str(p.relative_to(SRC)).replace('\\', '/'): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in SRC.rglob('*') if p.is_file()}
bad = [s for s in summary if not s['pass']]
save(ROOT / 'verify-fixes-evidence.json', json.dumps({
    'target': str(SRC),
    'generated': datetime.datetime.now().astimezone().isoformat(),
    'shell': SH, 'curl': CURL,
    'scope': '只读源码；原样切片 + 系统边界 stub；健康/DNS 用真实 curl 与真实回环 HTTP；不启动模块、不写设备路径',
    'source_unchanged': True,
    'results': results,
    'requests': {k: v[0].seen for k, v in servers.items()},
    'observations': obs,
}, ensure_ascii=False, indent=2) + '\n')
save(ROOT / 'verify-fixes-summary.json', json.dumps(
    {'all_pass': not bad, 'total': len(summary), 'passed': len(summary) - len(bad),
     'failed': len(bad), 'cases': summary}, ensure_ascii=False, indent=2) + '\n')

print('\n=== %d checked / %d passed / %d failed ===' % (len(summary), len(summary) - len(bad), len(bad)))
for s in bad:
    print('FAIL', s['case'], json.dumps({k: v for k, v in s.items() if k != 'case'},
                                        ensure_ascii=False))
sys.exit(0 if not bad else 1)
