#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · post-fs-data（开机早期，/data 已挂载、zygote 还没起）
#
# 这里只做三件事，且必须快 —— post-fs-data 阶段是阻塞开机的，超过 10 秒
# 系统会亮黄字警告。
#   1) 修正运行目录权限（模块热安装/升级会把权限重置成 0644）
#   2) 准备 glibc 要的三个运行时文件（resolv / nsswitch / gai）
#   3) 清掉上一次被打断留下的临时目录
#
# 注意：这里绝对不能启动服务端。服务端要等 boot_completed + 网络就绪，
# 那是 service.sh 的活。
# ============================================================================

_self="${0:-}"
case "$_self" in
  */*) MODDIR="${_self%/*}" ;;
  *)   MODDIR="." ;;
esac
[ -f "$MODDIR/module.prop" ] || MODDIR="/data/adb/modules/agent2api"

[ -f "$MODDIR/libexec/common.sh" ] || exit 0
. "$MODDIR/libexec/common.sh"
. "$MODDIR/libexec/dns.sh"
. "$MODDIR/libexec/payload.sh"

ensure_layout

# 权限：热安装/升级后模块目录是 0644，payload 里的可执行位要补回来，
# 否则 ld.so 跑不起来（报"Permission denied"）。
chmod 755 "$PAYLOAD" "$PLIB" "$LOADER" "$SERVER_BIN" 2>/dev/null
for _f in "$PLIB"/*.so*; do
  [ -e "$_f" ] && chmod 755 "$_f" 2>/dev/null
done
if [ -d "$MODDIR/libexec" ]; then
  chmod 755 "$MODDIR/libexec" 2>/dev/null
  for _f in "$MODDIR/libexec"/*; do
    [ -e "$_f" ] && chmod 755 "$_f" 2>/dev/null
  done
fi
chmod 700 "$CFGDIR" "$DATADIR" 2>/dev/null

# 运行期残留：pid / 锁 / stop 标记，一律清（这个时刻不可能有活进程）
rm -f "$RUNDIR/stop" "$RUNDIR/server.pid" "$RUNDIR/server.start" "$RUNDIR/supervisor.pid" "$RUNDIR/supervisor.start" "$RUNDIR/hot-restart.state" "$RUNDIR/state" 2>/dev/null
rm -rf "$RUNDIR/lock" "$RUNDIR/service.lock.d" "$RUNDIR/hot-restart.lock.d" "$RUNDIR/update.lock.d" 2>/dev/null

# 先恢复两次 rename 之间断电的现场，再清临时目录。
payload_recover_interrupted
# 时区库安装窗口被打断（旧库已移开、新库还没就位）时放回去。
if [ ! -e "$APP_HOME/zoneinfo" ]; then
  for _zo in "$APP_HOME"/zoneinfo.old.*; do
    [ -d "$_zo" ] || continue
    if mv -f "$_zo" "$APP_HOME/zoneinfo" 2>/dev/null; then
      log_to "$SUPLOG" "已恢复中断的时区库：$_zo"
    fi
    break
  done
fi
sweep_stale_dirs
# R01：这个时刻服务还没起来，一份"健康检查证据"都没有。在这里提交（删掉上一
# 事务留下的唯一可回滚副本）等于把"新载荷能跑"当成已知事实 —— 新载荷要是
# 起不来，回滚材料已经被自己删了。pending 原样保留，交给 supervise.sh 在首次
# 健康检查通过后提交。
if [ -s "$RUNDIR/update.pending" ]; then
  log_to "$SUPLOG" "保留事务旧载荷，等启动健康检查通过后再提交：$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null | head -n 1)"
fi

# glibc 运行时文件。
# 为什么放在 post-fs-data 而不是等 service.sh：glibc 一打开 resolv.conf 就
# 缓存了 fd，等 boot_completed 再写，第一次解析已经用"空配置"失败过了。
# 先写一份 bootstrap 保证"任何时候都有可用 DNS"，剩下的交给 service.sh 用
# 手机真实 DNS 覆盖。
if [ "$(cfg_get dns_mode auto)" != "off" ] && [ ! -s "$DNSFILE" ]; then
  [ -d "$A2A_LIVE" ] || mkdir -p "$A2A_LIVE" 2>/dev/null
  {
    printf '# bootstrap by post-fs-data.sh %s\n' "$(now_human)"
    # bootstrap 也要尊重用户配置：原来写死 223.5.5.5/119.29.29.29，
    # dns_static 改了却对开机第一份文件无效。dns_static_list 会带上 v6 兜底。
    _pf_list=$(dns_static_list 2>/dev/null) || _pf_list="223.5.5.5 119.29.29.29"
    [ -n "$_pf_list" ] || _pf_list="223.5.5.5 119.29.29.29"
    for _pf_ns in $_pf_list; do
      printf 'nameserver %s\n' "$_pf_ns"
    done
    dns_opts_line noprobe
  } >"$DNSFILE" 2>/dev/null
  chmod 644 "$DNSFILE" 2>/dev/null
fi
[ -s "$NSSFILE" ] || nss_apply
[ -s "$GAIFILE" ] || gai_apply

# /data/a2a/ld.so 软链（插件解释器指向它）
live_link_refresh

log_to "$LOGDIR/boot.log" "post-fs-data 完成（payload=$(payload_version 2>/dev/null)）"
rotate_log "$LOGDIR/boot.log" 256
exit 0