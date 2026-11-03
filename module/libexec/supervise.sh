#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · 守护进程（supervisor）
#
# 为什么需要它，而不是在 service.sh 里直接跑服务端：
#   1) Magisk 的 service.sh 是阻塞执行的，脚本不返回会拖慢 boot，甚至被判定
#      为"服务卡死"；所以 service.sh 只负责把我 detach 出去就退。
#   2) 手机上进程被杀是常态（lmkd / 省电策略 / 用户清理后台），必须有拉起。
#   3) 网络会切换（Wi-Fi ↔ 移动网络），DNS 会变，resolv.conf 要跟着变。
#   4) 崩溃要退避，不能 1 秒崩一次把电池烧穿 —— 所以有连续崩溃熔断。
#
# 职责：拉起、看护、按门限暂停、崩了退避重试、定期刷新 DNS、写状态文件。
# ============================================================================

A2A_DIR=${A2A_DIR:-$(dirname "$0")}
# source 进交互/测试 shell 时 $0 不是本脚本；已知 MODDIR 优先定位真实库目录。
if [ -n "${MODDIR:-}" ] && [ -f "$MODDIR/libexec/common.sh" ]; then
  A2A_DIR="$MODDIR/libexec"
fi
if [ "${A2A_COMMON_LOADED:-0}" != "1" ]; then
  . "$A2A_DIR/common.sh"
fi
. "$A2A_DIR/dns.sh"
. "$A2A_DIR/payload.sh"
. "$A2A_DIR/plugin.sh"
. "$A2A_DIR/control.sh"

supervise_main() {
ensure_layout
payload_recover_interrupted
secure_files

PORT=$(port_normalize "$(cfg_get port 3065)") || {
  log_to "$SUPLOG" "非法代理端口配置，守护进程回退到 3065"
  PORT=3065
}

LOCKDIR="$RUNDIR/lock"

# ---------------------------------------------------------------------------
# 单实例：pidfile + mkdir 原子锁
# （只看 pidfile 会踩 PID 复用的坑，所以再核一次 cmdline）
# ---------------------------------------------------------------------------
is_supervisor_pid() { pid_is_supervisor "$1"; }

_supervise_lock_acquire() {
  _sul_outer_token=${UPDATE_LOCK_TOKEN:-}
  _sul_outer_path=${UPDATE_LOCK_PATH:-}
  # 与安装/更新共用经过并发回归的原子 owner + 回收互斥实现；不另造
  # “检查后 rm”锁，避免两个 stale 回收者误删新一代 owner。
  _sul_seen=$(cat "$LOCKDIR/owner" 2>/dev/null) || _sul_seen=""
  _sul_pid=$(printf '%s\n' "$_sul_seen" | awk '{print $1}')
  _sul_ticks=$(printf '%s\n' "$_sul_seen" | awk '{print $2}')
  if [ -n "$_sul_pid" ] && [ -n "$_sul_ticks" ] && pid_alive "$_sul_pid" \
     && [ "$(proc_start_ticks "$_sul_pid" 2>/dev/null)" = "$_sul_ticks" ]; then
    log_to "$SUPLOG" "守护进程已在运行（pid=$_sul_pid），本次不重复启动"
    return 2
  fi
  update_lock_acquire "$LOCKDIR" 20
  _sul_rc=$?
  if [ "$_sul_rc" -ne 0 ]; then
    _sul_seen=$(cat "$LOCKDIR/owner" 2>/dev/null) || _sul_seen=""
    _sul_pid=$(printf '%s\n' "$_sul_seen" | awk '{print $1}')
    _sul_ticks=$(printf '%s\n' "$_sul_seen" | awk '{print $2}')
    if [ -n "$_sul_pid" ] && [ -n "$_sul_ticks" ] && pid_alive "$_sul_pid" \
       && [ "$(proc_start_ticks "$_sul_pid" 2>/dev/null)" = "$_sul_ticks" ]; then
      return 2
    fi
    return "$_sul_rc"
  fi
  # owner 是单行 "pid starttime token"；pid 文件必须只写第一个字段。
  # 曾经整行写入：read_pid 会把 token/时间戳里的数字一起拼进来，得到一个
  # 不存在的巨号 PID，导致 svc_is_running / doctor / 热安装全部误判。
  awk '{print $1}' "$LOCKDIR/owner" >"$RUNDIR/supervisor.pid.new" 2>/dev/null || { update_lock_release "$LOCKDIR"; return 1; }
  awk '{print $2}' "$LOCKDIR/owner" >"$RUNDIR/supervisor.start.new" 2>/dev/null || { update_lock_release "$LOCKDIR"; return 1; }
  mv -f "$RUNDIR/supervisor.pid.new" "$RUNDIR/supervisor.pid" 2>/dev/null || { update_lock_release "$LOCKDIR"; return 1; }
  mv -f "$RUNDIR/supervisor.start.new" "$RUNDIR/supervisor.start" 2>/dev/null || { update_lock_release "$LOCKDIR"; return 1; }
  UPDATE_LOCK_TOKEN=$_sul_outer_token
  UPDATE_LOCK_PATH=$_sul_outer_path
  return 0
}

_supervise_lock_acquire
_supervise_lock_rc=$?
if [ "$_supervise_lock_rc" -eq 2 ]; then
  return 0 2>/dev/null || exit 0
elif [ "$_supervise_lock_rc" -ne 0 ]; then
  log_to "$SUPLOG" "无法创建锁目录 $LOCKDIR 或发布守护身份，退出"
  return 1 2>/dev/null || exit 1
fi

# ---------------------------------------------------------------------------
# 状态
# ---------------------------------------------------------------------------
CHILD=""
CHILD_START=""
CHILD_TICKS=""
RESTARTS=0
FAILS=0
STOP=0
TICK=0
GIVEUP=0
CLEANED=0
HEALTH_FAILS=0
LOG_MAX=8192

payload_ver() { sed -n 's/^ver=//p' "$PAYLOAD/VERSION" 2>/dev/null | head -n 1; }

child_alive() {
  [ -n "$CHILD" ] && pid_matches_start "$CHILD" "$CHILD_TICKS"
}

write_state() { # $1=status
  _up=0
  if child_alive; then
    _up=$(proc_uptime "$CHILD" 2>/dev/null)
    case "$_up" in ''|*[!0-9]*) _up=0 ;; esac
  fi
  {
    printf 'status=%s\n' "$1"
    printf 'supervisor_pid=%s\n' "$$"
    printf 'server_pid=%s\n' "${CHILD:-}"
    printf 'uptime=%s\n' "$_up"
    printf 'restarts=%s\n' "$RESTARTS"
    printf 'fails=%s\n' "$FAILS"
    printf 'port=%s\n' "$PORT"
    printf 'version=%s\n' "$(payload_ver)"
    printf 'ts=%s\n' "$(now_epoch)"
  } >"$RUNDIR/state.new" 2>/dev/null && mv -f "$RUNDIR/state.new" "$RUNDIR/state" 2>/dev/null
  status_json_write "$1"
  _ds="运行中"
  case "$1" in
    stopped|dead) _ds="已停止" ;;
    disabled) _ds="已禁用" ;;
    paused) _ds="已暂停" ;;
    backoff) _ds="退避中" ;;
    running-unverified) _ds="运行中(未验证)" ;;
    port-conflict) _ds="端口冲突" ;;
    starting-unhealthy) _ds="启动中" ;;
  esac
  module_desc_set "$_ds · 端口 ${PORT:-?} · 载荷 $(payload_ver) · 面板 $(panel_port_effective 2>/dev/null)"
}

status_json_write() { # $1=status；把运行态落到 webroot/status.json，KSU 卡片可静态读
  _wj="$MODDIR/webroot/status.json"
  [ -d "$MODDIR/webroot" ] || return 0
  _pp=$(panel_port_effective 2>/dev/null) || _pp="$PORT"
  _tmp="$RUNDIR/status.json.$$"
  cat <<EOF >"$_tmp" 2>/dev/null
{"status":"$1","supervisor_pid":$$,"server_pid":${CHILD:-0},"uptime":${_up:-0},"restarts":${RESTARTS:-0},"fails":${FAILS:-0},"port":${PORT:-0},"panel_port":${_pp:-0},"version":"$(payload_ver)","ts":$(now_epoch)}
EOF
  [ -s "$_tmp" ] || { rm -f "$_tmp" 2>/dev/null; return 0; }
  cmp -s "$_tmp" "$_wj" 2>/dev/null && { rm -f "$_tmp" 2>/dev/null; return 0; }
  chmod 644 "$_tmp" 2>/dev/null
      mv -f "$_tmp" "$_wj" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
      # 顺手落一份日志尾巴：KSU 的 WebUI 页不用 ksu.exec 也能看见"最近在发生什么"。
      _wlog="$MODDIR/webroot/lastlog.txt"
      _ltmp="$RUNDIR/lastlog.txt.$$"
      if tail -n 30 "$SUPLOG" 2>/dev/null >"$_ltmp"; then
        chmod 644 "$_ltmp" 2>/dev/null
        cmp -s "$_ltmp" "$_wlog" 2>/dev/null || mv -f "$_ltmp" "$_wlog" 2>/dev/null
      fi
      rm -f "$_ltmp" 2>/dev/null
      return 0
    }
    

take_wake() {
  [ -w /sys/power/wake_lock ] && echo 'agent2api' >/sys/power/wake_lock 2>/dev/null
  return 0
}
release_wake() {
  [ -w /sys/power/wake_unlock ] && echo 'agent2api' >/sys/power/wake_unlock 2>/dev/null
  return 0
}

gates_ok() {
  if [ "$(cfg_get wifi_only 0)" = "1" ] && ! on_wifi; then
    GATE_REASON="wifi_only（当前不在 Wi-Fi）"
    return 1
  fi
  _floor=$(cfg_get battery_floor 0)
  case "$_floor" in ''|*[!0-9]*) _floor=0 ;; esac
  if [ "$_floor" -gt 0 ] && ! is_charging; then
    _lvl=$(battery_level 2>/dev/null)
    case "$_lvl" in ''|*[!0-9]*) _lvl=100 ;; esac
    if [ "$_lvl" -lt "$_floor" ]; then
      GATE_REASON="battery_floor（电量 ${_lvl}% < ${_floor}% 且未充电）"
      return 1
    fi
  fi
  GATE_REASON=""
  return 0
}

stop_child() {
  _sc_pid=$CHILD
  _sc_ticks=$CHILD_TICKS
  # 身份文件必须最后删。先删再杀，一旦杀不掉，外部就再也认不出这个进程，
  # 只剩 cmdline 猜测（可能误杀同名进程），"保留 PID/启动代次"的日志也是假的。
  if ! child_alive; then
    rm -f "$RUNDIR/server.pid" "$RUNDIR/server.start" 2>/dev/null
    [ -z "$_sc_pid" ] || wait "$_sc_pid" 2>/dev/null
    CHILD=""
    CHILD_START=""
    CHILD_TICKS=""
    return 0
  fi
  log_to "$SUPLOG" "停止服务端 pid=$_sc_pid（SIGTERM，等它自己收尾）"
  kill -TERM "$_sc_pid" 2>/dev/null
  _i=0
  while [ "$_i" -lt 20 ]; do
    child_alive || break
    sleep 1
    _i=$((_i + 1))
  done
  if child_alive; then
    log_to "$SUPLOG" "20s 内没退出，SIGKILL"
    kill -KILL "$_sc_pid" 2>/dev/null
    _i=0
    while [ "$_i" -lt 3 ] && child_alive; do
      sleep 1
      _i=$((_i + 1))
    done
  fi
  if child_alive; then
    log_to "$SUPLOG" "服务端仍存活，保留 PID/启动代次，拒绝清理后重复拉起"
    return 1
  fi
  [ -z "$_sc_pid" ] || wait "$_sc_pid" 2>/dev/null
  # 确认进程身份已经消失，才允许删身份文件。
  rm -f "$RUNDIR/server.pid" "$RUNDIR/server.start" 2>/dev/null
  CHILD=""
  CHILD_START=""
  CHILD_TICKS=""
  return 0
}

start_child() {
  # 运行时自愈：loader/lib 被弄坏（应用内自更新、误删、残留）时先修再起
  if ! lib_verify 2>/dev/null; then
    log_to "$SUPLOG" "运行时不可用，尝试从快照恢复：$PLIB"
    if lib_restore; then
      log_to "$SUPLOG" "运行时已从快照恢复"
    else
      log_to "$SUPLOG" "运行时恢复失败 —— 请重装模块，或 a2a doctor 看详情"
    fi
  fi

  # 每次拉起前把插件二进制的解释器再修一遍：面板可能刚装了新插件
  plugin_interp_fix

  rotate_log "$SRVLOG" "$LOG_MAX"
  rotate_log "$APPLOG" "$LOG_MAX"
  rotate_log "$SUPLOG" "$LOG_MAX"
  RESTARTS=$((RESTARTS + 1))
  log_to "$SUPLOG" "拉起服务端（第 $RESTARTS 次）"

  "$MODDIR/libexec/launch.sh" >>"$SRVLOG" 2>&1 &
  CHILD=$!
  CHILD_START=$(now_epoch)
  CHILD_TICKS=$(proc_start_ticks "$CHILD" 2>/dev/null)
  printf '%s\n' "$CHILD" >"$RUNDIR/server.pid.new" 2>/dev/null
  mv -f "$RUNDIR/server.pid.new" "$RUNDIR/server.pid" 2>/dev/null
  printf '%s\n' "$CHILD_TICKS" >"$RUNDIR/server.start.new" 2>/dev/null
  mv -f "$RUNDIR/server.start.new" "$RUNDIR/server.start" 2>/dev/null

  # 只有“本模块 PID + 同一 socket + 合法 /health 响应”同时成立才算启动成功。
  if svc_wait_health 40; then
    log_to "$SUPLOG" "服务端健康检查通过：port=$PORT pid=$CHILD"
    HEALTH_FAILS=0
    return 0
  fi
  # 启动健康失败与自然快速退出进入同一退避/熔断计数。
  # 若进程还活着，先停止它；否则下一轮会被 child_alive 分支接管。
  FAILS=$((FAILS + 1))
  if child_alive; then
    log_to "$SUPLOG" "进程在，但 40s 内未通过进程/端口/HTTP 联合健康检查"
    stop_child || log_to "$SUPLOG" "启动失败后无法停止残留服务端"
  else
    log_to "$SUPLOG" "服务端启动后立即退出，详见 $SRVLOG"
    [ -z "$CHILD" ] || wait "$CHILD" 2>/dev/null
    CHILD=""
    CHILD_START=""
    CHILD_TICKS=""
  fi
  return 1
}

cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  stop_child
  release_wake
  # 停止失败时保留身份与锁，svc_stop 才能发现并复核旧实例。
  if [ -n "$CHILD" ] && child_alive; then
    log_to "$SUPLOG" "守护退出收尾失败：服务端仍存活，保留实例身份"
    return 1
  fi
  rm -f "$RUNDIR/server.pid" "$RUNDIR/server.start" 2>/dev/null
  UPDATE_LOCK_TOKEN=$(awk '{print $3}' "$LOCKDIR/owner" 2>/dev/null) || UPDATE_LOCK_TOKEN=""
  UPDATE_LOCK_PATH=$LOCKDIR
  _clean_rc=0
  update_lock_release "$LOCKDIR" || _clean_rc=1
  UPDATE_LOCK_TOKEN=$_sul_outer_token
  UPDATE_LOCK_PATH=$_sul_outer_path
  if [ "$_clean_rc" -eq 0 ]; then
    rmdir "$LOCKDIR" 2>/dev/null
    rm -f "$RUNDIR/supervisor.pid" "$RUNDIR/supervisor.start" 2>/dev/null
  fi
  write_state stopped
  log_to "$SUPLOG" "守护进程退出"
}

on_signal() {
  STOP=1
  log_to "$SUPLOG" "收到终止信号，准备退出"
  cleanup
  exit 0
}
trap 'on_signal' TERM INT HUP

# ---------------------------------------------------------------------------
# 启动前准备
# ---------------------------------------------------------------------------
log_to "$SUPLOG" "======== 守护进程启动 pid=$$ 端口=$PORT ========"

# cgroup 逃逸：从 app 的 cgroup 里挪出来，避免被 app 的内存限制/冻结连坐
cgroup_escape

# 隐私遮蔽：把上游的 debug/last-request.json 顶成 /dev/null 软链
privacy_shield

dns_ensure
nss_apply
gai_apply
live_link_refresh
[ "$(cfg_get keep_awake 0)" = "1" ] && take_wake
rm -f "$RUNDIR/stop" 2>/dev/null

# ---------------------------------------------------------------------------
# 主循环
# ---------------------------------------------------------------------------
while [ "$STOP" = "0" ]; do
  LOG_MAX=$(cfg_get log_max_kb 8192)
  case "$LOG_MAX" in ''|*[!0-9]*) LOG_MAX=8192 ;; esac
  # 端口每轮重读：control.sh 的健康检查/占用检查永远读 settings.conf，
  # 只在这里读一次会让“改端口后”的端口占用判断和状态文件长期停在旧值。
  _np=$(port_normalize "$(cfg_get port 3065)" 2>/dev/null)
  [ -n "$_np" ] && PORT=$_np

  # 1) 停止标记（a2a stop 会 touch 它）
  if [ -f "$RUNDIR/stop" ]; then
    log_to "$SUPLOG" "收到停止标记"
    rm -f "$RUNDIR/stop" 2>/dev/null
    break
  fi

  # 2) 用户关了自启，且当前没在跑 → 静默待命（开着服务端就继续让它跑完）
  if [ "$(cfg_get autostart 1)" = "0" ] && [ -z "$CHILD" ]; then
    # 待命/暂停/熔断都不是"服务在跑"，必须把 wake lock 放掉，
    # 否则一次 keep_awake 会把这个锁一直攥到进程退出。
    release_wake
    write_state disabled
    sleep 30
    continue
  fi

  # 3) 门限（Wi-Fi / 电量）
  if ! gates_ok; then
    if [ -n "$CHILD" ] && child_alive; then
      log_to "$SUPLOG" "门限不满足：$GATE_REASON → 暂停服务"
      stop_child
    fi
    release_wake
    write_state paused
    sleep 60
    continue
  fi

  # 4) 子进程还活着 → 巡检。运行状态由联合健康检查决定，不只看出进程存在。
  if [ -n "$CHILD" ] && child_alive; then
    if svc_http_health 3; then
      write_state running
    else
      write_state running-unverified
    fi
    _i=0
    # 30 秒节拍必须真的累计，否则 DNS/日志维护会每轮重复执行。
    while [ "$_i" -lt 30 ]; do
      [ -f "$RUNDIR/stop" ] && break
      [ "$STOP" = "1" ] && break
      child_alive || break
      sleep 5
      _i=$((_i + 5))
    done
    TICK=$((TICK + 1))
    # 上游在 Android headless 下不写文件日志（见 common.sh 的 APPLOG 注释），
    # 真实增长的是 server.log（上游 stderr + 启动器输出）和 supervisor.log。
    # APPLOG 仍轮转，只在文件意外出现时才动作（rotate_log 对不存在直接返回）。
    rotate_log "$APPLOG" "$LOG_MAX"
    rotate_log "$SRVLOG" "$LOG_MAX"
    rotate_log "$SUPLOG" "$LOG_MAX"
    # 进程活着不等于服务健康。连续 3 次联合检查失败才重启，启动给 60 秒宽限。
    _now=$(now_epoch)
    if [ $((_now - ${CHILD_START:-$_now})) -ge 60 ]; then
      if svc_http_health 3; then
        HEALTH_FAILS=0
        # 只有真的稳定跑过快速崩溃窗口（120s）才清零连续失败计数。
        if [ "$FAILS" -gt 0 ] && [ $((_now - ${CHILD_START:-_now})) -ge 120 ]; then
          log_to "$SUPLOG" "服务端已稳定运行 120s 以上，清零连续快速失败计数（原 $FAILS）"
          FAILS=0
        fi
      else
        _hrc=$?
        HEALTH_FAILS=$((HEALTH_FAILS + 1))
        log_to "$SUPLOG" "进程/端口/HTTP 联合健康检查连续失败 $HEALTH_FAILS/3（rc=$_hrc）"
      fi
      if [ "$HEALTH_FAILS" -ge 3 ]; then
        log_to "$SUPLOG" "服务进程存活但不健康，执行受控重启"
        if stop_child; then
          svc_kill_stray
          HEALTH_FAILS=0
          FAILS=$((FAILS + 1))
        else
          log_to "$SUPLOG" "不健康进程停止失败，下一轮继续观察，不重复启动"
        fi
        continue
      fi
    fi
    # 每轮先用轻量探测看 VPN/默认网卡变没变（不跑 dumpsys，几乎零开销），
    # 变了就立刻重算 DNS；这样开/关 VPN、切节点最多 30 秒就有反应。
    _vn_now=0
    dns_vpn_active 2>/dev/null && _vn_now=1
    _vn_old=$(cat "$DNS_VPN_CACHE" 2>/dev/null || echo 0)
    _if_now=$(dns_default_iface 2>/dev/null)
    _if_old=$(cat "$DNS_ACTIVE_CACHE" 2>/dev/null || echo "")
    if [ "$_vn_now" != "${_vn_old:-0}" ] || [ "${_if_now:-unknown}" != "${_if_old:-unknown}" ]; then
      log_to "$SUPLOG" "VPN/网卡变化（vpn=${_vn_old:-0}->$_vn_now iface=${_if_old:-?}->${_if_now:-?}），立即重算 DNS"
      dns_refresh_if_changed
      continue
    fi
    # 每 4 轮（≈2 分钟）刷一次 DNS：Wi-Fi 切流量、换热点都会变
    if [ $((TICK % 4)) -eq 0 ]; then
      dns_refresh_if_changed
      privacy_shield
      secure_files
      if [ "$(cfg_get keep_awake 0)" = "1" ]; then take_wake; else release_wake; fi
    fi
    continue
  fi

  # 5) 子进程已死 → 记账
  if [ -n "$CHILD" ]; then
    _now=$(now_epoch)
    _up=$((_now - ${CHILD_START:-$_now}))
    [ "$_up" -lt 0 ] && _up=0
    wait "$CHILD" 2>/dev/null
    rm -f "$RUNDIR/server.pid" "$RUNDIR/server.start" 2>/dev/null
    if [ "$_up" -lt 60 ]; then
      FAILS=$((FAILS + 1))
    else
      FAILS=0
    fi
    log_to "$SUPLOG" "服务端已退出（存活 ${_up}s，连续异常 $FAILS 次）"
    # 服务端死了，它拉起的插件/内核就成了孤儿，一起清掉再重启，
    # 否则新实例会因为端口被孤儿占着起不来
    svc_kill_stray
    CHILD=""
    CHILD_START=""
    CHILD_TICKS=""
    if [ "$(cfg_get watchdog 1)" != "1" ]; then
      GIVEUP=1
      log_to "$SUPLOG" "watchdog=0，不再自动拉起"
    fi
  fi

  # 6) 放弃拉起
  if [ "$GIVEUP" = "1" ]; then
    release_wake
    write_state dead
    sleep 30
    continue
  fi

  # 7) 连续快速崩溃 → 指数退避（最多 5 分钟），别把电池烧穿
  # 快速失败达到 6 次后停止自动拉起，保留人工 a2a restart 恢复入口。
  if [ "$FAILS" -ge 6 ]; then
    GIVEUP=1
    log_to "$SUPLOG" "连续快速失败 6 次，熔断自动拉起；排障后执行 a2a restart"
    write_state dead
    sleep 30
    continue
  elif [ "$FAILS" -ge 3 ]; then
    _wait=$((FAILS * 30))
    [ "$_wait" -gt 300 ] && _wait=300
    log_to "$SUPLOG" "连续快速失败 $FAILS 次，退避 ${_wait}s 再试"
    write_state backoff
    sleep "$_wait"
    # 不能把 continue 留在这里：它会让 FAILS 永远不再增长，永久困在退避。
    # 落到统一的拉起入口，成功后由健康运行分支清零连续失败。
  fi

  # 8) 端口被别人占了 → 别硬抢，等着
  if port_listen "$PORT"; then
    _who=$(port_owner "$PORT" 2>/dev/null)
    log_to "$SUPLOG" "端口 $PORT 已被其它进程占用（pid=${_who:-未知}），60s 后复查"
    write_state port-conflict
    sleep 60
    continue
  fi

  # 9) 拉起
  if start_child; then
    # 不能"一起来就清零"：那样"起来 → 30 秒内崩 → 再起来"永远停在 1 次，
    # 3 次退避和 6 次熔断都触发不了，等于把保护逻辑关掉。
    # 计数留到巡检分支里、确认稳定运行 120s 后再清。
    if [ "$FAILS" -gt 0 ]; then
      log_to "$SUPLOG" "本次拉起成功，但仍保留此前 $FAILS 次快速失败计数以观察稳定性"
    fi
    write_state running
  else
    write_state starting-unhealthy
  fi
done

cleanup
}

# 测试入口只加载函数；生产入口行为保持原有阻塞主循环。
if [ "${A2A_SUPERVISE_LIB_ONLY:-0}" != "1" ]; then
  supervise_main "$@"
  exit $?
fi