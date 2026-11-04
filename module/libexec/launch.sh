#!/system/bin/sh
# ============================================================================
# Agent2API Magisk 模块 · 启动器
#
# 干一件事：把 Agent2API 服务端正确地带起来，然后 exec 掉自己（PID 不变，
# 守护进程根据这个 PID 判断存活）。
#
# 关键点：不能直接 exec agent2api-server。它是 glibc 动态链接的，PT_INTERP
# 写死了 /lib/ld-linux-aarch64.so.1，而 Android 根分区根本没有 /lib。
# 所以我们用自带的 loader 显式拉起它（不 chroot、不打补丁、不动系统）：
#
#   LD_LIBRARY_PATH=<payload>/lib <payload>/lib/ld-linux-aarch64.so.1 \
#       --argv0 agent2api-server --library-path <payload>/lib <payload>/agent2api-server
#
# 副作用（已经处理）：/proc/self/exe 会指向 ld.so，所以应用内的"自更新"必须关掉，
# 由模块自己的 `a2a update` 接管（见 libexec/updater.sh）。
# ============================================================================

A2A_DIR=$(dirname "$0")
. "$A2A_DIR/common.sh"

PRINT_ONLY=0
[ "$1" = "-n" ] || [ "$1" = "--print-env" ] && PRINT_ONLY=1

ensure_layout

if [ ! -f "$SERVER_BIN" ]; then
  log_to "$SUPLOG" "启动失败：服务端二进制不存在：$SERVER_BIN"
  echo "启动失败：缺少 $SERVER_BIN，请重装模块" >&2
  exit 78
fi
# R05：先判定静态/动态，再决定要不要 loader。静态（musl）载荷没有 PT_INTERP，
# 本来就不需要 lib/ld-linux-aarch64.so.1；旧顺序在静态包上直接 78 退出，
# 而同一个包 payload_validate 是通过的，两条判定互相打架。
if ! payload_is_static; then
  if [ ! -x "$LOADER" ]; then
    log_to "$SUPLOG" "启动失败：loader 不存在或不可执行：$LOADER"
    echo "启动失败：缺少运行时 $LOADER，请重装模块" >&2
    exit 78
  fi
fi

# ---------------------------------------------------------------------------
# 读配置
# ---------------------------------------------------------------------------
CFG_HOST=$(cfg_get host 127.0.0.1)
CFG_PORT=$(port_normalize "$(cfg_get port 3065)") || {
  log_to "$SUPLOG" "非法代理端口配置，运行期回退到 3065"
  CFG_PORT=3065
}
CFG_PANEL_RAW=$(cfg_get panel_port "")
CFG_PANEL=""
if [ -n "$CFG_PANEL_RAW" ]; then
  CFG_PANEL=$(port_normalize "$CFG_PANEL_RAW") || {
    log_to "$SUPLOG" "非法独立面板端口配置，运行期回退到与代理端口共用"
    CFG_PANEL=""
  }
fi
# 上游 agent2api-server 对 PANEL_PORT == 网关端口 是硬失败（打印
# “与网关端口相同”后 ExitCode::FAILURE），所以相同值必须当作“未设置”。
# 以前这里原样透传，配成相同端口会让守护进程陷入无限拉起。
if [ -n "$CFG_PANEL" ] && [ "$CFG_PANEL" = "$CFG_PORT" ]; then
  log_to "$SUPLOG" "独立面板端口与代理端口相同，按共用端口处理"
  CFG_PANEL=""
fi
CFG_ADMIN_USER=$(cfg_get admin_user "")
CFG_ADMIN_PASS=$(cfg_get admin_password "")
CFG_KEY=$(cfg_get gateway_key "")
CFG_NO_KEY=$(cfg_get allow_no_key 0)
CFG_CAPTCHA=$(cfg_get captcha 1)
CFG_VERBOSE=$(cfg_get verbose 0)

# ---------------------------------------------------------------------------
# 组装环境
# ---------------------------------------------------------------------------
export AGENT2API_PROXY_HOME="$DATADIR"
export AGENT2API_UI_DIR="$PAYLOAD/ui"
# 不要设 AGENT2API_LOG_FILE：上游只在 Windows 服务形态（bin/agent2api-server.rs
# 里 #[cfg(windows)] + service::requested() 那个分支）调用 logging::init_file_sink()，
# 打开文件通道。Linux/Android 的 headless 形态永远不建 FILE_SINK，
# write_file_line() 直接 return，console_line 只写 stderr —— 而 stderr 已经被
# 守护进程重定向进 server.log。以前这里把 LOG_FILE 指到 app.log，等于告诉用户
# 「应用日志在 app.log」，实际那个文件从头到尾不会被创建。
export AGENT2API_HOST="$CFG_HOST"
export AGENT2API_PROXY_PORT="$CFG_PORT"
export AGENT2API_ALLOW_NO_KEY="$CFG_NO_KEY"
export AGENT2API_CAPTCHA_ENABLED="$CFG_CAPTCHA"
export AGENT2API_VERBOSE="$CFG_VERBOSE"

# 必须硬关：loader 直启导致 /proc/self/exe 指向 ld.so，
# 应用内自更新会把我们的动态链接器覆盖掉，直接変砖。
export AGENT2API_SELF_UPDATE=0

# F-006（继承环境）：launch.sh 是被 exec 的新进程，会继承调用方（supervisor
# / 手动 shell）的全部环境。CFG_* 为空时只"不设置"不够 —— 外层残留的
# AGENT2API_* 会让服务端读到上一次的旧值。必须显式 unset。
if [ -n "$CFG_PANEL" ]; then
  export AGENT2API_PANEL_PORT="$CFG_PANEL"
else
  unset AGENT2API_PANEL_PORT
fi
if [ -n "$CFG_ADMIN_USER" ]; then
  export AGENT2API_ADMIN_USER="$CFG_ADMIN_USER"
else
  unset AGENT2API_ADMIN_USER
fi
if [ -n "$CFG_ADMIN_PASS" ]; then
  export AGENT2API_ADMIN_PASSWORD="$CFG_ADMIN_PASS"
else
  unset AGENT2API_ADMIN_PASSWORD
fi
if [ -n "$CFG_KEY" ]; then
  export AGENT2API_PROXY_API_KEY="$CFG_KEY"
else
  unset AGENT2API_PROXY_API_KEY
fi

# 运行时环境
export HOME="$HOMEDIR"
export TMPDIR="$TMPD"
export PATH="/system/bin:/system/xbin:$BINDIR"
export LD_LIBRARY_PATH="$PLIB"
export MALLOC_ARENA_MAX=2
export RUST_BACKTRACE=1

# 时区：优先用随包的完整 IANA zoneinfo，包含夏令时和历史规则。
# 仅系统没有提供时区名时才退到固定 POSIX 偏移。
CFG_AUTO_TZ=$(cfg_get auto_tz 1)
CFG_TZ=$(cfg_get tz "")
if [ -n "$CFG_TZ" ]; then
  export TZ="$CFG_TZ"
elif [ "$CFG_AUTO_TZ" = "1" ]; then
  . "$A2A_DIR/timezone.sh"
  # 时区只是显示/日志偏好，不该成为"服务起不来"的理由：原来这里 exit 1，
  # 只要 persist.sys.timezone 是个本机 zoneinfo 没有的名字，服务就永远起不来。
  # 改成降级告警，进程退回系统默认时区继续跑。
  timezone_apply || log_to "$SUPLOG" "完整时区初始化失败，已降级为系统默认时区继续启动"
fi

# 文件描述符上限：Android 默认 1024，长连接多了会 EMFILE
ulimit -n 8192 2>/dev/null || ulimit -n 4096 2>/dev/null || true

# 内存保护（可选）
if [ "$(cfg_get oom_protect 0)" = "1" ] && [ -w /proc/self/oom_score_adj ]; then
  echo -900 >/proc/self/oom_score_adj 2>/dev/null
fi

if [ "$PRINT_ONLY" = "1" ]; then
  # 给 a2a doctor / 排查用：打印将要使用的环境，不真的启动
  echo "APP_HOME=$APP_HOME"
  echo "AGENT2API_PROXY_HOME=$AGENT2API_PROXY_HOME"
  echo "AGENT2API_UI_DIR=$AGENT2API_UI_DIR"
  echo "AGENT2API_HOST=$AGENT2API_HOST"
  echo "AGENT2API_PROXY_PORT=$AGENT2API_PROXY_PORT"
  echo "AGENT2API_PANEL_PORT=${AGENT2API_PANEL_PORT:-}"
  echo "AGENT2API_ALLOW_NO_KEY=$AGENT2API_ALLOW_NO_KEY"
  echo "AGENT2API_CAPTCHA_ENABLED=$AGENT2API_CAPTCHA_ENABLED"
  echo "AGENT2API_VERBOSE=$AGENT2API_VERBOSE"
  echo "AGENT2API_SELF_UPDATE=$AGENT2API_SELF_UPDATE"
  echo "TZ=${TZ:-<unset>}"
  echo "TZDIR=${TZDIR:-<unset>}"
  echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
  echo "LOADER=$LOADER"
  echo "SERVER_BIN=$SERVER_BIN"
  exit 0
fi

log_to "$SUPLOG" "启动服务端：port=$CFG_PORT host=$CFG_HOST tz=${TZ:-unset}"

# exec：把当前进程整体替换成服务端，PID 不变
# 静态（musl）载荷不需要自带 glibc 加载器，直接跑
if payload_is_static; then
  exec "$SERVER_BIN"
fi
exec "$LOADER" \
  --argv0 agent2api-server \
  --inhibit-cache \
  --library-path "$PLIB" \
  "$SERVER_BIN"
