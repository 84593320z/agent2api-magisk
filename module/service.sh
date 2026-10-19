#!/system/bin/sh
# Magisk late_start service：常驻守护 agent2api-server（chroot + glibc）
#
# 两种角色：
#   service.sh              安装期被 Magisk 直接调用 —— 只做自检测试，几十毫秒内返回，
#                           真正的守护进程 fork 出去（Magisk 会等脚本的 stdio 关闭，
#                           在这里原地常驻会让每次开机卡在开机动画）
#   service.sh --loop ...   脱离 Magisk 的守护进程本体
#
# v3.1.1 守护循环从 `wait $pid` 改为轮询：
#   wait 会在服务存活期间把守护挂起 —— 日志轮转、DNS 重探、健康探活全都做不了。
#   改成每 AGENT2API_POLL_SECS 秒醒一次后：
#     * server.log/app.log 达到上限即轮转（不再依赖"服务退出"才轮转）
#     * /health 健康探活（假死检测，可关）
#     * 每小时重生成 resolv.conf（换网后 DNS 自愈）
#     * 数据 bind 失败等致命错误立刻拒启并留痕（不再把数据写进模块目录）
MODDIR=${0%/*}
. "$MODDIR/bin/lib.sh"

mkdir -p "$DATA" "$DATA/data" "$LOGDIR" "$BACKUPDIR" 2>/dev/null

# ── 角色一：fork 出守护并立刻返回 ─────────────────────────
if [ "$1" != "--loop" ]; then
  if supervisor_running; then
    log "supervisor 已在运行（pid=$(cat "$SUPPID" 2>/dev/null)），不再重复拉起"
    exit 0
  fi
  rm -f "$SUPPID"
  # 每次被要求启动都视为"用户要求重试"：清掉上次的致命标记，失败了会重新写
  rm -f "$FATALFILE"
  _chroot=$(find_chroot) || {
    log "自检失败：找不到 chroot（toybox / busybox 都没有），服务不会启动"
    exit 0
  }
  log "自检通过：chroot=$_chroot"
  spawn_detached "$MODDIR/service.sh" --loop
  # 开机路径同样要确认守护真的起来了：setsid(2) 在调用者已是进程组组长时
  # 返回 EPERM，toybox 的 setsid 会 perror_exit 而不 exec 目标 ——
  # 结果就是"脚本成功退出、守护根本不存在"，而 Magisk 不会重试，
  # 整台机器就停在"模块已装、服务从没启动过"的状态直到下次重启。
  _i=0
  while [ "$_i" -lt 5 ]; do
    supervisor_running && exit 0
    _sleep 1
    _i=$((_i + 1))
  done
  log "warning: setsid 拉起守护失败，改用双 fork 兜底"
  ( "$MODDIR/service.sh" --loop </dev/null >/dev/null 2>&1 & )
  exit 0
fi

# ── 角色二：守护循环本体 ─────────────────────────────────
# 原子锁先于一切：两个守护同时进入循环 = 双 server 抢端口 + PID 文件互踩
if ! acquire_supervisor_lock; then
  log "另一个守护已在运行（锁被持有），本进程退出"
  exit 0
fi
echo $$ > "$SUPPID"

cleanup() {
  trap - TERM INT HUP
  log "收到 TERM，守护退出"
  stop_server
  umount_chroot
  rm -f "$SUPPID" "$PIDFILE"
  release_supervisor_lock
  exit 0
}
trap cleanup TERM INT HUP

rm -f "$FATALFILE"

# ── 用户配置 ──────────────────────────────────────────────
# 放在等开机之前：安全闸门要在开机后第一秒就能给出结论，
# 而不是先干等最多 5 分钟的 boot_completed（那段时间 status 只会显示"未运行"）。
load_env
: "${AGENT2API_HOST:=127.0.0.1}"
: "${AGENT2API_PROXY_PORT:=3065}"
: "${TZ_NAME:=Asia/Shanghai}"
: "${DNS_LIST:=}"

: "${AGENT2API_POLL_SECS:=10}"
: "${AGENT2API_HEALTH_CHECK:=1}"
: "${AGENT2API_HANG_RESTART:=1}"
: "${AGENT2API_LOG_MAX_MB:=16}"
: "${AGENT2API_MAX_RSS_MB:=0}"
: "${AGENT2API_WATCHDOG:=1}"
# 手改 env 写了非数字会让 $(( )) 直接把脚本打死（dash 对算术错误是致命的），
# 先归一再进算术
case "$AGENT2API_POLL_SECS"  in ''|*[!0-9]*) AGENT2API_POLL_SECS=10 ;; esac
case "$AGENT2API_LOG_MAX_MB" in ''|*[!0-9]*) AGENT2API_LOG_MAX_MB=16 ;; esac
_srvlog_max=$(( ${AGENT2API_LOG_MAX_MB} * 1048576 ))

# 时区校验：写错时区名时 glibc/chrono 会退回 /etc/localtime，缺失就静默变 UTC
resolve_tz

log "模块启动：root=$ROOT host=$AGENT2API_HOST port=$AGENT2API_PROXY_PORT tz=$TZ_NAME pid=$$ poll=${AGENT2API_POLL_SECS}s"

# ── 安全闸门：对外监听但没有任何鉴权 ─────────────────────
# 面板的「首次注册管理员」是开放的。HOST 不是回环地址、又既没配网关 Key
# 也没预置管理员时，同一局域网内任何人都能抢先注册成管理员，拿到的还是
# chroot 内的 uid 0（= 整机 root）。这种状态拒绝启动。
#
# 为什么不是「一律拒绝对外监听」：面板本身是配置 Key/管理员的唯一入口，
# 全拒会形成死锁（要配 Key 得先进面板，进面板得先启动）。所以只拦
# 「对外 + 零鉴权」这一种真正裸奔的组合，并给出两条可操作的出路。
if lan_exposed_unsafe; then
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 拒绝启动：AGENT2API_HOST=$AGENT2API_HOST 对外监听，"
    echo "但 env.sh 里既没有 AGENT2API_PROXY_API_KEY，也没有 AGENT2API_ADMIN_USER。"
    echo "此时面板的首次注册对局域网开放，任何人都能注册成管理员（chroot 内 uid 0 = 整机 root）。"
    echo "修法二选一："
    echo "  1) 先把 AGENT2API_HOST 改回 127.0.0.1，启动并完成注册/建 Key 后再改回 $AGENT2API_HOST；"
    echo "  2) 直接在 env.sh 里预置 AGENT2API_PROXY_API_KEY 或 AGENT2API_ADMIN_USER/PASSWORD。"
    echo "改完执行：sh /data/adb/modules/agent2api/bin/ctl restart"
  } > "$FATALFILE" 2>/dev/null
  log "FATAL: 对外监听且零鉴权，拒绝启动（详见 $FATALFILE）"
  notify_user "Agent2API 拒绝启动：对外监听但未配置任何鉴权"
  rm -f "$SUPPID"
  release_supervisor_lock
  exit 0
fi
if lan_exposed; then
  log "warning: 监听 $AGENT2API_HOST（局域网可达），面板是明文 HTTP —— 确认已设强密码/网关 Key"
  : > "$DATA/lan-exposed" 2>/dev/null
else
  rm -f "$DATA/lan-exposed" 2>/dev/null
fi

# ── 等开机完成（网络与 /data 就绪）────────────────────────
# 配置与安全闸门已经判过了，这里只是等服务真正能跑的条件：
# 早于 boot_completed 起来会拿不到网络，DNS 探测会一路退到公网兜底。
_n=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
  _n=$((_n + 1))
  [ "$_n" -gt 150 ] && { log "等待 boot_completed 超时，继续启动"; break; }
  sleep 2
done

# ── 守护循环 ──────────────────────────────────────────────
fails=0
_pc=0   # 端口被占的连续确认次数
while :; do
  if [ -f "$DATA/disable" ]; then
    log "检测到 disable 标记，守护进程退出"
    break
  fi
  gen_resolv
  MOUNT_FATAL=0
  if ! mount_chroot; then
    if [ "$MOUNT_FATAL" = "1" ]; then
      # 数据/日志 bind 失败还继续启动 = 数据写进模块目录，重刷模块即静默丢失。
      # 拒启 + 留痕 + 通知，等用户介入（ctl restart 会清标记重试一次）
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] 数据/日志 bind 挂载失败，已拒绝启动以防数据写错位置；详见 $MODLOG" > "$FATALFILE"
      log "FATAL: mount_chroot 存在致命失败项，守护退出（ctl restart 可重试）"
      notify_user "Agent2API 启动失败：数据目录挂载异常，已停止以防数据写错位置"
      umount_chroot
      break
    fi
    log "chroot 挂载有非致命失败项（继续尝试启动）"
  fi
  rotate_log "$MODLOG" 4194304
  rotate_log "$SRVLOG" "$_srvlog_max"
  rotate_log "$APPLOG" "$_srvlog_max"

  if ! start_server; then
    fails=$((fails + 1))
    delay=30
    [ "$fails" -gt 5 ] && delay=120
    log "启动失败，${delay}s 后重试（连续失败=$fails）"
    sleep "$delay"
    continue
  fi

  # ── 轮询期：代替 wait，维护工作都在这里做 ──
  # 死亡检测原理：子进程退出成僵尸后 cmdline 变空 → pid_matches 失败；
  # 此时 kill -0 仍为真（僵尸占着 pid），确认两次后 kill -9 + wait 收割退出码。
  rc=0
  _first=1
  _tick=0
  _hfail=0
  _hgap=2          # 健康检查间隔（tick）：连续成功逐步退到 6，一失败立刻回 1
  _hnext=2
  _rsshit=0        # RSS 连续超限次数
  _dns_ts=$(date +%s)
  _bin_stamp=$(payload_stamp)   # 载荷二进制指纹（面板内自更新会让它变）
  while :; do
    if [ "$_first" = "1" ]; then _sleep 2; _first=0; else _sleep "$AGENT2API_POLL_SECS"; fi
    _tick=$((_tick + 1))

    if ! kill -0 "$SRV_PID" 2>/dev/null; then
      wait "$SRV_PID" 2>/dev/null; rc=$?
      break
    fi
    if ! pid_matches "$SRV_PID" agent2api-server; then
      _sleep 1
      if ! pid_matches "$SRV_PID" agent2api-server; then
        kill -9 "$SRV_PID" 2>/dev/null
        wait "$SRV_PID" 2>/dev/null; rc=$?
        break
      fi
    fi

    # 用户点了 stop（stop_all 会先置 disable 再 TERM 本进程）
    if [ -f "$DATA/disable" ]; then
      log "轮询中发现 disable 标记：停止服务并退出"
      stop_server
      rc=0
      break
    fi

    # 日志轮转（每 tick 一次，代价=三次 wc -c）
    rotate_log "$SRVLOG" "$_srvlog_max"
    rotate_log "$APPLOG" "$_srvlog_max"

    # 面板内自更新：服务端点「下载并更新」时，会用 rename 把新二进制换到
    # /opt/agent2api/agent2api-server 上，但**正在跑的进程还是旧镜像**
    # （Linux 上 rename 不影响已映射的可执行文件）。它自己那句「请重启」
    # 在本模块里没有重启通道（headless 容器入口才有），所以由守护补上：
    # 盯住二进制的 size+mtime，一变就重启，顺手用新二进制刷新 VERSION。
    _st=$(payload_stamp)
    if [ "$_st" != "$_bin_stamp" ]; then
      log "检测到载荷二进制变更（$_bin_stamp → $_st），重启以生效"
      notify_user "Agent2API 服务端已更新，正在重启"
      refresh_payload_version
      kill -TERM "$SRV_PID" 2>/dev/null
      _sleep 3
      kill -0 "$SRV_PID" 2>/dev/null && kill -9 "$SRV_PID" 2>/dev/null
      wait "$SRV_PID" 2>/dev/null
      rc=0
      break
    fi

    # 健康探活（自适应节拍）：默认每 2 tick（约 20s）一次；
    # 连续成功逐步退到每 6 tick（省电、少占 CPU），一旦失败立刻回到 1 tick 快速确认。
    # 原来固定每 2 tick，长时间稳定运行时等于每 20s 一次无谓的 HTTP 请求。
    if [ "$AGENT2API_HEALTH_CHECK" = "1" ] && [ "$_tick" -ge "$_hnext" ]; then
      if health_ok; then
        _hfail=0
        [ "$_hgap" -lt 6 ] && _hgap=$((_hgap + 1))
      else
        _hgap=1
        _hfail=$((_hfail + 1))
        [ $((_hfail % 3)) -eq 1 ] && log "warning: /health 无响应（连续 ${_hfail} 次）"
        # 失败期间间隔退回 1 tick（约 10s），18 次 ≈ 3 分钟仍无响应且进程活着
        # = 疑似假死，强杀换重启
        if [ "$_hfail" -ge 18 ] && [ "$AGENT2API_HANG_RESTART" = "1" ]; then
          log "server 疑似假死（健康检查连续 ${_hfail} 次失败），强制重启"
          notify_user "Agent2API 服务疑似无响应，已自动重启"
          kill -9 "$SRV_PID" 2>/dev/null
          wait "$SRV_PID" 2>/dev/null
          rc=137
          break
        fi
      fi
      _hnext=$((_tick + _hgap))
    fi

    # RSS 看门狗：每 6 tick 看一次，连续 2 次超限才动手（避开瞬时峰值）。
    # oom_score_adj=-900 保证泄漏时不再拖死系统，但也不该等内核来收：
    # 主动重启有日志、有通知，比被 OOM 静默杀掉可观测得多。
    if [ "$AGENT2API_WATCHDOG" = "1" ] && [ $((_tick % 6)) -eq 0 ]; then
      _rss=$(rss_mb "$SRV_PID")
      _lim=$(mem_limit_mb)
      if [ "$_lim" -gt 0 ] && [ "$_rss" -gt "$_lim" ]; then
        _rsshit=$((_rsshit + 1))
        log "warning: server RSS ${_rss}MB 超过阈值 ${_lim}MB（连续 ${_rsshit} 次）"
        if [ "$_rsshit" -ge 2 ]; then
          log "RSS 连续超限，判定内存泄漏，主动重启（避免内核 OOM 去杀系统进程）"
          notify_user "Agent2API 内存占用异常（${_rss}MB），已自动重启"
          kill -TERM "$SRV_PID" 2>/dev/null
          _sleep 3
          kill -0 "$SRV_PID" 2>/dev/null && kill -9 "$SRV_PID" 2>/dev/null
          wait "$SRV_PID" 2>/dev/null
          rc=137
          break
        fi
      else
        _rsshit=0
      fi
    fi

    # 每小时重探 DNS（换 Wi-Fi/流量后解析自愈；bind 过的 resolv.conf 立即生效）。
    # 用真实时间算而不是 _tick % 360：后者依赖 POLL_SECS=10，用户把间隔改成 5
    # 就悄悄变成 30 分钟，注释与行为脱钩。
    _now=$(date +%s)
    if [ $((_now - _dns_ts)) -ge 3600 ]; then
      gen_resolv
      _dns_ts=$_now
    fi
  done

  rm -f "$PIDFILE"
  up=$(( $(date +%s) - ${start_ts:-0} ))
  log "server 退出 rc=$rc uptime=${up}s"
  [ -f "$DATA/disable" ] && break

  # 端口被占诊断：bind 失败时服务会「启动即退出」，日志里只有 rc=1，
  # 守护按退避无限重试，用户完全无法归因（每小时一条通知，永远不自愈）。
  # 识别「端口处于 LISTEN 且持有人不是本服务」→ 写 fatal 标记停止重试。
  # 连续两次确认才下结论，避开「本服务刚退出、socket 尚未释放」的竞态；
  # 必须要求 port_owner_pid 能真正指到某个进程，否则宁可不报（避免误杀重试）。
  _op=""
  if [ "$up" -lt 10 ] && port_listening; then
    _op=$(port_owner_pid)
  fi
  if [ -n "$_op" ]; then
    _pc=$((_pc + 1))
    log "server 启动即退出，端口 $AGENT2API_PROXY_PORT 被 pid=${_op} 占用（第 ${_pc} 次确认）"
    if [ "$_pc" -ge 2 ]; then
      {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 端口 $AGENT2API_PROXY_PORT 已被 pid=${_op} 占用，服务无法监听。"
        echo "处理：改 env.sh 的 AGENT2API_PROXY_PORT 换一个端口，或结束占用进程，然后 ctl restart。"
        echo "占用者命令行：$(tr '\0' ' ' < "/proc/$_op/cmdline" 2>/dev/null)"
      } > "$FATALFILE" 2>/dev/null
      log "FATAL: 端口被占用，停止重试（详见 $FATALFILE）"
      notify_user "Agent2API 启动失败：端口 $AGENT2API_PROXY_PORT 被占用"
      break
    fi
  else
    _pc=0
  fi

  # 45s 内退出才算「崩溃」：冷启动慢的机器上正常重启也可能接近 20s，
  # 原来的 20s 会把正常重启误记成崩溃、把退避时间越拉越长。
  if [ "$up" -lt 45 ]; then
    fails=$((fails + 1))
  else
    fails=0
  fi
  # 崩溃计数（累积，ctl status 展示）+ 节流通知
  # 空文件会让 $(( )) 展开成 $(( + 1)) → mksh 算术错误 → 非交互 shell 直接退出，
  # 且死在 log 之前，日志里什么都看不到。先剔非数字。
  _rs=$(cat "$RESTARTS" 2>/dev/null | tr -dc '0-9')
  [ -n "$_rs" ] || _rs=0
  echo $((_rs + 1)) > "$RESTARTS" 2>/dev/null
  [ "$up" -lt 45 ] && notify_user "agent2api-server 异常退出（rc=$rc），已自动重启"
  delay=3
  [ "$fails" -gt 2 ] && delay=15
  [ "$fails" -gt 5 ] && delay=60
  log "将在 ${delay}s 后重启（连续快退=$fails）"
  sleep "$delay"
done

umount_chroot
rm -f "$SUPPID" "$PIDFILE"
release_supervisor_lock
log "守护进程结束"
