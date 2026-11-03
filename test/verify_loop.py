# -*- coding: utf-8 -*-
"""主循环集成复验：把 supervise.sh 的 while 主循环整段抽出来，配上虚拟时钟与
操作系统边界 stub，验证 R01/R15/R16/R17 在「真实循环结构」下的行为。

不做函数级打桩替代循环，循环体本身是源码原文。
"""
import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(os.environ.get('A2A_VERIFY_OUT') or (Path(__file__).resolve().parent / 'out'))
SRC = Path(os.environ.get('A2A_MODULE') or (Path(__file__).resolve().parent.parent / 'module'))
BIN = Path(r'C:/Users/Y-H/.dsh/profiles/desktop/node_modules/@dsh-ops/bash-win32-x64/usr/bin')
SH = os.environ.get('A2A_SH') or str(BIN / 'sh.exe')
ROOT.mkdir(parents=True, exist_ok=True)
results, summary = {}, []


def posix(p):
    s = str(p).replace('\\', '/')
    return '/' + s[0].lower() + s[2:]


def save(p, d):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(d.encode('utf-8') if isinstance(d, str) else d)
    return p


def kl(rel):
    return (SRC / rel).read_text(encoding='utf-8').splitlines(keepends=True)


def find(rel, needle, start=1):
    for i, ln in enumerate(kl(rel), 1):
        if i >= start and needle in ln:
            return i
    raise SystemExit('anchor: %r' % needle)


L = kl('libexec/supervise.sh')
i_defs = find('libexec/supervise.sh', 'payload_ver()')
i_loop = find('libexec/supervise.sh', 'while [ "$STOP" = "0" ]; do')
i_done = find('libexec/supervise.sh', 'cleanup', find('libexec/supervise.sh', 'done', i_loop))
# 只取 payload_ver / child_alive / write_state；stop_child、start_child、cleanup、
# on_signal 由本脚本自己 stub，避免把真实 launch.sh 拉起来。
DEFS = ''.join(L[i_defs - 1:find('libexec/supervise.sh', 'status_json_write() {') - 2])
LOOP = ''.join(L[i_loop - 1:i_done])          # while ... done
PRE_LOOP = ''.join(L[find('libexec/supervise.sh', '# 启动前准备') - 1:i_loop - 1])

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
PORT=3065
mkdir -p "$RUNDIR" "$LOGDIR" "$TMPD" "$BACKUPDIR" "$A2A_LIVE" "$CFGDIR" "$DATADIR" "$BINDIR"
: >"$SETTINGS"
metric() {{ printf 'METRIC %s=%s\\n' "$1" "$2"; }}
exists() {{ [ -e "$1" ] && printf 1 || printf 0; }}
fx() {{ cp -R "{posix(ROOT)}/fixtures/$1/." "$2"; }}
'''

STUBS = r'''
log_to() { :; }
dns_ensure() { :; }; nss_apply() { :; }; gai_apply() { :; }
live_link_refresh() { :; }; cgroup_escape() { :; }; payload_recover_interrupted() { :; }
write_state() { printf '%s\n' "$1" >>"$CASE/states.txt"; }
take_wake() { WAKE=1; TAKES=$((TAKES+1)); }
release_wake() { WAKE=0; RELEASES=$((RELEASES+1)); }
cfg_get() { case "$1" in
  autostart) printf '%s' "$AUTOSTART";; keep_awake) printf '%s' "$KEEP";;
  watchdog) printf 1;; log_max_kb) printf 8192;; port) printf 3065;;
  *) printf '%s' "${2:-}";; esac; }
gates_ok() { [ "$GATES_BLOCKED" = "1" ] && return 1; return 0; }
port_listen() { [ "$PORT_BUSY" = "1" ]; }
port_owner() { printf 4242; }
svc_http_health() { return "$HEALTH"; }
dns_vpn_active() { return 1; }; dns_default_iface() { :; }
dns_refresh_if_changed() { :; }; privacy_shield() { :; }; secure_files() { :; }
rotate_log() { :; }; svc_kill_stray() { :; }; wait() { :; }
module_desc_set() { :; }; status_json_write() { :; }
payload_ver() { printf 'v1'; }
panel_port_effective() { printf 3065; }
now_epoch() { printf '%s' "$CLOCK"; }
child_alive() { [ -n "$CHILD" ] && [ $((CLOCK - CHILD_START)) -lt "$LIFE" ]; }
start_child() {
  LAUNCHES=$((LAUNCHES+1))
  printf 'LAUNCH t=%s autostart=%s gates=%s wake=%s\n' "$CLOCK" "$AUTOSTART" "$GATES_BLOCKED" "$WAKE" >>"$CASE/events.txt"
  CHILD=9001; CHILD_START=$CLOCK; CHILD_TICKS=1
  if [ "$HEALTH" = "1" ] && [ "$CLOCK" != "0" ]; then FAILS=$((FAILS+1)); return 1; fi
  return 0
}
stop_child() { CHILD=""; CHILD_START=""; CHILD_TICKS=""; return 0; }
cleanup() {
  release_wake
  printf 'FINAL fails=%s giveup=%s launches=%s releases=%s takes=%s clock=%s\n' \
    "$FAILS" "$GIVEUP" "$LAUNCHES" "$RELEASES" "$TAKES" "$CLOCK"
}
sleep() {
  printf 'SLEEP t=%s dur=%s wake=%s fails=%s giveup=%s\n' "$CLOCK" "$1" "$WAKE" "$FAILS" "$GIVEUP" >>"$CASE/events.txt"
  CLOCK=$((CLOCK + $1))
  case "$MODE" in
    hot_off) KEEP=0 ;;
    backoff_auto_off) [ "$1" -ge 90 ] && AUTOSTART=0 ;;
    backoff_gate) [ "$1" -ge 90 ] && GATES_BLOCKED=1 ;;
    backoff_stop) [ "$1" -ge 90 ] && : >"$RUNDIR/stop" ;;
  esac
  [ "$CLOCK" -ge "$LIMIT" ] && STOP=1
}
DEFAULT_STOP=0
'''

SCN = {
    # 5s 一次崩溃，退避 90/120/150/180/210/240 后熔断
    'fast_crash_fuse': 'LIFE=5; LIMIT=6000; HEALTH=0',
    # 存活 70s 后自然死亡：旧实现会清零，R17 之后必须计数直到熔断
    'natural_death_70s': 'LIFE=70; LIMIT=6000; HEALTH=1',
    # 退避期间 keep_awake 关掉：必须释放锁，且重启前按新值决定是否再取
    'backoff_keepawake_off': 'LIFE=5; LIMIT=600; MODE=hot_off',
    # 退避醒来时 autostart 已关：不能继续拉起
    'backoff_autostart_off': 'LIFE=5; LIMIT=600; MODE=backoff_auto_off',
    # 退避醒来时门限不满足：不能拉起
    'backoff_gate_blocked': 'LIFE=5; LIMIT=600; MODE=backoff_gate',
    # 退避醒来时出现 stop 标记：必须退出循环
    'backoff_stop_marker': 'LIFE=5; LIMIT=600; MODE=backoff_stop',
    # 端口长期被占：只报告，不拉起，也不持锁
    'port_conflict_holds': 'LIFE=5; LIMIT=200; PORT_BUSY=1; HEALTH=1',
}


def run(name, cfg):
    case_dir = ROOT / 'cases' / name
    case_dir.mkdir(parents=True, exist_ok=True)
    body = PRE + '\nCHILD=""; CHILD_START=""; CHILD_TICKS=""; FAILS=0; GIVEUP=0\n' \
        'STOP=0; TICK=0; HEALTH_FAILS=0; RESTARTS=0; CLEANED=0; CLOCK=0\n' \
        'WAKE=0; RELEASES=0; TAKES=0; LAUNCHES=0; KEEP=1; AUTOSTART=1\n' \
        'GATES_BLOCKED=0; PORT_BUSY=0; MODE=normal\n' + STUBS + DEFS + '\n' + cfg + '\n' \
        + PRE_LOOP + '\n' + LOOP + '\ncleanup\n'
    pth = save(ROOT / 'cases' / (name + '.sh'), body)
    env = dict(os.environ, CASE=posix(case_dir),
               TMP=posix(ROOT / 'tmp'), TMPDIR=posix(ROOT / 'tmp'), TEMP=posix(ROOT / 'tmp'))
    (ROOT / 'tmp').mkdir(parents=True, exist_ok=True)
    p = subprocess.run([SH, posix(pth)], capture_output=True, timeout=120, env=env)
    out = p.stdout.decode('utf-8', 'replace')
    err = p.stderr.decode('utf-8', 'replace')
    ev = (case_dir / 'events.txt').read_text(encoding='utf-8') if (case_dir / 'events.txt').exists() else ''
    st = (case_dir / 'states.txt').read_text(encoding='utf-8') if (case_dir / 'states.txt').exists() else ''
    final = [l for l in out.splitlines() if l.startswith('FINAL ')]
    results[name] = {'rc': p.returncode, 'final': final, 'events': ev, 'states': st,
                     'stderr': err, 'script': str(pth)}
    print('%-28s rc=%-3s %s' % (name, p.returncode, final[0] if final else '(no FINAL)'))
    if err.strip():
        print('   stderr:', err.strip().splitlines()[-3:])
    return results[name]


for n, c in SCN.items():
    run(n, c)


def parse(txt, key):
    for tok in txt.split():
        if '=' in tok and tok.split('=', 1)[0].lstrip('FINAL ') == key:
            return tok.split('=', 1)[1]
    return None


r = results['fast_crash_fuse']
summary.append({'case': 'fast_crash_fuse', 'pass': bool(r['final']) and 'giveup=1' in r['final'][0]
                and 'fails=6' in r['final'][0], 'final': r['final']})
r = results['natural_death_70s']
summary.append({'case': 'natural_death_70s',
                'pass': bool(r['final']) and 'giveup=1' in r['final'][0],
                'final': r['final'],
                'note': '70s 自然死亡不再清零 FAILS，最终熔断'})
r = results['backoff_keepawake_off']
summary.append({'case': 'backoff_keepawake_off',
                'pass': bool(r['final']) and 'releases=0' not in r['final'][0],
                'final': r['final']})
def no_launch_after_backoff(ev):
    """退避（sleep>=90）之后不应再出现 LAUNCH。"""
    t_back = None
    for ln in ev.splitlines():
        if ln.startswith('SLEEP') and 'dur=' in ln:
            dur = int(ln.split('dur=')[1].split()[0])
            if dur >= 90:
                t_back = int(ln.split('t=')[1].split()[0])
                break
    if t_back is None:
        return False
    for ln in ev.splitlines():
        if ln.startswith('LAUNCH'):
            if int(ln.split('t=')[1].split()[0]) > t_back:
                return False
    return True


r = results['backoff_autostart_off']
summary.append({'case': 'backoff_autostart_off', 'pass': no_launch_after_backoff(r['events']),
                'launches_total': r['events'].count('LAUNCH '),
                'states': r['states'].strip().splitlines()[-3:]})
r = results['backoff_gate_blocked']
summary.append({'case': 'backoff_gate_blocked', 'pass': no_launch_after_backoff(r['events']),
                'launches_total': r['events'].count('LAUNCH '),
                'states': r['states'].strip().splitlines()[-3:]})
r = results['port_conflict_holds']
summary.append({'case': 'port_conflict_holds',
                'pass': 'LAUNCH' not in r['events'],
                'events_tail': r['events'].strip().splitlines()[-4:]})


def backoff_sleep_released(ev):
    """所有 >=90s 的退避 sleep 记录里 wake=0（锁已释放）。"""
    n = 0
    for ln in ev.splitlines():
        if ln.startswith('SLEEP') and 'dur=' in ln:
            dur = int(ln.split('dur=')[1].split()[0])
            if dur >= 90:
                n += 1
                if 'wake=0' not in ln:
                    return False
    return n > 0


summary.append({'case': 'backoff_sleep_releases_wake',
                'pass': backoff_sleep_released(results['fast_crash_fuse']['events']),
                'note': '熔断前的每一次退避 sleep 都不持 wake lock'})

r = results['backoff_stop_marker']
summary.append({'case': 'backoff_stop_marker', 'pass': no_launch_after_backoff(r['events']),
                'final': r['final']})

bad = [s for s in summary if not s['pass']]
save(ROOT / 'loop-evidence.json', json.dumps(
    {'target': str(SRC), 'generated': datetime.datetime.now().astimezone().isoformat(),
     'note': 'while 主循环为源码原文，仅替换 OS 边界与虚拟时钟', 'results': results},
    ensure_ascii=False, indent=2) + '\n')
save(ROOT / 'loop-summary.json', json.dumps(
    {'all_pass': not bad, 'total': len(summary), 'failed': len(bad), 'cases': summary},
    ensure_ascii=False, indent=2) + '\n')
print('\n=== %d checked / %d passed / %d failed ===' % (len(summary), len(summary) - len(bad), len(bad)))
for s in bad:
    print('FAIL', json.dumps(s, ensure_ascii=False)[:600])
sys.exit(0 if not bad else 1)
