# Agent2API Magisk v3.4.0 独立审查报告

审查日期：2026-11-04。**结论：存在明确缺陷，首要是升级失败和中断恢复的事务一致性，而不是3.4.0版本号或seed架构。**

本次确认 **11项问题：5项高优先、6项中优先**。严重性为项目修复优先级，不等同已证明远程利用；Android掉电/路由和真实数据库行为另列设备验证项。

## 1. 基线与范围

- 目标：[84593320z/agent2api-magisk](https://github.com/84593320z/agent2api-magisk)，tag `v3.4.0-magisk.34`，commit `23b881d93c13dc2081df23dd59da5c3d0d95b7bd`。
- 前版：`v3.3.0-beta.7-magisk.33`，commit `ec251842a090827cbdf2efa796d9f11ac105ce2b`。本次关注的shell目录对前版无差异：**多数是3.4.0仍携带的历史缺陷，未把它们冒充为本版新引入回归。**
- 上游：[aimod-cc/Agent2API v3.4.0](https://github.com/aimod-cc/Agent2API/tree/v3.4.0)，commit `31bc7bdb1083c81b36e9c4642a819d8b17f22875`，仅限API契约、静态UI及启动环境交叉核查，不是完整Rust代码/依赖漏洞审计。
- 关联musl构建仓库commit `1acee85e45aea32d52085ab6b0731fb08e614f73`；工作流优化属于关联项目，不算目标仓库本地CI。
- 模块版本3.4.0，APK是独立的3.1.2-mod、基于3.1.0改造；二者不能混为同一个3.4.0程序。
- [完整范围](<../scope.md>)；[时间线](<../timeline.md>)；[工作项](<../workitems.md>)。
- 产物：本地从固定commit运行打包，未改生产源码。公开Release页面/资源本次HTTP404，API曾HTTP403限额，因此未核对线上ZIP/APK与仓库的逐字节同一性；Git tag可获取，不据HTTP结果推断版本不存在。

## 2. 实际验证结果

| 检查 | 结果 |
|---|---|
| 现有verify_fixes | 37/37通过，见E-007 |
| 现有verify_loop | 8/8通过；仅证明原用例覆盖范围 |
| 全部shell语法 | sh -n通过；语法通过不覆盖状态机正确性 |
| README旧test/run入口 | 失败，见F-010 |
| 本地pack连续两次 | 相同SHA256，936项，执行位与路径检查通过 |
| seed ELF | ELF64 AArch64、无PT_INTERP；静态musl判断成立 |
| DNS路径 | `/data/a2a/resolv` 1处，`/etc/resolv.conf` 0处 |
| seed UI对上游 | 242文件齐全；178文件字节有换行差异，归一换行后0差异 |
| 新增离线复现 | 4类更新故障、4项运行函数、2个前端竞态 |

本地ZIP SHA256：`3dd8b12edef7e4bccaa244ec78e7404ee70db38914f7c32cc0f49d7c562b3386`。
seed二进制SHA256：`0672c6669bb96e0b911e12b90c8f48b357372d02c546a8637025fa865393b655`。
详见[产物证据](<../artifacts/artifact-evidence.json>)。

## 3. 缺陷总表

| ID | 优先级 | 问题 | 确认方式 |
|---|---|---|---|
| F-001 | 高 | 新版健康失败时，仍活着的新版进程参与数据回滚 | 源码 + 离线故障/函数复现 |
| F-002 | 高 | 快速重启时，恢复等待与垃圾清理组合删除事务旧载荷 | 源码 + 离线故障/函数复现 |
| F-003 | 高 | 数据回滚两次rename之间中断后，开机可留下空数据目录 | 源码 + 离线故障/函数复现 |
| F-004 | 高 | 再次刷入时安装器直接删除尚待提交的旧载荷 | 源码 + 离线故障/函数复现 |
| F-005 | 中 | CLI仍无条件要求loader，与静态载荷支持冲突 | 源码 + 离线故障/函数复现 |
| F-006 | 中 | 提交锁失败后，守护健康巡检并未按日志承诺重试 | 源码 + 离线故障/函数复现 |
| F-007 | 中 | VPN切换仅凭旧DNS可达便保留LAN解析器 | 源码 + 离线故障/函数复现 |
| F-008 | 中 | 有效缓存存在而生效DNS文件缺失时，auto分支返回伪成功 | 源码 + 离线故障/函数复现 |
| F-009 | 中 | APK开关页异步乱序覆盖已确认写入 | 源码 + 离线故障/函数复现 |
| F-010 | 中 | README主测试入口仍依赖已删除的旧架构文件 | 源码 + 离线故障/函数复现 |
| F-011 | 高 | 仓库包含可访问的APK签名私钥和公开口令 | 源码 + 私钥条目读取 |

## 4. 详细发现

所有路径及行号均对应固定commit；[独立静态快照](<../artifacts/source-snapshot.md>)和动态日志分别记录，避免仅凭注释或旧报告下结论。

### F-001
- title: 新版健康失败时，仍活着的新版进程参与数据回滚
- severity: high
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-002]
- location: module/libexec/updater.sh:535-541；module/libexec/updater.sh:267-285
- impact: 破坏“快照恢复期间无写者”的一致性前提；真实SQLite/WAL损坏尚未做Android实证，现证据确认错误顺序和可达写入窗口。
- remediation: 失败回滚前先停止supervisor/server及插件，核实全部退出；停服失败保持事务、快照和现场，避免继续覆盖数据。将信号、普通失败、显式回滚统一到同一quiesce入口。

**触发条件：** 更新前在运行；新版启动后健康检查失败，但新版或关联进程仍存活。

**为什么发生：** 失败分支先payload_rollback、payload_data_rollback，到svc_restart才处理进程。更新前的停服保护只覆盖旧进程，未覆盖健康失败后的新进程。

**实测观察：** CASE1显示 DATA_ROLLBACK service_alive=1，且模拟一次按路径写入能在快照换入后改写恢复数据。

**回归验收：** 让新版健康失败且持续写入；断言所有数据rename发生在进程退出之后；停服失败时断言数据目录和快照均未被覆盖。

### F-002
- title: 快速重启时，恢复等待与垃圾清理组合删除事务旧载荷
- severity: high
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-002]
- location: module/libexec/payload.sh:274-298；module/libexec/common.sh:773-779；module/libexec/common.sh:873-886
- impact: 活动payload缺失且事务旧副本被删，标记保留却材料消失。常规流程可能仍有backup/prev；这不是“所有备份永久丢失”的结论。
- remediation: 清理集合同时减去switching、pending及当前恢复日志引用的所有目录。开机无有效写者时按PID+启动时间识别失效事务，避免仅凭120秒年龄跳过。恢复未完成就跳过相关清理。

**触发条件：** 旧payload已rename到payload.new.old.*，新payload尚未换入，pending尚未登记；120秒内进入开机恢复。

**为什么发生：** 恢复看到很新的switching标记便跳过；随后sweep仅保护update.pending记录的旧路径，未保护payload.switching记录的旧路径。

**实测观察：** CASE2 crash_exit=77，old_before=1；恢复与清理后payload_exists=no old_after=0 switching=yes。

**回归验收：** 在两次rename之间注入退出、SIGKILL和重启；分别覆盖0/119/121秒，断言可用payload或其恢复副本始终存在。

### F-003
- title: 数据回滚两次rename之间中断后，开机可留下空数据目录
- severity: high
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-002]
- location: module/libexec/payload.sh:642-667；module/post-fs-data.sh:27-62；module/libexec/common.sh:895-898
- impact: 服务可能以空目录启动，表现为配置/账号/数据库丢失。原快照和upgraded目录仍保留，可人工恢复，不应描述为永久销毁。
- remediation: 数据切换前原子写入含txid、源/目标和阶段的数据恢复日志；启动先恢复日志再ensure_layout；未完成事务引用的restore/upgraded目录都免清理。

**触发条件：** data已移到data.upgraded.*，data.restore.*还未换入时掉电或进程终止。

**为什么发生：** 数据恢复没有独立journal；开机ensure_layout先建空data，后续sweep删除data.restore.*，并未把data-prev或upgraded现场自动恢复到data。

**实测观察：** CASE3 crash_exit=78 data_exists=no；模拟开机后data_files=0 restore_dirs=0 upgraded_dirs=1 snapshot_db=original。

**回归验收：** 对复制、首次rename、第二次rename、提交及日志删除分别故障注入；开机后必须指向一致旧快照或完整当前数据，绝不能仅因mkdir得到空目录便视为成功。

### F-004
- title: 再次刷入时安装器直接删除尚待提交的旧载荷
- severity: high
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-002]
- location: module/customize.sh:132-134；module/libexec/common.sh:873-886
- impact: 安装入口绕开了现有pending保护，破坏回滚事务恢复能力。
- remediation: 取消安装器直接glob清理；改走统一、事务感知的GC，先恢复或明确完成上笔事务，再按引用和状态回收。

**触发条件：** 上次更新留有update.pending，旧版位于payload.new.old.<pid>，用户再次安装模块。

**为什么发生：** customize拿锁后直接rm -rf payload.new.*，匹配pending保留目录；拿到互斥锁并不代表上笔事务已经健康提交。

**实测观察：** CASE4 pending_before=present，pending_after=absent，marker_preserved=yes。

**回归验收：** 带有效pending和旧副本进入customize；安装失败、热装及重复安装后都保留未提交旧版。

### F-005
- title: CLI仍无条件要求loader，与静态载荷支持冲突
- severity: medium
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-003]
- location: module/libexec/a2a:109；module/libexec/a2a:181-187；module/libexec/launch.sh:35-41
- impact: CLI启动被阻断。当前3.4.0 seed仍附带lib/loader，所以不是“默认新装3.4.0全部启动失败”。
- remediation: 只要求SERVER_BIN存在且满足验证；仅动态载荷检查LOADER。CLI、launch、doctor、安装校验使用同一个静态/动态判定函数。

**触发条件：** 使用合法纯静态musl载荷且未带glibc loader，例如更新到不含lib的静态包或精简运行时。

**为什么发生：** launch先判静态性，CLI cmd_ensure_payload却只要LOADER不可执行就报载荷缺失；验证与启动前置条件不一致。

**实测观察：** 隔离函数测试payload_is_static返回码0，cmd_start_rc=1，loader_exists=no，svc_start未被调用。

**回归验收：** 矩阵：static有lib、static无lib、dynamic有loader、dynamic缺loader；前两项均应启动到svc_start。

### F-006
- title: 提交锁失败后，守护健康巡检并未按日志承诺重试
- severity: medium
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-003]
- location: module/libexec/supervise.sh:364-410；module/libexec/supervise.sh:479-549；module/libexec/supervise.sh:646
- impact: 旧载荷和pending长期悬挂；需等后续重启等重新进入启动路径，增加状态不一致及与安装清理冲突概率。
- remediation: 在健康巡检分支按有限频率重试，继续校验pending/磁盘/子进程三方generation并短超时拿锁；仅在成功提交后删除标记。

**触发条件：** 启动健康通过，但payload_commit_old首次因锁竞争等暂时失败；之后子进程持续健康。

**为什么发生：** 唯一supervise_commit_pending调用在start_child成功路径，健康存活循环走continue，从未再次尝试提交。

**实测观察：** 模拟首次提交失败后经过5次健康巡检：healthy_turns=5 commit_calls=1 pending_exists=yes。

**回归验收：** 第一次锁失败，第二次成功，不重启子进程；断言后续巡检确实再次调用并清理当前代次pending。

### F-007
- title: VPN切换仅凭旧DNS可达便保留LAN解析器
- severity: medium
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-003]
- location: module/libexec/dns.sh:684-705；module/libexec/dns.sh:179-183、218-233
- impact: 已确认违反代码宣称的“VPN只取隧道DNS”选择策略；实际查询是否从物理网卡流出取决于VPN路由，须Android抓包验证，未据此宣称已外泄。
- remediation: VPN信任边界变化必须强制重新选源；liveness仅用于相同策略域内优化。缓存绑定networkId、iface和VPN身份；VPN分支隔离ROM/LAN fallback。

**触发条件：** wlan0切到tun0或VPN状态改变，旧LAN DNS仍能通过liveness。

**为什么发生：** 网络变化分支在重选DNS之前先测试旧配置；成功即写新iface/VPN缓存并return。可达性被误当成VPN解析策略符合性。ROM resolv.conf末级兜底也缺少VPN门控（静态附带）。

**实测观察：** 原配置nameserver 192.168.1.1；切tun0后内容未变，却记录recorded_iface=tun0，dns_ensure未触发。

**回归验收：** VPN进入/退出、节点切换、透明VPN无DNS、旧LAN DNS仍可达等矩阵；除文件内容外实机验证路由和抓包。

### F-008
- title: 有效缓存存在而生效DNS文件缺失时，auto分支返回伪成功
- severity: medium
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-003]
- location: module/libexec/dns.sh:282-289
- impact: 需要私有resolv路径的静态服务可能持续解析失败，修复函数却报告成功。
- remediation: 缓存回退必须通过校验后的临时文件+rename发布；只有DNSFILE存在、内容有效并满足策略时才允许无写入返回0。

**触发条件：** DNS_CACHE有合法nameserver，DNSFILE缺失，系统暂时未提供活动DNS。

**为什么发生：** auto检测缓存有效后直接return 0，未把缓存发布到DNSFILE；缓存有效不等于运行文件存在且有效。

**实测观察：** write_rc=0 live_exists=no cache=nameserver 9.9.9.9。

**回归验收：** 缓存有效且live缺失/为空/损坏、缓存损坏、写入失败等测试；成功返回时断言生效文件可读且至少含有效nameserver。

### F-009
- title: APK开关页异步乱序覆盖已确认写入
- severity: medium
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-004]
- location: apk-mod/src/pages/SettingsPage.tsx:449-489；apk-mod/src/pages/SettingsPage.tsx:509；apk-mod/src/api/switches.ts:178-190
- impact: 设置显示与服务端不一致，用户可能据错误状态再次操作。函数级已复现；未取得发布APK核验其内嵌代码与仓库完全一致。
- remediation: 每server/endpoint使用epoch或revision；写入时使旧GET失效，按端点串行化或按字段版本合并。busy使用Set而非单id。后台页面暂停轮询，重显只发一次refresh。缺字段响应应标记未确认，不要用next伪造服务器确认。

**触发条件：** GET先发后到，或者两个不同开关并发PUT并返回同端点全量状态。

**为什么发生：** load直接setState(next)且无版本号；PUT合并全量saved；busyId只记录最后一个id，任一finally即可清空。

**实测观察：** 摘取原load/toggle函数体并控制Promise顺序：GET覆盖后display=false/server=true；两个PUT乱序后display.b=false/server.b=true。

**回归验收：** GET/PUT乱序、两个PUT同端点、一个失败另一个成功、卸载/切服务器后响应、切后台；断言最终显示等于最新服务器状态。

### F-010
- title: README主测试入口仍依赖已删除的旧架构文件
- severity: medium
- category: design
- status: validated
- confidence: high
- evidence_ids: [E-001, E-006]
- location: test/run.sh:26、38；README.md:187；test/verify_fixes.py:22-24；test/verify_loop.py:17-18
- impact: 公开测试步骤失败；贡献者难以建立可信回归。现有用例覆盖不到本报告的更新中断窗口。
- remediation: 把主入口迁移到当前分库，统一一个跨平台入口并自动发现sh，A2A_SH仅作覆盖；测试前fixture失败必须立即失败；将本次故障用例纳入CI。

**触发条件：** 按README执行离线test/run.sh。

**为什么发生：** 脚本仍复制并source module/bin/lib.sh，但3.4.0已改为libexec分库；现有Python测试还默认作者个人MSYS路径。

**实测观察：** sh test/run.sh退出1，cp cannot stat module/bin/lib.sh。37项新测试和8项循环测试另行通过，不等同此入口可用。

**回归验收：** 干净Linux和Windows/MSYS clone按文档单命令测试；所有fixture创建/退出码均验证；禁止旧脚本静默跳过。

### F-011
- title: 仓库包含可访问的APK签名私钥和公开口令
- severity: high
- category: misconfig
- status: validated
- confidence: high
- evidence_ids: [E-001, E-005]
- location: README.md:107；apk-mod/a2a-mod.jks
- impact: 持有者可使用同一公开私钥签署其他APK。公开条目本身已确认；本次发布APK下载失败，未核定它与发布APK证书是否相同。若明确只用于可复现开发包，应与正式分发签名彻底分离。
- remediation: 将此公开密钥视为开发身份；新正式发布采用独立私密密钥及CI秘密存储。核对现有发布APK证书后制定签名轮换/迁移方案；删除当前文件并不能撤回已公开私钥。

**触发条件：** 该密钥被用于正式分发APK签名时，依赖此身份的更新信任即受影响。

**为什么发生：** 仓库直接跟踪密钥库并在README公布口令；keytool成功读取PrivateKeyEntry，证明不是仅含公钥证书。

**实测观察：** alias a2a，PrivateKeyEntry，SHA256 B1:8B:0E:B2:07:83:29:A9:96:33:22:E8:7F:47:66:99:43:65:5D:B8:57:AA:06:C0:76:DD:86:83:65:C0:BF:15。

**回归验收：** 对正式APK执行apksigner verify --print-certs；CI扫描拒绝跟踪正式keystore；发布构建只从秘密存储注入签名材料。

## 5. 调用路径与证据链

### P-001
- title: 新版健康失败到不静默的数据恢复
- path_type: callflow
- start: upd_do_update
- goal: 解释F-001的写者窗口
- steps:
  1. 旧服务停止并制作数据快照，属于正确保护；evidence: E-001 E-002；finding: none。
  2. 新版启动且保持运行，健康检查返回失败；evidence: E-002；finding: F-001。
  3. 未停新版便执行payload/data回滚；evidence: E-001 E-002；finding: F-001。
  4. 快照换入期间模拟按路径写入成功，之后才svc_restart；evidence: E-002；finding: F-001。
- residual_risks: SQLite具体损坏形态未做Android验证；本路径证明顺序违约，不宣称已损坏真实数据库。

### P-002
- title: payload切换中断到清理破坏恢复材料
- path_type: callflow
- start: payload_install_from第一次rename之后
- goal: 解释F-002与F-004的共同事务引用缺口
- steps:
  1. switching已写、旧目录移开，但pending尚未建立；evidence: E-001 E-002；finding: F-002。
  2. 快速恢复被120秒年龄条件跳过；evidence: E-001 E-002；finding: F-002。
  3. GC只保护pending，删除switching所引用旧目录；evidence: E-001 E-002；finding: F-002。
  4. 即使存在pending，customize直接glob仍会删除旧目录；evidence: E-001 E-002；finding: F-004。
- residual_risks: backup/prev可能仍可用于后续恢复；应同时保留事务原始旧副本和可验证备份。

## 6. 项目本身的优化建议

### 6.1 第一优先：一个状态机，多入口共用

把安装、更新、回滚、开机恢复、GC统一为明确阶段：`prepared -> quiesced -> snapshotted -> payload-switched -> started -> verified -> committed`；失败分支显式进入`quiescing-for-rollback -> restoring -> recovered`。

每个journal含txid、PID及进程启动时间、generation、源/目标目录及阶段；写journal用临时文件+rename，重要目录切换补齐适当sync/fsync策略。GC只回收“不被任何活跃/未恢复journal引用”的目录。恢复应幂等，重入100次仍保留至少一份有效payload和数据。短超时互斥锁解决并发，journal解决掉电，两者职责不同。

### 6.2 测试从“函数正常返回”升级到不变量验证

恢复主测试入口；把本报告复现加入CI。依次在每次mv/cp/journal写入之前之后注入失败、空间不足、TERM、KILL；验证进程静默、可用载荷存在、数据非空且代次一致、未提交副本免清理。

Python测试默认作者个人DSH路径应改为显式A2A_SH覆盖优先，再shutil.which自动发现。fixture构建必须检查returncode；并发锁、健康失败和pending重试应测真实函数组合，而不只测调用计数桩。至少加入Linux dash与Android实际shell矩阵。

### 6.3 DNS可达性与网络策略分离

DNS来源附networkId/iface/VPN身份与时间，跨策略边界强制重选，不以“还能解析”代替策略判定。缓存是恢复来源而非成功凭据。IPv4/IPv6、NAT64、透明VPN及系统重建live目录都应有验收用例。

### 6.4 APK异步层收口与构建可复现

请求统一带serverIdentity和epoch；页面卸载、服务器切换、write开始时失效旧read。请求去重/端点串行化与字段级busy由数据层负责。7端点每5秒约84请求/分钟，隐藏页面也继续定时；应隐藏暂停、可见刷新并退避失败，不凭“通常很快”推断耗电忽略。

[重打包脚本](<../../../apk-mod/repack.py>)第17–19行是作者绝对路径；应改`--original-apk --web-dir --out`，固定原APK哈希、上游commit、Node/包管理器版本和lockfile。仓库只带局部TSX及patch，缺一键恢复完整构建树的流程。正式签名与公开开发签名分离。

### 6.5 关联musl工作流加固（工程建议，不作为现版故障）

关联工作流第85–110行使用tag checkout、Rust stable、未固定cargo-zigbuild，实际编译未带`--locked`。建议固定上游commit、Rust工具链、cargo-zigbuild版本、Actions SHA，编译加`--locked`，写权限缩到发布job，产出SBOM和构建来源证明。checksum只能证明取得的字节一致，不是独立签名认证。

第135–149行解析器路径替换出现0次也成功，应该断言旧路径被替换或新路径已存在，并在目标架构实跑解析自检。当前3.4.0 seed检查符合预期，未据此报“现版DNS路径坏”。第161–165行仅复制UI；应验证它是可服务产物并记录版本，而非将“没跑npm”直接判成现版UI错误。

### 6.6 配置及发布契约

[启动器](<../../../module/libexec/launch.sh>)第94–97行只在非空时export，可继承外部同名环境；建议配置为空时显式unset，保持配置是唯一事实源。该项为静态优化，未纳入11项动态确认缺陷。

模块3.4.0与APK3.1.2-mod分别标兼容矩阵、上游commit、已测Android/内核/Magisk版本。Release附SHA256、签名证书指纹、回归摘要及来源；本次404只是访问观测，需要维护者核对公开可下载性。

## 7. 建议修复顺序与验收门槛

1. **P0：F-001–F-004。** 先修静默回滚、恢复journal和事务感知GC；四项故障注入都通过后再做自动升级发布。
2. **P0签名链：F-011。** 核对发布APK证书，确定开发/正式身份边界，完成正式密钥管理与迁移。
3. **P1：F-005–F-008。** 统一静态载荷校验、健康巡检提交重试、DNS策略及文件重建；函数矩阵加真机网络矩阵。
4. **P1：F-009–F-010。** 消除UI乱序，恢复跨平台测试入口，并固定构建来源。
5. **P2：工程改进。** 去个人绝对路径、停止后台轮询、环境清理、CI/SBOM/来源证明、补兼容文档。

最终验收必须包括Android真机的强制重启、真实进程退出核查、SQLite完整性检查和VPN路由抓包；这些是尚待验证的影响边界，不影响本报告源码与离线复现结论。

## 8. 排除项与覆盖边界

- 没有把UI换行差异、pack脚本转义显示、现有版本号报成bug；实际打包与归一文本对比已排除。
- 未把“直接调用底层回滚API可恢复陈旧快照”列为漏洞：生产有UPD_DATA_SNAP门控，缺少可达路径；更新日志末尾明确标NEGATIVE CONTROL。
- 子代理遗留的继承env、ROM DNS fallback部分fixture存在命令/PATH错误，未作为动态证据；主代理只重跑干净四项runtime脚本。
- 未基于CORS星号直接断言鉴权绕过，也未把上游当前client已有的serverIdentity防护报成缺失。
- 本次未完成Rust全量构建、SCA漏洞库扫描、发布APK签名同一性检查；不输出虚构CVE、后门或整仓安全背书。

## 9. 复现及证据索引

运行目录为`E:/AI/tmp/agent2api-audit-20261104`。使用Python3.12、MSYS Bash5.3、Node24及JDK keytool。更新脚本真实使用临时文件系统操作，Android服务/进程调用使用桩；UI脚本摘原函数体并控制Promise顺序。独立源码观察E-001与运行输出分开固定。

```bash
# 原测试与产物
(cd repo && python pack.py && python test/verify_fixes.py && python test/verify_loop.py)
(cd repo && sh test/run.sh)   # 当前预期失败，F-010
python inspect_artifacts.py
# 新增离线复现
bash agent-update/repro.sh
bash agent-runtime/static-cli.sh
bash agent-runtime/dns-vpn-retain-lan.sh
bash agent-runtime/dns-missing-live-cache.sh
bash agent-runtime/pending-no-retry.sh
python replay_ui.py
```

[复现脚本副本](<../repro/README.md>)记录移机方法及fixture限制；运行会重建审计临时case目录，不操作Android/data。脚本副本是此次审计环境的回放材料，不冒充项目已提交的通用测试套件。

| Evidence | 内容 |
|---|---|
| [E-001](<../evidence/E-001.md>) | 静态源码快照，含精确行号 |
| [E-002](<../evidence/E-002.md>) | 四类升级/回滚故障 |
| [E-003](<../evidence/E-003.md>) | CLI、pending、DNS函数复现 |
| [E-004](<../evidence/E-004.md>) | 原前端函数体的两个竞态 |
| [E-005](<../evidence/E-005.md>) | 签名私钥条目观测 |
| [E-006](<../evidence/E-006.md>) | 旧测试入口失败 |
| [E-007](<../evidence/E-007.md>) | 37项现有测试通过 |
| [E-008](<../evidence/E-008.md>) | ZIP/ELF/UI结构核对 |

交付包含[SHA256清单](<../SHA256SUMS.txt>)，每条Evidence另固定其原始artifact哈希。审计仅新增文档及证据，未修补生产代码。
