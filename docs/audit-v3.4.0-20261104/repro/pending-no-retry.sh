. /e/AI/tmp/agent2api-audit-20261104/repo/module/libexec/common.sh
APP_HOME=/e/AI/tmp/agent2api-audit-20261104/agent-runtime/fixture
PAYLOAD="$APP_HOME/payload"; PLIB="$PAYLOAD/lib"; BINDIR="$APP_HOME/bin"; CFGDIR="$APP_HOME/etc"; DATADIR="$APP_HOME/data"; LOGDIR="$APP_HOME/logs"; RUNDIR="$APP_HOME/run"; TMPD="$APP_HOME/tmp"; HOMEDIR="$APP_HOME/home"; BACKUPDIR="$APP_HOME/backup"; DLDIR="$APP_HOME/download"
SETTINGS="$CFGDIR/settings.conf"; SUPLOG="$LOGDIR/supervisor.log"; SRVLOG="$LOGDIR/server.log"; APPLOG="$LOGDIR/app.log"; SERVER_BIN="$PAYLOAD/agent2api-server"; LOADER="$PLIB/ld-linux-aarch64.so.1"
A2A_LIVE="$APP_HOME/live"; DNSFILE="$A2A_LIVE/resolv"; DNS_CACHE="$RUNDIR/resolv.last"
ensure_layout; mkdir -p "$A2A_LIVE"
supervise_commit_pending() {
  _scp_disk=$(payload_generation_read)
  if [ -s "$RUNDIR/update.pending" ]; then
    _scp_line=$(head -n 1 "$RUNDIR/update.pending" 2>/dev/null) || _scp_line=""
    _scp_tag=$(printf '%s\n' "$_scp_line" | awk '{print $1" "$2}')
    _scp_txid=$(printf '%s\n' "$_scp_line" | awk '{print $4}')
    if [ -n "$_scp_txid" ] || [ -n "$_scp_disk" ] || [ -n "$CHILD_GENERATION" ]; then
      # 新式记账：三方代次完全一致才提交
      if [ -n "$_scp_txid" ] && [ "$_scp_txid" = "$CHILD_GENERATION" ] \
         && [ "$_scp_txid" = "$_scp_disk" ]; then
        if payload_commit_old "$_scp_tag" "$_scp_txid"; then
          log_to "$SUPLOG" "已提交代次 $_scp_txid 的事务旧载荷（$_scp_tag）"
        else
          log_to "$SUPLOG" "事务旧载荷暂未提交（代次 $_scp_txid），下一轮再试"
        fi
      else
        log_to "$SUPLOG" "pending 属于其它代次（pending=${_scp_txid:-无} 启动=${CHILD_GENERATION:-无} 磁盘=${_scp_disk:-无}），本轮不提交"
      fi
    elif [ -n "$_scp_tag" ]; then
      # 旧版遗留的 pending（无代次信息）：退回 tag 匹配
      if payload_commit_old "$_scp_tag"; then
        log_to "$SUPLOG" "已提交旧式记账的事务旧载荷（$_scp_tag）"
      else
        log_to "$SUPLOG" "事务旧载荷暂未提交（$_scp_tag），下一轮再试"
      fi
    fi
  fi
  # 问题 8：「已安装、未启动、未验证」的独立状态标记（更新前服务是停止的，
  # 更新只切载荷不做健康验证）。该代次现在通过了健康检查 -> 提交并清除标记；
  # 标记代次已不是磁盘代次时它不可能再被满足（代次从不回退），清掉防悬空。
  if [ -f "$RUNDIR/update.pending-verify" ]; then
    _scp_vtxid=$(awk 'NR==1{print $1; exit}' "$RUNDIR/update.pending-verify" 2>/dev/null)
    if [ -n "$_scp_vtxid" ] && [ "$_scp_vtxid" = "$CHILD_GENERATION" ] \
       && [ "$_scp_vtxid" = "$_scp_disk" ]; then
      log_to "$SUPLOG" "未验证安装（代次 $_scp_vtxid）已通过健康检查，提交并清除标记"
      if payload_commit_old "" "$_scp_vtxid"; then
        rm -f "$RUNDIR/update.pending-verify" 2>/dev/null
      else
        log_to "$SUPLOG" "pending-verify 对应提交未完成，保留标记下一轮重试"
      fi
    elif [ -n "$_scp_vtxid" ] && [ "$_scp_vtxid" != "$_scp_disk" ]; then
      log_to "$SUPLOG" "pending-verify 标记的代次（$_scp_vtxid）已不是当前代次（${_scp_disk:-无}），清除悬空标记"
      rm -f "$RUNDIR/update.pending-verify" 2>/dev/null
    fi
  fi
  return 0
}

printf 'update 123 /isolated/payload.update.old.123 tx1 9
' >"$RUNDIR/update.pending"
CHILD_GENERATION=tx1; CHILD=123; CHILD_START=1; FAILS=0; HEALTH_FAILS=0; TICK=0; STOP=0; LOG_MAX=8192
payload_generation_read() { echo tx1; }
COMMIT_CALLS=0
payload_commit_old() { COMMIT_CALLS=$((COMMIT_CALLS+1)); if [ "$COMMIT_CALLS" -eq 1 ]; then return 1; else rm -f "$RUNDIR/update.pending"; return 0; fi; }
child_alive() { return 0; }; svc_http_health() { return 0; }; write_state() { :; }; sleep() { :; }; rotate_log() { :; }; now_epoch() { echo 1000; }; dns_vpn_active() { return 1; }; dns_default_iface() { echo wlan0; }; dns_refresh_if_changed() { :; }; privacy_shield() { :; }; secure_files() { :; }; release_wake() { :; }
DNS_VPN_CACHE="$RUNDIR/mock-vpn"; DNS_ACTIVE_CACHE="$RUNDIR/mock-iface"; echo 0 >"$DNS_VPN_CACHE"; echo wlan0 >"$DNS_ACTIVE_CACHE"
supervise_commit_pending
for mock_turn in 1 2 3 4 5; do
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

done
printf 'healthy_turns=5 commit_calls=%s pending_exists=%s
' "$COMMIT_CALLS" "$([ -e "$RUNDIR/update.pending" ] && echo yes || echo no)"
