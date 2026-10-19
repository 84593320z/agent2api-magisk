#!/system/bin/sh
# Agent2API Magisk 模块公共库：路径 / 日志 / DNS / chroot 挂载 / 进程控制 / 在线更新
# 由 service.sh、bin/ctl、action.sh、uninstall.sh source；不单独执行。
#
# v3.1.2 变更（相对 v3.1.1）：
#   * 日志轮转改 copytruncate（mv 会让长期持有 fd 的写入方把 .1 写爆）
#   * rootfs 只读加固走两步法 + 写测试（一步法 bind,ro 在内核层被忽略）
#   * 停机加"按 exe 扫描"兜底（pidfile 丢失 / 安装期 $ROOT 指向新目录都能杀干净）
#   * setsid 失败回退双 fork（守护静默拉不起来）
#   * oom_score_adj -1000 → -900 + RSS 看门狗（泄漏时不再拖死整机）
#   * 空文件参与算术、tar 路径穿越、端口被占无诊断、时区缺失等一批修复
#
# v3.1.1 变更（相对 v3.1.0）：
#   * 数据/日志 bind 失败从"继续启动"改为"拒绝启动"（防止数据写进模块目录）
#   * rootfs 只读加固（服务进程即使被攻破也改不了自己的二进制与运行时）
#   * /dev/tty 不再 bind（无用且指向无意义的控制终端）
#   * OOM 保护：服务进程 oom_score_adj=-1000，内核内存压力下不被杀
#   * DNS：props 之外新增 dumpsys connectivity 兜底 + IPv6 兜底 + timeout 参数
#   * 在线更新层：/data/adb/agent2api/update 下的二进制与 ui bind 覆盖进 chroot
#   * 原子锁（mkdir）根治双守护竞态
#   * 健康探活 /health、崩溃通知、日志运行中轮转（不再依赖重启）

: "${MODDIR:?MODDIR 未设置}"
# MODDIR 必须是绝对路径：_have_mount 拿它去和 /proc/mounts 里的挂载点做字符串比对，
# 相对路径永远比不上，会导致每轮重复挂载。
MODDIR=$(cd "$MODDIR" 2>/dev/null && pwd) || true

# 数据根目录。允许用环境变量覆盖只为「离线桩测试 / 临时排查」：
# 真机上永远走默认值，env.sh 里的配置不会改到它（load_env 之后才 source）。
DATA=${AGENT2API_DATA_DIR:-/data/adb/agent2api}
ROOT="$MODDIR/rootfs"
LOGDIR="$DATA/logs"
MODLOG="$LOGDIR/module.log"   # 守护进程自己的日志（log() 写入）
SRVLOG="$LOGDIR/server.log"   # agent2api-server 的 stdout/stderr
APPLOG="$LOGDIR/app.log"      # 服务自身按 AGENT2API_LOG_FILE 写的日志
PIDFILE="$DATA/agent2api.pid"
SUPPID="$DATA/supervisor.pid"
SUPLOCK="$DATA/sup.lock"      # mkdir 原子锁：双守护竞态的根治（check-then-act 有窗口）
FATALFILE="$DATA/fatal"       # 不可自愈状态（数据挂载失败等）的说明，ctl restart 清除
RESOLV_SRC="$DATA/resolv.conf"  # 真正的 resolv.conf：rootfs 只读化后仍可随时改写
UPDDIR="$DATA/update"         # 在线更新层（bind 覆盖进 chroot 的 /opt/agent2api）
UPDSTAGE="$DATA/update.staging"
BACKUPDIR="$DATA/backup"
RESTARTS="$DATA/restarts"

# ── 在线更新常量 ──────────────────────────────────────────
# 仓库地址可由用户在 env.sh 里覆盖（AGENT2API_REPO=owner/name）：
# 上游仓库被封/搬家时指到新家，解封后删掉那行即回到默认仓库，无需重刷模块。
# 必须延迟到 load_env 之后求值（lib.sh 被 source 时 env.sh 还没加载），
# 所以用函数而不是变量——GH_REPO 在 source 瞬间取值会拿不到用户配置。
GH_REPO_DEFAULT="Agent2API/agent2api"
ASSET_NAME="agent2api-server-linux-arm64.tar.gz"

# 归一化 owner/name：接受 owner/name、https://github.com/owner/name(.git)、末尾带 /
# 只放行"恰好一段 owner/name"（空段、多级斜杠都按非法处理），
# 非法时退回默认仓库并记日志，绝不拼出坏 URL。
gh_repo() {
  _r=${AGENT2API_REPO:-$GH_REPO_DEFAULT}
  _r=${_r#https://github.com/}
  _r=${_r#http://github.com/}
  _r=${_r#git@github.com:}
  _r=${_r%/}
  _r=${_r%.git}
  _head=${_r%%/*}
  _tail=${_r#*/}
  if [ "$_r" != "$_head" ] && [ -n "$_head" ] && [ -n "$_tail" ] \
     && [ "$_tail" = "${_tail%%/*}" ]; then
    echo "$_r"
  else
    [ -n "${AGENT2API_REPO:-}" ] && \
      log "warning: AGENT2API_REPO=\"$_r\" 不是 owner/name 格式，本次退回默认仓库 $GH_REPO_DEFAULT"
    echo "$GH_REPO_DEFAULT"
  fi
}

gh_api_url() {
  echo "https://api.github.com/repos/$(gh_repo)/releases/latest"
}

log() {
  mkdir -p "$LOGDIR" 2>/dev/null
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$MODLOG" 2>/dev/null
}

# 安全加载用户配置：env.sh 是手改的，写错一个引号就会让整段脚本在 source 处死掉。
# 先在子 shell 里试执行一次，语法没问题才真正 source。
# 每个进程只报一次，否则守护循环每轮都会刷同一行告警。
ENV_WARNED=
load_env() {
  [ -f "$DATA/env.sh" ] || return 0
  if ! ( set -e; . "$DATA/env.sh" ) >/dev/null 2>&1; then
    if [ -z "$ENV_WARNED" ]; then
      log "warning: $DATA/env.sh 有语法错误，本次忽略用户配置（改成合法赋值后 ctl restart）"
      ENV_WARNED=1
    fi
    return 1
  fi
  set -a
  . "$DATA/env.sh"
  set +a
  return 0
}

# 超限就裁成 .1（只留一份历史，够排查就行）
#
# v3.1.2 关键修复：这里原来用 `mv "$1" "$1.1"`，对长期持有 fd 的写入方是致命的。
#   server.log 是 start_server 里 `>> "$SRVLOG"` 打开、随 exec 继承给服务进程的；
#   app.log 由服务自己按 AGENT2API_LOG_FILE 打开（常驻 appender 同样持有 fd）。
#   mv 只改目录项，写入方继续往同一个 inode 追加 —— 也就是继续写 .1；
#   而原路径消失了，下一轮 `[ -f "$1" ]` 直接 return，轮转永久失效，
#   .1 从此无上限增长（几周就能把 /data 写满）。
# 改成 copy + 原地截断：inode 不变，写入方的 fd 继续有效，体积立刻归零。
rotate_log() {
  [ -f "$1" ] || return 0
  _sz=$(wc -c < "$1" 2>/dev/null || echo 0)
  case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
  [ "$_sz" -gt "$2" ] || return 0
  cp -f "$1" "$1.1" 2>/dev/null && : > "$1" 2>/dev/null
  return 0
}

# 读 /proc/<pid>/cmdline 判断这个 pid 到底是谁。
# 关键作用：PID 会被系统复用，pidfile 里的数字事后可能已经属于别的进程，
# 不做校验就 kill 等于随机杀进程。
pid_matches() {
  [ -n "$1" ] || return 1
  # 重定向放到子 shell 上：进程可能刚好在这一刻退出，
  # 若写成 cmd < /proc/$1/cmdline 2>/dev/null，shell 打开文件失败时错误会漏到真实 stderr。
  { tr '\0' ' ' < "/proc/$1/cmdline"; } 2>/dev/null | grep -qF "$2"
}

# 比 pid_matches 更严格：cmdline 匹配 + exe 确实是本模块 rootfs 里的那个二进制。
# /proc/pid/exe 在宿主侧看到的是全局路径（bind 覆盖后也是 rootfs 内路径），
# 两者都校验可挡住"碰巧 cmdline 里带 agent2api-server 的无关进程"。
server_pid_ok() {
  pid_matches "$1" agent2api-server || return 1
  _exe=$(readlink "/proc/$1/exe" 2>/dev/null)
  case "$_exe" in
    "$ROOT"/opt/agent2api/*) return 0 ;;
    *) return 1 ;;
  esac
}

# ── 按 exe 特征扫描 server 进程（v3.1.2 新增）────────────────
# 为什么需要它：pidfile 与 $ROOT 都可能"不可信"。
#   * pidfile 被误删 / /data 被清理工具动过 → stop_server 认不出进程，孤儿占着端口；
#   * 安装期 customize.sh 跑的是 modules_update 下的新 ctl，$ROOT 指向新目录，
#     而正在跑的是旧目录里的二进制 → server_pid_ok 永远不匹配，杀不掉。
# 这条通道不依赖 pidfile、也不依赖当前 $ROOT，只认「路径里带 rootfs/opt/agent2api
# 的 agent2api-server」，跨模块目录版本都能命中。只用于停机，不参与常规存活判断。
srv_pids() {
  for _p in /proc/[0-9]*; do
    _q=${_p#/proc/}
    [ "$_q" = "$$" ] && continue
    _e=$(readlink "$_p/exe" 2>/dev/null) || continue
    case "$_e" in
      */rootfs/opt/agent2api/agent2api-server) echo "$_q" ;;
    esac
  done
}

kill_by_scan() {
  _pids=$(srv_pids)
  [ -n "$_pids" ] || return 0
  # shellcheck disable=SC2086
  log "scan: 发现游离 server 进程（$_pids），终止"
  # shellcheck disable=SC2086
  kill -TERM $_pids 2>/dev/null
  _i=0
  while [ "$_i" -lt 10 ]; do
    _alive=$(srv_pids)
    [ -z "$_alive" ] && return 0
    _sleep 0.5
    _i=$((_i + 1))
  done
  _alive=$(srv_pids)
  # shellcheck disable=SC2086
  [ -n "$_alive" ] && kill -9 $_alive 2>/dev/null
  return 0
}

# chroot 的实现来源：优先系统自带 toybox，其次 Magisk / KernelSU 的 busybox
find_chroot() {
  for _p in /system/bin/chroot /system/xbin/chroot /vendor/bin/chroot; do
    [ -x "$_p" ] && { echo "$_p"; return 0; }
  done
  if command -v chroot >/dev/null 2>&1; then
    command -v chroot
    return 0
  fi
  for _bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /system/xbin/busybox; do
    [ -x "$_bb" ] || continue
    if "$_bb" --list 2>/dev/null | grep -qx chroot; then
      echo "$_bb chroot"
      return 0
    fi
  done
  return 1
}

# busybox 来源（awk / wget / tar / od / setuidgid 这类 applet 依赖它）
# Android 自带的 toybox 没有 awk，且各 ROM 差异大，统一从根管理器的 busybox 找。
find_busybox() {
  [ -n "${_BB_CACHE:-}" ] && { echo "$_BB_CACHE"; return 0; }
  for _p in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox \
            /data/adb/ap/bin/busybox /system/xbin/busybox /system/bin/busybox; do
    [ -x "$_p" ] && { _BB_CACHE=$_p; echo "$_p"; return 0; }
  done
  return 1
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  _rp=$(cat "$PIDFILE" 2>/dev/null)
  server_pid_ok "$_rp"
}

# 守护进程的判定用命令行里的固定标记，不用路径：
# 脚本可能被相对路径或软链接拉起（KernelSU / 某些管理器会），按路径比会认不出来，
# 认不出来就会重复拉起一个守护、或者 stop 杀不掉它。
SUP_MARK="service.sh --loop"

supervisor_running() {
  [ -f "$SUPPID" ] || return 1
  _sp0=$(cat "$SUPPID" 2>/dev/null)
  pid_matches "$_sp0" "$SUP_MARK"
}

# 端口 LISTEN socket 的 inode 列表（/proc/net/tcp{,6} 第 4 字段 0A = LISTEN）
_port_inodes() {
  _hex=$(printf '%04X' "${AGENT2API_PROXY_PORT:-3065}" 2>/dev/null)
  [ -n "$_hex" ] || return 1
  grep -h ":$_hex " /proc/net/tcp /proc/net/tcp6 2>/dev/null | while read _l; do
    set -- $_l
    [ "$4" = "0A" ] && echo "${10}"
  done
}

port_listening() {
  # 只认 LISTEN(0A)：原来只按端口号 grep，TIME_WAIT(06)/CLOSE_WAIT 的残留条目
  # 也会命中，服务刚停时 status 会误报"仍在监听"。
  [ -n "$(_port_inodes)" ]
}

# 端口监听者身份校验：先在 /proc/net/tcp{,6} 里找该端口的 LISTEN socket inode，
# 再确认其中一个是服务进程持有的 fd。挡住"3065 被别的进程占了，status 却报已监听"。
# 变量名带前缀：这些函数被 status/doctor/健康探活反复调用，而 shell 没有局部变量，
# 复用 _pid 之类的通用名会悄悄踩掉调用方的值。
port_owned_by_server() {
  server_pid_ok "$(cat "$PIDFILE" 2>/dev/null)" || return 1
  _pob_pid=$(cat "$PIDFILE" 2>/dev/null)
  _pob_inos=$(_port_inodes)
  [ -n "$_pob_inos" ] || return 1
  for _pob_ino in $_pob_inos; do
    ls -l "/proc/$_pob_pid/fd" 2>/dev/null | grep -q "socket:\[$_pob_ino\]" && return 0
  done
  return 1
}

# 谁占着这个端口（pid）。只在失败路径调用，扫一遍 /proc/*/fd 的开销可以接受。
# 为什么需要：端口被别的应用占住时，服务 bind 失败 → 退避重启无限循环，
# 日志里只有 rc=1，用户完全无法归因。把占位者找出来写进 fatal 标记，
# status / doctor 就能直接说"3065 被 pid=12345 占用"。
port_owner_pid() {
  _pop_inos=$(_port_inodes)
  [ -n "$_pop_inos" ] || return 1
  for _pop_p in /proc/[0-9]*; do
    _pop_q=${_pop_p#/proc/}
    [ "$_pop_q" = "$$" ] && continue
    for _pop_ino in $_pop_inos; do
      if ls -l "$_pop_p/fd" 2>/dev/null | grep -q "socket:\[$_pop_ino\]"; then
        echo "$_pop_q"
        return 0
      fi
    done
  done
  return 1
}

# 生成 resolv.conf：glibc 只认这个文件，Android 自身不用它。
# v3.1.1：真实文件放在 /data（rootfs 挂成只读后仍可改写），挂载时 bind 进 chroot。
# DNS 发现链：DNS_LIST（用户指定）→ 系统 props → dumpsys connectivity → 公网兜底。
# 注意 glibc 的 MAXNS=3：再多条目也只取前三个，所以兜底顺序（用户 > 系统 > 公网）比数量重要。
#
# v3.1.2 两处修复：
#   1) 先在变量里拼好、一次 printf 写入。原来是 `: >` 清空后逐行追加，bind 挂载下
#      服务可能正好读到"只有注释行"的中间态 → 一次 DNS 解析失败。
#   2) IPv6 兜底原来固定追加在第 4 位，而 glibc 只消费前 3 个 —— 那条兜底从未生效，
#      是死代码。现在改成：检测到 IPv6 默认路由且没探到 v6 DNS 时，把它顶到兜底序列最前。
gen_resolv() {
  _rf="$RESOLV_SRC"
  mkdir -p "$(dirname "$_rf")" 2>/dev/null
  _ns=""
  _ns_add() {
    [ -n "$1" ] || return 0
    case " $_ns " in
      *" $1 "*) return 0 ;;
    esac
    _ns="$_ns $1"
  }

  if [ -n "${DNS_LIST:-}" ]; then
    for _s in $DNS_LIST; do _ns_add "$_s"; done
  fi
  # 部分 ROM / 网络会把 DNS 写进这些 props
  for _p in net.dns1 net.dns2 net.dns3 net.dns4 \
            dhcp.wlan0.dns1 dhcp.wlan0.dns2 dhcp.wlan0.dns3 dhcp.wlan0.dns4 \
            dhcp.eth0.dns1 dhcp.eth0.dns2 \
            net.wlan0.dns1 net.wlan0.dns2; do
    _ns_add "$(getprop "$_p" 2>/dev/null)"
  done
  # Android 8+ 之后 props 常常是空的，root 下从 connectivity 服务再抓一份
  # （real DNS 每网络 agent 一行 "DNS servers: [ /1.2.3.4 /5.6.7.8 ]"）
  # 直接调用不用 timeout 包一层：dumpsys 是毫秒级 binder 调用，
  # 而外层 timeout 无法转发 shell 函数（也会让桩测试不可行）
  if command -v dumpsys >/dev/null 2>&1; then
    _ds=$(dumpsys connectivity 2>/dev/null)
    for _s in $(echo "$_ds" | sed -n 's/.*DNS servers: *\[\([^]]*\)\].*/\1/p' \
                | tr ' ,/' '\n\n\n' | grep -E '^[0-9a-fA-F:.]{3,45}$'); do
      _ns_add "$_s"
    done
  fi

  # 兜底：不足 3 个才补（glibc 实际只消费前 3 个 nameserver，堆多了只是噪音）
  _fb=""
  if ! echo " $_ns " | grep -q ':'; then
    # 没有任何 v6 DNS，但设备确实有 v6 默认路由（全零前缀）→ 纯 v6 网络下 v4 兜底全死
    if [ -r /proc/net/ipv6_route ] && grep -qE '^0{32} 00 ' /proc/net/ipv6_route 2>/dev/null; then
      _fb="2400:3200::1"
    fi
  fi
  for _s in $_fb 223.5.5.5 119.29.29.29 8.8.8.8; do
    [ "$(echo "$_ns" | wc -w)" -ge 3 ] && break
    _ns_add "$_s"
  done

  # 一次写入（单次 write 系统调用，尽量压缩"服务读到半截文件"的窗口）
  _content="# generated by agent2api module: $(date '+%Y-%m-%d %H:%M:%S')"
  for _s in $_ns; do
    _content="$_content
nameserver $_s"
  done
  _content="$_content
options timeout:1 attempts:2"
  printf '%s\n' "$_content" > "$_rf" 2>/dev/null

  # rootfs 尚未 bind（未挂载/手动 ctl dns）时顺手同步一份到 rootfs，挂载后以 bind 为准
  if ! _have_mount "$ROOT/etc/resolv.conf"; then
    cp -f "$_rf" "$ROOT/etc/resolv.conf" 2>/dev/null
  fi
  log "resolv.conf: $(grep -c '^nameserver' "$_rf" 2>/dev/null) nameservers"
}

_have_mount() {
  grep -q " $1 " /proc/mounts 2>/dev/null
}

# 部分 ROM 的 toybox / busybox 没编进小数秒 sleep，失败就退化成整秒
_sleep() {
  sleep "$1" 2>/dev/null || sleep 1
}

# 只挂 chroot 真正需要的东西，不把整个 /dev、/sys 敞给第三方二进制：
#   /dev  逐个设备 bind（null/zero/random/urandom；tty 已去掉——服务器进程用不到
#         控制终端，bind 进去的 /dev/tty 只会指向挂载者早已退出的控制终端）
#   /sys  不挂（见下面的说明）
#   /proc 独立挂一份
#   tmp   tmpfs（SQLite 临时文件），大小可配
#   resolv.conf / bin/busybox 从 /data bind 进来（rootfs 只读后仍可更新）
#
# 失败分级（v3.1.1 的核心修复）：
#   致命（MOUNT_FATAL=1，拒启）：proc、null、urandom、tmpfs、数据、日志
#     ——数据 bind 失败时继续启动，SQLite 会写进模块目录，重刷模块即静默丢数据。
#   警告（记日志，继续）：rootfs 只读加固、zero、random、resolv、busybox、更新层
mount_chroot() {
  _rc=0
  MOUNT_FATAL=0
  mkdir -p "$ROOT/proc" "$ROOT/sys" "$ROOT/dev" "$ROOT/tmp" \
           "$ROOT/var/lib/agent2api" "$ROOT/var/log/agent2api" 2>/dev/null

  # 0) rootfs 整体只读加固：自身 bind + ro。服务进程即使被攻破也改不了
  #    自己的二进制 / 运行时 / ca-certificates；后续挂在其上的 proc/dev/tmp/data
  #    与更新层都是独立挂载，不受 ro 影响（在 ro 挂载上再挂子挂载是允许的）。
  #
  #    v3.1.2 修复：原来先试 `mount -o bind,ro` 一步法，但它**在内核层面无效**——
  #    mount(2) 单次调用里 MS_BIND|MS_RDONLY 的 MS_RDONLY 会被忽略（只读 bind 必须
  #    由 MS_REMOUNT|MS_BIND|MS_RDONLY 二次调用才生效）。util-linux 是用户态自己拆
  #    成两次 syscall 才做到的；Android 的 toybox 各版本行为不一致，不拆的版本会
  #    **返回成功但仍是可写**，于是 if ! 分支不进入、两步兜底不执行、也没有任何告警，
  #    日志里却只有"已加固"的正面描述 —— 虚假安全感。
  #    现在只走确定有效的两步法，并在挂载后做写测试：只读挂载连 root 都写不进去
  #    （EROFS），这是唯一可靠的判据。
  if ! _have_mount "$ROOT"; then
    if mount -o bind "$ROOT" "$ROOT" 2>/dev/null; then
      # 三种写法都试一遍：toybox 各版本对 remount+bind+ro 的解析不一致，
      # 真机上见过 `remount,bind,ro` 直接失败、而 `remount,ro,bind` 有效的。
      # 最终以写测试为准，不靠返回值下结论。
      mount -o remount,bind,ro "$ROOT" "$ROOT" 2>/dev/null || \
        mount -o remount,ro,bind "$ROOT" "$ROOT" 2>/dev/null || \
        mount -o remount,ro "$ROOT" "$ROOT" 2>/dev/null || true
      if : > "$ROOT/.rotest" 2>/dev/null; then
        rm -f "$ROOT/.rotest" 2>/dev/null
        _rc=1
        log "warning: rootfs 仍可写 —— 只读加固未生效（内核/toybox 忽略了 ro）"
      else
        log "rootfs 只读加固已生效"
      fi
    else
      _rc=1
      log "warning: rootfs 只读加固失败（bind 失败，继续，风险=可写二进制）"
    fi
  fi

  # 1) proc：致命
  if ! _have_mount "$ROOT/proc"; then
    mount -t proc proc "$ROOT/proc" 2>/dev/null || { _rc=1; MOUNT_FATAL=1; log "FATAL: proc 挂载失败"; }
  fi

  # 2) dev：tmpfs + mknod（v3.1.3 重写）
  #
  #    原来的做法是「把宿主机的 /dev/null 逐个 bind 到 rootfs 里的占位文件」。
  #    真机实测（KernelSU + toybox 0.8.13-android）：这条路根本走不通 ——
  #    `mount -o bind /dev/null <普通文件>` 会被 toybox 当成 loop 挂载：
  #        losetup: /dev/block/loop52=/dev/null: Invalid argument
  #        mount: losetup failed
  #    四个节点全失败，其中 null/urandom 是致命项 → 守护每轮都在这里拒启。
  #    （目录 bind 是好的，只有「字符设备 → 普通文件」这一种组合坏。）
  #
  #    新做法：tmpfs 挂到 $ROOT/dev，再 mknod 出四个节点。tmpfs 不继承 /data
  #    的 nodev，节点可直接用；顺带避免了把宿主机设备节点暴露给 chroot。
  #    兜底：mknod 被 SELinux 拦时，退化成整目录 bind /dev（可用性优先，记警告）。
  if ! _have_mount "$ROOT/dev"; then
    _dev_ok=0
    if mount -t tmpfs -o size=1m,mode=0755 tmpfs "$ROOT/dev" 2>/dev/null; then
      for _spec in "null 1 3" "zero 1 5" "random 1 8" "urandom 1 9"; do
        # shellcheck disable=SC2086
        set -- $_spec
        [ -c "$ROOT/dev/$1" ] || mknod "$ROOT/dev/$1" c "$2" "$3" 2>/dev/null
      done
      chmod 0666 "$ROOT/dev/null" "$ROOT/dev/zero" "$ROOT/dev/random" "$ROOT/dev/urandom" 2>/dev/null
      _dev_ok=1
      for _n in null zero random urandom; do
        [ -c "$ROOT/dev/$_n" ] || _dev_ok=0
      done
      # 可用性验证：写 null 必须成功，读 urandom 必须拿得到字节
      [ "$_dev_ok" = "1" ] && { : > "$ROOT/dev/null" 2>/dev/null || _dev_ok=0; }
      [ "$_dev_ok" = "1" ] && { head -c 1 "$ROOT/dev/urandom" >/dev/null 2>&1 || _dev_ok=0; }
      if [ "$_dev_ok" = "1" ]; then
        log "chroot /dev：tmpfs + mknod 就绪（null/zero/random/urandom）"
      else
        umount "$ROOT/dev" 2>/dev/null
      fi
    fi
    if [ "$_dev_ok" = "0" ]; then
      if mount -o bind /dev "$ROOT/dev" 2>/dev/null; then
        _dev_ok=1
        log "warning: chroot /dev 退化为整目录 bind（chroot 内可见全部设备节点，安全性下降）"
      fi
    fi
    if [ "$_dev_ok" = "0" ]; then
      _rc=1; MOUNT_FATAL=1
      log "FATAL: chroot /dev 设备节点不可用（tmpfs+mknod 与目录 bind 都失败）"
    fi
  fi

  # /sys 不挂进去。服务读 /sys/fs/cgroup 只是为了推算线程池大小，
  # 读不到就退回 num_cpus；而 sysfs 一旦因为 bind 的只读语义被带成
  # 全局只读，影响的是整台手机而不是这个模块。两相权衡，不挂。

  # 3) resolv.conf：bind /data 里的真身（gen_resolv 随时改写、立即生效）
  if [ -f "$RESOLV_SRC" ] && ! _have_mount "$ROOT/etc/resolv.conf"; then
    mount -o bind "$RESOLV_SRC" "$ROOT/etc/resolv.conf" 2>/dev/null || \
      log "warning: resolv.conf bind 失败（用 rootfs 内的静态副本）"
  fi

  # 4) busybox bind 进 chroot（只给实验性降权用：chroot 后需要它做 setuidgid）
  _bb=$(find_busybox 2>/dev/null)
  if [ -n "$_bb" ] && [ -e "$ROOT/bin/busybox" ] && ! _have_mount "$ROOT/bin/busybox"; then
    mount -o bind "$_bb" "$ROOT/bin/busybox" 2>/dev/null || \
      log "warning: busybox bind 失败（降权选项将不可用）"
  fi

  # 5) tmpfs：致命（SQLite 临时文件）
  if ! _have_mount "$ROOT/tmp"; then
    # tmpfs 占的是 RAM 不是磁盘：默认 64m（v3.1.0 的值）足够 SQLite 临时文件，
    # v3.1.1 提到 256m 等于在最坏情况下白占 256MB 物理内存。跑大批量导入导出
    # 再按需调大（AGENT2API_TMPFS_SIZE）。
    mount -t tmpfs -o size="${AGENT2API_TMPFS_SIZE:-64m},mode=1777" tmpfs "$ROOT/tmp" 2>/dev/null || \
      { _rc=1; MOUNT_FATAL=1; log "FATAL: tmpfs 挂载失败"; }
  fi

  # 6) 数据与日志：致命（v3.1.0 的静默丢数据洞就在这里）
  if ! _have_mount "$ROOT/var/lib/agent2api"; then
    mount -o bind "$DATA/data" "$ROOT/var/lib/agent2api" 2>/dev/null || \
      { _rc=1; MOUNT_FATAL=1; log "FATAL: 数据目录 bind 失败（$DATA/data）"; }
  fi
  if ! _have_mount "$ROOT/var/log/agent2api"; then
    mount -o bind "$LOGDIR" "$ROOT/var/log/agent2api" 2>/dev/null || \
      { _rc=1; MOUNT_FATAL=1; log "FATAL: 日志目录 bind 失败（$LOGDIR）"; }
  fi

  # 7) 在线更新：**不再 bind 覆盖**（v3.1.4）。
  #
  #    以前的做法是把 /data/adb/agent2api/update/agent2api-server bind 到
  #    rootfs 的同名文件上。好处是"更新层与模块内置分离、重刷模块不丢"，
  #    代价是**面板里的自更新彻底失效**：服务端换二进制用的是
  #        rename(现行 → .backup) + rename(新 → 现行)
  #    而 bind 挂载点不能被 rename（EBUSY），面板只会得到一句
  #    "备份现行文件失败"。
  #
  #    现在改为：rootfs 的 opt/agent2api 就是运行版本，面板和 ctl 都直接写它。
  #    代价是重刷模块会把载荷退回内置版本（重刷后重跑一次 ctl update 即可），
  #    换来的是"面板里点一下就能升级"这条主路径。

  return $_rc
}

# 先正常卸，占用就 lazy 卸：宁可挂载点晚点消失，也不要把挂载滞留到下次开机。
# 顺序=挂载的逆序：更新层最先卸，rootfs 自身只读 bind 最后卸（它要等所有子挂载卸完，
# 否则 umount 会报 busy）。
umount_chroot() {
  # 列表里保留 sys：新版本已经不再 bind /sys，但升级前装的旧版本可能还留着，
  # 顺手卸掉比一直带着强（本来就没挂载时 umount 什么都不做）。
  for _d in bin/busybox etc/resolv.conf \
            tmp var/log/agent2api var/lib/agent2api sys \
            dev proc; do
    _have_mount "$ROOT/$_d" || continue
    umount "$ROOT/$_d" 2>/dev/null || umount -l "$ROOT/$_d" 2>/dev/null
  done
  # rootfs 自身只读 bind（若启用过）
  if _have_mount "$ROOT"; then
    umount "$ROOT" 2>/dev/null || umount -l "$ROOT" 2>/dev/null
  fi
  return 0
}

# 时区校验：TZ_NAME 写错（如 Asia/Shanghia）时，chrono/glibc 会退回 /etc/localtime，
# 而 rootfs 里若没有那个文件就静默变 UTC —— 报表时间整体错 8 小时，极难发现。
# 这里在启动前校验一次，不存在就告警并回落 Asia/Shanghai。
resolve_tz() {
  case "${TZ_NAME:-}" in
    '') TZ_NAME=Asia/Shanghai; return 0 ;;
    UTC|GMT|Etc/*|UCT|Zulu) return 0 ;;
  esac
  [ -f "$ROOT/usr/share/zoneinfo/$TZ_NAME" ] && return 0
  log "warning: 时区 $TZ_NAME 在 rootfs 的 tzdata 里不存在，回落到 Asia/Shanghai"
  TZ_NAME=Asia/Shanghai
  return 0
}

# 启动服务（后台，调用方负责轮询其存亡）
start_server() {
  load_env
  : "${AGENT2API_HOST:=127.0.0.1}"
  : "${AGENT2API_PROXY_PORT:=3065}"
  : "${TZ_NAME:=Asia/Shanghai}"
  : "${DNS_LIST:=}"

  resolve_tz
  export AGENT2API_HOST AGENT2API_PROXY_PORT
  # 数据与日志通过 bind 挂进 chroot：/data/adb/agent2api/{data,logs}
  export AGENT2API_PROXY_HOME=/var/lib/agent2api
  export AGENT2API_UI_DIR=/opt/agent2api/ui
  # v3.1.4：允许服务进程自替换（面板里点「下载并更新」就能升级）。
  # 前提是把「更新层 bind」改成「直接写 rootfs」—— 见 mount_chroot 的说明：
  # 自更新是用 rename 换二进制的，bind 挂载点上 rename 必然 EBUSY。
  # 校验/回滚仍在模块侧：面板替换完，守护会盯住二进制变化自动重启并刷新 VERSION。
  : "${AGENT2API_SELF_UPDATE:=1}"
  export AGENT2API_SELF_UPDATE
  export AGENT2API_LOG_FILE="${AGENT2API_LOG_FILE:-/var/log/agent2api/app.log}"

  if [ ! -x "$ROOT/opt/agent2api/agent2api-server" ]; then
    log "缺少可执行的 $ROOT/opt/agent2api/agent2api-server（模块包不完整？）"
    return 1
  fi

  _chroot=$(find_chroot) || {
    log "找不到 chroot（toybox / busybox 都没有），无法启动"
    return 1
  }

  # 实验性降权：chroot 需要 root，所以先 chroot 再在 chroot 内用 busybox setuidgid
  # 降权 exec 服务。要求 busybox 带 setuidgid applet 且已 bind 进 chroot。
  _drop_args=""
  if [ -n "${AGENT2API_RUN_UID:-}" ] && [ -e "$ROOT/bin/busybox" ]; then
    _bb=$(find_busybox 2>/dev/null)
    if [ -n "$_bb" ] && "$_bb" --list 2>/dev/null | grep -qx setuidgid; then
      _drop_args="/bin/busybox setuidgid ${AGENT2API_RUN_UID}:${AGENT2API_RUN_GID:-${AGENT2API_RUN_UID}}"
      # 数据目录属主随降权走（root 写入降权 uid 的文件会让 Termux/服务两头别扭）
      chown -R "$AGENT2API_RUN_UID:${AGENT2API_RUN_GID:-$AGENT2API_RUN_UID}" \
        "$DATA/data" "$LOGDIR" 2>/dev/null
      log "降权运行：uid=${AGENT2API_RUN_UID}（实验性）"
    else
      log "warning: 指定了 AGENT2API_RUN_UID 但 busybox 无 setuidgid，本次仍以 root 运行"
    fi
  fi

  log "starting: $_chroot $ROOT /opt/agent2api/agent2api-server (host=$AGENT2API_HOST port=$AGENT2API_PROXY_PORT)$( [ -n "$_drop_args" ] && echo " drop=$_drop_args")"
  # TZ / HOME 只在子 shell 里生效：否则会连带改掉本进程 log() 的时区，
  # 让 module.log 与 server.log 的时间戳对不上。
  (
    # OOM 保护：exec 前写 /proc/self，随 exec 保留。
    # v3.1.2：从 -1000 改为 -900。-1000 是 OOM_SCORE_ADJ_MIN，内核**永不回收**这个
    # 进程；网关是长驻 + SSE + 报表缓存的典型易泄漏进程，一旦泄漏，内核只能去杀
    # system_server / launcher —— 用户看到的是"手机莫名重启"，而不是"网关挂了"，
    # 极难归因。-900 仍然高于 lmkd 的普通应用档，但极端压力下可被回收，
    # 配合 service.sh 的 RSS 看门狗把不可控的内核 OOM 变成可控的优雅重启。
    echo "${AGENT2API_OOM_SCORE_ADJ:--900}" > /proc/self/oom_score_adj 2>/dev/null
    export TZ="$TZ_NAME"
    export HOME=/var/lib/agent2api
    # _chroot 可能是 "路径" 或 "busybox chroot"（两个词）：
    # 先 set -- 拆词、再 exec "$@" 逐词引用，两头都对。
    if [ -n "$_drop_args" ]; then
      # shellcheck disable=SC2086
      set -- $_chroot "$ROOT" $_drop_args /opt/agent2api/agent2api-server
    else
      # shellcheck disable=SC2086
      set -- $_chroot "$ROOT" /opt/agent2api/agent2api-server
    fi
    exec "$@"
  ) </dev/null >> "$SRVLOG" 2>&1 &
  SRV_PID=$!
  start_ts=$(date +%s)
  echo "$SRV_PID" > "$PIDFILE"
  return 0
}

stop_server() {
  # 注意：is_running 依赖 pidfile + exe 路径校验，pidfile 丢失或安装期 $ROOT 指向
  # 新目录时它会判 false。直接 return 会留下一个占着端口的孤儿，后面 start 永远
  # bind 失败、无限退避。所以这里必须再走一次不依赖 pidfile 的扫描。
  if ! is_running; then
    rm -f "$PIDFILE"
    kill_by_scan
    return 0
  fi
  _pid=$(cat "$PIDFILE" 2>/dev/null)
  log "stopping server pid=$_pid"
  kill -TERM "$_pid" 2>/dev/null
  _i=0
  while pid_matches "$_pid" agent2api-server && [ "$_i" -lt 20 ]; do
    _sleep 0.5
    _i=$((_i + 1))
  done
  pid_matches "$_pid" agent2api-server && kill -9 "$_pid" 2>/dev/null
  rm -f "$PIDFILE"
  kill_by_scan
}

# 停守护：TERM 之后等它自己收尾（它要在 trap 里停服务、卸挂载），超时才 KILL。
# v3.1.1：等待从 5s 放宽到 15s——守护的轮询循环最长睡 10s（AGENT2API_POLL_SECS），
# TERM 最迟会在一次 sleep 结束后被 trap 处理；等太短会 KILL 掉来不及卸挂载的守护。
stop_supervisor() {
  supervisor_running || { rm -f "$SUPPID"; return 0; }
  _sp=$(cat "$SUPPID" 2>/dev/null)
  log "stopping supervisor pid=$_sp"
  kill -TERM "$_sp" 2>/dev/null
  _i=0
  while pid_matches "$_sp" "$SUP_MARK" && [ "$_i" -lt 30 ]; do
    _sleep 0.5
    _i=$((_i + 1))
  done
  if pid_matches "$_sp" "$SUP_MARK"; then
    # 走到这里说明 trap 没来得及跑完（TERM 没被处理）。KILL 之后挂载一定还留着，
    # 而 Magisk 升级/卸载时 rm 会 EBUSY，留下半更新状态。
    # 这里只 KILL + 释放锁，不在此时卸挂载：此刻服务进程可能还活着（守护被 KILL
    # 时它不会跟着死），先卸掉它脚下的 /var/lib 反而会让它写出半截数据。
    # 卸载统一放在 stop_all 的末尾 —— 那时服务已经被 stop_server/kill_by_scan 收掉。
    log "supervisor 未响应 TERM，KILL（挂载由 stop_all 末尾统一卸载）"
    kill -9 "$_sp" 2>/dev/null
    release_supervisor_lock
  fi
  rm -f "$SUPPID"
}

# 统一的停机顺序：先守护（它活着就会不停拉起服务）、再服务、最后卸挂载。
stop_all() {
  touch "$DATA/disable" 2>/dev/null
  stop_supervisor
  stop_server
  # 兜底：pidfile 丢了、安装期 $ROOT 指向新目录，都可能让上面两步都"成功"却留下孤儿
  kill_by_scan
  umount_chroot
}

# 脱离当前 shell 拉起命令：setsid > nohup > 裸后台。
# v3.1.1：与 service.sh 角色一的拉起策略统一（v3.1.0 两处优先级相反）。
# setsid 成新会话即脱离控制终端，stdout/stderr 已重定向，不需要再叠 nohup。
spawn_detached() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >/dev/null 2>&1 &
  elif command -v nohup >/dev/null 2>&1; then
    nohup "$@" </dev/null >/dev/null 2>&1 &
  else
    "$@" </dev/null >/dev/null 2>&1 &
  fi
}

# 脱离当前 shell 拉起守护入口（入口自己再 fork 出 --loop 并立即返回）
#
# v3.1.2：加存活确认 + 双 fork 兜底。
# setsid(2) 在调用者已是进程组组长时返回 EPERM，toybox 的 setsid 会 perror_exit
# 直接退出、不 exec 目标 —— 结果是"命令返回 0、守护根本没起来"，而调用方
# （action.sh / update 流程）此时已经把 $DATA/disable 删了，只能等下次开机。
# 双 fork（子 shell 里再后台一次）不依赖 setsid/nohup，子进程被 init 收养，
# 同样脱离控制终端；重复拉起由 mkdir 原子锁兜住，不会出现两个守护。
spawn_supervisor() {
  spawn_detached "$MODDIR/service.sh"
  _i=0
  while [ "$_i" -lt 5 ]; do
    supervisor_running && return 0
    _sleep 1
    _i=$((_i + 1))
  done
  log "warning: setsid/nohup 拉起守护未成功，改用双 fork 兜底"
  ( "$MODDIR/service.sh" </dev/null >/dev/null 2>&1 & )
  _i=0
  while [ "$_i" -lt 5 ]; do
    supervisor_running && return 0
    _sleep 1
    _i=$((_i + 1))
  done
  log "FATAL: 守护进程拉不起来（$MODDIR/service.sh 是否可执行？）"
  return 1
}

# ── 守护原子锁 ────────────────────────────────────────────
# mkdir 是原子操作，天然只有赢家：两处同时 check-then-act 的竞态窗口就此关死。
acquire_supervisor_lock() {
  if mkdir "$SUPLOCK" 2>/dev/null; then
    echo $$ > "$SUPLOCK/pid" 2>/dev/null
    return 0
  fi
  # 锁已存在：持有者还活着就认输退出
  _lp=$(cat "$SUPLOCK/pid" 2>/dev/null)
  if [ -n "$_lp" ] && pid_matches "$_lp" "$SUP_MARK"; then
    return 1
  fi
  # 陈旧锁（持有者崩溃被 KILL 过）：清掉重试一次
  rm -rf "$SUPLOCK" 2>/dev/null
  if mkdir "$SUPLOCK" 2>/dev/null; then
    echo $$ > "$SUPLOCK/pid" 2>/dev/null
    return 0
  fi
  return 1
}

release_supervisor_lock() {
  rm -rf "$SUPLOCK" 2>/dev/null
}

# ── 健康探活 / 通知 ───────────────────────────────────────
# /health 是上游公开端点（Docker 健康检查同款），不用鉴权。
# 探测地址：0.0.0.0 表示全接口监听 → 探 127.0.0.1；其它地址按配置值探。
#
# 工具链优先级：busybox wget（一定支持 -T）→ curl（-m）→ 系统 wget（仅当有 timeout 兜底）。
# v3.1.2 两个修正：
#   1) 不再把"没找到 busybox"缓存成系统 wget —— 部分 ROM 的 wget 不认 -T，
#      一旦钉死，健康检查恒失败 → 每 3~5 分钟误判假死重启一次。
#   2) busybox 存在但没编 wget applet 时（很常见）也要跳过，别把命令拼成必失败。
# 三者都没有时降级为「进程活着 + 端口在监听」，并在日志里说明检测能力受限。
HEALTH_WGET=
HEALTH_TOOL=
HEALTH_DEGRADED=
_health_pick_tool() {
  [ -n "$HEALTH_TOOL" ] && return 0
  _bb=$(find_busybox 2>/dev/null)
  if [ -n "$_bb" ] && "$_bb" --list 2>/dev/null | grep -qx wget; then
    HEALTH_WGET="$_bb wget"
    HEALTH_TOOL=wget
    return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    HEALTH_TOOL=curl
    return 0
  fi
  if command -v wget >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then
    HEALTH_WGET=wget
    HEALTH_TOOL=wget
    return 0
  fi
  HEALTH_TOOL=none
  return 1
}

health_ok() {
  _h=${AGENT2API_HOST:-127.0.0.1}
  [ "$_h" = "0.0.0.0" ] && _h=127.0.0.1
  _p=${AGENT2API_PROXY_PORT:-3065}
  _url="http://$_h:$_p/health"
  if ! _health_pick_tool; then
    # 降级模式：至少确认端口还是本服务在听（挡不住"进程活着但不响应"的假死，
    # 但比恒失败导致的误重启好得多）
    [ -z "$HEALTH_DEGRADED" ] && {
      HEALTH_DEGRADED=1
      log "warning: 没有可用的 http 探测工具（busybox wget / curl / wget+timeout），健康检查降级为端口探测"
    }
    port_owned_by_server
    return $?
  fi
  if [ "$HEALTH_TOOL" = "curl" ]; then
    curl -fsS -m 5 -o /dev/null "$_url" 2>/dev/null
    return $?
  fi
  if command -v timeout >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    timeout 8 $HEALTH_WGET -q -T 5 -O /dev/null "$_url" 2>/dev/null
  else
    # shellcheck disable=SC2086
    $HEALTH_WGET -q -T 5 -O /dev/null "$_url" 2>/dev/null
  fi
}

# 服务进程 RSS（MB）：读 /proc/<pid>/status 的 VmRSS（kB）
rss_mb() {
  [ -n "$1" ] && [ -r "/proc/$1/status" ] || { echo 0; return 0; }
  _kb=$(sed -n 's/^VmRSS:[[:space:]]*\([0-9]*\).*/\1/p' "/proc/$1/status" 2>/dev/null)
  case "$_kb" in ''|*[!0-9]*) _kb=0 ;; esac
  echo $((_kb / 1024))
}

# RSS 看门狗阈值（MB）。0/空 = 自动：MemTotal 的 1/8，夹在 [256, 1024]。
# 为什么需要：oom_score_adj 从 -1000 改成 -900 之后，泄漏不再能拖死系统，
# 但也不该等到内核来收——主动重启比被 OOM 杀掉可观测得多（有日志、有通知）。
mem_limit_mb() {
  _lim=${AGENT2API_MAX_RSS_MB:-0}
  case "$_lim" in ''|*[!0-9]*) _lim=0 ;; esac
  if [ "$_lim" -gt 0 ]; then echo "$_lim"; return 0; fi
  _mt=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p' /proc/meminfo 2>/dev/null)
  case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
  _lim=$((_mt / 1024 / 8))
  [ "$_lim" -lt 256 ] && _lim=256
  [ "$_lim" -gt 1024 ] && _lim=1024
  echo "$_lim"
}

# 是否监听在非回环地址（= 局域网可达）
lan_exposed() {
  case "${AGENT2API_HOST:-127.0.0.1}" in
    127.*|::1|localhost) return 1 ;;
  esac
  return 0
}

# 「裸奔」判定：对外监听，但既没有网关 Key、也没有预置管理员。
# 此时面板的首次注册是开放的 —— 同一 Wi-Fi 下任何人都能抢先注册成管理员，
# 拿到的是整机 root（chroot 内 uid 0）。这种状态拒绝启动。
# 注意不能一概拒绝「对外监听」：面板本身是配 Key/管理员的唯一入口，
# 全拒会形成死锁（要配 Key 得先进面板，进面板得先启动）。
lan_exposed_unsafe() {
  lan_exposed || return 1
  [ "${AGENT2API_ALLOW_NO_KEY:-0}" = "1" ] && return 1   # 用户明确接受了无鉴权
  [ -n "${AGENT2API_PROXY_API_KEY:-}" ] && return 1
  [ -n "${AGENT2API_ADMIN_USER:-}" ] && return 1
  return 0
}

# 系统通知（Android 10+ 的 cmd notification；失败静默——ROM 差异太大不值得报错）
# 一小时最多一条，防崩溃风暴把自己刷成骚扰。
notify_user() {
  _now=$(date +%s)
  # 空文件会让 $(( )) 展开成 $(( - )) → mksh 算术错误 → 非交互 shell 直接退出。
  # 先剔掉非数字再进算术。
  _last=$(cat "$DATA/last_notify" 2>/dev/null | tr -dc '0-9')
  [ -n "$_last" ] || _last=0
  [ "$((_now - _last))" -lt 3600 ] && return 0
  echo "$_now" > "$DATA/last_notify" 2>/dev/null
  # 多用户设备上不指定 --user 会发到当前调用者所在的 user；先带 --user 0 试，
  # 老版本 cmd 不认这个参数时再退回无参形式。
  cmd notification post --user 0 -t "Agent2API" Agent2API "$1" >/dev/null 2>&1 || \
    cmd notification post -t "Agent2API" Agent2API "$1" >/dev/null 2>&1
  return 0
}

# ── 版本与比较 ────────────────────────────────────────────
# base = 模块包内置服务端版本（构建时写死）；overlay = 在线更新层版本
base_version() { cat "$ROOT/opt/agent2api/VERSION" 2>/dev/null; }
overlay_version() { cat "$UPDDIR/version" 2>/dev/null; }
current_version() { _v=$(overlay_version); [ -n "$_v" ] || _v=$(base_version); echo "$_v"; }

# ver_gt A B → A>B 时返回 0。比较 "v3.2.0" / "3.2.0" / "3.2" 均可。
# busybox awk 逐段数值比较；没有 busybox 时退字典序（同位数数字串仍正确）。
ver_gt() {
  _bb=$(find_busybox 2>/dev/null)
  if [ -n "$_bb" ] && "$_bb" --list 2>/dev/null | grep -qx awk; then
    "$_bb" awk -v a="${1#v}" -v b="${2#v}" 'BEGIN{
      n=split(a,A,"."); m=split(b,B,".");
      for(i=1; i<=n || i<=m; i++){
        x=(i<=n)?A[i]+0:0; y=(i<=m)?B[i]+0:0;
        if(x>y) exit 0; if(x<y) exit 1
      }
      exit 1
    }'
    return $?
  fi
  # 无 awk 时的纯 shell 数值比较——字典序会把 3.10.0 < 3.9.0 判反，必须逐段比
  _a=${1#v}; _b=${2#v}
  _a=${_a%%-*}; _b=${_b%%-*}
  while :; do
    _x=${_a%%.*}; _y=${_b%%.*}
    [ -n "$_x" ] || _x=0
    [ -n "$_y" ] || _y=0
    _x=$(printf '%s' "$_x" | sed 's/^0*//'); [ -n "$_x" ] || _x=0
    _y=$(printf '%s' "$_y" | sed 's/^0*//'); [ -n "$_y" ] || _y=0
    if [ "$_x" -gt "$_y" ]; then return 0; fi
    if [ "$_x" -lt "$_y" ]; then return 1; fi
    case "$_a" in *.*) _a=${_a#*.} ;; *) _a= ;; esac
    case "$_b" in *.*) _b=${_b#*.} ;; *) _b= ;; esac
    [ -z "$_a" ] && [ -z "$_b" ] && return 1
    [ -z "$_a" ] && _a=0
    [ -z "$_b" ] && _b=0
  done
}

# ── 在线更新流水线 ────────────────────────────────────────
# 分工：模块 zip 只更新"底座"（glibc 运行时/脚本），上游 Release 只更新"载荷"
# （二进制 + ui）。载荷放 /data/adb/agent2api/update，挂载时 bind 覆盖，回滚=删目录。

# 下载工具：curl（部分 ROM 有）→ busybox wget（TLS 能力看构建）→ 失败。
# 镜像前缀只作用于 github.com 的文件下载（API 不走镜像）。
fetch_to() { # $1=url $2=输出文件
  _u=$1
  _m=${AGENT2API_MIRROR:-}
  case "$_u" in
    https://github.com/*|https://objects.githubusercontent.com/*)
      [ -n "$_m" ] && _u="${_m%/}/$_u"
      ;;
  esac
  if command -v curl >/dev/null 2>&1; then
    curl -L --connect-timeout 10 -m 600 -sS -o "$2" "$_u" 2>/dev/null && return 0
  fi
  _bb=$(find_busybox 2>/dev/null)
  [ -n "$_bb" ] && "$_bb" wget -q -T 30 -O "$2" "$_u" 2>/dev/null && return 0
  return 1
}

sha256_of() { # $1=文件 → 小写 hash（失败输出空）
  _bb=$(find_busybox 2>/dev/null)
  if [ -n "$_bb" ]; then
    "$_bb" sha256sum "$1" 2>/dev/null | cut -d' ' -f1 | tr 'A-F' 'a-f'
  else
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1 | tr 'A-F' 'a-f'
  fi
}

# 解析 .sha256 文件（"hash  filename" 或裸 hash）→ 小写 hash
parse_sha_file() {
  [ -f "$1" ] || return 1
  sed -n 's/^\([0-9a-fA-F]\{64\}\).*/\1/p' "$1" | head -n 1 | tr 'A-F' 'a-f'
}

# 查询上游 latest release：设置 UPDATE_TAG / UPDATE_URL / UPDATE_SHA_URL
update_query_remote() {
  mkdir -p "$UPDSTAGE" 2>/dev/null
  _j="$UPDSTAGE/api.json"
  fetch_to "$(gh_api_url)" "$_j" || { log "无法访问 GitHub API（可配 AGENT2API_MIRROR，或设 AGENT2API_REPO 换仓库，或改用 ctl update drop）"; return 1; }
  # 仓库被封/不存在时 API 返回 404 JSON（HTTP 层仍 200/404 因工具而异），提前给出可操作的提示
  if grep -q '"message"[": ]*"Not Found"' "$_j" 2>/dev/null; then
    log "GitHub API 报 Not Found：仓库 $(gh_repo) 不存在或已下架（换仓库：env.sh 设 AGENT2API_REPO=owner/name）"
    return 1
  fi
  UPDATE_TAG=$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' "$_j" | head -n 1)
  UPDATE_URL=$(sed -n "s/.*\"browser_download_url\": *\"\([^\"]*$ASSET_NAME\)\".*/\1/p" "$_j" | head -n 1)
  UPDATE_SHA_URL=""
  [ -n "$UPDATE_URL" ] && UPDATE_SHA_URL="$UPDATE_URL.sha256"
  if [ -z "$UPDATE_TAG" ] || [ -z "$UPDATE_URL" ]; then
    log "release 解析失败（资产名变更？当前预期：$ASSET_NAME）"
    return 1
  fi
  return 0
}

# 手动投放目录里找更新包（手机浏览器下载 → 放 Download → ctl update drop）
find_drop_pkg() {
  _d=${AGENT2API_UPDATE_DROP_DIR:-/sdcard/Download}
  [ -d "$_d" ] || return 1
  ls -t "$_d/$ASSET_NAME" "$_d"/agent2api-server-*-arm64*.tar.gz 2>/dev/null | head -n 1
}

# 解包 + 校验内容：返回 0 并设置 EXTRACT_BIN / EXTRACT_UI
update_extract() { # $1=tar.gz
  _xdir="$UPDSTAGE/x"
  rm -rf "$_xdir"; mkdir -p "$_xdir"
  _tar=""
  if command -v tar >/dev/null 2>&1; then _tar=tar
  else
    _bb=$(find_busybox 2>/dev/null); [ -n "$_bb" ] && _tar="$_bb tar"
  fi
  [ -n "$_tar" ] || { log "没有可用的 tar，无法解包"; return 1; }

  # 解包前先审条目：包来自网络（甚至可指向任意 fork），以 root 解包时
  # `../../` 路径与「符号链接指向 /data 再往里写」都能落到包外任意位置。
  # tar -C 并不防穿越（busybox / toybox 都不防），只能在动手前拦。
  _list=$(${_tar} -tzf "$1" 2>/dev/null)
  if [ -z "$_list" ]; then
    log "更新包无法列出内容（损坏或不是 tar.gz）"
    return 1
  fi
  _bad=$(printf '%s\n' "$_list" | grep -E '^/|(^|/)\.\.(/|$)' | head -n 3)
  if [ -n "$_bad" ]; then
    log "更新包含越界路径，拒绝解包：$(printf '%s' "$_bad" | head -n 1)"
    return 1
  fi
  _tlist=$(${_tar} -tvzf "$1" 2>/dev/null | grep -E '^[lh]')
  if [ -n "$_tlist" ]; then
    _bad=$(printf '%s\n' "$_tlist" | sed -n 's/.* -> \(.*\)$/\1/p' \
             | grep -E '^/|(^|/)\.\.(/|$)' | head -n 3)
    if [ -n "$_bad" ]; then
      log "更新包含越界符号链接，拒绝解包：$_bad"
      return 1
    fi
  fi

  ${_tar} -xzf "$1" -C "$_xdir" 2>/dev/null

  _bins=$(find "$_xdir" -type f -name agent2api-server 2>/dev/null)
  _n=$(printf '%s\n' "$_bins" | grep -c . 2>/dev/null)
  [ "${_n:-0}" -gt 1 ] && log "warning: 更新包里有 $_n 个 agent2api-server，取第一个：$(printf '%s' "$_bins" | head -n 1)"
  EXTRACT_BIN=$(printf '%s\n' "$_bins" | head -n 1)
  [ -n "$EXTRACT_BIN" ] || { log "解包后找不到 agent2api-server"; return 1; }
  EXTRACT_UI=$(find "$_xdir" -type d -name ui 2>/dev/null | while read _u; do
    [ -f "$_u/index.html" ] && { echo "$_u"; break; }
  done)
  # ELF 架构检查：魔数 + e_machine=0xB7（aarch64）。exec 预检会兜底，这里提前拦。
  _od=""
  if command -v od >/dev/null 2>&1; then _od=od
  else
    _bb=$(find_busybox 2>/dev/null); [ -n "$_bb" ] && _od="$_bb od"
  fi
  if [ -n "$_od" ]; then
    _h=$($_od -An -tx1 -N 20 "$EXTRACT_BIN" 2>/dev/null | tr -d ' \n')
    case "$_h" in
      7f454c46*) ;;
      *) log "更新包不是 ELF 文件"; return 1 ;;
    esac
    _em=$(printf '%s' "$_h" | cut -c 37-40)   # e_machine 在第 19-20 字节（b700 = aarch64）
    [ "$_em" = "b700" ] || { log "更新包不是 arm64 ELF（e_machine=$_em）"; return 1; }
  fi
  return 0
}

# 确保 chroot 挂载在场（预检要在 chroot 里 exec 一次）
ensure_mounted() {
  _have_mount "$ROOT/proc" || mount_chroot
}

# 兼容性预检（热更新安全性的核心）：把待装二进制临时 bind 到 chroot 内路径上，
# 在 chroot 里跑一次 --version。exec 本身成功=当前 glibc 底座满足它的符号版本与
# 依赖库；缺 GLIBC_x.xx / 缺 .so / 架构不对都会在这一步暴露，而不是变砖后才发现。
# 绑定对正在运行的旧服务无影响（它持有旧 inode）。
update_preflight() { # $1=待装二进制
  PREFLIGHT_VER=""
  _chroot=$(find_chroot) || return 2
  ensure_mounted
  _tgt="$ROOT/opt/agent2api/agent2api-server"
  mount -o bind "$1" "$_tgt" 2>/dev/null || { log "预检 bind 失败"; return 2; }
  # shellcheck disable=SC2086
  set -- $_chroot "$ROOT" /opt/agent2api/agent2api-server --version
  # 必须带超时：这个二进制不认 --version，会当成正常启动去 bind 端口。
  # 服务在跑时它会立刻因端口冲突退出；服务已停时它会真的启动起来——
  # 没有 timeout 的话 ctl update 会在这里永久挂住（实测过）。
  _out=$(timeout 6 "$@" 2>&1)
  _rc=$?
  umount "$_tgt" 2>/dev/null || umount -l "$_tgt" 2>/dev/null
  PREFLIGHT_VER=$(printf '%s' "$_out" | head -n 1)
  if [ "$_rc" -eq 0 ] || [ "$_rc" -eq 124 ]; then
    # 124 = 被 timeout 掐掉，说明 exec 成功且真的跑起来了 → 底座没问题
    return 0
  fi
  case "$_out" in
    *"GLIBC"*|*"not found"*|*"No such file"*|*"Exec format"*)
      log "预检失败（rc=$_rc）：$_out"
      return 1   # 底座不满足 → 需要升级模块而不是热更新
      ;;
  esac
  # rc 非 0 但没有装载器错误特征：多半是 --version 不被支持，exec 本身成功 → 放行
  log "预检提示（rc=$_rc，按 exec 成功处理）：${PREFLIGHT_VER:-无输出}"
  return 0
}

# 数据快照（升级前服务已停）：SQLite 可能被新版迁移 schema 且不可逆，
# 回滚二进制必须连着回滚数据快照，否则旧版读新库直接拒启。
#
# v3.1.2：加体积上限。请求日志攒到几百 MB 时，原来的全量 tar 会让
# `ctl update` 卡在"停止服务并快照数据 ..."很久（此时服务已停，等于长时间宕机）。
# 超限就跳过快照并明确说明「回滚只回滚二进制」，而不是假装快照成功。
db_snapshot() {
  _cap=${AGENT2API_SNAPSHOT_MAX_MB:-1024}
  case "$_cap" in ''|*[!0-9]*) _cap=1024 ;; esac
  _sz=$(du -sk "$DATA/data" 2>/dev/null | cut -f1)
  case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
  _szmb=$((_sz / 1024))
  if [ "$_cap" -gt 0 ] && [ "$_szmb" -gt "$_cap" ]; then
    log "warning: data/ 有 ${_szmb}MB，超过快照上限 ${_cap}MB，跳过快照（本次回滚只回滚二进制；可用 AGENT2API_SNAPSHOT_MAX_MB 调整）"
    return 1
  fi
  mkdir -p "$BACKUPDIR" 2>/dev/null
  [ -f "$BACKUPDIR/pre-update.tgz" ] && mv -f "$BACKUPDIR/pre-update.tgz" "$BACKUPDIR/pre-update.tgz.1" 2>/dev/null
  # env.sh 可能被用户删掉（想回默认配置）：tar 遇到不存在的路径会整体失败，
  # 导致"明明数据目录很小却快照失败"。按存在的路径拼参数。
  _paths="data"
  [ -f "$DATA/env.sh" ] && _paths="data env.sh"
  if command -v tar >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    tar -czf "$BACKUPDIR/pre-update.tgz.new" -C "$DATA" $_paths 2>/dev/null || return 1
  else
    _bb=$(find_busybox 2>/dev/null)
    [ -n "$_bb" ] || return 1
    # shellcheck disable=SC2086
    "$_bb" tar -czf "$BACKUPDIR/pre-update.tgz.new" -C "$DATA" $_paths 2>/dev/null || return 1
  fi
  mv -f "$BACKUPDIR/pre-update.tgz.new" "$BACKUPDIR/pre-update.tgz"
  log "已做升级前数据快照：$BACKUPDIR/pre-update.tgz（${_szmb}MB）"
  return 0
}

# 激活更新层：文件落位到 /data/adb/agent2api/update（原子：先 .new 再 mv）
update_activate() { # $1=tag $2=bin $3=ui目录(可空) $4=sha256 $5=version输出
  # 先把当前运行版本备份下来：面板自更新也会覆盖同一个路径，
  # 所以"上一版"必须在这里留一份，否则 ctl rollback 无从恢复。
  rm -rf "$BACKUPDIR/payload-prev" 2>/dev/null
  mkdir -p "$BACKUPDIR/payload-prev" 2>/dev/null
  if [ -f "$ROOT/opt/agent2api/agent2api-server" ]; then
    cp -f "$ROOT/opt/agent2api/agent2api-server" "$BACKUPDIR/payload-prev/" 2>/dev/null
    [ -f "$ROOT/opt/agent2api/VERSION" ] && \
      cp -f "$ROOT/opt/agent2api/VERSION" "$BACKUPDIR/payload-prev/VERSION" 2>/dev/null
    [ -d "$ROOT/opt/agent2api/ui" ] && \
      cp -a "$ROOT/opt/agent2api/ui" "$BACKUPDIR/payload-prev/ui" 2>/dev/null
  fi

  # 落位到运行目录。先写 .new 再 rename：中途失败也不会留下半截二进制
  cp -f "$2" "$ROOT/opt/agent2api/agent2api-server.new" 2>/dev/null || return 1
  chmod 0755 "$ROOT/opt/agent2api/agent2api-server.new"
  mv -f "$ROOT/opt/agent2api/agent2api-server.new" "$ROOT/opt/agent2api/agent2api-server" || return 1
  if [ -n "$3" ] && [ -d "$3" ]; then
    rm -rf "$ROOT/opt/agent2api/ui.old" 2>/dev/null
    [ -d "$ROOT/opt/agent2api/ui" ] && mv "$ROOT/opt/agent2api/ui" "$ROOT/opt/agent2api/ui.old" 2>/dev/null
    if cp -a "$3" "$ROOT/opt/agent2api/ui" 2>/dev/null; then
      rm -rf "$ROOT/opt/agent2api/ui.old" 2>/dev/null
    else
      rm -rf "$ROOT/opt/agent2api/ui" 2>/dev/null
      [ -d "$ROOT/opt/agent2api/ui.old" ] && mv "$ROOT/opt/agent2api/ui.old" "$ROOT/opt/agent2api/ui" 2>/dev/null
      log "warning: ui 落位失败（仅二进制更新）"
    fi
  fi
  printf '%s\n' "$1" > "$ROOT/opt/agent2api/VERSION" 2>/dev/null
  # $UPDDIR 退化为"记录 + 归档"，不再参与挂载
  mkdir -p "$UPDDIR" 2>/dev/null
  printf '%s\n' "$1" > "$UPDDIR/version" 2>/dev/null
  [ -n "$4" ] && printf '%s\n' "$4" > "$UPDDIR/sha256" 2>/dev/null
  [ -n "$5" ] && printf '%s\n' "$5" > "$UPDDIR/ver-report" 2>/dev/null
  return 0
}

# 载荷二进制的 size+mtime 指纹：面板里自更新会用 rename 换掉它，
# 守护靠这个指纹发现"文件变了但进程还是旧的"。
payload_stamp() {
  stat -c '%s-%Y' "$ROOT/opt/agent2api/agent2api-server" 2>/dev/null || echo none
}

# 用服务端自己的更新日志刷新 VERSION 文件。
#
# 为什么不用 `--version`：这个二进制**不认这个参数**，会当成正常启动去 bind 端口
# （实测：直接输出「网关启动失败：端口 3065 已被占用」并退出），
# 既拿不到版本号，还会跟正在跑的服务抢一次端口。
#
# 面板内更新成功时，服务端会往自己的日志里写一行：
#   ✅ 已在容器内替换程序（v3.1.1），重启后生效
# 版本号从这里取，是唯一"服务端亲口说的"来源。
refresh_payload_version() {
  _ver=""
  for _f in "$SRVLOG" "$SRVLOG.1"; do
    [ -f "$_f" ] || continue
    # 只用 ASCII 正则：toybox 的 sed 在字符组里放全角括号会匹配不上。
    # 这里先按中文锚点筛行，再用纯 ASCII 的版本号模式抠出来。
    _hit=$(grep -a "替换程序" "$_f" 2>/dev/null | tail -n 1 \
      | grep -o 'v\{0,1\}[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | tail -n 1 \
      | sed 's/^v//')
    [ -n "$_hit" ] && _ver=$_hit
  done
  if [ -z "$_ver" ]; then
    log "warning: 载荷已变更，但没能从日志确定版本号，VERSION 暂不更新（ctl update 会自动纠正）"
    return 1
  fi
  _old=$(cat "$ROOT/opt/agent2api/VERSION" 2>/dev/null)
  printf '%s\n' "$_ver" > "$ROOT/opt/agent2api/VERSION" 2>/dev/null
  [ "$_old" = "$_ver" ] || log "载荷版本已刷新：${_old:-?} → $_ver（面板内更新）"
  return 0
}

# 等就绪：守护在、服务在、健康通过（或出现 fatal 提前失败）
wait_ready() { # $1=超时秒
  _i=0
  _limit=$(( ${1:-120} / 3 ))
  while [ "$_i" -lt "$_limit" ]; do
    [ -f "$FATALFILE" ] && return 1
    if supervisor_running && is_running && health_ok; then return 0; fi
    _sleep 3
    _i=$((_i + 1))
  done
  return 1
}

# 清理回滚归档：每份 $UPDDIR.failed.<epoch> 含 12MB 二进制 + 6MB ui，
# 原来只增不减（连续失败几次就是几十 MB）。目录名就是 epoch，逆序排即从新到旧。
# 默认保留最近 2 份；ctl clean [keep] 可手动指定。
prune_failed_archives() {
  _keep=${1:-${AGENT2API_KEEP_FAILED:-2}}
  case "$_keep" in ''|*[!0-9]*) _keep=2 ;; esac
  _all=$(ls -1d "$UPDDIR".failed.* 2>/dev/null | sort -r)
  [ -n "$_all" ] || return 0
  _i=0
  for _d in $_all; do
    _i=$((_i + 1))
    if [ "$_i" -gt "$_keep" ]; then
      rm -rf "$_d" 2>/dev/null && log "清理旧回滚归档：$_d"
    fi
  done
  return 0
}

# 回滚：移除更新层（归档留查）、可选恢复数据快照、拉回内置版本
rollback_update() { # $1=1 时恢复升级前数据快照
  log "回滚：恢复上一版载荷$( [ "$1" = "1" ] && echo '（含数据快照恢复）')"
  stop_all
  # 优先用面板自更新留下的 .backup（它永远是"紧邻的上一版"），
  # 其次用 ctl update 自己留的 payload-prev
  if [ -f "$ROOT/opt/agent2api/agent2api-server.backup" ]; then
    mv -f "$ROOT/opt/agent2api/agent2api-server.backup" "$ROOT/opt/agent2api/agent2api-server" 2>/dev/null
    chmod 0755 "$ROOT/opt/agent2api/agent2api-server" 2>/dev/null
    if [ -d "$ROOT/opt/agent2api/ui.backup" ]; then
      rm -rf "$ROOT/opt/agent2api/ui" 2>/dev/null
      mv "$ROOT/opt/agent2api/ui.backup" "$ROOT/opt/agent2api/ui" 2>/dev/null
    fi
    refresh_payload_version
    log "已用面板备份回滚"
  elif [ -f "$BACKUPDIR/payload-prev/agent2api-server" ]; then
    cp -f "$BACKUPDIR/payload-prev/agent2api-server" "$ROOT/opt/agent2api/agent2api-server.new" 2>/dev/null && \
      chmod 0755 "$ROOT/opt/agent2api/agent2api-server.new" && \
      mv -f "$ROOT/opt/agent2api/agent2api-server.new" "$ROOT/opt/agent2api/agent2api-server"
    if [ -d "$BACKUPDIR/payload-prev/ui" ]; then
      rm -rf "$ROOT/opt/agent2api/ui" 2>/dev/null
      cp -a "$BACKUPDIR/payload-prev/ui" "$ROOT/opt/agent2api/ui" 2>/dev/null
    fi
    [ -f "$BACKUPDIR/payload-prev/VERSION" ] && \
      cp -f "$BACKUPDIR/payload-prev/VERSION" "$ROOT/opt/agent2api/VERSION" 2>/dev/null
    log "已恢复 ctl update 备份的上一版"
  else
    log "没有可回滚的上一版载荷（从未通过 ctl / 面板更新过）；如需回到出厂版本，重刷模块包"
  fi
  if [ -d "$UPDDIR" ]; then
    mv "$UPDDIR" "$UPDDIR.failed.$(date +%s)" 2>/dev/null
    prune_failed_archives
  fi
  if [ "$1" = "1" ] && [ -f "$BACKUPDIR/pre-update.tgz" ]; then
    if command -v tar >/dev/null 2>&1; then
      tar -xzf "$BACKUPDIR/pre-update.tgz" -C "$DATA" 2>/dev/null
    else
      _bb=$(find_busybox 2>/dev/null)
      [ -n "$_bb" ] && "$_bb" tar -xzf "$BACKUPDIR/pre-update.tgz" -C "$DATA" 2>/dev/null
    fi
    log "已恢复升级前数据快照（期间写入的增量不保留）"
  fi
  rm -f "$FATALFILE" "$DATA/disable"
  spawn_supervisor
  wait_ready 90
  return $?
}

# 总编排：ctl update [check|drop|install] [tag]
#   check  只查版本不动文件
#   drop   从投放目录手动装包（零 shell TLS 依赖的保底通道）
#   install/默认  在线下载并安装
update_action() {
  _mode=${1:-install}
  _tag=${2:-}
  rm -f "$FATALFILE"
  mkdir -p "$UPDSTAGE"

  # ── 1. 确定包来源与期望 hash ──
  _pkg=""; _expect=""
  if [ "$_mode" = "check" ]; then
    _rq=$(gh_repo)
    echo "更新仓库：$_rq"
    [ "$_rq" != "$GH_REPO_DEFAULT" ] && echo "（自定义仓库，默认 $GH_REPO_DEFAULT；改回：删掉 env.sh 里的 AGENT2API_REPO）"
  fi
  if [ "$_mode" = "drop" ]; then
    _pkg=$(find_drop_pkg) || {
      echo "投放目录（${AGENT2API_UPDATE_DROP_DIR:-/sdcard/Download}）里没有 agent2api-server-*-arm64*.tar.gz"
      echo "用手机浏览器从 Release 页下载后放入该目录，再执行 ctl update drop"
      return 1
    }
    _expect=$(parse_sha_file "$_pkg.sha256")
    if [ -z "$_expect" ] && [ "${AGENT2API_UPDATE_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      echo "找不到校验文件 $_pkg.sha256"
      echo "可从 Release 页下载同名 .sha256 放在旁边；确认要跳过校验就设 AGENT2API_UPDATE_ALLOW_UNVERIFIED=1"
      return 1
    fi
    _tag=$(basename "$_pkg" | sed -n 's/.*-\(v\{0,1\}[0-9][0-9.]*\)-arm64.*/\1/p')
  else
    _explicit=0
    if [ -n "$_tag" ]; then
      # 指定 tag：URL 直接构造（配镜像可绕开 API 不可达）；显式指定视为重装意图
      _explicit=1
      UPDATE_TAG="$_tag"
      UPDATE_URL="https://github.com/$(gh_repo)/releases/download/$_tag/$ASSET_NAME"
      UPDATE_SHA_URL="$UPDATE_URL.sha256"
    else
      update_query_remote || { echo "版本查询失败（详见 $MODLOG）"; return 1; }
    fi
    _tag=${UPDATE_TAG#v}
    _cur=$(current_version)
    if ! ver_gt "$_tag" "$_cur"; then
      if [ "$_mode" = "check" ]; then
        echo "已是最新：当前 $_cur，上游 ${UPDATE_TAG}"
        return 0
      fi
      if [ "$_explicit" = "0" ]; then
        echo "已是最新：当前 $_cur，上游 ${UPDATE_TAG}"
        echo "如仍要重装：ctl update install v$_cur"
        return 0
      fi
      echo "note: $_tag 不高于当前 $_cur，按显式指定执行重装"
    fi
    [ "$_mode" = "check" ] && { echo "发现新版本：$_cur → $_tag"; echo "$UPDATE_URL"; return 0; }
    _pkg="$UPDSTAGE/pkg.tar.gz"
    echo "下载 $_tag ..."
    fetch_to "$UPDATE_URL" "$_pkg" || { echo "下载失败（可配 AGENT2API_MIRROR 镜像，或用 ctl update drop）"; return 1; }
    _sha_file="$UPDSTAGE/pkg.sha256"
    fetch_to "$UPDATE_SHA_URL" "$_sha_file" 2>/dev/null
    [ -s "$_sha_file" ] && _expect=$(parse_sha_file "$_sha_file")
    if [ -z "$_expect" ] && [ "${AGENT2API_UPDATE_ALLOW_UNVERIFIED:-0}" != "1" ]; then
      echo "拿不到官方 sha256（$UPDATE_SHA_URL）"
      echo "确认要跳过校验就设 AGENT2API_UPDATE_ALLOW_UNVERIFIED=1"
      rm -f "$_pkg"
      return 1
    fi
  fi

  # ── 2. 校验 ──
  if [ -n "$_expect" ]; then
    _got=$(sha256_of "$_pkg")
    [ "$_got" = "$_expect" ] || { echo "sha256 校验失败（期望 $_expect 实得 $_got），拒绝安装"; rm -f "$_pkg"; return 1; }
    echo "sha256 校验通过"
  else
    echo "warning: 跳过 sha256 校验（用户显式允许）"
  fi

  # ── 3. 解包 + 预检 ──
  update_extract "$_pkg" || { echo "更新包内容异常（详见 $MODLOG）"; rm -f "$_pkg"; return 1; }
  update_preflight "$EXTRACT_BIN"
  _pf=$?
  [ "$_pf" -eq 0 ] || {
    echo "兼容性预检未通过：新二进制在当前模块底座（glibc/依赖库）上无法加载。"
    echo "→ 此版本需要等模块底座升级，本次不安装，现有版本不受影响。"
    rm -f "$_pkg"
    return 1
  }
  echo "预检通过：${PREFLIGHT_VER:-（--version 无输出）}"

  # 预检输出里如果带语义化版本号，优先用它补全 drop 模式的版本标记，
  # 并对"投放了旧包"给出明确提示（仍按用户意图继续，不擅自拦截）
  _pv=$(printf '%s' "$PREFLIGHT_VER" | tr ' ' '\n' \
        | sed -n 's/^v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\(-[0-9A-Za-z.]*\)\{0,1\}$/\1/p' | head -n 1)
  if [ -n "$_pv" ] && ! ver_gt "$_pv" "$(current_version)"; then
    echo "warning: 包内版本 $_pv 不高于当前 $(current_version)（重装/降级请自行确认）"
  fi
  [ -z "$_tag" ] && [ -n "$_pv" ] && _tag=$_pv

  # ── 4. 停机 + 快照 + 激活 ──
  echo "停止服务并快照数据 ..."
  stop_all
  db_snapshot || log "warning: 数据快照失败，回滚时将不恢复数据库"
  if [ -z "$_tag" ]; then
    _tag=$(date +%Y%m%d-%H%M)
  fi
  update_activate "$_tag" "$EXTRACT_BIN" "$EXTRACT_UI" "$_expect" "$PREFLIGHT_VER" || {
    echo "更新层落位失败（磁盘满？）"
    rollback_update 0
    return 1
  }

  # ── 5. 重启 + 验证 ──
  rm -f "$DATA/disable" "$FATALFILE"
  spawn_supervisor
  echo "等待新版就绪 ..."
  if wait_ready 120; then
    echo "更新完成：server=$_tag（模块底座仍为 $(grep -E '^version=' "$MODDIR/module.prop" | cut -d= -f2)）"
    log "在线更新成功：$_tag"
    notify_user "agent2api 已更新到 $_tag"
    # drop 模式的包归档，避免下次误装
    if [ "$_mode" = "drop" ] && [ -f "$_pkg" ]; then
      mkdir -p "$DATA/update-packages" 2>/dev/null
      mv -f "$_pkg" "$DATA/update-packages/" 2>/dev/null
    fi
    rm -f "$UPDSTAGE/pkg.tar.gz" "$UPDSTAGE/pkg.sha256"
    return 0
  fi
  echo "新版未能就绪，自动回滚 ..."
  log "更新后健康验证失败，回滚"
  rollback_update 1
  echo "已回滚到内置版本 $(base_version)；失败包归档在 $DATA/update.failed.*"
  return 1
}

# 用户数据备份：data/ + env.sh 打包
backup_data() { # $1=目标目录（默认 /sdcard/Download）
  _d=${1:-/sdcard/Download}
  mkdir -p "$_d" 2>/dev/null
  _f="$_d/agent2api-backup-$(date +%Y%m%d-%H%M).tgz"
  if command -v tar >/dev/null 2>&1; then
    tar -czf "$_f" -C "$DATA" data env.sh 2>/dev/null || return 1
  else
    _bb=$(find_busybox 2>/dev/null)
    [ -n "$_bb" ] || { echo "没有可用的 tar"; return 1; }
    "$_bb" tar -czf "$_f" -C "$DATA" data env.sh 2>/dev/null || return 1
  fi
  echo "$_f"
  return 0
}
