#!/system/bin/sh
# 卸载：停服务、停守护、卸挂载点，保留数据目录（含在线更新层）
MODDIR=${0%/*}
. "$MODDIR/bin/lib.sh"

stop_all
release_supervisor_lock

# 卸载时必须清掉这两个标记：
#   disable      —— 留着它，重装后守护每次开机第一行就退出，服务永远静默不自启；
#   .installed   —— 模块都没了，"已安装"标记继续存在会让 customize.sh 把重装
#                   误判成升级（进而保留 disable、不重发默认配置）。
# 数据（data/、env.sh、update/）照旧保留，用户重装后账号与 Key 都在。
rm -f "$DATA/disable" "$DATA/.installed" "$DATA/fatal" 2>/dev/null

echo "Agent2API 已卸载；数据保留在 $DATA（不需要可手动 rm -rf $DATA）"
