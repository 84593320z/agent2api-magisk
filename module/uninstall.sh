#!/system/bin/sh
# ============================================================================
# Agent2API Magisk 模块 · uninstall.sh
#
# 顺序很重要：先停进程，再考虑要不要删数据。
# 问题 5：旧流程忽略 svc_stop 的返回码，停止失败也照样删 pid/start 文件、
# 实例锁与各类锁 —— 活着的 supervisor 会继续拉起服务、访问已删数据。现在：
#   1) 先取 update 锁（短超时），与在线更新/热安装事务互斥；拿不到立即
#      中止，不动任何东西。
#   2) svc_stop 正常停止，返回码如实检查；失败（旧进程仍在/锁竞争）转入
#      强化停止：按 cmdline 身份核验定位全部模块进程（不排除当前
#      supervisor），TERM（带超时）→ KILL → 逐个核实退出。
#   3) 强化停止后仍有活进程 → 立即中止卸载并报出存活 pid，pid/锁/数据
#      全部保持原状。
#   4) 全部确认退出后才清理状态与锁：pid/start、实例锁、service/update/
#      hot-restart/boot 各类锁、请求与事务标记（run/ 下模块自有的运行时
#      标记按同口径扩展，不动 data/backup/logs 等非锁内容）。
#   5) purge 仅在"配置要求且步骤 3 已确认全部进程退出"后执行，前后留痕。
# 每一步失败都如实报错退出，绝不"尽力而为继续删"。
# 默认不删数据（purge_on_uninstall=0），这样重装模块时账号、签到记录还在。
# ============================================================================

MODDIR="${MODDIR:-/data/adb/modules/agent2api}"

# 卸载以 root 运行。公共库缺失时必须立刻退出，绝不能在空路径变量下继续 rm。
[ -f "$MODDIR/libexec/common.sh" ] || {
  printf '卸载中止：缺少 %s/libexec/common.sh，未执行任何删除\n' "$MODDIR" >&2
  exit 1
}
. "$MODDIR/libexec/common.sh" 2>/dev/null || {
  printf '卸载中止：common.sh 加载失败，未执行任何删除\n' >&2
  exit 1
}
[ -f "$MODDIR/libexec/control.sh" ] || {
  printf '卸载中止：缺少 control.sh，未执行任何删除\n' >&2
  exit 1
}
. "$MODDIR/libexec/control.sh" 2>/dev/null || {
  printf '卸载中止：control.sh 加载失败，未执行任何删除\n' >&2
  exit 1
}
command -v svc_stop >/dev/null 2>&1 && command -v cfg_get >/dev/null 2>&1 || {
  printf '卸载中止：关键函数不完整，未执行任何删除\n' >&2
  exit 1
}
# 强化停止依赖 control.sh 的卸载模式入口；旧 control.sh 配新 uninstall.sh
# 时宁可整体中止，也不退回"忽略失败继续删"的老路。
command -v svc_kill_all_module_procs >/dev/null 2>&1 || {
  printf '卸载中止：control.sh 缺少强化停止函数（模块文件版本不匹配），未执行任何删除\n' >&2
  exit 1
}
# update_lock_* 定义在 payload.sh（control.sh 只在文件存在时才 source 它）；
# payload.sh 缺失/损坏时函数不存在，取锁步骤会以"无法取得 update 锁"的
# 误导文案失败。这里先诚实拦截：模块文件不完整，无法安全卸载。
command -v update_lock_acquire >/dev/null 2>&1 || {
  printf '卸载中止：缺少 update 锁实现（payload.sh 缺失或损坏，模块文件不完整），无法安全卸载\n' >&2
  exit 1
}

# 删除前一次性核对所有目标。路径必须等于模块自己的固定绝对路径，且不能是软链。
_uninstall_path_ok() {
  [ -n "$1" ] && [ "$1" = "$2" ] && [ ! -L "$1" ]
}
_uninstall_path_ok "$APP_HOME" /data/adb/agent2api &&
_uninstall_path_ok "$RUNDIR" /data/adb/agent2api/run &&
_uninstall_path_ok "$TMPD" /data/adb/agent2api/tmp &&
_uninstall_path_ok "$DLDIR" /data/adb/agent2api/download &&
_uninstall_path_ok "$BACKUPDIR" /data/adb/agent2api/backup &&
_uninstall_path_ok "$A2A_LIVE" /data/a2a || {
  printf '卸载中止：删除路径校验失败，未执行任何删除\n' >&2
  exit 1
}

date '+uninstall %Y-%m-%d %H:%M:%S' >>"$LOGDIR/boot.log" 2>/dev/null

# 1) update 锁：与在线更新/热安装的载荷事务互斥（问题 5a）。短超时 ——
#    活跃事务会立即失败返回，僵死 owner 最多回收重试 8 轮。拿不到说明
#    有事务正在运行，卸载与其互踩（删掉事务正要切换的载荷/数据）比"稍后
#    再卸载"糟糕得多，必须原样退出、不动任何东西。
_uni_outer_token=${UPDATE_LOCK_TOKEN:-}
_uni_outer_path=${UPDATE_LOCK_PATH:-}
update_lock_acquire "$RUNDIR/update.lock.d" 8 >/dev/null 2>&1 || {
  printf '卸载中止：无法取得 update 锁（%s），可能有更新或热安装事务正在运行，请稍后重试\n' "$RUNDIR/update.lock.d" >&2
  exit 1
}

# 统一的中止出口：先放掉自己持有的锁（release 按 pid+启动代次核验，
# 只清理本进程的持有），再报错退出。调用点保证此刻还没删过任何文件。
_uninstall_abort() {
  update_lock_release "$RUNDIR/update.lock.d" >/dev/null 2>&1
  UPDATE_LOCK_TOKEN=$_uni_outer_token
  UPDATE_LOCK_PATH=$_uni_outer_path
  printf '卸载中止：%s\n' "$1" >&2
  exit 1
}

# 2) 正常停止（问题 5b）：svc_stop 按 pidfile+cmdline 核验身份，
#    TERM（supervisor 25s / server 10s）→ KILL → 复核退出，失败时保留
#    PID/锁状态。这里如实检查返回码：失败不忽略、不跳过，交给下面的
#    强化停止兜底 —— 但在此之前一个文件都不删。
svc_stop || printf '正常停止未完成，进入强化停止\n'

# 3) 强化停止 + 后台执行体清理（问题 5b/c/d）：换用卸载模式 —— 不排除
#    当前 supervisor，覆盖 server、插件、boot-worker 与 hot-restart
#    worker（它们是可能常驻的执行体，不清掉会在卸载后把服务拉回来）。
#    仍有一个活进程就整体中止：pid/锁/数据全部保持原状。
svc_kill_all_module_procs || _uninstall_abort "仍有模块进程存活（见上方 pid 列表），pid/锁/数据全部保持原状，可稍后重试或重启后再卸载"

# 4) 全部进程确认退出，开始清状态与锁（问题 5e）：pid/start、实例锁、
#    service/update/hot-restart/boot 锁、热重启请求、载荷事务标记、
#    supervisor 状态快照与 DNS 探测缓存 —— 全是 run/ 下模块自有的运行时
#    标记；data/backup/logs 等非锁内容不在此处触碰（purge 才整体删）。
#    先优雅放掉自己持有的 update 锁，再连目录一起清（顺带兜底残留 owner）。
update_lock_release "$RUNDIR/update.lock.d" >/dev/null 2>&1
UPDATE_LOCK_TOKEN=$_uni_outer_token
UPDATE_LOCK_PATH=$_uni_outer_path
rm -f "$RUNDIR/stop" "$RUNDIR/server.pid" "$RUNDIR/server.start" \
      "$RUNDIR/supervisor.pid" "$RUNDIR/supervisor.start" \
      "$RUNDIR/hot-restart.state" "$RUNDIR/hot-restart.state.new" \
      "$RUNDIR/hot-restart.request" "$RUNDIR/payload.generation" \
      "$RUNDIR/payload.switching" "$RUNDIR/update.pending" \
      "$RUNDIR/update.pending-verify" "$RUNDIR/update.active" \
      "$RUNDIR/state" "$RUNDIR/state.new" \
      "$RUNDIR/dns-active" "$RUNDIR/dns-vpn" "$RUNDIR/dns-vpn.state" \
      "$RUNDIR/resolv.last" "$RUNDIR/desc.last" 2>/dev/null
rm -rf "$RUNDIR/lock" "$RUNDIR/service.lock.d" "$RUNDIR/hot-restart.lock.d" \
       "$RUNDIR/hot-restart.req.lock.d" "$RUNDIR/boot.lock.d" \
       "$RUNDIR/update.lock.d" "$TMPD" 2>/dev/null
rm -f "$RUNDIR"/.update.claim.* "$RUNDIR"/.update.reap.claim.* 2>/dev/null
# 崩溃孤儿（B8）：write-then-rename 断在 mv 之前留下的中转文件。
# 固定名的 .new（supervise 写 pid/start/state 的中转）逐一列出；带进程号
# 的按实际命名模式匹配 —— *.tmp.<pid>（payload.generation / payload.
# switching / update.pending / update.pending-verify / hot-restart.request）
# 与无 .tmp 中缀的 status.json.<pid> / lastlog.txt.<pid>（supervise 写
# webroot 前的中转）。此刻全部模块进程已确认退出，不可能有活进程正在写
# 这些中转，清理是安全的；未匹配到时 rm -f 静默通过。
rm -f "$RUNDIR/server.pid.new" "$RUNDIR/server.start.new" \
      "$RUNDIR/supervisor.pid.new" "$RUNDIR/supervisor.start.new" \
      "$RUNDIR"/*.tmp.[0-9]* "$RUNDIR"/status.json.[0-9]* \
      "$RUNDIR"/lastlog.txt.[0-9]* 2>/dev/null
rm -rf /data/local/tmp/agent2api_install* 2>/dev/null

# 5) 无论是否保留账号数据，都移除模块私有的 glibc 配置和 ld.so 链接。
rm -rf "$A2A_LIVE" 2>/dev/null

# 6) 是否连数据一起删（问题 5f）。只删已核对的目录本身，不使用可能扩成
#    /* 的变量通配符。purge 只在此刻执行 —— 配置要求且步骤 3 已确认全部
#    进程退出；前后在日志与输出里留痕（purge 后 $APP_HOME 连同 logs 一起
#    消失，"执行后"的记录只能进标准输出，由 Magisk/KSU 卸载日志承接）。
if [ "$(cfg_get purge_on_uninstall 0)" = "1" ]; then
  log_to "$LOGDIR/boot.log" "purge_on_uninstall=1：开始删除 $APP_HOME"
  printf 'purge_on_uninstall=1：删除全部数据 %s\n' "$APP_HOME"
  rm -rf "$APP_HOME" 2>/dev/null
  printf 'purge 完成\n'
else
  # 留下数据但把大文件清掉（下载缓存、旧备份），省空间。
  rm -rf "$DLDIR" "$BACKUPDIR/prev" "$BACKUPDIR/prev.old" "$BACKUPDIR/prev.new" 2>/dev/null
  rotate_log "$SRVLOG" 512 2>/dev/null
  rotate_log "$APPLOG" 512 2>/dev/null
  rotate_log "$SUPLOG" 512 2>/dev/null
  printf '模块已卸载，数据保留在 %s\n' "$APP_HOME" >"$APP_HOME/UNINSTALLED.txt" 2>/dev/null
fi

exit 0
