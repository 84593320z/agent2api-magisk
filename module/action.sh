#!/system/bin/sh
# ============================================================================
# Agent2API Magisk 模块 · action.sh
#
# [执行] 按钮不再只是打印状态：没跑就拉起来，然后把面板直接丢给浏览器。
# 这个交互是照 magpie v0.4 的 action.sh 抄的 —— 卡片按钮的语义应该是"一键可用"，
# 让用户在看输出里自己找地址、再手抄到浏览器，属于白扔掉的体验。
# ============================================================================

MODDIR="${MODDIR:-/data/adb/modules/agent2api}"

if [ -f "$MODDIR/libexec/common.sh" ]; then
  . "$MODDIR/libexec/common.sh" 2>/dev/null
fi
if [ -f "$MODDIR/libexec/control.sh" ]; then
  . "$MODDIR/libexec/control.sh" 2>/dev/null
fi

_pv=$(sed -n 's/^ver=//p' "$PAYLOAD/VERSION" 2>/dev/null | head -n 1)
_mv=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
_port=$(port_normalize "$(cfg_get port 3065)" 2>/dev/null) || _port=3065
_pport=$(panel_port_effective 2>/dev/null) || _pport=$_port
_url="http://127.0.0.1:$_pport/m.html"

_sup=$(read_pid "$RUNDIR/supervisor.pid" 2>/dev/null) || _sup=""
_srv=$(read_pid "$RUNDIR/server.pid" 2>/dev/null) || _srv=""

echo "Agent2API · 模块 ${_mv:-?}"
echo "载荷 ${_pv:-?}"
echo ""

_alive=0
if [ -n "$_sup" ] && pid_is_supervisor "$_sup"; then
  _alive=1
fi

if [ "$_alive" = "0" ]; then
  echo "状态：未运行，正在拉起（最多等 12 秒）……"
  svc_start >/dev/null 2>&1
  _i=0
  while [ "$_i" -lt 12 ]; do
    svc_http_health 2 && break
    _i=$((_i + 1))
    sleep 1
  done
fi

if [ -n "$_srv" ] && pid_is_server "$_srv"; then
  _up=$(proc_uptime "$_srv" 2>/dev/null)
  echo "状态：运行中（server pid=$_srv，已跑 ${_up:-?}s）"
elif [ "$_alive" = "1" ]; then
  echo "状态：守护进程在，服务端正在拉起/重启"
else
  echo "状态：仍未起来，看日志：a2a logs 40 sup"
fi

if svc_http_health 2; then
  echo "健康：通过（PID + socket 归属 + /health 都验过）"
elif port_listen "$_port"; then
  echo "健康：未通过；端口 $_port 有人监听，但不是已验证的本模块服务"
else
  echo "健康：未通过；端口 $_port 未监听"
fi

echo ""
echo "面板：$_url"
if [ "$(cfg_get host 127.0.0.1)" = "0.0.0.0" ]; then
  _ip=$(local_ip 2>/dev/null)
  [ -n "$_ip" ] && echo "局域网：http://$_ip:$_pport/m.html"
fi

# 直接把面板丢给系统浏览器（KSU 卡片的弹窗里点一下就能进，不用手抄地址）
if command -v am >/dev/null 2>&1; then
  am start -a android.intent.action.VIEW -d "$_url" --user 0 >/dev/null 2>&1 || am start -a android.intent.action.VIEW -d "$_url" >/dev/null 2>&1
fi

echo ""
echo "常用命令（su 下）：a2a status|doctor|logs|update|dns"
echo ""

if [ -f "$SUPLOG" ]; then
  echo "--- 守护进程最近 5 行 ---"
  tail -n 5 "$SUPLOG" 2>/dev/null
fi

exit 0
