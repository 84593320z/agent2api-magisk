#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · 公共函数库
#
# 约束：只允许 POSIX sh 语法。
#   - Magisk 下脚本跑在 busybox ash，KernelSU 下跑在 busybox ash（Standalone
#     模式，命令直接走 applet，忽略 PATH），APatch 同理；
#   - 运行期不一定有 bash，也不一定有完整 PATH。
#   所以：不用 local / 数组 / ${x//y} / [[ ]] / set -e / $RANDOM。
#
# 目录约定（为什么把载荷放 /data/adb/agent2api 而不是模块目录里）：
#   模块目录 /data/adb/modules/agent2api 在"模块升级/热安装"时会被整个清空
#   替换，把 15MB 的二进制和数据库放里面等于每次升级都把用户数据回退一次。
#   所以模块目录只放脚本 + 种子，运行数据全部在 /data/adb/agent2api 下。
# ============================================================================

A2A_COMMON_LOADED=1
MODULE_ID=agent2api
MODDIR="${MODDIR:-/data/adb/modules/$MODULE_ID}"

APP_HOME=/data/adb/agent2api
PAYLOAD="$APP_HOME/payload"
PLIB="$PAYLOAD/lib"
BINDIR="$APP_HOME/bin"
CFGDIR="$APP_HOME/etc"
DATADIR="$APP_HOME/data"
LOGDIR="$APP_HOME/logs"
RUNDIR="$APP_HOME/run"
TMPD="$APP_HOME/tmp"
HOMEDIR="$APP_HOME/home"
BACKUPDIR="$APP_HOME/backup"
DLDIR="$APP_HOME/download"

SETTINGS="$CFGDIR/settings.conf"
SUPLOG="$LOGDIR/supervisor.log"
SRVLOG="$LOGDIR/server.log"
# 上游的文件日志通道只在 Windows 服务形态打开（bin/agent2api-server.rs 的
# #[cfg(windows)] 分支调 logging::init_file_sink），Android headless 永远不建
# FILE_SINK，所以这个文件正常情况下不存在，内容全在 SRVLOG 里。
# 保留变量只为「上游哪天在非 Windows 形态也开文件通道」时仍能按大小轮转它。
APPLOG="$LOGDIR/app.log"
UPDLOG="$LOGDIR/update.log"
INSTLOG="$LOGDIR/install.log"

CURL="$BINDIR/curl"
CACERT="$BINDIR/cacert.pem"

SERVER_BIN="$PAYLOAD/agent2api-server"
LOADER="$PLIB/ld-linux-aarch64.so.1"

# ---------------------------------------------------------------------------
# 运行时上下文（给"二进制内路径重定向"用）
#
# 这几个路径必须是这么短，因为要原地顶掉二进制里的字符串：
#   /etc/resolv.conf   (16 字节) -> /data/a2a/resolv   (16 字节)
#   /etc/gai.conf      (13)      -> /data/a2a/gai      (13)
#   /etc/nsswitch.conf (18)      -> /data/a2a/nsswitch (18)
# 详见 pack 时的 patch_elf.py。这里改名 = 二进制里的补丁对不上 = DNS 全废。
#
# /data/a2a/ld.so 是给"面板拉起的插件二进制"用的解释器软链：它们的 PT_INTERP
# 写死 /lib/ld-linux-aarch64.so.1（26 字节槽），Android 上没这个文件，所以
# 报 "No such file or directory (os error 2)"。我们把 interp 改写成
# /data/a2a/ld.so（14 字节，槽里剩的全是 0，合法）。
# ---------------------------------------------------------------------------
A2A_LIVE=/data/a2a
DNSFILE="$A2A_LIVE/resolv"
GAIFILE="$A2A_LIVE/gai"
NSSFILE="$A2A_LIVE/nsswitch"
LDSO_LINK="$A2A_LIVE/ld.so"
# 最后可用 DNS 的副本：切网/采样失败时靠它兜底，dns_probe 也拿它做对照。
# 必须放在这里：dns.sh 在 post-fs-data / supervise / a2a 三处被 source，
# 早先只在 dns.sh 里写 DNS_ACTIVE_CACHE，DNS_CACHE 从未赋值，导致缓存写入
# 变成 cp 到空路径（必然失败）→ dns_write 永远返回 1，且"保留最后可用配置"
# 这条分支永远是死代码。
DNS_CACHE="$RUNDIR/resolv.last"

# ---------------------------------------------------------------------------
# 时间 / 日志
# ---------------------------------------------------------------------------
now_human() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date; }
now_epoch() { date +%s 2>/dev/null; }

log_to() { # $1=文件 其余=消息
  _lf="$1"; shift
  [ -d "$LOGDIR" ] || return 0
  printf '[%s] %s\n' "$(now_human)" "$*" >>"$_lf" 2>/dev/null
}

say() { printf '%s\n' "$*"; }

# 日志轮转：超过 $2 KB 就滚动，最多留 3 份历史。
# 活跃日志必须 copytruncate：直接 rename 后，服务端仍拿着旧 inode 的 fd，
# 会让 app.log.1 无限增长。复制历史后原地清空，fd 和路径都持续受控。
rotate_log() { # $1=文件 $2=上限KB
  [ -f "$1" ] || return 0
  _sz=$(wc -c <"$1" 2>/dev/null | tr -d ' \t\r\n')
  case "$_sz" in ''|*[!0-9]*) return 0 ;; esac
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_sz" -gt $(($2 * 1024)) ] || return 0
  [ -f "$1.2" ] && mv -f "$1.2" "$1.3" 2>/dev/null
      [ -f "$1.1" ] && mv -f "$1.1" "$1.2" 2>/dev/null
      # 归档只留最后 $2 KB：原来整份 cp 一个 8MB 日志，等于每次轮转多写 8MB，
      # 闪存寿命和耗时都不划算；tail -c 从尾部截，存档上限即 threshold。
      tail -c $(($2 * 1024)) "$1" >"$1.1" 2>/dev/null \
        || cp -f "$1" "$1.1" 2>/dev/null || return 1
    
  : >"$1" 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------------------
# 目录与权限
# ---------------------------------------------------------------------------
ensure_layout() {
  for _d in "$APP_HOME" "$PAYLOAD" "$PLIB" "$BINDIR" "$CFGDIR" "$DATADIR" \
            "$LOGDIR" "$RUNDIR" "$TMPD" "$HOMEDIR" "$BACKUPDIR" "$DLDIR" \
            "$A2A_LIVE"; do
    [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  done
  chmod 755 "$APP_HOME" "$PAYLOAD" "$PLIB" "$BINDIR" "$LOGDIR" "$RUNDIR" \
            "$TMPD" "$HOMEDIR" "$BACKUPDIR" "$DLDIR" "$A2A_LIVE" 2>/dev/null
  # 配置和数据库里可能有 API Key / 面板密码，收紧到 700
  chmod 700 "$CFGDIR" "$DATADIR" 2>/dev/null
  # Never inherit an installer/manager cache as supervisor temporary storage.
  [ -d "$TMPD" ] && [ -w "$TMPD" ] || return 1
  TMPDIR=$TMPD
  export TMPDIR
  live_link_refresh
}

# 把 /data/a2a/ld.so 指到我们自己的动态链接器。
# 为什么用软链而不是拷贝：模块升级后 payload 目录会换，软链永远指向新的那份。
live_link_refresh() {
  [ -d "$A2A_LIVE" ] || mkdir -p "$A2A_LIVE" 2>/dev/null
  chmod 755 "$A2A_LIVE" 2>/dev/null
  [ -x "$LOADER" ] || return 0
  _cur=$(readlink "$LDSO_LINK" 2>/dev/null)
  [ "$_cur" = "$LOADER" ] && return 0
  _tmp="$A2A_LIVE/ld.so.new.$$"
  rm -f "$_tmp" 2>/dev/null
  ln -s "$LOADER" "$_tmp" 2>/dev/null || return 1
  mv -f "$_tmp" "$LDSO_LINK" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  [ "$(readlink "$LDSO_LINK" 2>/dev/null)" = "$LOADER" ]
}

# ---------------------------------------------------------------------------
# 配置读取（settings.conf：KEY=VALUE，允许行尾 # 注释与引号）
# ---------------------------------------------------------------------------
cfg_get() { # $1=键 $2=默认值；显式空值与“键不存在”语义不同
  _k="$1"; _def="${2:-}"
  case "$_k" in ''|*[!A-Za-z0-9_]*) printf '%s' "$_def"; return 0 ;; esac
  if [ ! -r "$SETTINGS" ]; then printf '%s' "$_def"; return 0; fi
  _raw=$(sed -n "/^[[:space:]]*${_k}[[:space:]]*=/p" "$SETTINGS" 2>/dev/null \
         | tail -n 1 | tr -d '\r')
  if [ -z "$_raw" ]; then printf '%s' "$_def"; return 0; fi
  _v=$(printf '%s' "$_raw" | sed "s/^[[:space:]]*${_k}[[:space:]]*=[[:space:]]*//")
  case "$_v" in
    \"*\") _v="${_v#\"}"; _v="${_v%\"}"; printf '%s' "$_v"; return 0 ;;
    \'*\') _v="${_v#\'}"; _v="${_v%\'}"; printf '%s' "$_v"; return 0 ;;
  esac
  _v=$(printf '%s' "$_v" | sed 's/[[:space:]]#.*$//; s/[[:space:]]*$//')
  printf '%s' "$_v"
}

cfg_set() { # 用 awk 写值，避免 sed 的 | & \ 与正则注入；磁盘满不破坏原配置
  case "$1" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
  # R11：值里出现任何控制字符（换行/回车/TAB）都会让一行变多行，等于让
  # 调用者写进另一个键（配置注入）。awk -v 时代靠转义挡住一半，换成
  # ENVIRON 原样传值之后必须在这里显式拒绝。
  case "$2" in
    *[[:cntrl:]]*) say "配置值不能包含控制字符：$1"; return 1 ;;
  esac
  # 含空格或 # 的值不加引号会被 cfg_get 当成"行尾注释"截断，读回来就不是
  # 写进去的东西。这里统一用引号包裹，cfg_get 会原样返回。
  _cs_val=$2
  case "$_cs_val" in
    *'"'*)
      case "$_cs_val" in
        *"'"*) say "配置值不能同时包含单双引号：$1"; return 1 ;;
      esac
      _cs_val=$(printf "'%s'" "$_cs_val")
      ;;
    *[[:space:]]*|*#*) _cs_val=$(printf '"%s"' "$_cs_val") ;;
  esac
  [ -d "$CFGDIR" ] || mkdir -p "$CFGDIR" 2>/dev/null || return 1
  [ -f "$SETTINGS" ] || : >"$SETTINGS" || return 1
  _tmp="$SETTINGS.tmp.$$"
  # 用 ENVIRON 传键值：awk -v 会把值里的反斜杠转义序列展开，
  # 于是字面量 abc\nallow_no_key=1 会被写成两行，等于让调用者改到了
  # 另一个键（安全上就是配置注入）。ENVIRON 是原样字符串，不做解释。
  A2A_CFG_KEY="$1" A2A_CFG_VAL="$_cs_val" awk 'BEGIN { k=ENVIRON["A2A_CFG_KEY"]; v=ENVIRON["A2A_CFG_VAL"]; done=0 }
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      if (!done) { print k "=" v; done=1 }; next
    }
    { print }
    END { if (!done) print k "=" v }' "$SETTINGS" >"$_tmp" 2>/dev/null || {
      rm -f "$_tmp"; return 1;
    }
  [ -s "$_tmp" ] || { rm -f "$_tmp"; return 1; }
  chmod 600 "$_tmp" 2>/dev/null
  mv -f "$_tmp" "$SETTINGS" 2>/dev/null || { rm -f "$_tmp"; return 1; }
  return 0
}

# 递归设置权限。
# 不用 `find -exec ... +`：不同 ROM 的 toybox find 对 `+` 终止符支持不一致，
# 用纯 shell 递归最稳（模块里的目录最多几层，开销可忽略）。
chmod_tree() { # $1=目录 $2=目录权限 $3=文件权限
  [ -d "$1" ] || return 0
  for _ct in "$1"/*; do
    [ -e "$_ct" ] || continue
    if [ -d "$_ct" ]; then
      # 子 shell 隔离递归变量；否则子层 _ct 会覆盖父层当前路径。
      ( chmod_tree "$_ct" "$2" "$3" ) || return 1
      chmod "$2" "$_ct" 2>/dev/null || return 1
    else
      chmod "$3" "$_ct" 2>/dev/null || return 1
    fi
  done
  chmod "$2" "$1" 2>/dev/null || return 1
  return 0
}

# ISO8601 时间串比较：$1 >= $2 时返回 0
# （不用 test 的 > / < ：不同 shell 对它们的支持不一致，mksh 和 busybox ash 行为不同）
ts_newer_eq() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  _first=$(printf '%s\n%s\n' "$1" "$2" | sort | head -n 1)
  [ "$_first" = "$2" ]
}

# 端口表：抽成变量一是为了可测（离线时塞固定样本进来），二是某些 ROM 上
# /proc/net/tcp6 可能被 SELinux 挡住，坏掉一张不至于把整个检查搞瞎。
PROC_TCP_FILES=${PROC_TCP_FILES:-"/proc/net/tcp /proc/net/tcp6"}

# ---------------------------------------------------------------------------
# 进程 / 端口
# ---------------------------------------------------------------------------
# 所有入口共用同一十进制规范化，避免 printf 把前导零当八进制。
port_normalize() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  _pn=$(printf '%s' "$1" | sed 's/^0*//')
  [ -n "$_pn" ] || _pn=0
  [ "${#_pn}" -le 5 ] || return 1
  [ "$_pn" -ge 1 ] && [ "$_pn" -le 65535 ] || return 1
  printf '%s' "$_pn"
}

# 有效面板端口。
# 上游 agent2api-server 对 AGENT2API_PANEL_PORT == 网关端口 是硬失败（直接
# 打印“与网关端口相同”并退出），所以这里的“等于主端口”必须归一化成“未设置”，
# 否则配成相同值会让守护进程陷入无限拉起。非法值同样按未设置处理。
panel_port_effective() {
  _ppe_main=$(port_normalize "$(cfg_get port 3065)") || _ppe_main=3065
  _ppe_raw=$(cfg_get panel_port "")
  if [ -n "$_ppe_raw" ]; then
    _ppe_val=$(port_normalize "$_ppe_raw") || _ppe_val=""
    if [ -n "$_ppe_val" ] && [ "$_ppe_val" != "$_ppe_main" ]; then
      printf '%s' "$_ppe_val"
      return 0
    fi
  fi
  printf '%s' "$_ppe_main"
}

# POSIX df 的可用 KB；不能计算时 fail-closed，由调用者中止写事务。
space_available_kb() {
  [ -n "${1:-}" ] || return 1
  _sa_path=$1
  while [ ! -e "$_sa_path" ]; do
    _sa_parent=${_sa_path%/*}
    [ "$_sa_parent" != "$_sa_path" ] || return 1
    [ -n "$_sa_parent" ] || _sa_parent=/
    _sa_path=$_sa_parent
  done
  df -Pk "$_sa_path" 2>/dev/null | awk 'NF >= 4 && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {print $4; found=1} END {if (!found) exit 1}'
}
space_require_kb() { # $1=路径 $2=事务所需 KB
  case "${2:-}" in ''|*[!0-9]*) return 1 ;; esac
  _sr_avail=$(space_available_kb "$1") || {
    echo "无法读取 $1 的可用空间，取消写事务"; return 1;
  }
  if [ "$_sr_avail" -lt "$2" ]; then
    echo "空间不足：需要约 $2 KB，可用 $_sr_avail KB"
    return 1
  fi
  return 0
}

pid_alive() {
  [ -n "$1" ] || return 1
  case "$1" in *[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

read_pid() { # $1=pidfile
  [ -r "$1" ] || return 1
  # 只取第一个字段：整行 tr -dc '0-9' 会把版本号/时间戳里的数字拼进来，
  # 得到一个不存在的巨号 PID，健康检查会永远失败。
  _rp=$(awk 'NR==1{print $1}' "$1" 2>/dev/null)
  case "$_rp" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$_rp"
}

proc_start_ticks() { # $1=pid，输出内核 starttime，防止 PID 复用
  [ -r "/proc/$1/stat" ] || return 1
  _rest=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null)
  _start=$(printf '%s' "$_rest" | awk '{print $20}' 2>/dev/null)
  case "$_start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$_start"
}

pid_matches_start() { # $1=pid $2=启动时记录的 starttime；记录缺失时 fail-closed
  pid_alive "$1" || return 1
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(proc_start_ticks "$1" 2>/dev/null)" = "$2" ]
}

# 进程运行了多久（秒），从 /proc/<pid>/stat 的 starttime 换算
proc_uptime() { # $1=pid
  [ -r "/proc/$1/stat" ] || return 1
  _rest=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null)
  _start=$(printf '%s' "$_rest" | awk '{print $20}' 2>/dev/null)
  case "$_start" in ''|*[!0-9]*) return 1 ;; esac
  _up=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null)
  case "$_up" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' $((_up - _start / 100))
}

# 端口是否处于 LISTEN（直接读 /proc/net/tcp，不依赖 ss / netstat / curl）
port_listen() { # $1=端口
  _port_dec=$(port_normalize "$1") || return 1
  _hex=$(printf '%04X' "$_port_dec" 2>/dev/null) || return 1
  for _f in $PROC_TCP_FILES; do
    [ -r "$_f" ] || continue
    while read -r _sl _loc _rem _st _rest; do
      [ "$_st" = "0A" ] || continue
      case "$_loc" in
        *":$_hex") return 0 ;;
      esac
    done <"$_f" 2>/dev/null
  done
  return 1
}

# 端口对应的 LISTEN socket inode。端口必须匹配本地地址末尾完整的 4 位十六进制。
port_socket_inodes() { # $1=端口
  _port_dec=$(port_normalize "$1") || return 1
  _hex=$(printf '%04X' "$_port_dec" 2>/dev/null) || return 1
  awk -v k=":$_hex" '$4=="0A" && substr($2,length($2)-4)==k && $10+0>0 {print $10}' \
    $PROC_TCP_FILES 2>/dev/null | sort -u
}

# 健康检查只扫记录 PID 的 fd，避免把同端口的其它服务认成自己。
port_owned_by_pid() { # $1=端口 $2=pid
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  [ -d "/proc/$2/fd" ] || return 1
  _inodes=$(port_socket_inodes "$1" 2>/dev/null | tr '\n' ' ')
  [ -n "$_inodes" ] || return 1
  for _fd in "/proc/$2"/fd/*; do
    _l=$(ls -l "$_fd" 2>/dev/null) || continue
    case "$_l" in *socket:*) ;; *) continue ;; esac
    _ino=$(printf '%s' "$_l" | sed 's/.*\[\([0-9]*\)\].*/\1/')
    case " $_inodes " in *" $_ino "*) return 0 ;; esac
  done
  return 1
}

# 谁占了端口（扫描 /proc/*/fd，只在 doctor 里用，慢但不需要额外工具）
port_owner() { # $1=端口 —— 谁在占它，输出 pid
  _port_dec=$(port_normalize "$1") || return 1
  _hex=$(printf '%04X' "$_port_dec" 2>/dev/null) || return 1
  # 一次 awk 扫完两张表：$4==0A 是 LISTEN，$2 是本地地址，$10 是 socket inode。
  # 以前是按 read 切字段再对剩下那截取第 10 列 —— 那已经不是整行的第 10 列了，
  # 拿到的是错的数字，于是永远匹配不到任何进程。
  _inodes=$(port_socket_inodes "$1" 2>/dev/null | tr '\n' ' ')
  [ -n "$_inodes" ] || return 1
  for _p in /proc/[0-9]*; do
    _pid="${_p#/proc/}"
    for _fd in "$_p"/fd/*; do
      _l=$(ls -l "$_fd" 2>/dev/null) || continue
      case "$_l" in
        *socket:*) ;;
        *) continue ;;
      esac
      _ino=$(printf '%s' "$_l" | sed 's/.*\[\([0-9]*\)\].*/\1/')
      case " $_inodes " in
        *" $_ino "*) printf '%s' "$_pid"; return 0 ;;
      esac
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# 设备状态
# ---------------------------------------------------------------------------
battery_level() {
  for _p in /sys/class/power_supply/battery/capacity /sys/class/power_supply/bms/capacity; do
    if [ -r "$_p" ]; then cat "$_p" 2>/dev/null; return 0; fi
  done
  if command -v dumpsys >/dev/null 2>&1; then
    dumpsys battery 2>/dev/null | sed -n 's/.*level: *\([0-9]*\).*/\1/p' | head -n 1
  fi
  return 0
}

is_charging() {
  _p=/sys/class/power_supply/battery/status
  if [ -r "$_p" ]; then
    _s=$(cat "$_p" 2>/dev/null)
    case "$_s" in
      Charging|Full) return 0 ;;
    esac
  fi
  for _p in /sys/class/power_supply/usb/online /sys/class/power_supply/ac/online \
            /sys/class/power_supply/pc_port/online /sys/class/power_supply/dc/online; do
    [ -r "$_p" ] && [ "$(cat "$_p" 2>/dev/null)" = "1" ] && return 0
  done
  return 1
}

on_wifi() {
  command -v ip >/dev/null 2>&1 || return 0   # 判断不了就放行，不要把服务卡死
  for _dev in wlan0 wlan1 swlan0; do
    ip -4 addr show "$_dev" 2>/dev/null | grep -q 'inet ' && return 0
  done
  return 1
}

net_ready() {
  command -v ip >/dev/null 2>&1 || return 0
  # Android 的路由按 netId 分表，main 表常年是空的。
  # 旧实现只 grep `ip route`（= main 表），没有 VPN 时几乎必然为空，
  # 于是 wait_net 每次都空等到超时（默认 45s）才继续 —— 开机后“服务半天不起来”。
  # 判断顺序：真实选路结果 > 任意表里的默认路由 > 有全局地址。
  _nr_dev=$(ip route get 1.1.1.1 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [ -n "$_nr_dev" ] && [ "$_nr_dev" != "lo" ] && return 0
  _nr_dev=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null \
            | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [ -n "$_nr_dev" ] && [ "$_nr_dev" != "lo" ] && return 0
  ip route show table all 2>/dev/null | grep -q '^default ' && return 0
  ip -6 route show table all 2>/dev/null | grep -q '^default ' && return 0
  # 兜底：拿到一个非环回、非链路本地的 IPv4 地址就算网络可用
  # 兜底不要用"看起来像 IP"的正则：127.0.0.1 也匹配，结果永远返回 0，
  # wait_net 形同虚设。这里明确排除回环与链路本地。
  ip -4 addr 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="inet"){split($(i+1),a,"/"); print a[1]}}' \
    | grep -qvE '^(127[.]|169[.]254[.])' && return 0
  return 1
}

wait_boot_completed() { # $1=最多等多少秒
  _i=0
  while [ "$_i" -lt "$1" ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && return 0
    sleep 2
    _i=$((_i + 2))
  done
  return 1
}

wait_net() { # $1=最多等多少秒
  _i=0
  while [ "$_i" -lt "$1" ]; do
    net_ready && return 0
    sleep 2
    _i=$((_i + 2))
  done
  return 1
}

is_usable_lan_ip() {
  case "$1" in
    ''|0.0.0.0|127.*|169.254.*|255.*) return 1 ;;
    198.18.*|198.19.*) return 1 ;;
    # 198.18.0.0/15 是 Clash/mihomo 这类 TUN 代理的 fake-ip 段。
    # 旧实现只排掉 127.*，开着代理时就会把面板地址算成 http://198.18.0.0:3065，
    # 别的设备永远打不开，还容易被误会成"服务没起来"。
    # magpie v0.4 踩过同一个坑（README 里贴了 198.18.0.0:3430 的日志），这里照抄它的排除表。
  esac
  case "$1" in *[!0-9.]*) return 1 ;; esac
  return 0
}

# 蜂窝口一律不当"局域网地址"：rmnet/ccmni 的地址在运营商 NAT 后面，
# 同一个 Wi-Fi 下的电脑根本连不上，显示它比不显示更误导。
# wb2api v1.4.4 的 lib.sh 就是因为取到了 10.100.x.x 才改成只认 wlan 的。
_lan_iface_excluded() {
  case "$1" in
    rmnet*|ccmni*|pdp*|clat*|dummy*|lo|sit*|ip6tnl*|tun*|ppp*|wg*) return 0 ;;
  esac
  return 1
}

_ips_of_dev() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -o -4 addr show dev "$1" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="inet"){split($(i+1),a,"/");print a[1];exit}}'
}

# ifconfig 兜底要认两种格式，且不能把 inet6 的 fe80:: 当成地址：
#   玩具箱（现代 Android）  inet 192.168.1.5  netmask ...
#   老版（部分定制 ROM）    inet addr:192.168.1.5  Bcast:...
# 两条 sed 分支都要求 inet 后面跟空格或 " addr:"，
# 否则 "inet6 fe80::1" 也会命中，取出来的是个 "6"。
_ifc_ip() {
  command -v ifconfig >/dev/null 2>&1 || return 0
  ifconfig "$1" 2>/dev/null | sed -n \
    -e 's/.*[[:space:]]inet addr:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' \
    -e 's/.*[[:space:]]inet[[:space:]][[:space:]]*\([0-9][0-9.]*\).*/\1/p' | head -n 1
}

_dev_ip() { # $1=网卡；ip 优先，ifconfig 兜底
  _di=$(_ips_of_dev "$1")
  [ -n "$_di" ] || _di=$(_ifc_ip "$1")
  printf '%s' "$_di"
}

local_ip() {
  _ip=""
  # 第一梯队：无线 / 热点 / 以太网口（PC 真能连上的那些）
  for _dev in wlan0 wlan1 ap0 wlan2 eth0; do
    _ip=$(_dev_ip "$_dev")
    is_usable_lan_ip "$_ip" && break
    _ip=""
  done
  # 第二梯队：枚举所有无线/热点类网卡（有些机型叫 swlan0 / wlan2 / ap1）
  if [ -z "$_ip" ]; then
    for _dev in $( { command -v ip >/dev/null 2>&1 && ip -o -4 addr show 2>/dev/null | awk '{print $2}';
                     command -v ifconfig >/dev/null 2>&1 && ifconfig -a 2>/dev/null | sed -n 's/^\([a-zA-Z0-9_.-]*\)[[:space:]:].*/\1/p'; } \
                   | sort -u | grep -E '^(wlan|ap|swlan|eth|rndis)' ); do
      _lan_iface_excluded "$_dev" && continue
      _ip=$(_dev_ip "$_dev")
      is_usable_lan_ip "$_ip" && break
      _ip=""
    done
  fi
  # 注意：这里不再回落到 rmnet/ccmni/任意网卡。
  # 拿不到局域网地址就返回空，调用方自然只显示 127.0.0.1 —— 空比错地址有用。
  printf '%s' "$_ip"
}

# ---------------------------------------------------------------------------
# 二进制检查
# ---------------------------------------------------------------------------
elf_magic_ok() { # 是不是 ELF
  [ -f "$1" ] || return 1
  _m=$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \t\r\n')
  [ "$_m" = "7f454c46" ]
}

elf_arch() { # aarch64 / arm / x86_64 / unknown
  [ -f "$1" ] || { printf 'unknown'; return 0; }
  _m=$(od -An -tx1 -j18 -N2 "$1" 2>/dev/null | tr -d ' \t\r\n')
  case "$_m" in
    b700) printf 'aarch64' ;;
    b600) printf 'arm' ;;
    3e00) printf 'x86_64' ;;
    *)    printf 'unknown' ;;
  esac
}

# 找本机的 busybox（KSU / Magisk / APatch 各有一条路径）。
# 不依赖 PATH：KSU 的 Standalone 模式会忽略 PATH，直接走 applet。
find_busybox() {
  for _bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
             /data/adb/ap/bin/busybox /data/adb/apd/bin/busybox; do
    [ -x "$_bb" ] && { printf '%s' "$_bb"; return 0; }
  done
  command -v busybox >/dev/null 2>&1 && { command -v busybox; return 0; }
  return 1
}

# sha256：多级兜底。
# 为什么要兜这么多层：Android 的 toybox 有一部分机型不带 sha256sum，而
# "算不出哈希就放行"等于升级没有完整性校验（旧版就是 fail-open）。这里把
# sha256sum / KSU busybox / Magisk busybox / APatch busybox / toybox / 自带
# 二进制全试一遍，全都算不出来才返回空 —— 上游拿到空值必须 fail-closed。
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    _h=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
    [ -n "$_h" ] && { printf '%s' "$_h"; return 0; }
  fi
  for _bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox \
             /data/adb/ap/bin/busybox /data/adb/apd/bin/busybox; do
    [ -x "$_bb" ] || continue
    _h=$("$_bb" sha256sum "$1" 2>/dev/null | awk '{print $1}')
    [ -n "$_h" ] && { printf '%s' "$_h"; return 0; }
  done
  if command -v toybox >/dev/null 2>&1; then
    _h=$(toybox sha256sum "$1" 2>/dev/null | awk '{print $1}')
    [ -n "$_h" ] && { printf '%s' "$_h"; return 0; }
  fi
  for _b in "$BINDIR/sha256sum" "$MODDIR/tools/sha256sum"; do
    [ -x "$_b" ] || continue
    _h=$("$_b" "$1" 2>/dev/null | awk '{print $1}')
    [ -n "$_h" ] && { printf '%s' "$_h"; return 0; }
  done
  return 0
}

# ---------------------------------------------------------------------------
# 手机环境适配（KernelSU / Magisk 都会踩的三个坑）
# ---------------------------------------------------------------------------

# 1) cgroup 逃逸。
#    service.sh / hot-restart.sh 有时会被塞进某个 app 的 cgroup。那个 cgroup
#    有内存上限，而且 app 被杀/被冻结时整组进程一起完蛋 —— 表现为"服务莫名
#    其妙没了，日志里啥也没有"。把守护进程挪到各控制器层级根就免疫。
#    旧实现的三个洞（问题 4）：只看 /proc/self/cgroup 第一行（本机是 hybrid
#    模式，freezer 恰好在根，真正被困的 cpuset/cpu 在后面的行里）；只写 v2
#    统一层级的 /sys/fs/cgroup/cgroup.procs（本机 cpuset 挂在 /dev/cpuset、
#    cpu 挂在 /dev/cpuctl，路径完全对不上）；写失败也返回成功（静默假成功）。
#    新实现：逐行解析 /proc/self/cgroup；v1 控制器行按 /proc/self/mountinfo
#    找到该控制器的挂载点（fstype=cgroup 且 superopts 含控制器名），把本
#    进程 PID 写进挂载根的 tasks（无 tasks 再用 cgroup.procs）；v2 行
#    （0::/path）写统一层级挂载根的 cgroup.procs。每次写入后回读
#    /proc/<pid>/cgroup 核验，逐控制器记录结果；任一控制器仍在非根 app 路径
#    就如实返回非零，调用方记警告但不阻断启动。
#    函数自包含：只依赖 /proc 与 awk，不依赖 common.sh 的其它状态或路径
#    （cfg_get 仅在存在时用于配置门控），可整体提取到独立脚本测试。
#    --check 为只读检查模式：只打印每个控制器当前路径与计划动作，不写任何
#    文件。注意：本函数迁移的是"当前 shell 进程"自身，必须直接调用（不能放
#    进命令替换），调用方后续拉起的子进程会继承迁移后的归属。
cgroup_escape() { # $1 可选 --check：只读检查模式
  _cge_mode=run
  [ "${1:-}" = "--check" ] && _cge_mode=check
  # 配置门控：模块内按 settings.conf（默认开）；单独提取测试时没有 cfg_get
  # 就直接执行，保证测试环境行为完整。
  if [ "$_cge_mode" = "run" ] && command -v cfg_get >/dev/null 2>&1; then
    [ "$(cfg_get cgroup_escape 1)" = "1" ] || return 0
  fi
  _cge_pid=$$
  _cge_cg=/proc/$_cge_pid/cgroup
  [ -r "$_cge_cg" ] || { printf 'cgroup_escape: 无法读取 %s\n' "$_cge_cg"; return 1; }
  _cge_bad=0
  _cge_moved=0
  while IFS= read -r _cge_line; do
    [ -n "$_cge_line" ] || continue
    _cge_hier=${_cge_line%%:*}
    _cge_rest=${_cge_line#*:}
    _cge_ctrls=${_cge_rest%%:*}
    _cge_path=${_cge_rest#*:}
    if [ "$_cge_path" = "/" ]; then
      # 已在该层级根：视为成功，不写（问题 4b）。检查模式也要报告。
      if [ "$_cge_mode" = "check" ]; then
        printf 'cgroup_escape: [%s] 当前 / ：已在层级根，无需迁移\n' "${_cge_ctrls:-cgroup2}"
      fi
      continue
    fi
    # 找该层级的挂载点：v1 按控制器名匹配 cgroup 挂载，v2 找 cgroup2 挂载。
    # 挂载根一律从 mountinfo 解析，不硬编码（本机 cpuset 在 /dev/cpuset、
    # cpu 在 /dev/cpuctl，根本不在 /sys/fs/cgroup 下）。
    if [ -z "$_cge_ctrls" ]; then
      _cge_want=cgroup2
    else
      _cge_want=${_cge_ctrls%%,*}
    fi
    _cge_mnt=$(awk -v want="$_cge_want" '
      {
        sep = 0
        for (i = 1; i <= NF; i++) if ($i == "-") { sep = i; break }
        if (!sep) next
        fst = $(sep + 1)
        if (want == "cgroup2") {
          if (fst != "cgroup2") next
        } else {
          if (fst != "cgroup") next
          hit = 0
          for (i = sep + 3; i <= NF; i++) {
            n = split($i, a, ",")
            for (j = 1; j <= n; j++) if (a[j] == want) hit = 1
          }
          if (!hit) next
        }
        # 优先 root 字段为 "/" 的挂载（bind 子树挂载的根不是层级根），
        # 没有再退到第一个匹配挂载。
        if ($4 == "/") { print $5; exit }
        if (m == "") m = $5
      }
      END { if (m != "") print m }
    ' /proc/self/mountinfo 2>/dev/null)
    # v1 层级根的迁移入口是 tasks（noprefix 模式直接在挂载根），没有再用 cgroup.procs
    if [ -z "$_cge_ctrls" ]; then
      _cge_target=cgroup.procs
    elif [ -n "$_cge_mnt" ] && [ -e "$_cge_mnt/tasks" ]; then
      _cge_target=tasks
    else
      _cge_target=cgroup.procs
    fi
    if [ "$_cge_mode" = "check" ]; then
      if [ -z "$_cge_mnt" ]; then
        printf 'cgroup_escape: [%s] 当前 %s ：mountinfo 中找不到挂载点，无法迁移\n' "$_cge_ctrls" "$_cge_path"
      else
        printf 'cgroup_escape: [%s] 当前 %s ：计划写入 %s/%s 迁到层级根\n' "$_cge_ctrls" "$_cge_path" "$_cge_mnt" "$_cge_target"
      fi
      _cge_bad=1
      continue
    fi
    if [ -z "$_cge_mnt" ]; then
      printf 'cgroup_escape: [%s] 当前 %s ：mountinfo 中找不到挂载点，无法迁移\n' "$_cge_ctrls" "$_cge_path"
      _cge_bad=1
      continue
    fi
    if printf '%s\n' "$_cge_pid" >"$_cge_mnt/$_cge_target" 2>/dev/null; then
      # 回读核验（问题 4c）：按层级号重读 /proc/<pid>/cgroup，确认已到根
      _cge_now=$(awk -F: -v h="$_cge_hier" '$1 == h {print $3; exit}' "$_cge_cg" 2>/dev/null)
      if [ "$_cge_now" = "/" ]; then
        printf 'cgroup_escape: [%s] 已从 %s 迁到层级根（%s/%s）\n' "$_cge_ctrls" "$_cge_path" "$_cge_mnt" "$_cge_target"
        _cge_moved=1
      else
        printf 'cgroup_escape: [%s] 写入成功但仍停在 %s（期望 /），如实上报\n' "$_cge_ctrls" "${_cge_now:-未知}"
        _cge_bad=1
      fi
    else
      # 写失败（只读挂载/权限不足）必须如实报告，不得静默成功（问题 4d）
      printf 'cgroup_escape: [%s] 写入 %s/%s 失败（只读挂载或权限不足），如实上报\n' "$_cge_ctrls" "$_cge_mnt" "$_cge_target"
      _cge_bad=1
    fi
  done <"$_cge_cg"
  if [ "$_cge_bad" = "0" ] && [ "$_cge_moved" = "1" ]; then
    printf 'cgroup_escape: 全部控制器已就位（含本次迁移的层级）\n'
  fi
  [ "$_cge_bad" = "0" ]
}

# 2) 隐私遮蔽：上游会把完整请求正文写到 debug/last-request.json。
#    没有私有挂载命名空间可用了（KSU 不保证 unshare 权限），改用软链到
#    /dev/null：写入照常成功，内容直接进黑洞。
#    为什么不用目录顶替：有些代码路径会把"写文件失败"当致命错误，目录会让
#    File::create 报 EISDIR，反而可能把服务打挂。软链是零风险方案。
privacy_shield() {
  [ "$(cfg_get privacy_last_request 1)" = "1" ] || return 0
  for _d in "$DATADIR/debug" "$HOMEDIR/debug"; do
    [ -d "$_d" ] || continue
    for _n in last-request.json last-request.meta.txt; do
      _f="$_d/$_n"
      [ -L "$_f" ] && continue
      rm -f "$_f" 2>/dev/null
      ln -s /dev/null "$_f" 2>/dev/null
    done
  done
  return 0
}

# 3) 开机残留：上次升级/卸载中途被打断，会在 APP_HOME 里留下
#    payload.new.* / payload.old / payload.rollback.* / upd.* 这些目录，
#    最坏情况把 /data 撑满。这里按证据恢复（只动"确定已死事务"的现场）。
#    问题 6：恢复是证据驱动的 —— 只在「切换进行中标记(payload.switching)
#    已过期（>120s）」或「pending 明确属于已死事务（pid+启动代次对不上）」
#    且「当前载荷确实缺失/损坏」时才动手；绝不因瞬时缺失就判定上一事务
#    死亡。临界区用 update 锁短超时包裹：拿不到锁说明有活跃事务，本轮
#    不动作。调用点（supervise.sh）已挪到取得实例锁之后。
payload_recover_interrupted() { # $1=boot|runtime（默认 runtime）
  # F-001/F-002/F-003：journal 是跨重启的第一手进度记录，有它就必须先按
  # journal 收尾；journal 缺失才退回旧的标记/pending 启发式。boot 模式下
  # 锁已清、更新进程必然不在，年龄门槛也不再有意义。
  _pri_boot=0
  [ "${1:-}" = "boot" ] && _pri_boot=1
  if [ -s "$A2A_TXN_JOURNAL" ]; then
    # RR-02：按 journal 收尾会移动载荷目录、换入数据快照、删中转目录，必须
    # 与更新/安装事务互斥。旧实现直接调用 payload_txn_recover，supervise
    # 与 updater 可以同时改同一份现场（journal 只挡"主人还活着"，挡不住
    # 另一个刚启动、还没写 journal 的更新进程）。已持有锁（updater 事务内
    # 调用）时直接复用，不重复取。
    _pri_jtok=${UPDATE_LOCK_TOKEN:-}
    _pri_jpath=${UPDATE_LOCK_PATH:-}
    _pri_jlock=0
    if ! update_lock_is_self "$RUNDIR/update.lock.d"; then
      if update_lock_acquire "$RUNDIR/update.lock.d" 5 >/dev/null 2>&1; then
        _pri_jlock=1
      else
        log_to "$SUPLOG" "拿不到 update 锁（有活跃更新事务），本轮不按 journal 恢复"
        return 0
      fi
    fi
    payload_txn_recover "${1:-runtime}"
    _pri_jrc=$?
    if [ "$_pri_jlock" = "1" ]; then
      update_lock_release "$RUNDIR/update.lock.d"
      UPDATE_LOCK_TOKEN=$_pri_jtok
      UPDATE_LOCK_PATH=$_pri_jpath
    fi
    [ "$_pri_jrc" = "0" ] && return 0
    # journal 收尾失败：现场保持原样等下次，绝不再叠加启发式动作
    return 1
  fi
  # 必须校验 ELF、完整 lib 和 UI；不能只凭主 ELF 存在就认定切换完成。
  # 完整性判定统一走 payload_validate：它会先区分静态/动态载荷，
  # 静态包本来就没有 lib/ld-linux-aarch64.so.1，硬要求会让中断恢复永远失败。
  _pri_valid=0
  payload_validate "$PAYLOAD" >/dev/null 2>&1 && _pri_valid=1
  if [ "$_pri_valid" = "1" ]; then
    # 载荷完好：切换早已完成或从未开始。只清掉可能残留的切换标记。
    if [ -f "$RUNDIR/payload.switching" ]; then
      rm -f "$RUNDIR/payload.switching" 2>/dev/null
      log_to "$SUPLOG" "清除残留的载荷切换标记（当前载荷完好）"
    fi
    return 0
  fi
  # 载荷不完整：收集「上一事务已死」的证据
  _pri_evidence=0
  _pri_reason=""
  if [ -f "$RUNDIR/payload.switching" ]; then
    _pri_sw_ts=$(awk 'NR==1{print $2; exit}' "$RUNDIR/payload.switching" 2>/dev/null)
    case "$_pri_sw_ts" in ''|*[!0-9]*) _pri_sw_ts=0 ;; esac
    _pri_age=$(( $(now_epoch) - _pri_sw_ts ))
    [ "$_pri_age" -lt 0 ] && _pri_age=0
    if [ "$_pri_age" -gt 120 ] || [ "$_pri_boot" = "1" ]; then
      _pri_evidence=1
      _pri_reason="切换标记已过期 ${_pri_age}s（boot=$_pri_boot）"
    else
      # 标记还新：可能真有事务在跑（或刚死），本轮不动
      log_to "$SUPLOG" "载荷不完整但切换标记仅 ${_pri_age}s（<=120s），跳过恢复等下轮"
      return 0
    fi
  fi
  if [ "$_pri_evidence" != "1" ] && [ -s "$RUNDIR/update.pending" ]; then
    # pending 属于已死事务：登记的 pid 已不存在或启动代次对不上
    _pri_pid=$(awk 'NR==1{print $2; exit}' "$RUNDIR/update.pending" 2>/dev/null)
    _pri_ticks=$(awk 'NR==1{print $5; exit}' "$RUNDIR/update.pending" 2>/dev/null)
    case "$_pri_pid$_pri_ticks" in
      ''|*[!0-9]*) ;;
      *)
        if ! pid_alive "$_pri_pid" \
           || [ "$(proc_start_ticks "$_pri_pid" 2>/dev/null)" != "$_pri_ticks" ]; then
          _pri_evidence=1
          _pri_reason="pending 属于已死事务（pid=$_pri_pid）"
        fi
        ;;
    esac
  fi
  if [ "$_pri_evidence" != "1" ]; then
    log_to "$SUPLOG" "载荷不完整但没有已死事务的证据，跳过恢复（避免误伤活跃事务）"
    return 0
  fi
  log_to "$SUPLOG" "检测到中断的载荷事务（$_pri_reason），尝试恢复"
  # 临界区：update 锁短超时。已持有（如 upd_recover_activation 在事务内调用）
  # 则直接复用；拿不到说明有活跃事务，本轮不动作。
  _pri_outer_token=${UPDATE_LOCK_TOKEN:-}
  _pri_outer_path=${UPDATE_LOCK_PATH:-}
  _pri_locked=0
  if ! update_lock_is_self "$RUNDIR/update.lock.d"; then
    if update_lock_acquire "$RUNDIR/update.lock.d" 5 >/dev/null 2>&1; then
      _pri_locked=1
    else
      log_to "$SUPLOG" "拿不到 update 锁（有活跃更新事务），本轮跳过载荷恢复"
      return 0
    fi
  fi
  for _old in "$APP_HOME"/payload.*.old.* "$APP_HOME"/payload.old "$APP_HOME"/payload.rollback.old "$BACKUPDIR/prev"; do
    [ -d "$_old" ] || continue
    if payload_validate "$_old" >/dev/null 2>&1; then
      # R09：移开"坏 current"失败时必须放弃这一次恢复。旧实现忽略 mv 的
      # 返回码继续往下 mv，old 会被嵌进坏目录（payload/下再套一层 old 名），
      # 结果 current 仍然坏、唯一回滚副本也被毁掉，函数还照样 return 0 报成功。
      if [ -e "$PAYLOAD" ]; then
        if ! mv "$PAYLOAD" "$APP_HOME/payload.incomplete.$$" 2>/dev/null; then
          log_to "$SUPLOG" "无法移开不完整的当前载荷，跳过本次恢复：$_old"
          continue
        fi
      fi
      if mv "$_old" "$PAYLOAD" 2>/dev/null && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
        payload_fix_perms "$PAYLOAD"
        log_to "$SUPLOG" "已恢复中断的载荷切换：$_old"
        rm -rf "$APP_HOME/payload.incomplete.$$"
        # 恢复成功：清掉切换标记，避免下次开机再次进入恢复判定
        rm -f "$RUNDIR/payload.switching" 2>/dev/null
        break
      fi
      # 换上去的仍然不可用：把刚移开的目录放回原位，别把 current 留空。
      if [ -d "$APP_HOME/payload.incomplete.$$" ] && [ ! -e "$PAYLOAD" ]; then
        mv "$APP_HOME/payload.incomplete.$$" "$PAYLOAD" 2>/dev/null
      fi
      log_to "$SUPLOG" "恢复中断载荷失败（$_old 换上去后仍未通过校验）"
    fi
  done
  if [ "$_pri_locked" = "1" ]; then
    update_lock_release "$RUNDIR/update.lock.d"
    UPDATE_LOCK_TOKEN=$_pri_outer_token
    UPDATE_LOCK_PATH=$_pri_outer_path
  fi
  return 0
}

secure_files() {
  chmod 600 "$SETTINGS" 2>/dev/null
  for _root in "$DATADIR" "$HOMEDIR" "$CFGDIR"; do
    [ -d "$_root" ] || continue
    for _f in "$_root"/*.db "$_root"/*.sqlite "$_root"/*.sqlite3 "$_root"/*.json \
              "$_root"/*.key "$_root"/*.token "$_root"/*.yaml "$_root"/*.yml; do
      [ -f "$_f" ] && chmod 600 "$_f" 2>/dev/null
    done
  done
  return 0
}

payload_is_static() { # 静态（musl）载荷没有 PT_INTERP，也就不需要自带 glibc
  [ "${A2A_STATIC:-}" = "1" ] && return 0
  [ "${A2A_STATIC:-}" = "0" ] && return 1
  [ -f "$SERVER_BIN" ] || return 1
  # glibc 动态载荷里一定带着解释器路径字符串；musl 静态载荷没有
  grep -qa 'ld-linux-aarch64' "$SERVER_BIN" 2>/dev/null && return 1
  grep -qa 'ld-musl' "$SERVER_BIN" 2>/dev/null && return 0
  grep -qa 'ld-linux' "$SERVER_BIN" 2>/dev/null && return 1
  return 0
}

sweep_stale_dirs() {
  # pending 里记着还没提交的事务旧载荷：它可能正是唯一能回滚的副本，
  # 清理时必须跳过，否则"开机先清垃圾再恢复"会把恢复材料先删掉。
  _ss_keep=$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null | head -n 1)
  # F-002/F-004：journal 登记的 old_payload / data_tmp / data_aside 与
  # switching 标记里的旧载荷去向同样是活跃恢复材料，清理时一个都不许碰。
  _ss_jkeep=""
  if [ -s "$A2A_TXN_JOURNAL" ]; then
    for _ss_jf in 7 9 10; do
      _ss_jv=$(payload_txn_field "$_ss_jf")
      case "$_ss_jv" in ''|'-') ;; *) _ss_jkeep="$_ss_jkeep $_ss_jv" ;; esac
    done
  fi
  if [ -f "$RUNDIR/payload.switching" ]; then
    _ss_sv=$(awk 'NR==1{print $4; exit}' "$RUNDIR/payload.switching" 2>/dev/null)
    case "$_ss_sv" in ''|'-') ;; *) _ss_jkeep="$_ss_jkeep $_ss_sv" ;; esac
  fi
  for _d in "$APP_HOME"/payload.new.* "$APP_HOME"/payload.old \
            "$APP_HOME"/payload.rollback.new "$APP_HOME"/payload.rollback.old \
            "$APP_HOME"/payload.rollback.old.* \
            "$APP_HOME"/payload.incomplete.* "$APP_HOME"/payload.broken.* \
            "$APP_HOME"/payload.interrupted.* "$APP_HOME"/payload.new.old.* \
            "$APP_HOME"/payload.rollback.failed.* \
            "$TMPD"/upd.* "$BACKUPDIR/lib.new"; do
    [ -e "$_d" ] || continue
    [ -n "$_ss_keep" ] && [ "$_d" = "$_ss_keep" ] && continue
    case " $_ss_jkeep " in *" $_d "*) continue ;; esac
    rm -rf "$_d" 2>/dev/null
  done
  # $TMPD 里除了 upd.* 还有解包残留
  # 切换标记是中断恢复的证据：载荷完好时它是残留垃圾可以清；载荷不完整时
  # 必须保留给 payload_recover_interrupted（它在 post-fs-data 里先于本函数
  # 执行，走到这里还留着说明恢复被跳过或没做成，留给下次开机再试）。
  if [ -f "$RUNDIR/payload.switching" ] && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
    rm -f "$RUNDIR/payload.switching" 2>/dev/null
  fi
  # 数据快照/回滚（问题 1）的可重建临时物：中断的快照副本与回滚中转目录。
  # data-prev（快照本体）与 DATADIR.upgraded.*（升级后数据的现场保全）绝不清。
  rm -rf "$BACKUPDIR/data-prev.new" 2>/dev/null
  # F-003：restore.* 是数据回滚的中转副本，journal 还指着它就绝不能删
  # （旧实现无条件清掉，中断的换入从此无法补完）。
  for _d in "$DATADIR".restore.*; do
    [ -e "$_d" ] || continue
    case " $_ss_jkeep " in *" $_d "*) continue ;; esac
    rm -rf "$_d" 2>/dev/null
  done
  [ -d "$TMPD" ] && rm -rf "$TMPD"/* 2>/dev/null
  return 0
}

module_desc_set() { # $1=新描述；只有真的变了才写，避免每轮 spawn 进程
  [ "$(cfg_get dynamic_desc 1)" = "1" ] || return 0
  _md="$*"
  [ -n "$_md" ] || return 0
  _mdlast="$RUNDIR/desc.last"
  # desc.pending 是上一次"想写但没写成"的文案：它跟目标一致时也要重试，
  # 否则一次 ksud 调用失败就会把旧的「已停止」永久钉在模块卡片上。
  [ -f "$_mdlast" ] && [ "$(cat "$_mdlast" 2>/dev/null)" = "$_md" ] && [ ! -f "$RUNDIR/desc.pending" ] && return 0
  _ok=0
  # 一、直接改模块目录里的 module.prop（magpie 用过的路子，管理器读的就是它）
  _mp="$MODDIR/module.prop"
  if [ -f "$_mp" ] && grep -q '^description=' "$_mp" 2>/dev/null; then
    # 描述里可能带 & | \ 之类的字符，直接拼进 sed 替换串会被当成
    # "匹配内容/分隔符"解释，轻则写坏 module.prop，重则整行丢失。
    # 这里先转义替换串里的特殊字符。
    _md_esc=$(printf '%s' "$_md" | sed 's/[\\&|]/\\&/g')
    if _new_mp=$(sed "s|^description=.*|description=$_md_esc|" "$_mp" 2>/dev/null) && [ -n "$_new_mp" ]; then
      printf '%s' "$_new_mp" >"$_mp.new" 2>/dev/null && mv -f "$_mp.new" "$_mp" 2>/dev/null && _ok=1
    fi
  fi
  # 二、再试 KernelSU / APatch 的 override.description（有它就以它为准）
  for _ksud in /data/adb/ksud /data/adb/ap/bin/ksud /data/adb/magisk/ksud; do
    [ -x "$_ksud" ] || continue
    if "$_ksud" module config set override.description "$_md" >/dev/null 2>&1 </dev/null; then
      _ok=1
    fi
    break
  done
  if [ "$_ok" = "1" ]; then
    printf '%s' "$_md" >"$_mdlast" 2>/dev/null
    rm -f "$RUNDIR/desc.pending" 2>/dev/null
  else
    # 一次没成功就挂个标记，下一轮继续重试，不写 desc.last
    printf '%s' "$_md" >"$RUNDIR/desc.pending" 2>/dev/null
  fi
  return 0
}
