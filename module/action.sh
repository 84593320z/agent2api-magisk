#!/system/bin/sh
# Magisk 模块「操作」按钮：重启并回显状态
# v3.1.1：固定 sleep 3 改为就绪轮询（冷启动 3 秒内服务大概率还没监听，
# 老逻辑在慢设备上必然误报"未运行"）；同时显示版本与在线更新入口。
MODDIR=${0%/*}
. "$MODDIR/bin/lib.sh"

load_env
PORT=${AGENT2API_PROXY_PORT:-3065}

stop_all
sleep 1
rm -f "$DATA/disable" "$FATALFILE"
spawn_supervisor

# 就绪等待：最多 60s（冷启动含 chroot 挂载 + 二进制初始化）
_i=0
while [ "$_i" -lt 30 ]; do
  [ -f "$FATALFILE" ] && break
  is_running && health_ok && break
  _sleep 2
  _i=$((_i + 1))
done

echo "Agent2API"
echo "模块：$(grep -E '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)  服务端：$(current_version)"
if is_running; then
  echo "状态：运行中  pid=$(cat "$PIDFILE" 2>/dev/null)"
else
  echo "状态：未运行"
fi
# 失败时把死因直接打在这里。
# v3.1.2 的「操作」按钮只报「未运行」，真正的原因躺在 fatal / module.log 里，
# 用户还得自己 adb 进去翻 —— 一个按钮点了没反应却不说为什么，是最差的体验。
if [ -f "$FATALFILE" ]; then
  echo "原因（$FATALFILE）："
  sed 's/^/  /' "$FATALFILE"
  echo "  → 处理完执行：sh $MODDIR/bin/ctl restart"
elif ! is_running; then
  echo "原因（$MODLOG 末尾）："
  tail -n 8 "$MODLOG" 2>/dev/null | sed 's/^/  /'
  echo "  → 完整日志：sh $MODDIR/bin/ctl log 60"
fi
if supervisor_running; then
  echo "守护：运行中  pid=$(cat "$SUPPID" 2>/dev/null)"
else
  echo "守护：未运行"
fi
if port_owned_by_server; then
  echo "端口：$PORT 已监听（本服务）"
else
  echo "端口：$PORT 未监听"
fi
if health_ok; then
  echo "健康：/health 正常"
elif is_running; then
  echo "健康：/health 暂未通过（仍在启动？）"
fi
echo "面板：http://127.0.0.1:$PORT/"
echo "在线更新：sh $MODDIR/bin/ctl update check"
