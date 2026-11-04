# overlay/ —— 用户自备的"脚本层覆盖包"安装器（只作参考，不进模块包）

这里的 `customize.sh` 来自用户 2026-11-04 提交的
`agent2api-v3.3.0-beta.7-magisk.32-localfix-20261104.zip`，**原样保留**，目的是让这份
"覆盖安装"的思路有据可查，而不是被悄悄丢掉。

## 它做什么

- 包内**只有脚本与文档**：`*.sh`、`libexec/*`、`webroot/index.html`、`module.prop`、`docs/*`。
  没有 `seed/`（服务端载荷）、没有 `tools/`（curl、CA）、没有 `zoneinfo/`、没有 `META-INF/`。
- 安装时的动作只有三步：包完整性预检 → 权限恢复 → 把包内文件原子复制进**已安装**的
  `/data/adb/modules/agent2api`，全部复制成功后调用 live 目录里的 `hotinstall.sh` 触发后台热应用。
- 下载、停服、启动、等健康它一概不做，交给 `hotinstall.sh` 的后台链路；任何一步失败只提示、
  不改退出码（管理器照常判定"安装完成"，重启后仍可生效）。
- 全新安装装不上：本包不含载荷，必须先刷完整模块包。

## 为什么不把它当作模块的 `customize.sh`

仓库的 `module/customize.sh` 是**完整安装器**，除了复制文件还负责：

- 播种 `seed/` 载荷（`payload_install_from`）、`tools/` 与 `zoneinfo/`；
- 静态/动态载荷分叉（`payload_seed_is_static`）与执行位恢复；
- zoneinfo 切换与失败整体回退（R10）；
- 安装期必备文件清单校验、旧版本清理、`a2a` 命令入口落地。

用覆盖版替换它，模块就装不出可用状态——所以两者职责不同，不能互换：覆盖包是**已装模块的补丁**，
`module/customize.sh` 是**从零安装**。融合时采用的是"取其脚本、弃其安装器"：
`libexec/*`、顶层脚本、`webroot/index.html` 的内容已全部合进 `module/`，
只有这份 `customize.sh` 留在 `overlay/` 作为参考。

## 只想推脚本、不想重打包时

按覆盖包原来的用法即可：把要更新的文件按同样结构打成一个 zip，让它的 `customize.sh` 负责复制，
或者直接把文件推到手机上再执行 `hotinstall.sh`。日常升级仍建议走完整模块包（`pack.py` 产物），
由安装器统一处理载荷与 zoneinfo。
