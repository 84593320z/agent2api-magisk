# Agent2API magisk.31 · 19 组问题修复报告

> 本报告在仓库里另存一份，正文路径引用的是本轮分析现场 `E:/AI/tmp/a2a-rereview-20261103/`；
> 与仓库直接对应的两份产物是 `docs/2026-11-03_Agent2API-magisk32-19组修复.patch`（完整 diff）
> 与 `docs/verify-fixes-summary-2026-11-03.json`、`docs/loop-summary-2026-11-03.json`（复验原始输出）。
> 复验脚本在 `test/verify_fixes.py`、`test/verify_loop.py`，可直接复跑。

## 结论

按独立复审报告 [artifacts/baseline-rereview-report.md](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/baseline-rereview-report.md>) 的 19 组问题（R01–R19）与 6 项部分修复（F-002/011/012/013/014/018）逐条改动源码，**13 个文件、361 行新增、78 行删除**，未做任何"顺手重构"或绕过式修补。

- 逐条落盘：19 组全部有对应改动，改动点用 `R01`…`R19` 注释就地标注，便于逐条核对（`cd module && grep -rn 'R[0-9][0-9]' --include='*.sh' --include='a2a' --include='VERSION' .` 得 37 处命中，覆盖全部 19 个编号）。
- 复验：函数级隔离复验 **32/32 通过**，主循环集成复验 **8/8 通过**；20 个 Shell 入口 `sh -n` 全通过。
- 边界：复验在 Windows + MSYS `sh` 沙箱内完成，未在 Android 17 真机、Magisk 服务环境或真实 aarch64 进程上跑过安装/启停/更新；MSYS `sh` 不等于 Android BusyBox `ash`。本报告不声称真机通过。

本报告里 Finding 的 `status: validated` 表示**缺陷已在隔离环境中复现确认、且已修复**；是否在真机闭环见各条"边界"。

## 范围与基线

- 源码根：`E:/AI/tmp/a2a-magisk-repo/module`，HEAD `0398e1287d748aaf99b98a73f3aa1fec1aa6a687`。
- 包版本：`v3.3.0-beta.7 (magisk.31)`，versionCode `2026110331`；内置 musl 静态载荷二进制自报 `3.3.0-beta.6`。
- 改动文件（13）：`customize.sh`、`post-fs-data.sh`、`module.prop`、`seed/VERSION`、`libexec/{a2a,boot-start.sh,common.sh,control.sh,dns.sh,launch.sh,payload.sh,supervise.sh,updater.sh}`。
- 哈希与 diff：[fix-manifest.json](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/fix-manifest.json>)、[fix.patch](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/fix.patch>)。
- 未改：`dist/` 发布包、远端仓库、tag、Release。Git 工作区仅本 13 个文件为已修改，另有一份未跟踪的复审报告副本。

## 方法与证据解释

三层验证，全部可复跑：

1. **函数级隔离复验**（`E:/AI/tmp/a2a-rereview-20261103/verify_fixes/verify_fixes.py`）：从源码**原样切片**函数体进用例，只替换操作系统边界（`/proc`、`settings.conf`、`curl` 目标、时钟）。健康检查与 DNS 验活用**真实 curl** 打**真实回环 HTTP 服务**（含 `::1`），并额外把 `http_proxy` 指到返回 502 的端口验证不依赖代理。
2. **主循环集成复验**（`E:/AI/tmp/a2a-rereview-20261103/verify_loop/verify_loop.py`）：把 `supervise.sh` 的 `while` 主循环与启动准备段整段切片运行，用虚拟时钟（`sleep` 累加）驱动 8 种故障场景，断言最终 `FAILS`/`GIVEUP`/`LAUNCHES` 与 wake lock 状态。
3. **静态收口**：20 个入口 `sh -n`、改动文件哈希、`git status` 快照。

不做的判断：不以 Semgrep/ShellCheck 的零告警代表通过（本机 Semgrep 启动即因证书失败、ShellCheck 缺失，本轮未用于通过性判定）。

## 逐条修复明细

### F-R01 健康前提交与过早清除旧载荷身份

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/payload.sh:296–307](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L296-L307>), [libexec/updater.sh:236–247](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh#L236-L247>), [libexec/supervise.sh:544–556](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L544-L556>), [post-fs-data.sh:60–66](<E:/AI/tmp/a2a-magisk-repo/module/post-fs-data.sh#L60-L66>)

**根因**：`payload_activate_staged` 在切换完成后立刻调 hook `upd_payload_commit`，该 hook 清空 `UPD_ACTIVATE_BEFORE/AFTER`；而真正的删除点 `payload_commit_old` 在 `post-fs-data.sh` 无任何健康证据时就被调用。两者叠加：新载荷还没跑过一次，唯一能回滚的旧目录就被删了。

**修复**：hook 拆成两段语义——`upd_payload_commit` 只置 `UPD_INSTALLED=1`（承认"新载荷已就位"），新增 `upd_payload_committed` 才清事务身份并置 `UPD_COMMITTED=1`；`post-fs-data.sh` 不再提交，只记录 pending 待处理；提交点移到 `supervise.sh` 首次 `start_child` 成功（进程 / 端口 / HTTP 三项联合健康 + `write_state running`）之后。

**验证**：`r01_updater_commit_keeps_identity {installed:1, identity_kept:1, identity_cleared:1, committed_flag:1}`；`r01_post_fs_data_keeps_pending {pending_kept:1, old_kept:1}`；`r01_supervisor_commits_after_health {launches:1, pending_gone:1, old_payload_gone:1, live_version:v2.0.0}`。

**边界**：真机上"首次健康通过"的判定依赖服务端真实回 200/`status` 字段，本环境用夹具模拟。

### F-R02 pending 写入与删除失败被当作事务成功

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/payload.sh:297–307](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L297-L307>), [libexec/payload.sh:343–349](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L343-L349>)

**根因**：pending 用 `printf … >"$RUNDIR/update.pending" 2>/dev/null` 写、不看返回码，marker 被外来者建成目录时静默失败，函数仍 `return 0`；提交阶段 `rm -rf "$_pco_path"` 与 `rm -f marker` 同样不看结果，删不掉也报成功，随后 marker 消失，这笔旧载荷彻底失记。

**修复**：pending 改成"先写 `.tmp.$$` 再 `mv -f`"，任一步失败就清 tmp、清 active、打印明确中文错误并 `return 1`；删除段改成 `if ! rm -rf … || [ -e "$_pco_path" ]; then log + return 1`，marker 删除失败同样 `return 1`，让 pending 保留以便下一轮重试。

**验证**：`r02_pending_write_failure_aborts {activation_rc:1, active_cleared:1}`；`r02_commit_delete_failure_reports_error {commit_rc:1, old_kept:1, pending_kept:1}`。

### F-R03 回滚解锁后读取全局 pending，跨代删除下一事务旧版

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/a2a:357–374](<E:/AI/tmp/a2a-magisk-repo/module/libexec/a2a#L357-L374>), [libexec/payload.sh:318–334](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L318-L334>), [libexec/updater.sh:461–468](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh#L461-L468>)

**根因**：`cmd_rollback` 在 `rollback_finish 0` 里释放 update 锁之后才调 `payload_commit_old`，而该函数裸读全局 `update.pending`——若此时另一笔事务刚写入自己的标记，删掉的就是别人的旧载荷。

**修复**：`payload_commit_old` 增加可选参数 `$1="tag pid"`，与 pending 首行前两字段比对，不符则一个字节都不动并记日志；三个调用点都带标记：更新成功 `"new $$"`、回滚收敛 `"rollback $$"`、守护提交用 pending 里读出的 `_sup_tag`。`cmd_rollback` 改为**趁锁内**取 `_rb_tag`，释放后重取锁 30 秒，拿到锁再按标记提交，拿不到就留给下次启动。

**验证**：`r03_commit_rejects_foreign_generation {foreign_rc:1, foreign_kept:1, foreign_pending_kept:1, match_rc:0, old_deleted:1, pending_cleared:1}`。

### F-R04 回滚失败只恢复文件，运行实例及 pending 未一致恢复

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/updater.sh:432–458](<E:/AI/tmp/a2a-magisk-repo/module/libexec/updater.sh#L432-L458>)

**根因**：在线更新健康失败走回滚，恢复了文件、重启了服务，但 `update.pending` 仍指着刚才失败的那一版；下一轮开机由守护拿着这份旧标记去提交，删的是别的代次目录。

**修复**：回滚后引入 `_upd_rb_ok` 明确表达"旧版是否真的恢复可用"：旧版健康通过且当前载荷 `payload_validate` 通过，就 `payload_commit_old "rollback $$"` 把失败版本提交掉并 `upd_payload_committed`；否则打印"旧版尚未确认健康，保留事务现场"并保留 pending 与旧目录。

**验证**：`r04_rollback_converges_pending {before_version:v2.0.0, after_version:v1.0.0, pending_gone:1, committed:1}`。

### F-R05 静态无 lib 载荷通过校验却无法安装/启动

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/payload.sh:44–58](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L44-L58>), [libexec/launch.sh:27–41](<E:/AI/tmp/a2a-magisk-repo/module/libexec/launch.sh#L27-L41>), [customize.sh:78–108](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L78-L108>), [customize.sh:191–205](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L191-L205>), [customize.sh:230–262](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L230-L262>)

**根因**：`payload_validate` 已经为静态载荷放宽，但下游五处仍按"必有 lib/"假设硬失败：`payload_fix_perms` 直接 `chmod "$_d/lib"`；`launch.sh` 在判定静态之前就 `[ ! -x "$LOADER" ] && exit 78`；`customize.sh` 的 seed 清单、无 seed 分支、`install_payload_perms`、链接器自检、`_patch_bad` 各有一条。结果是同一个包"校验通过、安装/启动必挂"。

**修复**：五处全部按实际布局分叉——`if [ -d "$_d/lib" ]` 才处理运行时；`launch.sh` 先判 `payload_is_static` 再决定是否要求 loader；`customize.sh` 新增安装期静态粗判 `payload_seed_is_static()`（读 `agent2api-server` 里有无 `ld-linux` 字串，安装期没有 readelf），seed 清单只强制 `VERSION/agent2api-server/ui/index.html`，`_patch_bad` 对不存在的 `libc.so.6` 直接 `continue`，链接器自检整段跳过并记 `static（无动态链接器）`。

**验证**：`r05_static_payload_functions {static_validate:0, static_perms:0, static_smoke:0, broken_validate:1}`；`r05_static_launch_skips_loader {launch_reached:1}`；`r05_customize_static_detection {static_hit:0, dyn_hit:1}`。

**边界**：`payload_seed_is_static` 是字串粗判，动态载荷里若恰好含 `ld-linux` 字串会被判成动态（偏保守，只会多要一次运行时检查，不会误放行）。

### F-R06 stale supervisor 清理覆盖 service 锁 token

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/control.sh:233–253](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L233-L253>)

**根因**：`svc_stop_impl` 清理实例锁时，是 `update_lock_acquire "$RUNDIR/lock"` **之后**才把 `UPDATE_LOCK_TOKEN/PATH` 存进 `_stop_held_*`，存进去的已是内层 token；恢复后外层 `service.lock.d` 的 owner 再也匹配不上，`svc_stop` 报成功却留下 service owner，下次安装直接"另一个事务正在运行"。

**修复**：先存 `_stop_outer_token/_stop_outer_path`，再用新增的 `update_lock_is_self` 判定"这把实例锁是不是本进程的"：是则不动，否才 acquire → 删 owner → 清空 → `rmdir`，末位无条件恢复外层身份。

**验证**：`r06_stop_cleans_dead_owner {outer:1, stop_rc:0, instance_lock_gone:1, outer_token_ok:1, service_owner_intact:1}`；`r06b_stop_timeout_keeps_state {stop_rc:1, pid_kept:1, stop_marker:1}`。

### F-R07 服务锁临界区 TERM 重入破坏更新恢复与锁身份

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/control.sh:161–184](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L161-L184>), [libexec/control.sh:258–272](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L258-L272>), [libexec/payload.sh:153–180](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L153-L180>)

**根因**：`svc_start`/`svc_stop` 在临界区内收到 TERM，handler 会重入并再调一次同函数；此时本进程已持锁，`update_lock_acquire` 必然失败 → 直接 `return 1` 让外层半途退出；即便不退出，内层 `update_lock_release` 又会读一个被覆盖的全局 token，把外层身份一起冲掉。

**修复**：新增 `update_lock_is_self()`（按 owner 里的 pid + `/proc` 启动代次判定），`svc_start`/`svc_stop` 遇到"自己已持有"就按 `_svc_owned=1` 走完不重复取放；`update_lock_release` 不再依赖全局 token 判"是不是我"，改按 pid + 启动代次比对，token 只用于"同 pid 内是否已换代"的二次确认。

**验证**：`r07_reentrant_start_keeps_lock {acq:1, reentrant_rc:0, token_kept:1, owner_kept:1, owner_freed:1}`。

### F-R08 死 reaping 快照后盲删同名新活代次

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/payload.sh:118–131](<E:/AI/tmp/a2a-magisk-repo/module/libexec/payload.sh#L118-L131>)

**根因**：回收僵死 reaping 的流程是"读内容 → 判死 → `rm -f reaping`"，中间没有任何再确认；若在这段窗口里旧 marker 被过期删除、新一代回收者刚建好同名文件，盲删就会删掉活着的回收权。

**修复**：删之前重新读一次 `reaping` 内容，与刚才读到的 token 逐字比对，不一致或为空就清自己的 claim 并 `continue` 重试，一致才确认回收。

**验证**：`r08_reaper_generation_guard {acquire_rc:1, live_owner_kept:1, live_token:livetoken}`（活代次被保留，竞争者按预期退出）。

### F-R09 恢复时忽略"移开坏 current"失败，old 被嵌套进坏目录

- severity: high
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/common.sh:652–677](<E:/AI/tmp/a2a-magisk-repo/module/libexec/common.sh#L652-L677>)

**根因**：`payload_recover_interrupted` 用 `[ -e "$PAYLOAD" ] && mv … 2>/dev/null` 移开坏载荷，mv 失败也继续往下 `mv "$_old" "$PAYLOAD"`；目标已存在时 mv 会把 old 塞进坏目录内部，于是 current 仍然坏、唯一回滚副本被毁，函数还 `return 0` 报成功。

**修复**：移开失败就 `log + continue`，换上去之后追加 `payload_validate "$PAYLOAD"` 复核；复核不过则把刚移开的目录放回原位并记"恢复中断载荷失败"，不再假报成功。

**验证**：`r09_recovery_no_nesting {recovery_rc:0, old_intact:1, no_nest:1}`。

### F-R10 zoneinfo flag 窗口与辅助文件非整体回退

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [customize.sh:141–153](<E:/AI/tmp/a2a-magisk-repo/module/customize.sh#L141-L153>)

**根因**：`install_cleanup` 只在 `_ZONE_COMMITTED=1` 时删现目录、只在现目录不存在时才 mv 回旧目录；进程恰好死在"新目录已发布、flag 还没置"的窗口里时，两边都不动，留下新旧混用，`VERSION`/`tzdata.zi` 这些辅助文件跟着半新半旧。

**修复**：失败即整体回退——先 `rm -rf` 现 `zoneinfo`（可能是换了一半的新目录），再无条件 `mv` 旧目录回来，不再看 flag。

**验证**：`r10_zoneinfo_rollback_without_flag {zone_version:old, aux_restored:old-tz, old_dir_gone:1}`，且用例专门在 flag 未置位的中断点断言。

### F-R11 真实换行仍能向配置追加第二键

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/common.sh:161–190](<E:/AI/tmp/a2a-magisk-repo/module/libexec/common.sh#L161-L190>)

**根因**：`cfg_set` 改用 `ENVIRON` 传值后挡住了 `\n` 字面量被 awk 展开，但**真实换行/回车**仍会原样写进文件，一行变两行；另外含空格或 `#` 的值不加引号会被 `cfg_get` 当行尾注释截断，读回来与写进去不一致。

**修复**：入口先 `case "$2" in *[[:cntrl:]]*` 拒绝任何控制字符并给出中文提示；再按内容自动加引号——含单引号且含双引号直接拒绝，含双引号包单引号，含空格或 `#` 包双引号，`cfg_get` 原样返回。

**验证**：`r11_cfg_set_roundtrip {lf_rc:1, cr_rc:1, plain_rc:0, space_val:"has space", hash_val:"has # hash", quote_val:"it's", injected_absent:ABSENT, dedup:1, last_wins:v3}`。

### F-R12 健康检查受继承代理影响，IPv6 通配地址仍误判

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/control.sh:52–75](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L52-L75>), [libexec/control.sh:86–99](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L86-L99>)

**根因**：`host=::`/`[::]` 与 `0.0.0.0` 同归一支，只试 `127.0.0.1`；Android 上服务端常只监听 `[::]:port`，v6-only 环境下一个健康实例每 30 秒被判死一次并重启。另外回环健康请求走 `http_proxy`，代理回 502 就会判死。

**修复**：`''` 单列只试 v4 回环；`0.0.0.0|*|::|[::]` 改成先 `http://[::1]:port/health` 再 `http://127.0.0.1:port/health`；健康请求统一加 `--noproxy '*'`。

**验证**：`r12_health_ipv6_wildcard {explicit:0, wildcard:0, bracket_wildcard:0, urls:"http://[::1]:1914/health http://127.0.0.1:1914/health "}`；`r12_health_proxy_independent {direct:0, proxied:0, proxied_upper:0}`（`http_proxy`/`HTTP_PROXY` 指向 502 端口仍判健康）。

### F-R13 DNS 验活接受 curl 失败后的 200 与门户页 200

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/dns.sh:421–440](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L421-L440>), [libexec/control.sh:89–96](<E:/AI/tmp/a2a-magisk-repo/module/libexec/control.sh#L89-L96>)

**根因**：`_dl_code=$(curl …)` 只保留 `-w '%{http_code}'` 的输出，curl 退出码被丢弃；连接被中途截断（rc=18/56）时响应头已到、`-w` 仍打印 200，于是坏解析链被判可用并写进 `dns.lastgood`，之后每次开机优先用它。健康检查侧同理，只看 200 + body。

**修复**：dns 侧加 `_dl_rc`，`|| _dl_rc=$?` 捕获退出码，`rc != 0` 直接记"DNS 验活失败（curl rc=…）"并 `return 1`，再判 200/204；control 侧同样取 `_crc`，非 0 就 `continue`。

**验证**：`r13_liveness_curl_status {ok:0, truncated:1, refused:1, probe_off:0}`；`r12_health_status_matrix {ok:0, degraded:0, bad:1, truncated:1}`。

### F-R14 DNS 备份失败仍切换，回滚丢原文件选项

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/dns.sh:549–561](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L549-L561>), [libexec/dns.sh:575–585](<E:/AI/tmp/a2a-magisk-repo/module/libexec/dns.sh#L575-L585>)

**根因**：`[ -s "$DNSFILE" ] && cp -f "$DNSFILE" "$_eback" 2>/dev/null` 无视 cp 失败，一旦四级候选全不可用，"整文件还原"走不了，只能退到"仅回填 nameserver"，`search`/`ndots`/注释整段丢失；成功路径又忘了删 `_eback`，每次生效都在 tmp 留一份整文件副本。

**修复**：备份段改成"cp 失败或结果为空 → 删残件 + 明确日志 + `return 1`，本次不改写"；成功分支在 `return 0` 前 `rm -f "$_eback"`。

**验证**：`r14_dns_backup_failure_blocks {ensure_rc:1, search_kept:1, backup_left:0}`；`r14_dns_success_cleans_backup {ensure_rc:0, backup_left:0}`。

**边界**：备份失败即 return 之后，"无备份 → 仅回填 nameserver"这条降级分支在正常路径上已不可达，仍保留作为防御性兜底。

### F-R15 退避/开机等待后未重验停止与门禁

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/supervise.sh:503–524](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L503-L524>)

**根因**：退避 `sleep "$_wait"`（最长 300 秒）醒来后直接落到统一拉起入口，期间用户可能点了停止、关了自启、断了网或掉到电量门限以下，仍然会多拉起一次。

**修复**：睡醒后三重复核——`STOP=1` 或存在 `$RUNDIR/stop` 就清标记并 `break`；`autostart != 1` 且无子进程则写 `disabled` 并 `continue`；`gates_ok` 不满足则写 `paused` 并 `continue`。三条都过才进入拉起。

**验证**：`r15_backoff_rechecks_state {gate_launches:0, autooff_launches:0, stop_launches:0, normal_launches:1}`（对照组仍能拉起，证明复核没有把正常路径堵死）；主循环侧 `backoff_autostart_off`/`backoff_gate_blocked`/`backoff_stop_marker` 三条的运行轨迹里，退避后不再出现 LAUNCH。

### F-R16 wake lock 在退避/端口冲突持有，恢复启动又未及时获取

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/supervise.sh:487–503](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L487-L503>), [libexec/supervise.sh:526–536](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L526-L536>)

**根因**：熔断（`FAILS>=6`）、退避（`FAILS>=3`）、端口冲突三处等待期间都没有子进程，却继续持有 wake lock；反过来，恢复启动只依赖每 4 轮一次的维护去 `take_wake`，`keep_awake=1` 时可能短期不生效。

**修复**：三处等待前统一 `release_wake`；拉起前按 `keep_awake` 配置 `take_wake`，不再等 TICK%4。

**验证**：`r16_backoff_releases_wake {releases_after_backoff:1, wake_after_backoff:0, releases_after_fuse:1, giveup:1}`；`r16_port_conflict_releases_wake {releases:1, wake:0, launches:0}`；`r16_take_wake_on_relaunch {takes:1, wake:1, takes_when_off:0}`。

**边界**：`/sys/power/wake_lock` 的真实效果取决于设备内核支持，本环境只验证调用序列。

### F-R17 70 秒不健康自然死亡仍清零失败计数

- severity: medium
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/supervise.sh:458–465](<E:/AI/tmp/a2a-magisk-repo/module/libexec/supervise.sh#L458-L465>)

**根因**：死亡分支按"存活 < 60 秒才计失败"，存活 60–119 秒的自然死亡直接 `FAILS=0`；一个每 70 秒死一次的服务永远停在 `FAILS=0`，3 次退避、6 次熔断都触发不了，等于无限重启。

**修复**：删除按存活时长清零的分支，改为无条件 `FAILS=$((FAILS + 1))`；只有巡检确认连续健康满 120 秒才允许清零（该逻辑原本就在存活分支，未改动）。

**验证**：`r17_natural_death_still_counts {fails_after_70s:1, fails_after_kill:1}`；主循环 `natural_death_70s FINAL fails=7 giveup=1 launches=5`（对照修复前会在 `FAILS=0` 上无限拉起）。

### F-R18 seed 版本元数据升级而二进制字节未升级

- severity: low
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [seed/VERSION:1–4](<E:/AI/tmp/a2a-magisk-repo/module/seed/VERSION#L1-L4>), [module.prop:6](<E:/AI/tmp/a2a-magisk-repo/module/module.prop#L6>)

**根因**：`seed/VERSION` 写 `ver=3.3.0-beta.7`，但 `seed/agent2api-server` 的 SHA-256 仍是 `7ed6f986…ff319845`（与 beta.6 同一份），二进制内唯一版本串是 `3.3.0-beta.6`；`payload_install_from` 的版本比较、`a2a status` 显示全建立在假数据上。

**修复**：`VERSION` 改成 `ver=3.3.0-beta.6` 并加三行说明（写的是二进制自报版本，二进制没重编就不能跟着模块跳号）；`module.prop` 的 `description` 明确写成"模块 v3.3.0-beta.7（内置 musl 静态载荷 v3.3.0-beta.6）"，模块版本与载荷版本分开表述。

**验证**：`r18_version_metadata {binary:3.3.0-beta.6, version_file:3.3.0-beta.6, consistent:1, module_prop:"v3.3.0-beta.7 (magisk.31)", prop_mentions_payload:1}`。

### F-R19 boot-start 模块目录推导错误，依赖固定路径兜底

- severity: low
- status: validated
- confidence: high
- evidence_ids: E-002 E-003
- location: [libexec/boot-start.sh:19–28](<E:/AI/tmp/a2a-magisk-repo/module/libexec/boot-start.sh#L19-L28>)

**根因**：脚本住在 `<模块根>/libexec/`，`${_self%/*}` 只得到 `libexec`，`module.prop` 不在这层，于是每次都靠 `/data/adb/modules/agent2api` 硬兜底；模块目录改名、走 `modules_update` 或多开时会拿错路径。

**修复**：先向上找一级父目录，若那层有 `module.prop` 就用它，否则才退标准路径。

**验证**：`r19_boot_helper_module_dir {resolved:/e/AI/tmp/a2a-magisk-repo/module, has_prop:1, is_fallback:0}`（在非标准路径下也不再走兜底）。

## 完整调用链

### P-001 更新事务的提交与收敛链

- path_type: callflow
- evidence_ids: E-002 E-003

`a2a update` → `upd_do_update`（取 update 锁、写 `update.active`）→ `payload_install_from` → `payload_activate_staged`（`upd_payload_before_move` 记旧路径 → mv 旧→`_pa_old`、新→`PAYLOAD` → `upd_payload_after_move` 记 `UPD_INSTALLED` → **写 `update.pending` 失败即整体回退**）→ `upd_finish_service`（停旧、起新、等 45 秒健康）→ 健康通过：`payload_commit_old "new $$"` 成功才 `upd_payload_committed`；健康失败：回滚 + `payload_commit_old "rollback $$"` 收敛，收敛不了就保留现场。开机路径：`post-fs-data.sh` 只记录 pending 不提交 → `supervise.sh` 首次 `start_child` 健康通过后 `payload_commit_old "$_sup_tag"`。

### P-002 守护状态机与健康/DNS 判定链

- path_type: callflow
- evidence_ids: E-002 E-003

`supervise.sh` 主循环 → 停止标记 / autostart / `gates_ok` 三道门 → 存活分支 `svc_http_health`（`--noproxy`、判 curl 退出码、判 200+body；`host` 为通配时 `[::1]` 与 `127.0.0.1` 双试）→ 健康满 120 秒才清 `FAILS` → 死亡分支无条件 `FAILS++` → 退避/熔断/端口冲突三处先 `release_wake`，退避醒来重验 stop/autostart/门禁 → 拉起前按 `keep_awake` `take_wake`。

## 复验结果总览

| 套件 | 覆盖 | 结果 |
|---|---|---|
| 函数级隔离（verify_fixes.py） | R01–R19 共 32 个断言，含真实 curl 与回环 HTTP（v4/v6）、代理干扰、截断响应 | 32/32 通过 |
| 主循环集成（verify_loop.py） | 快崩熔断、70 秒自然死亡、退避期关自启/掉门禁/写停止标记、端口占用、wake 释放 | 8/8 通过 |
| 静态收口 | 20 个 Shell 入口 `sh -n`、13 文件哈希、工作区状态 | `syntax_fail=0` |

## 未覆盖与残余风险

- **无真机**：Android 17 / Magisk 环境下的安装、开机拉起、在线更新、回滚全链未执行；F-R05/F-R12/F-R16 的真机行为（静态载荷启动、v6-only socket、wake lock sysfs 效果）仍需设备验证。
- **shell 差异**：复验用 MSYS `sh`，不是 Android BusyBox `ash`；`local`、`${var%/*}` 等已确认可用，但 `printf`/`sed`/`awk` 的边界行为未在 BusyBox 上复核。
- **R14 降级分支**：备份失败即阻断后，"仅回填 nameserver"分支正常路径不可达，属防御性残留。
- **R05 静态粗判**：`payload_seed_is_static` 靠字串判断，极端构造下可能误判为动态（只会多要一次运行时检查）。
- **未做优化**：本轮只按报告修缺陷，未做性能/结构优化、未重打发布包、未推送远端。

## 复现入口与归档

- 函数级复验：`python E:/AI/tmp/a2a-rereview-20261103/verify_fixes/verify_fixes.py`
- 主循环复验：`python E:/AI/tmp/a2a-rereview-20261103/verify_loop/verify_loop.py`
- 改动清单与 diff：[fix-manifest.json](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/fix-manifest.json>)、[fix.patch](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/fix.patch>)
- 复验原始输出：[verify-fixes-summary.json](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/verify-fixes-summary.json>)、[loop-summary.json](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/loop-summary.json>)
- 语法与工作区快照：[syntax-and-status.txt](<E:/AI/tmp/a2a-rereview-20261103/fix-case/artifacts/syntax-and-status.txt>)
