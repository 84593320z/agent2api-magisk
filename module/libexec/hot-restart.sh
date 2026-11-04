#!/system/bin/sh
# ============================================================================
# hotinstall.sh 的脱钩子工作进程：不受 Root 管理器 hot-run 时限约束。
#
# 问题 9：请求文件 + 单 worker 模式。旧实现把「安装前是否在跑 / autostart」
# 通过命令行参数传给每个后台任务，多个任务会按各自的（可能过期的）参数
# 串行重复重启。现在每次触发只做两件事：短锁内原子写/更新请求标记（含
# 时间戳），然后尝试取 worker 独占锁；已被持有就退出 0 —— 运行中的 worker
# 每轮都会重读最新请求，动作前重读当前 autostart 配置，绝不拿过期状态
# 重启。CLI 兼容：hotinstall.sh 仍以「$1=安装前是否在跑 $2=autostart」调用
# 本脚本（参数写进请求标记）；无参数调用按「仅触发」处理。
# ============================================================================
MODDIR="${MODDIR:-/data/adb/modules/agent2api}"
. "$MODDIR/libexec/common.sh" || exit 1
. "$MODDIR/libexec/control.sh" || exit 1
. "$MODDIR/libexec/dns.sh" || exit 1
. "$MODDIR/libexec/plugin.sh" || exit 1

HOT_REQ="$RUNDIR/hot-restart.request"
HOT_REQ_LOCK="$RUNDIR/hot-restart.req.lock.d"
HOT_WORKER_LOCK="$RUNDIR/hot-restart.lock.d"

ensure_layout

# 请求标记内容："was_running autostart epoch"（一行）。短锁内 tmp+mv 原子写入，
# 保证并发触发时读到的一定是某一次完整写入的结果，时间戳供诊断。
hot_request_write() { # $1=was_running $2=autostart
  _hrw_token=${UPDATE_LOCK_TOKEN:-}
  _hrw_path=${UPDATE_LOCK_PATH:-}
  update_lock_acquire "$HOT_REQ_LOCK" 5 >/dev/null 2>&1 || {
    printf 'hot-restart: 拿不到请求锁（%s），跳过本次登记\n' "$HOT_REQ_LOCK" >&2
    return 1
  }
  printf '%s %s %s\n' "${1:-0}" "${2:-1}" "$(now_epoch)" \
    >"$HOT_REQ.tmp.$$" 2>/dev/null \
    && mv -f "$HOT_REQ.tmp.$$" "$HOT_REQ" 2>/dev/null
  _hrw_rc=$?
  update_lock_release "$HOT_REQ_LOCK"
  UPDATE_LOCK_TOKEN=$_hrw_token
  UPDATE_LOCK_PATH=$_hrw_path
  return "$_hrw_rc"
}

hot_request_read() { # 输出最新请求内容（无请求时输出空串）
  [ -s "$HOT_REQ" ] || return 0
  head -n 1 "$HOT_REQ" 2>/dev/null
}

hot_request_clear() {
  rm -f "$HOT_REQ" 2>/dev/null
}

# worker 主体：读最新请求 -> 动作前重读当前 autostart -> svc_restart +
# svc_wait_health -> 清请求 -> 再查有无新请求，无则退出。
hot_worker_run() {
  while :; do
    _hw_req=$(hot_request_read)
    # B4：空请求一律退出（含首轮）。触发侧保证「先写请求再抢锁」，worker
    # 拿到锁时至少有一个请求；首轮就为空说明请求已被清或状态异常，按默认
    # 参数重启一次反而是多余动作。
    if [ -z "$_hw_req" ]; then
      break
    fi
    _hw_was=0
    _hw_auto_req=1
    if [ -n "$_hw_req" ]; then
      _hw_was=$(printf '%s\n' "$_hw_req" | awk '{print $1}')
      _hw_auto_req=$(printf '%s\n' "$_hw_req" | awk '{print $2}')
      case "$_hw_was" in 0|1) ;; *) _hw_was=0 ;; esac
      case "$_hw_auto_req" in 0|1) ;; *) _hw_auto_req=1 ;; esac
    fi
    # 动作前重读当前 autostart：请求里的值只作诊断，决策用最新配置，
    # 热安装期间用户关掉自启时不该被过期参数拉起。
    _hw_auto_now=$(cfg_get autostart 1)
    log_to "$LOGDIR/boot.log" "hot-restart 处理请求：was_running=$_hw_was autostart(请求)=${_hw_auto_req} autostart(当前)=${_hw_auto_now}"
    if [ "$_hw_was" = "1" ] || [ "$_hw_auto_now" = "1" ]; then
      # 拉起 supervisor 之前先做 cgroup 逃逸（问题 4f）：worker 与它拉起的
      # supervisor / 服务端都会继承这里的 cgroup 归属，热安装常从 Root 管理
      # 器的 app 上下文触发，不逃逸就会被连坐冻结。迁移不完整只告警。
      if ! cgroup_escape; then
        log_to "$LOGDIR/boot.log" "警告：cgroup 逃逸不完全（详见输出），继续重启"
      fi
      if svc_restart && svc_wait_health 45; then
        log_to "$LOGDIR/boot.log" "热安装后台重启完成，联合健康检查通过"
      else
        log_to "$LOGDIR/boot.log" "热安装后台重启未通过健康检查，详见 supervisor.log/server.log"
        return 1
      fi
    else
      log_to "$LOGDIR/boot.log" "热安装后台任务完成，保留手动停止/autostart=0 状态"
    fi
    hot_request_clear
  done
  return 0
}

# ---- 触发侧：登记请求，然后尝试成为 worker ----
case "${1:-}" in
  0|1) hot_request_write "$1" "${2:-1}" ;;
  *)   hot_request_write 0 1 ;;
esac || exit 0

# 等 Root 管理器先结束 hotinstall hook，避免与目录替换/进程清理竞争。
sleep 2

# 尝试取 worker 独占锁：已被持有说明有 worker 在跑（它会重读最新请求），
# 直接退出 0，绝不排队重复重启。
_hr_outer_token=${UPDATE_LOCK_TOKEN:-}
_hr_outer_path=${UPDATE_LOCK_PATH:-}
if ! update_lock_acquire "$HOT_WORKER_LOCK" 2 >/dev/null 2>&1; then
  log_to "$LOGDIR/boot.log" "hot-restart: 已有 worker 在运行，本次触发只更新请求后退出"
  exit 0
fi

hot_restart_cleanup() {
  trap - EXIT HUP INT TERM
  update_lock_release "$HOT_WORKER_LOCK"
  rm -f "$RUNDIR/hot-restart.state" 2>/dev/null
}
trap 'trap - HUP INT TERM; hot_restart_cleanup; exit 1' HUP INT TERM
trap 'hot_restart_cleanup' EXIT

log_to "$LOGDIR/boot.log" "后台重启 worker 启动（pid=$$）"
# 热安装属于"启动路径"，和 service.sh 一样走带验活的分级兜底；
# 验活全失败时 dns_ensure 自己会把原配置写回，所以再用 dns_bootstrap 兜一层。
dns_ensure || dns_bootstrap
live_link_refresh
plugin_interp_fix

_hot_rc=0
hot_worker_run || _hot_rc=$?
hot_restart_cleanup
trap - EXIT HUP INT TERM

# 关闭丢失窗口（问题 9，B5 改有界循环）：清完请求、释放锁之后请求又出现
# —— 触发方「写请求后抢锁失败退出 0」而本轮检查恰好发生在写入之前的极小
# 竞态。最多复检 3 轮（防活锁）：每轮重读请求，有则重新成为 worker 处理，
# 无则收工；抢不到 worker 锁说明已有别的 worker 接手，同样收工。
_hw_retry=0
while [ "$_hw_retry" -lt 3 ]; do
  [ -n "$(hot_request_read)" ] || break
  update_lock_acquire "$HOT_WORKER_LOCK" 2 >/dev/null 2>&1 || break
  trap 'trap - HUP INT TERM; hot_restart_cleanup; exit 1' HUP INT TERM
  trap 'hot_restart_cleanup' EXIT
  log_to "$LOGDIR/boot.log" "后台重启 worker 复检发现新请求，继续处理（第 $((_hw_retry + 1)) 轮）"
  hot_worker_run || _hot_rc=$?
  hot_restart_cleanup
  trap - EXIT HUP INT TERM
  _hw_retry=$((_hw_retry + 1))
done
UPDATE_LOCK_TOKEN=$_hr_outer_token
UPDATE_LOCK_PATH=$_hr_outer_path
exit "$_hot_rc"
