# Agent2API magisk.31 独立复审报告
## 结论

上次“19项全部修复”的结论需要更正。按**原缺陷精确定义**：13项已解决、6项部分修复；部分修复为 F-002、F-011、F-012、F-013、F-014、F-018。按**完整事务与运行状态链**，还存在本报告19组残留/新增问题：6高、11中、2低。二者不是相加的漏洞总数，R项包含F项的残留及新的邻接问题。

F-004/F-007/F-017 的旧复现已经修复，但新代次回收、信号重入链仍有缺陷；不能将新问题冒充旧问题未修，也不能用字面修复代表整条链已闭环。
## 范围与基线

- 本轮源码及远程发布保持只读；仅在独立复审目录写报告、探针及沙箱文件。
- HEAD：`0398e1287d748aaf99b98a73f3aa1fec1aa6a687`；模块881文件前后SHA一致。
- 包版本：v3.3.0-beta.7 (magisk.31)，versionCode 2026110331。
- 发布ZIP：[发布包](<E:/AI/tmp/a2a-magisk-repo/dist/agent2api-magisk-v3.3.0-beta.7-arm64.zip>)；17,472,507字节，925项/881文件，CRC通过，每个文件与module一致。SHA256：`cd0fec87510c54447d3c2c78fda53c793e9faec6962207889dc371bf65c3e938`。
- 20个Shell入口 sh -n 全通过。语法正确不代表状态机正确。
- 原包主程序仍为静态musl，无PT_INTERP/DT_DYNAMIC，已含 /data/a2a/resolv 路径；既有ELF LOAD 64KB对齐结论不受本轮脚本问题影响。curl不是glibc动态程序。
## 方法与证据解释

父侧：真实curl+本地HTTP服务、DNS真实函数与定向I/O故障注入、全包哈希/权限/源码语法核对。事务侧：18个隔离观察断言匹配，代表预期缺陷/正向行为被复现，不是18项安全通过。运行侧：真实配置/服务函数、原完整supervisor循环与辅助函数，替换时钟/进程/系统命令；健康探测使用真实回环HTTP及代理。所有系统替换均写在探针中，可审阅复现。

本轮未在Android17真机、Magisk服务环境或真实ARM64进程上执行安装/启停/更新；MSYS sh并非Android BusyBox ash。并发通过确定性交错证明逻辑窗口，不宣称已观察真机双事务损坏。Semgrep/ShellCheck/BusyBox本轮未用于通过性判断；普通源码审查无需REA，不假造SAST零告警。

证据：[parent-evidence.json](<E:/AI/tmp/a2a-rereview-20261103/parent-evidence.json>)；[runtime-evidence.json](<E:/AI/tmp/a2a-rereview-20261103/runtime/runtime-evidence.json>)；[transaction-evidence.json](<E:/AI/tmp/a2a-rereview-20261103/transaction/transaction-evidence.json>)；[transaction-review.md](<E:/AI/tmp/a2a-rereview-20261103/transaction/transaction-review.md>)。
## 原19项逐项判定

| 原编号 | 原缺陷 | 字面旧缺陷状态 | 当前依据/完整链补充 | 位置 |
|---|---|---|---|---|
| F-001 | 后台 $$ 身份 | **已解决** | service 改为独立 sh/boot-start 进程；原父 PID 继承模式消失。开机延迟期间停止竞态另列 R15。 | [service.sh](<E:/AI/tmp/a2a-magisk-repo/module/service.sh>) |
| F-002 | 健康前删除旧载荷 | **部分修复** | 激活后确实保留 old，但 boot 无健康提交、pending 错误处理、跨代提交及失败进程恢复仍未闭环。 | [post-fs-data.sh:61](<E:/AI/tmp/a2a-magisk-repo/module/post-fs-data.sh#L61>) |
| F-003 | 误改 bionic 解释器 | **已解决** | linker/linker64 被拒，glibc 白名单分流；原 APEX linker64 误改路径消失。 | [libexec/plugin.sh:83](<E:/AI/tmp/a2a-magisk-repo/module/libexec/plugin.sh#L83>) |
| F-004 | 僵死 reaping 阻塞 | **已解决** | 死 reaping 能回收且正常释放 owner；新代次盲删是另一个竞态，列 R08。 | [libexec/payload.sh:106](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L106>) |
| F-005 | 启动成功就清失败计数 | **已解决** | 5 秒快崩真实完整循环达到 FAILS=6/GIVEUP=1；70 秒自然死亡的另一处清零列 R17。 | [libexec/supervise.sh:514](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L514>) |
| F-006 | awk 展开字面反斜杠 | **已解决** | ENVIRON 保留字面量 \n，未写入第二键；真实 LF 未拒绝是新输入边界问题 R11。 | [libexec/common.sh:169](<E:/AI/tmp/a2a-magisk-repo/module/libexec/common.sh#L169>) |
| F-007 | 服务函数清除外层 trap | **已解决** | 正常服务调用后外层 TERM trap 保留；实际信号重入的共享变量/锁问题列 R07。 | [libexec/control.sh:151](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L151>) |
| F-008 | beta 版本比较 | **已解决** | 真实函数选择 v4.0.0 > v3、beta.10 > beta.6、正式版 > 同版本 beta；扩展 SemVer 另作优化。 | [libexec/updater.sh](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh>) |
| F-009 | DNS HTTP500 判成功 | **已解决** | 真实 curl22/code500 → liveness1，204 → 0；传输失败仍带200和门户页是 R13。 | [libexec/dns.sh:416](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L416>) |
| F-010 | 只查 IPv6 main 表 | **已解决** | 查 table all default 后回退 main，原非 main 默认路由遗漏已修；真实 Android 策略仍需设备回归。 | [libexec/dns.sh:446](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L446>) |
| F-011 | DNS 非原子/回滚丢选项 | **部分修复** | 原子 rename 与备份成功时整文件恢复已修；备份失败仍改写、最终丢 search/ndots，列 R14。 | [libexec/dns.sh:529](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L529>) |
| F-012 | 健康探测固定 IPv4 | **部分修复** | 显式 ::1 成功；host=:: 仍只试127，在 IPv6-only socket 上失败；代理继承另列 R12。 | [libexec/control.sh:52](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L52>) |
| F-013 | wake lock 释放 | **部分修复** | disabled/paused/GIVEUP 常规分支释放；backoff/port-conflict/首次熔断及恢复重新获取不完整。 | [libexec/supervise.sh:338](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L338>) |
| F-014 | 静态/动态载荷契约 | **部分修复** | validate 静态放宽，但无 lib 时 fix_perms=1，真实 launch 入口 rc78；当前 seed 含 lib，非声称默认包必崩。 | [libexec/launch.sh:27](<E:/AI/tmp/a2a-magisk-repo/module/libexec/launch.sh#L27>) |
| F-015 | 自定义镜像前缀 | **已解决** | 配置镜像前缀被实际使用；与包路径 Windows 单反斜杠替换均需区别，当前打包替换也正确。 | [libexec/updater.sh](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh>) |
| F-016 | 停止前删除 PID 身份 | **已解决** | stop_child 失败保留 pid/start，成功才删除；真实函数沙箱两分支匹配。 | [libexec/supervise.sh:196](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L196>) |
| F-017 | 信号清理后继续事务 | **已解决** | 普通 TERM 子进程 rc1 且无 continuation；临界区恢复失败/锁残留是 R07。 | [libexec/updater.sh:288](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh#L288>) |
| F-018 | zoneinfo rename 中断 | **部分修复** | 常规两 rename 间清理可还原；rename 与状态 flag 之间仍有窗口，保留 old 可开机修复但非即时原子回退。 | [customize.sh:249](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L249>) |
| F-019 | 独立 unzip 命令双拼 | **已解决** | 真实选择片段得到 unzip 而非 unzip unzip，隔离 ZIP 真实解包成功。 | [META-INF/com/google/android/update-binary:71](<E:/AI/tmp/a2a-magisk-repo/module/META-INF/com/google/android/update-binary#L71>) |

## 残留与新问题明细

编号 F-Rxx 专用于本轮，原 F-001..019 保持原义。high主要指恢复完整性与服务可用性，并非均代表可远程利用。每项修法均为建议，本轮未应用。

### F-R01 健康前提交及过早清除旧载荷身份

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/payload.sh:251–258](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L251-L258>), [libexec/updater.sh:235–239](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh#L235-L239>), [post-fs-data.sh:48–61](<E:/AI/tmp/a2a-magisk-repo/module/post-fs-data.sh#L48-L61>)

**复现/机制**：真实 install 返回0，旧目录最初保留，但 updater 精确 old 路径被清空；随后执行 boot recovery→sweep→commit，health_calls=0，old_after_boot_commit=0。

**影响与边界**：下次启动健康失败时，唯一精确回退身份或旧目录已丢失。

**修复方向**：将结构校验与健康提交彻底分开；保留 txn_id/old/current 身份至联合健康通过。post-fs-data 只恢复不提交；首次安装、离线替换和运行中更新分别定义提交策略。

**验收测试**：重启夹在 activate 与健康之间；新版本结构完整但健康失败时 old 必须仍在且能精确恢复。

### F-R02 pending 写入与删除失败被当作事务成功

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/payload.sh:251–284](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L251-L284>), [libexec/common.sh:673–689](<E:/AI/tmp/a2a-magisk-repo/module/libexec/common.sh#L673-L689>)

**复现/机制**：pending 路径被故障注入为目录时 activation_rc=0、active_exists=0，随后 sweep 把 old 删除；另一个用例 rm old 失败却 commit_rc=0 且 pending 消失。

**影响与边界**：成功标志与持久状态脱节，清扫可能删除仍需保留的恢复资源。

**修复方向**：使用同目录临时 marker+rename，逐步检查状态写入、移动和删除结果；未持久化 pending 时恢复 active/old，不报成功；删除失败保留可重试 marker。

**验收测试**：对 marker 写/rename、old rm、磁盘满逐点注入失败；断电重放应保持至少一份已验证载荷。

### F-R03 回滚解锁后读取全局 pending，跨代删除下一事务旧版

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/a2a:330–360](<E:/AI/tmp/a2a-magisk-repo/module/libexec/a2a#L330-L360>), [libexec/payload.sh:269–284](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L269-L284>)

**复现/机制**：确定性交错：A rollback_finish 解锁；B 激活到 v3 并生成 pending；A commit 读取 B 的 marker，b_health_calls=0 却删除 B old/pending。

**影响与边界**：A 能错误提交 B，破坏 B 的健康失败回滚保证。

**修复方向**：健康检查与 commit 同属一把 update 锁；commit 显式接收并核对 txn_id/token/old/current，拒绝别代 marker。

**验收测试**：在解锁点安排第二事务，A 绝不可删除 B 的任何资源。

### F-R04 回滚失败只恢复文件，运行实例及 pending 未一致恢复

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/a2a:319–350](<E:/AI/tmp/a2a-magisk-repo/module/libexec/a2a#L319-L350>), [libexec/updater.sh:422–435](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh#L422-L435>)

**复现/机制**：手动回滚健康失败：磁盘 restored_file_version=v1，running_version=v2，pending_old_exists=0；在线更新失败用例虽运行恢复v1，pending 仍指失败v2。

**影响与边界**：CLI 返回失败后文件、活进程、状态标记三者不一致，后续恢复可能选错目录。

**修复方向**：失败时先按 PID+start 停止本事务实例，再恢复文件并重启原实例、验证健康；以同代状态收敛 pending/active，清理失败目录独立留证。

**验收测试**：手动与在线两链分别测 start失败、health失败、TERM；断言磁盘版本、实际运行身份、pending 指向一致。

### F-R05 静态无 lib 载荷通过校验却无法安装/启动

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-003
- location: [libexec/payload.sh:12–53](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L12-L53>), [libexec/launch.sh:27–31](<E:/AI/tmp/a2a-magisk-repo/module/libexec/launch.sh#L27-L31>), [libexec/launch.sh:148–150](<E:/AI/tmp/a2a-magisk-repo/module/libexec/launch.sh#L148-L150>), [customize.sh:82–85](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L82-L85>)

**复现/机制**：无 lib 静态夹具 STATIC_VALIDATE_RC=0、STATIC_PERMS_RC=1；真实 launch 入口退出78，输出缺少 ld-linux-aarch64.so.1。

**影响与边界**：在线静态载荷及精简布局契约自相矛盾。当前默认 seed 自带 lib，因此不是默认包必然启动失败。

**修复方向**：先解析 ELF PT_INTERP/DT_NEEDED，再选择 loader/权限/库预检；静态主程序与动态插件兼容库分开建模，安装与启动共用分类器。

**验收测试**：静态无lib、静态带插件lib、glibc动态、bionic动态四布局跑安装→激活→launch全链。

### F-R06 stale supervisor 清理覆盖 service 锁 token

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/control.sh:219–240](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L219-L240>)

**复现/机制**：stop_rc=0 但 service_owner_exists=1，同一进程随后 same_process_start_rc=1。嵌套获取 supervisor 锁后才保存 token，导致用错 token 释放 service 锁。

**影响与边界**：同一长事务内部后续启动被自身遗留 owner 阻塞。进程退出后的 stale 回收不等于当前调用正确。

**修复方向**：每把锁使用独立上下文/token；任何嵌套 acquire 之前保存外层身份，release 显式传 expected token。

**验收测试**：stale supervisor→stop→start 在同一 shell 执行，并检查所有 owner 消失。

### F-R07 服务锁临界区 TERM 重入破坏更新恢复和锁身份

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/control.sh:151–165](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L151-L165>), [libexec/control.sh:233–243](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L233-L243>), [libexec/updater.sh:288–303](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh#L288-L303>)

**复现/机制**：普通 TERM 已正确退出且不继续；但 svc_start 持 service 锁时 TERM→upd_on_signal→svc_stop 重入，同进程活动锁拒绝，共享 _svc_outer_* 被覆盖，子进程退出1后 update/service owner 均残留。

**影响与边界**：中断清理未完成文件/服务恢复，还丢失原外层锁身份。原 F007/F017 字面缺陷已修，此项是完整链新增问题。

**修复方向**：信号处理仅记录 abort，受控退出临界区后统一恢复；或使用不可重入的独立事务上下文与单一 cleanup 状态机。锁与 trap 生命周期都由顶层所有者管理。

**验收测试**：对 service acquire/start/stop/release 每个边界发 TERM/HUP/INT，断言无继续提交、恢复一致、token不丢。

### F-R08 死 reaping 快照后盲删同名新活代次

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/payload.sh:106–115](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L106-L115>)

**复现/机制**：原 stale reaper 回收成功；在读旧 token 后发布一个新活 generation，旧回收者仍 rm 同名路径，live_generation_removed=1。

**影响与边界**：并发回收仲裁身份被破坏；本复现证明身份盲删，不扩张为已观察到真机双写。

**修复方向**：回收前验证 inode/token 仍为旧代；用原子 claim/rename 取得回收权，并在同代身份内删除。

**验收测试**：两个 actor 确定性交错：死快照→新ln→旧rm；新 token 必须保留。

### F-R09 恢复时忽略移开坏 current 失败，old 被嵌套进坏目录

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [libexec/common.sh:637–647](<E:/AI/tmp/a2a-magisk-repo/module/libexec/common.sh#L637-L647>)

**复现/机制**：模拟移开 current 失败：recovery_rc=0、current_validate_rc=1、old_top_exists=0、nested_old_exists=1。

**影响与边界**：恢复报告成功但 current 无效，正常 old 路径也丢失。

**修复方向**：每次 mv 检查结果和目标不存在前置条件；失败立即停止并保留 old；恢复结束必须 validate 且不得把目录移动到已有目录内部。

**验收测试**：EACCES/ENOSPC/目标目录存在逐点注入；返回值应失败且旧版仍在精确原位。

### F-R10 zoneinfo flag 窗口及辅助文件非整体回退

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002
- location: [customize.sh:121–134](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L121-L134>), [customize.sh:237–258](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L237-L258>)

**复现/机制**：旧库 rename 后 flag 前中断：live_zone_exists=0，old仍在；新库 rename 后 committed flag 前失败：仍使用new、old留存。curl/证书/CLI 在 payload 提交前先发布也无统一回退。

**影响与边界**：失败安装可能暂缺时区库或留下混合代辅助文件。开机可补旧库的路径不等于当前事务完整回退。

**修复方向**：用持久事务日志和磁盘真实状态恢复，避免只依内存flag；辅助文件同代 staging/rename，全部发布或全部还原。

**验收测试**：在每个 rename 的前后、flag 前后中断；失败后运行目录应回到原版本组合。

### F-R11 真实换行仍能向配置追加第二键

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-003
- location: [libexec/common.sh:145–180](<E:/AI/tmp/a2a-magisk-repo/module/libexec/common.sh#L145-L180>)

**复现/机制**：字面 \n 安全；真实 LF 输入 cfg_set 返回0，gateway_key=abc 后出现 allow_no_key=1，LF_LINES=2；space/hash/CR 也未原样读回。

**影响与边界**：可控值突破单行格式边界。复现是本地 setter 输入，不声称存在未经验证的远程调用入口。

**修复方向**：拒绝键值中的 CR/LF/NUL，或定义可逆引号/转义编码且 getter 同步；布尔、端口、host 逐键校验。

**验收测试**：覆盖真实LF/CR、字面反斜杠、空白、#、引号，断言只能改目标键且读写可逆。

### F-R12 健康检查受继承代理影响，IPv6 通配地址仍误判

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-003
- location: [libexec/control.sh:52–91](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L52-L91>)

**复现/机制**：本地真实HTTP direct_rc=0，http_proxy 指向本地502代理后 proxied_rc=1；host=::1 能通过，host=::只生成127URL，在 v6-only socket 上失败。

**影响与边界**：健康服务可能被误判并触发重启。curl HTTP200也应联合退出状态核对，避免半响应误判。

**修复方向**：本机健康探测使用 --noproxy 并清理相关代理；::/[::] 同时尝试 [::1] 与127；检查curl退出码并严格解析响应。

**验收测试**：IPv4/IPv6-only/双栈 socket + 各代理变量矩阵，外部代理不得捕获本机健康请求。

### F-R13 DNS 验活接受 curl 失败后的200及门户200

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-001
- location: [libexec/dns.sh:416–433](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L416-L433>)

**复现/机制**：真实 Content-Length=100 实发6字节，curl_rc=18/code200，LIVENESS_RC=0；门户HTML200也 liveness0。500已正确拒绝。

**影响与边界**：网络/DNS候选可能在传输失败或门户劫持条件下被接受；不是声称对端200必然恶意。

**修复方向**：先要求curl rc0，再按端点契约校验204或精确预期body；HTTPS验证链与DNS可达性分层记录，不把任意200当验证成功。

**验收测试**：截断200、超时200、门户200、正常204、500五组断言。

### F-R14 DNS 备份失败仍切换，回滚丢原文件选项

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-001
- location: [libexec/dns.sh:529–583](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L529-L583>)

**复现/机制**：正常备份回滚 BYTE_EQUAL_RC=0；只让 resolv.orig.* cp 失败后，ENSURE_RC=1但SEARCH_RETAINED_RC=1，原 search/ndots 丢失。成功路径还留一份PID命名备份。

**影响与边界**：故障路径破坏原解析器配置；成功备份残留是低优先级清理问题，非同PID无限增长。

**修复方向**：已有DNS文件时备份失败立即返回、不改写；恢复按整文件并检查mv；统一finally清理备份及同步active/vpn缓存。

**验收测试**：备份cp失败、恢复mv失败、每个候选失败，最终原文件逐字节一致。

### F-R15 退避/开机等待后未重验停止与门禁，autostart语义混合

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-003
- location: [libexec/supervise.sh:339–379](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L339-L379>), [libexec/supervise.sh:494–514](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L494-L514>), [libexec/boot-start.sh:27–59](<E:/AI/tmp/a2a-magisk-repo/module/libexec/boot-start.sh#L27-L59>)

**复现/机制**：backoff 的 sleep 内关闭autostart/置WiFi门禁/写stop，醒来仍LAUNCH_CHECK；boot延迟期间stop+disable+remove后仍svc_start。autostart=0手动循环不启动，运行中关闭自启后死进程却继续重启。

**影响与边界**：用户刚停止或关门禁后仍可能多拉起一次；开机策略与人工运行意图没有分离。

**修复方向**：所有等待可中断；真正start_child前统一核验stop、disable/remove、门禁和期望运行generation；autostart只控制开机，人工start另建desired_state。

**验收测试**：在每个sleep内改变stop/disable/remove/autostart/门禁，断言后续无启动；区分手动start与开机start。

### F-R16 wake lock 在退避/端口冲突持有，恢复启动又未及时获取

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-003
- location: [libexec/supervise.sh:338–378](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L338-L378>), [libexec/supervise.sh:444–514](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L444-L514>)

**复现/机制**：退避90/120/150s和port-conflict60s WAKE=1；首次熔断30s仍持有，下一轮才放；paused恢复running到探针100s WAKE仍0。

**影响与边界**：既有空转耗电，也有希望keep_awake时恢复后短期未生效；实际sysfs效果取决设备能力。

**修复方向**：由状态转换统一管理：进入非运行态先release；成功启动且配置启用立即take，不依赖每4轮维护。

**验收测试**：running↔paused/backoff/conflict/dead/disabled全转移检查锁，含启用和热关闭。

### F-R17 70秒不健康自然死亡仍清零失败计数

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-003
- location: [libexec/supervise.sh:406–424](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L406-L424>), [libexec/supervise.sh:453–475](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L453-L475>)

**复现/机制**：5秒快崩能6次熔断；70秒不健康自然死亡8轮仍FAILS=0，LAUNCHES=9。死亡分支按60s清零，与健康稳定120s规则不一致。

**影响与边界**：60–119秒失败循环绕过退避/熔断；原启动即清零已修。

**修复方向**：只由连续健康稳定窗口清零；自然异常退出和联合健康失败共同累计，不因存活时间单独判成功。

**验收测试**：5/59/60/70/119/120秒与健康/不健康退出矩阵，稳定健康120秒才允许清零。

### F-R18 seed 版本元数据升级而二进制字节未升级

- severity: low
- status: validated
- confidence: high
- evidence_ids: E-001
- location: [seed/VERSION:1–4](<E:/AI/tmp/a2a-magisk-repo/module/seed/VERSION#L1-L4>)

**复现/机制**：VERSION写3.3.0-beta.7，built仍2026-11-01；server SHA与原beta.6相同：7ed6f986eaa2f289d55a4b1ebbb65d64a1744e1cdba67df324d6ea34ff319845。未执行该ARM64程序 --version。

**影响与边界**：模块包版本与上游服务端版本混淆，影响更新判断及问题追溯；不据此推断二进制内置版本字符串。

**修复方向**：模块与server分别标版本，保留真实构建时间/commit/hash；CI从构建产物生成元数据，禁止手改上游版本冒充重编。

**验收测试**：发布检查metadata与产物manifest，明确本次仅壳修复还是server重建。

### F-R19 boot-start 模块目录推导错误，依赖固定路径兜底

- severity: low
- status: validated
- confidence: high
- evidence_ids: E-003
- location: [libexec/boot-start.sh:14–21](<E:/AI/tmp/a2a-magisk-repo/module/libexec/boot-start.sh#L14-L21>)

**复现/机制**：脚本在libexec下却只取一次dirname，得到libexec，module.prop检查失败后固定回退 /data/adb/modules/agent2api。标准安装路径恰好可用。

**影响与边界**：重定位/非标准测试布局静默退出，降低可测试性；不夸大标准Magisk路径必现失败。

**修复方向**：由脚本目录再上一级推导MODDIR并验证；service通过显式环境传递经验证路径。

**验收测试**：标准/重定位/含空格路径分别测试入口，禁止静默选错模块。

## 完整调用链

### P-001 更新与恢复提交链

- path_type: callflow
- evidence_ids: E-002

安装/在线更新/手动回滚 → update锁 → staging及结构校验 → current移old → 新current激活 → active/pending持久化 → 重启/联合健康 → 同代commit → 释放锁。

当前偏离：payload安装hook提前清身份；boot跳过健康直接commit；手动rollback先释放锁再commit；失败恢复仅文件移动。R01–R04/R07/R09分别对应不同边界，不能靠一条payload_validate代替健康或事务原子性。

### P-002 守护状态与DNS链

- path_type: callflow
- evidence_ids: E-001, E-003

service独立boot helper → 等待boot/net → DNS候选及验活 → svc_start → supervisor期望状态/门禁 → start_child → PID+start/socket/HTTP健康 → 稳定窗口 → 回收/退避/熔断。

所有等待结束及真正启动前应重验同代desired_state；wake按状态转换管理；DNS应先有可恢复快照，curl成功必须同时满足退出码与端点契约。

## 优化与测试工程

1. 用单一持久事务结构记录txn_id、owner pid/start、old/new/current、阶段和健康结果；锁上下文显式传递，避免shell共享全局token/临时变量隐式覆盖。重复source payload重置token目前可复现，但多数真实入口source在加锁前；作为依赖约束优化，未当默认必经漏洞计数。
2. 静态判断不要用“搜不到ld-linux字符串”代替ELF解析；主程序ABI与插件兼容运行库拆分。可选择继续携带glibc插件库，但必须明确是插件依赖，不是静态主程序必需。
3. 版本比较采用完整SemVer标识序列；beta.1 与 beta.1.0等扩展当前不足，原major/beta10问题已解决。
4. DNS成功返回前清理备份，恢复后同步active/vpn缓存；Wi-Fi判定IPv4接口限制作为既有设备适配项，不充作本轮新漏洞。
5. 打包器当前单反斜杠替换正确，权限关键项755正确。补充无扩展名CLI/update-binary的文本规范检查、完整UI/CA/运行库契约manifest及CI可复现构建校验。
6. 原测试预建lib、片段抽取/静态grep只测局部。保留这些单元测试，但新增完整入口、真实文件恢复、同进程嵌套锁、signal临界点与多actor调度测试；每项断言同时检查返回值、磁盘、活进程身份、marker和锁。

## 修复优先级与验收

- P0：R01–R04、R07、R09：先保证旧版、事务代次、信号恢复与文件/运行实例一致。所有故障路径都应保留至少一份已验证载荷。
- P1：R05/R06/R08/R10–R17：统一ABI契约、锁上下文、输入格式、HTTP成功定义及运行状态机。
- P2：R18/R19与测试/打包/版本工程优化。
- 每组修复后回跑旧单测与新故障注入；再在真实Android17/Magisk环境验证冷启动、60–119秒崩溃、IPv6-only/VPN切换、停止时boot/backoff等待、安装各rename处中断，以及进程拒绝退出。

## 复现入口与归档

[parent_verify.py](<E:/AI/tmp/a2a-rereview-20261103/parent_verify.py>)：DNS真实HTTP、I/O失败、ZIP与源码基线。

[runtime_probe.py](<E:/AI/tmp/a2a-rereview-20261103/runtime/runtime_probe.py>)：配置、完整循环、健康回环代理、静态入口。

[verify_transactions.py](<E:/AI/tmp/a2a-rereview-20261103/transaction/verify_transactions.py>)：18个事务观察，包含确定性交错与I/O/信号失败。

复现脚本只在独立沙箱运行；请查看脚本中平台路径和依赖替换，不将其成功退出等同真机通过。

## 原测试为何仍然全绿

本轮再次在独立输出目录运行原 test/fix_verify.py，仍是 **21 passed / 0 failed**（E-005），而上述故障注入仍能复现问题。静态载荷测试预建lib且没有真实launch；快崩只覆盖短周期；zoneinfo只覆盖构造的状态组合；锁和trap未覆盖临界区重入。因此旧测试绿灯是真实的局部结果，推导“19项整链全部修复”才是错误。结果见 [fix_verify.json](<E:/AI/tmp/a2a-rereview-20261103/legacy/fix_verify.json>)。

源码固定清单：[source-manifest.json](<E:/AI/tmp/a2a-rereview-20261103/source-manifest.json>)（E-004）。
