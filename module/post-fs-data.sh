#!/system/bin/sh
# 开机早期：只准备目录，不启动服务（网络还没就绪）
# 这里任何一步失败都不能阻塞开机，所以全部加 2>/dev/null 且不 exit 非零。
MODDIR=${0%/*}

mkdir -p /data/adb/agent2api/logs 2>/dev/null
mkdir -p /data/adb/agent2api/data 2>/dev/null

if [ ! -f /data/adb/agent2api/env.sh ] && [ -f "$MODDIR/config/default.env" ]; then
  cp -f "$MODDIR/config/default.env" /data/adb/agent2api/env.sh 2>/dev/null
  chmod 0600 /data/adb/agent2api/env.sh 2>/dev/null
fi

# 模块目录可能被某些管理器挂成只读，chmod 失败无害：定制脚本安装时已设好权限
chmod 0755 "$MODDIR/rootfs/opt/agent2api/agent2api-server" 2>/dev/null

exit 0
