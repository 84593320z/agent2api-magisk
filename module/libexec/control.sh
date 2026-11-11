#!/system/bin/sh
# Agent2API 模块 · 启停与精确进程管理
# 只认本模块的 exe/cmdline；绝不 pkill -f，也绝不把调用者自己列入清理。
[ -f "$MODDIR/libexec/payload.sh" ] && . "$MODDIR/libexec/payload.sh"

svc_supervisor_pid() { read_pid "$RUNDIR/supervisor.pid"; }
svc_server_pid() { read_pid "$RUNDIR/server.pid"; }

pid_is_supervisor() {
  pid_alive "$1" || return 1
  [ -r "/proc/$1/cmdline" ] || return 1
  _cl=$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)
  case "$_cl" in *"$MODDIR/libexec/supervise.sh"*) ;; *) return 1 ;; esac
  if [ -r "$RUNDIR/supervisor.start" ]; then
    pid_matches_start "$1" "$(cat "$RUNDIR/supervisor.start" 2>/dev/null)" || return 1
  fi
  return 0
}

pid_is_server() {
  pid_alive "$1" || return 1
  [ -r "/proc/$1/cmdline" ] || return 1
  _cl=$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)
  # 静态载荷直接 exec，cmdline 以绝对路径开头、没有前导空格，
  # 这里统一补空格，让下面的整词匹配对两种启动方式都成立。
  _cl=" $_cl "
  # 仅接受 launch.sh 或本模块服务端路径；ld.so 可被任何程序共用，不能作为身份。
  case "$_cl" in
    *"$MODDIR/libexec/launch.sh"*|*"$LOADER --argv0 agent2api-server"*|*" $PAYLOAD/agent2api-server "*) ;;
    *) return 1 ;;
  esac
  # 一旦进入 exec，必须同时出现本模块 loader 与精确服务端参数；不能只有路径子串。
  case "$_cl" in
    *"$MODDIR/libexec/launch.sh"*) ;;
    *" $PAYLOAD/agent2api-server "*) ;;
    *) return 1 ;;
  esac
  if [ -r "$RUNDIR/server.start" ]; then
    pid_matches_start "$1" "$(cat "$RUNDIR/server.start" 2>/dev/null)" || return 1
  fi
  return 0
}

svc_is_running() {
  _p=$(svc_supervisor_pid 2>/dev/null) || return 1
  pid_is_supervisor "$_p"
}

# 健康探测地址必须跟着 host 配置走：服务端按 settings.conf 的 host 监听，
# 配成 ::1 或某个局域网地址时，硬编码 127.0.0.1 会永远判不健康，
# supervisor 于是每 30 秒"受控重启"一次，服务实际不可用。
svc_health_urls() { # $1=端口；一行一个候选 URL
  _hu_port="$1"
  _hu_host=$(cfg_get host 127.0.0.1)
  case "$_hu_host" in
    '') printf 'http://127.0.0.1:%s/health\n' "$_hu_port" ;;
    0.0.0.0|"*"|::|"[::]")
      # R12：host=:: 时服务端常常只监听 [::]:port（Android 上 v6-only 很常见），
      # 只试 127.0.0.1 会把一个健康的实例判成死，每 30 秒无意义地重启一次。
      printf 'http://[::1]:%s/health\n' "$_hu_port"
      printf 'http://127.0.0.1:%s/health\n' "$_hu_port" ;;
    ::1|"[::1]") printf 'http://[::1]:%s/health\n' "$_hu_port" ;;
    *:*)
      _hu_host=${_hu_host#\[}; _hu_host=${_hu_host%\]}
      printf 'http://[%s]:%s/health\n' "$_hu_host" "$_hu_port"
      printf 'http://127.0.0.1:%s/health\n' "$_hu_port"
      ;;
    *)
      printf 'http://%s:%s/health\n' "$_hu_host" "$_hu_port"
      # 服务端也可能监听在通配地址上，回环补一次（与上面重复时不补）。
      [ "$_hu_host" = "127.0.0.1" ] || [ "$_hu_host" = "localhost" ] \
        || printf 'http://127.0.0.1:%s/health\n' "$_hu_port"
      ;;
  esac
}

svc_http_health() { # $1=单次超时秒；同时核对进程身份、socket 归属和健康响应体
  _port=$(port_normalize "$(cfg_get port 3065)") || return 1
  _t="${1:-5}"
  _pid=$(svc_server_pid 2>/dev/null) || return 1
  pid_is_server "$_pid" || return 1
  port_owned_by_pid "$_port" "$_pid" || return 1
  [ -x "$CURL" ] || return 2
  _body="$TMPD/health.$$.json"
  # 明文 http 不需要 --cacert：带上虽然无害，但 curl 会先做一次 CA 解析，
  # 每次健康检查多花几毫秒，还得保证 $CACERT 一直存在。
  _rc=1
  for _url in $(svc_health_urls "$_port"); do
    # R12：回环请求绝不能被 http_proxy 劫持（代理回 502 会把健康实例判死）。
    _code=$("$CURL" -sS --noproxy '*' -o "$_body" -w '%{http_code}' --max-time "$_t" "$_url" 2>/dev/null)
    _crc=$?
    # R13：只看状态码不够。连接被中途截断时 curl 返回 18/56，而 -w 仍可能打印
    # 200，于是坏实例被当成健康的；必须同时要求 curl 退出码为 0。
    [ "$_crc" -eq 0 ] || continue
    [ "$_code" = "200" ] || continue
    grep -Eq '"status"[[:space:]]*:[[:space:]]*"(ok|degraded)"' "$_body" 2>/dev/null || continue
    _rc=0
    break
  done
  rm -f "$_body" 2>/dev/null
  return "$_rc"
}

svc_wait_health() { # $1=总等待秒
  _port=$(port_normalize "$(cfg_get port 3065)") || return 1
  _budget="${1:-30}"
  _deadline=$(( $(now_epoch) + _budget ))
  while :; do
    _remain=$((_deadline - $(now_epoch) ))
    [ "$_remain" -gt 0 ] || break
    [ "$_remain" -gt 3 ] && _remain=3
    svc_http_health "$_remain" && return 0
    [ "$(( _deadline - $(now_epoch) ))" -gt 0 ] && sleep 1
  done
  return 1
}

write_cli() { # 修复 KSU modules_update 安装路径导致的入口失效
  [ -d "$BINDIR" ] || mkdir -p "$BINDIR" 2>/dev/null
  _w="$BINDIR/a2a.new.$$"
  {
    printf '%s\n' '#!/system/bin/sh'
    printf '%s\n' 'MODDIR=/data/adb/modules/agent2api'
    printf '%s\n' '[ -f "$MODDIR/libexec/a2a" ] || { echo "Agent2API 模块目录不存在或尚未重启生效" >&2; exit 1; }'
    printf '%s\n' 'exec sh "$MODDIR/libexec/a2a" "$@"'
  } >"$_w" 2>/dev/null || return 1
  chmod 755 "$_w" 2>/dev/null && mv -f "$_w" "$BINDIR/a2a" 2>/dev/null
}

svc_start_impl() {
  if svc_is_running; then
    say "已在运行（supervisor pid=$(svc_supervisor_pid)）"
    return 0
  fi
  # 旧 pidfile 可能已被 PID 复用；只有确认是本模块进程才处理
  _old=$(svc_supervisor_pid 2>/dev/null)
  if [ -n "$_old" ] && pid_alive "$_old" && ! pid_is_supervisor "$_old"; then
    rm -f "$RUNDIR/supervisor.pid" 2>/dev/null
  fi
  ensure_layout
  write_cli
  rm -f "$RUNDIR/stop" 2>/dev/null
  [ -x "$MODDIR/libexec/supervise.sh" ] || {
    say "启动失败：$MODDIR/libexec/supervise.sh 不存在或不可执行"; return 1;
  }
  # 问题 4-入口：本函数是所有 supervisor 的实际拉起点，而 control.sh 常在
  # Root 管理器上下文里执行 —— WebUI 经 ksu.exec 调 a2a start/restart、
  # action.sh 的 [执行] 按钮等，进程会继承 KSU App 的 cgroup
  # （cpuset:/top-app、cpu:/top-app），app 被杀/被冻结时整组连坐，这正是
  # 历次"后台服务莫名消失"事故的入口。supervise.sh 自身启动后还会再逃逸
  # 一次，但那发生在 exec 之后；这里先把"当前 shell"迁到各控制器层级根，
  # spawn 出的 supervisor 才能从干净的分组起步。尽力而为：迁移不完整只记
  # 警告日志，绝不阻断启动（与 supervise.sh 侧同一条原则）。
  if command -v cgroup_escape >/dev/null 2>&1; then
    if ! cgroup_escape >>"$SUPLOG" 2>&1; then
      log_to "$SUPLOG" "警告：svc_start 前 cgroup 逃逸不完全（部分控制器仍在 app 分组，详见上方逐控制器结果），继续启动"
    fi
  fi
  if command -v setsid >/dev/null 2>&1; then
    setsid "$MODDIR/libexec/supervise.sh" >>"$SUPLOG" 2>&1 </dev/null &
  else
    "$MODDIR/libexec/supervise.sh" >>"$SUPLOG" 2>&1 </dev/null &
  fi
  _i=0
  while [ "$_i" -lt 20 ]; do
    svc_is_running && { say "已启动（supervisor pid=$(svc_supervisor_pid)）"; return 0; }
    sleep 1
    _i=$((_i + 1))
  done
  say "启动超时，请看 $SUPLOG"
  return 1
}

svc_start() {
  _svc_outer_token=${UPDATE_LOCK_TOKEN:-}
  _svc_outer_path=${UPDATE_LOCK_PATH:-}
  # 这里刻意不装 trap。装了就必须在出口把调用者原来的处理器还原，
  # 而 POSIX sh 没有可移植的"读回当前 trap"手段；旧实现直接 `trap -`
  # 会把 cmd_rollback / upd_do_update 装的事务恢复处理器一起清掉，
  # 之后收到 TERM 就没人收尾，留下半截事务。
  # 锁的活性由 stale owner / 僵死 reaping 回收保证。
  # R07：临界区内可能被 TERM 打断，信号处理器会重入 svc_start/svc_stop。
  # 同一进程已经持锁时必须按「已持有」处理：再去 acquire 必然失败，直接
  # return 1 会让外层半途退出，update / service 两把 owner 一起残留。
  _svc_owned=0
  if update_lock_is_self "$RUNDIR/service.lock.d"; then
    _svc_owned=1
  else
    update_lock_acquire "$RUNDIR/service.lock.d" || return 1
  fi
  svc_start_impl
  _rc=$?
  [ "$_svc_owned" = "1" ] || update_lock_release "$RUNDIR/service.lock.d"
  UPDATE_LOCK_TOKEN=$_svc_outer_token
  UPDATE_LOCK_PATH=$_svc_outer_path
  return "$_rc"
}

term_pid_verified() { # $1=pid $2=supervisor|server $3=等待秒；不覆盖调用者 PID
  case "$2" in
    supervisor) pid_is_supervisor "$1" || return 0 ;;
    server) pid_is_server "$1" || return 0 ;;
  esac
  kill -TERM "$1" 2>/dev/null
  _term_i=0
  while [ "$_term_i" -lt "${3:-20}" ]; do
    pid_alive "$1" || return 0
    sleep 1
    _term_i=$((_term_i + 1))
  done
  case "$2" in
    supervisor) pid_is_supervisor "$1" || return 0 ;;
    server) pid_is_server "$1" || return 0 ;;
  esac
  kill -KILL "$1" 2>/dev/null
  _term_i=0
  while [ "$_term_i" -lt 3 ]; do
    pid_alive "$1" || return 0
    sleep 1
    _term_i=$((_term_i + 1))
  done
  # 身份消失（正常退出或 PID 被复用）才允许清理本模块状态。
  case "$2" in
    supervisor) ! pid_is_supervisor "$1" ;;
    server) ! pid_is_server "$1" ;;
  esac
}

svc_stop_impl() {
  # stop 标记让 supervisor 自己走清理路径；随后再按身份兜底
  : >"$RUNDIR/stop" 2>/dev/null
  _p=$(svc_supervisor_pid 2>/dev/null)
  _stop_rc=0
  if [ -n "$_p" ]; then term_pid_verified "$_p" supervisor 25 || _stop_rc=1; fi
  _sp=$(svc_server_pid 2>/dev/null)
  if [ -n "$_sp" ]; then term_pid_verified "$_sp" server 10 || _stop_rc=1; fi
  if [ "$_stop_rc" -ne 0 ] \
     || { [ -n "$_p" ] && pid_is_supervisor "$_p"; } \
     || { [ -n "$_sp" ] && pid_is_server "$_sp"; }; then
    say "停止超时：旧进程仍在，保留 PID/锁状态"
    return 1
  fi
  # 只清理由旧进程持有的实例锁。更新/回滚进程可能刚重启了新守护，
  # 盲 rm -rf 会连同新 owner、回收锁和后代次状态一起删掉。
  _stop_owner=$(cat "$RUNDIR/lock/owner" 2>/dev/null) || _stop_owner=""
  _stop_opid=$(printf '%s\n' "$_stop_owner" | awk '{print $1}')
  _stop_oticks=$(printf '%s\n' "$_stop_owner" | awk '{print $2}')
  if [ -n "$_stop_opid" ] && [ -n "$_stop_oticks" ] \
     && { ! pid_alive "$_stop_opid" || [ "$(proc_start_ticks "$_stop_opid" 2>/dev/null)" != "$_stop_oticks" ]; }; then
    # R06：外层身份必须在取内层锁之前存好。旧顺序是 acquire 之后才存，
    # 存进去的已是内层 token；恢复后外层 service.lock.d 的 owner 再也匹配不上，
    # svc_stop 报成功却留下 service owner，下一次安装直接「另一个事务正在运行」。
    _stop_outer_token=${UPDATE_LOCK_TOKEN:-}
    _stop_outer_path=${UPDATE_LOCK_PATH:-}
    if update_lock_is_self "$RUNDIR/lock"; then
      : # 已经是本进程的实例锁：不重复取，也不要重复放
    else
      update_lock_acquire "$RUNDIR/lock" 2 || return 1
      rm -f "$RUNDIR/lock/owner" 2>/dev/null
      UPDATE_LOCK_TOKEN=""
      UPDATE_LOCK_PATH=""
      rmdir "$RUNDIR/lock" 2>/dev/null
    fi
    UPDATE_LOCK_TOKEN=$_stop_outer_token
    UPDATE_LOCK_PATH=$_stop_outer_path
  fi
  rm -f "$RUNDIR/server.pid" "$RUNDIR/server.start" "$RUNDIR/supervisor.pid" "$RUNDIR/supervisor.start" "$RUNDIR/stop" 2>/dev/null
  return 0
}

svc_stop() {
  _svc_outer_token=${UPDATE_LOCK_TOKEN:-}
  _svc_outer_path=${UPDATE_LOCK_PATH:-}
  # 同 svc_start：不覆盖调用者的信号处理器，且允许同进程重入。
  _svc_owned=0
  if update_lock_is_self "$RUNDIR/service.lock.d"; then
    _svc_owned=1
  else
    update_lock_acquire "$RUNDIR/service.lock.d" || return 1
  fi
  svc_stop_impl
  _rc=$?
  [ "$_svc_owned" = "1" ] || update_lock_release "$RUNDIR/service.lock.d"
  UPDATE_LOCK_TOKEN=$_svc_outer_token
  UPDATE_LOCK_PATH=$_svc_outer_path
  return "$_rc"
}

svc_restart() { svc_stop || return 1; sleep 1; svc_start; }

# 找残留：排除调用者、父进程、当前 supervisor；命令行必须带本模块真实路径。
# $1 可选 --include-self：卸载/强化模式 —— 不再排除当前 supervisor（卸载时
# 它必须退出，否则删完身份它还会继续拉起服务），并把两个后台执行体
# （boot-worker、hot-restart worker）一并纳入扫描。无参数调用（supervise、
# updater 等运行时路径）的语义保持不变，绝不波及 worker。
svc_stray_pids() {
  _sp_mode="${1:-}"
  _self="$$"
  _sup=$(svc_supervisor_pid 2>/dev/null)
  _ppid=$(sed 's/.*) //' "/proc/$$/stat" 2>/dev/null | awk '{print $2}')
  for _p in /proc/[0-9]*; do
    _pid="${_p#/proc/}"
    [ "$_pid" = "$_self" ] && continue
    if [ "$_sp_mode" != "--include-self" ] && [ "$_pid" = "$_sup" ]; then
      continue
    fi
    [ "$_pid" = "$_ppid" ] && continue
    [ -r "$_p/cmdline" ] || continue
    _cl=$(tr '\0' ' ' <"$_p/cmdline" 2>/dev/null)
    case "$_cl" in
      *"$PAYLOAD/agent2api-server"*|*"$MODDIR/libexec/launch.sh"*)
        printf '%s ' "$_pid"; continue ;;
    esac
    case "$_cl" in
      *"$DATADIR/plugins/"*|*"$DATADIR/providers/"*|*"$DATADIR/kernels/"*|\
      *"$DATADIR/runtimes/"*|\
      *"$HOMEDIR/plugins/"*|*"$HOMEDIR/providers/"*|*"$HOMEDIR/kernels/"*)
        printf '%s ' "$_pid" ;;
    esac
    # 卸载/强化模式：supervisor 与两个后台 worker 不算"残留"，但卸载时
    # 必须一起退出（否则它们会在卸载后把服务重新拉起来）；同样只按本模块
    # 真实路径精确匹配，绝不 pkill -f。
    if [ "$_sp_mode" = "--include-self" ]; then
      case "$_cl" in
        *"$MODDIR/libexec/supervise.sh"*|\
        *"$MODDIR/libexec/boot-worker.sh"*|*"$MODDIR/libexec/hot-restart.sh"*)
          printf '%s ' "$_pid" ;;
      esac
    fi
  done
  return 0
}

svc_kill_stray() {
  _pids=$(svc_stray_pids 2>/dev/null)
  [ -n "$_pids" ] || return 0
  for _pid in $_pids; do kill -TERM "$_pid" 2>/dev/null; done
  sleep 2
  # 重新扫描并复核，避免等待期间 PID 被复用后杀错
  for _pid in $_pids; do
    case " $(svc_stray_pids 2>/dev/null) " in *" $_pid "*) kill -KILL "$_pid" 2>/dev/null ;; esac
  done
  return 0
}

# 卸载/强化停止（问题 5）：覆盖本模块全部进程身份 —— 当前 supervisor、
# server、插件、boot-worker 与 hot-restart worker（后两个是可能常驻的后台
# 执行体，不清理它们会在卸载后把服务重新拉起来）。与 svc_kill_stray 的
# 区别：经 --include-self 扫描，不排除当前 supervisor。TERM（带超时）→
# KILL → 逐个核实退出；全部退出返回 0；仍存活的 pid 列在 stderr 并返回 1，
# 调用方（uninstall.sh）必须据此中止，不得继续删除任何状态与数据。
svc_kill_all_module_procs() {
  _kap_pids=$(svc_stray_pids --include-self 2>/dev/null)
  [ -n "$_kap_pids" ] || return 0
  for _kap_pid in $_kap_pids; do kill -TERM "$_kap_pid" 2>/dev/null; done
  _kap_i=0
  while [ "$_kap_i" -lt 10 ]; do
    _kap_pids=$(svc_stray_pids --include-self 2>/dev/null)
    [ -z "$_kap_pids" ] && return 0
    sleep 1
    _kap_i=$((_kap_i + 1))
  done
  # 等待期间 PID 可能死亡后被复用；每轮重扫后再逐个复核，只杀仍在最新
  # 扫描结果里的 pid，绝不按旧列表盲杀（与 svc_kill_stray 同一套防御）。
  for _kap_pid in $_kap_pids; do
    case " $(svc_stray_pids --include-self 2>/dev/null) " in
      *" $_kap_pid "*) kill -KILL "$_kap_pid" 2>/dev/null ;;
    esac
  done
  _kap_i=0
  while [ "$_kap_i" -lt 5 ]; do
    _kap_pids=$(svc_stray_pids --include-self 2>/dev/null)
    [ -z "$_kap_pids" ] && return 0
    sleep 1
    _kap_i=$((_kap_i + 1))
  done
  printf '仍有模块进程存活：%s\n' "$_kap_pids" >&2
  return 1
}
