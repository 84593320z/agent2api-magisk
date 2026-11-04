# agent2api-magisk

把 [Agent2API](https://github.com/Agent2API/agent2api) 的服务端跑在 Android 手机上（Magisk / KernelSU 模块），
外加一个改造过的手机端 APK：自动发现本机网关、功能开关与面板双向同步。

> 这是**个人修改版**，不是上游官方产物。服务端二进制与面板 UI 来自上游 Release，模块脚本与 APK 改造是本仓库的内容。

---

## 下载

最新构建在 **Releases** 页面（手机上直接点链接就能下）：

- [agent2api-magisk-v3.3.0-beta.7-magisk.33-arm64.zip](https://github.com/84593320z/agent2api-magisk/releases/download/v3.3.0-beta.7-magisk.33/agent2api-magisk-v3.3.0-beta.7-magisk.33-arm64.zip) —— Magisk / KernelSU 模块包（musl 静态载荷，融合 localfix-20261104）
- [agent2api-magisk-v3.3.0-beta.7-magisk.32-arm64.zip](https://github.com/84593320z/agent2api-magisk/releases/download/v3.3.0-beta.7-magisk.32/agent2api-magisk-v3.3.0-beta.7-magisk.32-arm64.zip) —— 上一版（magisk.32，R01–R19 修复），保留备用
- [agent2api-magisk-v3.3.0-beta.7-arm64.zip](https://github.com/84593320z/agent2api-magisk/releases/download/v3.3.0-beta.7/agent2api-magisk-v3.3.0-beta.7-arm64.zip) —— 更早一版（magisk.31），保留备用
- [Agent2API-3.1.2-mod.apk](https://github.com/84593320z/agent2api-magisk/releases/download/v3.1.4/Agent2API-3.1.2-mod.apk) —— 手机端 APK

---

## 这一版（v3.3.0-beta.7 / magisk.33）改了什么

这一版把 2026-11-04 交来的 `localfix-20261104` 覆盖包**融合**进仓库：R01–R19 全部保留
（其中三处被加强），另外补进一批事务与运行时能力。逐条对照见
[docs/2026-11-04_localfix融合说明.md](docs/2026-11-04_localfix融合说明.md)。

**输入包不是完整模块包**：只有脚本、`webroot/index.html`、`module.prop` 与 `docs/`，没有 `seed/`（服务端载荷）、
`tools/`（curl/CA）、`zoneinfo/`、`META-INF/`；它的 `customize.sh` 也只是"把包内文件覆盖进已装目录再调
`hotinstall.sh`"的补丁脚本。所以处理方式是**取其脚本、弃其安装器**：脚本与文档合进 `module/`，
那份安装器存进 [overlay/](overlay/) 作参考（见 [overlay/README.md](overlay/README.md)），
仓库的 `module/customize.sh`、`seed/`、`tools/`、`zoneinfo/`、`META-INF/` 一律保留。

**更新事务（这一版最大的改动）**

1. **先停服、再快照、最后才切**。旧流程是"切完再健康"，服务还在跑旧进程时也可能被判健康。
   现在 staging → `upd_stop_service`（停服并核实真的退出）→ `payload_data_snapshot` →
   原子切换 → 健康校验（并用 `/proc/<pid>/exe` 确认命中的就是新载荷进程）→ 提交。
2. **数据也跟着回滚**。切换前把数据目录 `cp -a` 到 `$BACKUPDIR/data-prev`（另写 `data-prev.txid`），
   并核验 `*.db` / `-wal` / `-shm` 的字节数；回滚时用 `$DATADIR.restore.$$` 中转、
   `$DATADIR.upgraded.$$` 保全现场。新增 `a2a rollback --with-data` 走"旧程序 + 旧数据"一起回退；
   不加这个开关时，若存在数据快照会明确提示"你会得到旧程序 + 新数据"。
3. **代次绑定（txid）**。`update.pending` 从 3 个字段扩到 `tag pid path txid startticks`，
   另有 `$RUNDIR/payload.generation` 与 `payload.switching` 记录切换现场。提交要求
   "pending 的 txid = 本次子进程启动时读到的代次 = 磁盘代次"三方一致；无代次的旧 pending 回退到 tag 匹配。
4. **"已安装未验证"独立状态**。更新时服务本来就是停的（`UPD_WAS_RUNNING!=1`），这种更新只切载荷、
   不做健康验证，因此单独写 `$RUNDIR/update.pending-verify`，等下次开机/启动真正健康通过后再提交。

**运行时与安全**

5. **cgroup 逃逸重写**：逐行解析 `/proc/self/cgroup`，v1 按 `/proc/self/mountinfo` 找每个控制器
   真正挂载点（优先 `$4=="/"` 的根挂载），v2 用 cgroup2 根；写 `tasks` 否则 `cgroup.procs`；
   写完全部**回读** `/proc/<pid>/cgroup` 校验每个层级都到 `/`，任一失败就返回非零（不再"改一个当成功"）。
   `cgroup_escape --check` 只读。
6. **开机入口统一**：`boot-start.sh`、`boot-completed.sh` 都只投递，新文件 `libexec/boot-worker.sh`
   独占 `boot.lock.d` 串行跑完整流程（等 boot_completed → 延迟 → 等网 → DNS 三件套 → 解释器修正 →
   复核 autostart → 幂等启动），两个入口不再各跑一套。
7. **热重启不再重复重启**：改成"请求文件 + 单 worker"。触发只写 `hot-restart.request` 并抢 worker 锁；
   在跑的 worker 每轮重读最新请求、动作前重读 `autostart`，收尾有 ≤3 轮有界复检防丢失窗口。
8. **卸载零删除保护**：缺 `svc_kill_all_module_procs` / `update_lock_acquire` 直接中止（一个文件都不删）；
   进更新锁后停服，正常停不掉就强化停止，仍失败则中止；确认全退出才清锁与崩溃孤儿。
9. **DNS 三态还原**：原文件"不存在 / 空 / 有内容"分别精确还原（空文件走 tmp+mv，原本不存在则删掉并核实），
   还原后读回比对。
10. **安全收紧**：`wget` 回退只在配置了 `update_pin`（固定 digest）时允许，否则明确拒绝并说明原因；
    `update_sha_via_mirror=1` 会打印"镜像可同时伪造包与校验值"的 WARNING；`status.json` 走 `json_escape`；
    WebUI 全部改成 DOM + `textContent`，不再拼 `innerHTML`。

**验证**（两个套件都在 `test/`，可复跑）

- `test/verify_fixes.py` —— **37 项全绿**：R01–R19 原 32 项，加上本轮新增的 5 项
  （代次不符不提交、热重启请求往返、DNS 文件比较原语、JSON 转义、开机入口投递 + wget 闸门顺序）。
- `test/verify_loop.py` —— **8 场景全绿**，并新增"拉起成功后确实走到 `supervise_commit_pending`"断言。
- `sh -n` 全量 21 个 Shell 入口全过。

> **仍然没有真机回归**：以上都在 Windows + msys `sh` 沙箱里跑，msys `sh` 不等于 Android BusyBox `ash`。
> 安装、开机拉起、在线更新、`rollback --with-data` 这条完整链仍需上机确认。
> 另外 `svc_start_impl` 在 `setsid` 前仍会清掉 `$RUNDIR/stop`，`boot-worker.sh` 复核 `autostart`
> 但不复核 stop 标记与门禁——这两处原报告就列为"看到但未修"，这版沿用同样处理。

---

## 上一版（v3.3.0-beta.7 / magisk.32）改了什么

magisk.31 发布后又做了一次**独立复审**：把"上次说已经修好的 19 项"逐条重新验证，结论是
**13 项真解决了、6 项只是部分修复**，另外查出 **19 组新问题**（R01–R19：6 高 / 11 中 / 2 低）。
这一版就是照这份复审报告逐条改的，不掺优化、不绕道。

复审判定"部分修复"的 6 项：F-002（健康前删旧载荷）、F-011（DNS 原子写与整文件回滚）、
F-012（健康检查地址）、F-013（wake lock 释放）、F-014（静态/glibc 载荷契约）、F-018（zoneinfo 切换）。

**致命级（会导致数据或版本不可恢复）**

1. **健康前就删掉旧载荷**（R01）。`payload_activate_staged` 切换完立刻调 `upd_payload_commit`，那函数把 `UPD_ACTIVATE_BEFORE/AFTER` 清空；`post-fs-data.sh` 又在**没有任何健康证据**时就调 `payload_commit_old` 把旧目录删了。新版本还没跑过一次，唯一的回滚副本已经没了。现在 hook 拆成两段：`upd_payload_commit` 只认"新载荷已就位"，新增 `upd_payload_committed` 才清事务身份；开机只记录 pending 不提交；真正的提交点挪到守护**首次健康通过**（进程 + 端口 + HTTP 三项）之后。
2. **pending 写失败、删失败都当成功**（R02）。marker 被外来者建成目录时 `printf >` 静默失败，函数照样 `return 0`；提交阶段 `rm -rf` 删不掉也报成功，随后 marker 消失，这笔旧载荷彻底失记、永远清不掉。现在 pending 走"先写 `.tmp.$$` 再 `mv -f`"，失败就清 tmp、清 active、打印原因并 `return 1`；删除失败保留 marker 等下次重试。
3. **回滚解锁后裸读全局 pending，跨代误删**（R03）。`cmd_rollback` 在 `rollback_finish 0` 里释放锁之后才调 `payload_commit_old`，而它读的是全局 `update.pending`——这中间另一笔事务刚写进自己的标记，删的就是别人的旧版。现在 `payload_commit_old` 接受 `"tag pid"` 做比对，不符一个字节都不动；回滚改为**趁锁内**取标记、释放后重取锁 30 秒再按标记提交，拿不到锁就留给下次开机。
4. **回滚失败只恢复文件，运行实例与 pending 不收敛**（R04）。文件回退了、服务也重启了，但 `update.pending` 还指着刚失败的那一版，下一轮开机照样去删错代次。现在引入 `_upd_rb_ok`：旧版真健康且当前载荷校验通过，才用 `"rollback $$"` 把失败版本提交掉；否则打印"旧版尚未确认健康，保留事务现场"并两边都留着。
5. **静态无 lib 载荷"校验通过却装不上、起不来"**（R05）。`payload_validate` 早就为静态载荷放宽了，但下游还有五处按"必有 `lib/`"硬失败：`payload_fix_perms` 直接 `chmod "$_d/lib"`；`launch.sh` 在判静态之前就 `[ ! -x "$LOADER" ] && exit 78`；`customize.sh` 的 seed 清单、无 seed 分支、`install_payload_perms`、链接器自检、`_patch_bad` 各有一条。现在五处全按实际布局分叉，安装期用 `payload_seed_is_static()` 粗判（读二进制里有没有 `ld-linux` 字串），静态包不再要求 loader/libc。
6. **TERM 重入破坏更新恢复与锁身份**（R07）。`svc_start`/`svc_stop` 在临界区里收到 TERM，handler 重入再调一次同函数；此刻本进程已持锁，`update_lock_acquire` 必然失败直接 `return 1`，外层半途退出；即便不退出，内层 `update_lock_release` 又会用一个被覆盖的全局 token 把外层身份冲掉。新增 `update_lock_is_self()`（按 owner 的 pid + `/proc` 启动代次判定），重入时按"自己已持有"走完不重复取放；释放改按 pid + 启动代次而不是全局 token。
7. **恢复时"移开坏 current"失败会被忽略，old 被嵌进坏目录**（R09）。`mv … 2>/dev/null` 失败也继续往下 `mv "$_old" "$PAYLOAD"`，目标已存在时把 old 塞进坏目录内部，于是 current 仍然坏、唯一回滚副本被毁，函数还 `return 0`。现在移开失败就跳过并记日志，换上去之后追加 `payload_validate` 复核，复核不过把刚移开的放回原位。

**中危（会在特定设备/时序上反复出问题）**

8. **stale supervisor 清理覆盖 service 锁 token**（R06）。`svc_stop_impl` 是 acquire 实例锁**之后**才保存 token，存进去的已是内层 token，恢复后外层 `service.lock.d` 再也对不上，`svc_stop` 报成功却留下 service owner，下次安装直接"另一个事务正在运行"。
9. **死 reaping 快照后盲删同名新活代次**（R08）。回收僵死 reaping 是"读→判死→`rm -f`"，中间没有二次确认；窗口里新一代回收者刚建好同名文件就被删掉。现在删前重读内容逐字比对，不一致就重试。
10. **zoneinfo flag 窗口、辅助文件半新半旧**（R10）。`install_cleanup` 只在 `_ZONE_COMMITTED=1` 时删现目录、只在现目录不存在时才 mv 回；进程死在"新目录已发布、flag 还没置"的窗口里就两边都不动，`VERSION`/`tzdata.zi` 跟着半新半旧。现在失败即整体回退，不看 flag。
11. **真实换行仍能往配置里追加第二键**（R11）。改用 `ENVIRON` 只挡住了 `\n` 字面量，**真实换行/回车**仍会原样写进文件把一行变两行；含空格或 `#` 的值不加引号还会被 `cfg_get` 当行尾注释截断。现在入口拒一切控制字符，并按内容自动加引号。
12. **健康检查被继承的代理打死，`::` 通配地址只试 v4**（R12）。`host=::` 与 `0.0.0.0` 同归一支只试 `127.0.0.1`，而 Android 上服务端常只监听 `[::]:port`，v6-only 环境下一个健康实例每 30 秒被判死一次；回环请求还会走 `http_proxy`，代理回 502 就判死。现在通配地址先试 `[::1]` 再试 `127.0.0.1`，健康请求统一 `--noproxy '*'`。
13. **DNS 验活接受 curl 失败后的 200**（R13）。`_dl_code=$(curl …)` 只留 `-w` 输出、丢掉退出码，连接被截断（rc=18/56）时响应头已到、仍打印 200，坏解析链被判可用并写进 `dns.lastgood`，之后每次开机优先用它。现在同时判 curl 退出码，dns 与 health 两侧都改。
14. **DNS 备份失败仍切换、成功路径残留备份**（R14）。备份 `cp` 不看结果，一旦四级候选全不可用，"整文件还原"走不了，只能退到"仅回填 nameserver"，`search`/`ndots` 整段丢失；成功路径又忘了删备份，每次生效都在 tmp 留一份整文件副本。
15. **退避/开机等待后不重验停止与门禁**（R15）。退避最长 300 秒，醒来直接落到统一拉起入口；期间用户点了停止、关了自启、断网或掉到电量门限以下，仍会多拉起一次。现在睡醒三重复核：stop 标记 → autostart → `gates_ok`。
16. **wake lock 在退避/端口冲突期间持有，恢复启动又不及时取**（R16）。熔断、退避、端口冲突三处等待期间没有子进程却继续持锁；恢复启动只靠每 4 轮一次的维护去 `take_wake`。现在三处等待前统一 `release_wake`，拉起前按 `keep_awake` 立即 `take_wake`。
17. **70 秒不健康自然死亡仍清零失败计数**（R17）。死亡分支按"存活 < 60 秒才计失败"，存活 60–119 秒的自然死亡直接 `FAILS=0`；一个每 70 秒死一次的服务永远停在 0，3 次退避与 6 次熔断等于没有。现在无条件 `FAILS++`，只有巡检确认连续健康满 120 秒才清零。

**低危（元数据与路径推导）**

18. **seed 版本写 beta.7 而二进制是 beta.6**（R18）。`seed/VERSION` 跟着模块跳号，但 `seed/agent2api-server` 的 SHA-256 仍是 beta.6 那一份、二进制内唯一版本串也是 `3.3.0-beta.6`，`payload_install_from` 的版本比较与 `a2a status` 全建立在假数据上。现在 `VERSION` 写回 `3.3.0-beta.6` 并加注释说明，`module.prop` 的 `description` 分开表述"模块版本 / 内置载荷版本"。
19. **boot-start 模块目录推导少一层**（R19）。脚本住在 `<模块根>/libexec/`，`${_self%/*}` 只得到 `libexec`，`module.prop` 不在这层，于是每次靠 `/data/adb/modules/agent2api` 硬兜底。现在先上溯一级找 `module.prop`，找不到才退标准路径。

**没修、但已经看到的**（不在复审报告范围内，按"只修报告"原则留给你决定）

- `control.sh` 的 `svc_start_impl` 在 `setsid` 前 `rm -f "$RUNDIR/stop"`，会抹掉用户刚点的停止标记。
- `boot-start.sh` 的开机等待段只复核 `autostart`，没复核 stop 标记与门禁。

**验证方式**（两个套件都在 `test/` 里，可复跑）

- `test/verify_fixes.py` —— 函数级隔离复验，**32 项断言全绿**。函数体从源码原样切片，只替换操作系统边界；健康与 DNS 用**真实 curl** 打**真实回环 HTTP 服务**（含 `[::1]`），另把 `http_proxy` 指到返回 502 的端口验证不依赖代理。
- `test/verify_loop.py` —— 主循环集成复验，**8 个场景全绿**。`supervise.sh` 的 `while` 主循环与启动准备段整段切片，虚拟时钟驱动：快崩熔断、70 秒自然死亡、退避期关自启/掉门禁/写停止标记、端口占用、wake 释放。
- 20 个 Shell 入口 `sh -n` 全过。

> **仍然没有真机回归**：以上都在 Windows + msys `sh` 沙箱里跑，msys `sh` 不等于 Android BusyBox `ash`。
> 安装、开机拉起、在线更新、回滚这条完整链仍需上机确认；R05（静态载荷启动）、R12（v6-only socket）、
> R16（wake lock sysfs 实效）三处尤其依赖真实设备。

---

## 上一版（v3.3.0-beta.7 / magisk.31）改了什么

这一版做了一次完整源码审计，19 项缺陷全部修掉并逐项复测。按影响排序：

**启动与守护**

1. `service.sh` 原来在括号子 shell 里跑整个启动流程，子 shell 继承的是**已经退出的父进程 PID**，`proc_start_ticks` 取不到启动代次 → 加锁直接拒绝；Magisk 又没有 boot-completed 钩子兜底，真机表现是"模块开着但服务不在"。现在改成 `setsid sh libexec/boot-start.sh` 独立进程，`$$` 是真身。
2. `stop_child` 先删 `server.pid / server.start` 再发信号：一旦杀不掉，外部再也认不出这个进程，日志里"保留 PID/启动代次"是假的。改成确认杀干净后才删，杀不掉时身份文件留着。
3. 快速崩溃熔断：原实现只要 `start_child` 成功就 `FAILS=0`，"起来 → 30 秒内崩 → 再起来"永远停在 1 次，3 次退避和 6 次熔断等于关掉。现在只有稳定运行 ≥120 s 才清零。
4. `keep_awake` 只有 `take_wake` 没有释放：热关自动启动 / 暂停 / 熔断三条路径都会留下 wake_lock。三条路径补 `release_wake`，运行期按配置按需释放。
5. 健康检查写死 `http://127.0.0.1`，而 `host` 可配置。新增 `svc_health_urls`：按配置归一化（`0.0.0.0`/`*`/`::` → 回环，`::1` 加方括号，局域网地址补回环兜底）。

**更新与回滚**

6. `payload_activate_staged` 在**健康检查之前**就 `rm -rf` 掉旧载荷，于是 `rollback_finish` 里"恢复旧目录"的分支永远空转，回滚只能报 `PREVIOUS-UNHEALTHY`。改成两阶段：切换时写 `run/update.pending` 标记保留旧目录，健康通过后由 `payload_commit_old` 提交删除；`sweep_stale_dirs` 认这个标记不误删。
7. 更新信号处理器 `upd_on_signal` 末尾是 `return 1`，回到 `upd_do_update` 继续装，还可能以 0 退出。改成 `exit 1` 真正终止顶层事务。
8. `svc_start` / `svc_stop` 里的 `trap 'exit 130' …` + `trap - HUP INT TERM` 会清掉调用方（`cmd_rollback` / `upd_do_update`）注册的事务处理器。删掉这层覆盖。
9. 自定义 `https://` 镜像被忽略：`mirror_url` 把配置当参数用（调用只传一个 URL），拼出来还是原地址。改成读一次 `github_mirror` 再拼前缀。
10. 版本比较 `better()` 先按 `.` 切分，`3.3.0-beta.10` 被切成 `3 / 3 / 0-beta / 10`，预发布号落到第四段，beta.10 与 beta.6 判等、`v3.x` 与 `v4.x` 也可能反序。改成先用 `-` 拆主版本与预发布段，再逐段按数字比。

**DNS**

11. `dns_liveness_ok` 用 `curl -sS -o /dev/null` 就算成功：HTTP 500、DNS 劫持页都当"可用"；`CURL` 缺失时还返回成功。改成缺 CURL 直接失败，`-f -w '%{http_code}'` 只认 200/204。
12. IPv6 可用性只看 main 表，Android 上 `default` 常挂在 per-netId 表里，判断偏保守。改成先查 `ip -6 route show table all default` 再退回 main。
13. `dns_apply_list` 用 `cp -f` 直接覆盖现役 resolv，写一半被中断就是半个文件；`dns_ensure` 全候选失败后只回填 nameserver，原文件的 `search` / `options` 丢失。改成 `mv -f` 原子替换，并在切换前整文件备份、失败整文件还原。

**安装、插件与打包**

14. 静态载荷（musl，无 `PT_INTERP`）仍被按 glibc 载荷校验，`payload_validate` / `loader_smoke` / 恢复逻辑 / 更新器全在找 `lib/ld-linux-aarch64.so.1`。新增 `payload_dir_is_static` 分流，静态载荷不再要求 loader/libc，更新器也不再往静态载荷里塞 glibc 库。
15. 插件解释器改写白名单把 `/apex/...`、`/system/bin/*linker64` 也算进去，会把 bionic 动态链接器改成 glibc 路径。白名单收紧成只放行 `ld-linux*.so*`。
16. 更新锁的 `reaping` 互斥由回收者创建，回收者崩溃后没人再回收，锁永久卡死。`ln reaping` 失败时读持有者身份，确认僵死就清掉重试。
17. `cfg_set` 用 `awk -v` 传值，awk 会把值里的 `\n` 当真换行——写成 `gateway_key=abc\nallow_no_key=1` 会多出一行 `allow_no_key=1`，等于凭空改配置。改用 `ENVIRON` 传值。
18. `install_cleanup` 只在 `_ZONE_COMMITTED=1` 时恢复时区库，而两次 `mv` 之间被打断正好没提交 → zoneinfo 整个丢失。改成只要旧目录还在就恢复；`post-fs-data.sh` 开机补一次 `zoneinfo.old.*` 回填。
19. `update-binary` 的 unzip 循环把命令拼成 `unzip unzip` / `busybox unzip unzip`，回退分支必然失败。改成分支拼装。

顺带修的两处小问题：`module_desc_set` 的 `sed` 替换串没转义 `&`/`|`；`pack.py` 的 `os.path.relpath(...).replace("\\\\", "/")` 匹配的是两个反斜杠，等于从未替换成功，重建 zip 时 `libexec/*` 会掉成 0644。

---

## 三个产物

| 产物 | 说明 | 怎么得到 |
|---|---|---|
| `agent2api-magisk-vX.Y.Z-magisk.NN-arm64.zip` | Magisk / KernelSU 模块包（模块壳 + 内置服务端） | `python pack.py` → `dist/` |
| `Agent2API-3.1.2-mod.apk` | 改造过的手机端 APK | `apk-mod/` 里的流程（见下） |
| `docs/*.md` | 审计报告与修复自查报告 | — |

---

## 目录

```
module/                模块源码（就是打进 zip 的东西）
  module.prop          壳版本 / 描述
  customize.sh         安装脚本（加锁、时区库原子切换、载荷安装）
  post-fs-data.sh      早期钩子（崩溃恢复、残留清理、bootstrap resolv）
  service.sh           开机入口：只负责把 libexec/boot-start.sh 拉成独立进程
  boot-completed.sh    KernelSU 的 boot-completed 钩子（Magisk 不触发）
  action.sh            KernelSU/Magisk 的「操作」按钮
  uninstall.sh         卸载（停服务、清锁、保留数据）
  hotinstall.sh        热安装
  libexec/             模块逻辑
    common.sh          路径与配置、日志、进程身份、锁、静态判定
    control.sh         启停、健康探活、端口、CLI 生成
    supervise.sh       守护主循环（退避、熔断、cgroup、wake_lock）
    payload.sh         载荷校验、安装、回滚、两阶段提交
    updater.sh         在线更新（镜像、校验、事务、信号）
    dns.sh             resolv / nsswitch / gai 生成、验活、回退
    plugin.sh          插件解释器改写
    launch.sh          载荷启动（静态直接 exec，动态走 loader）
    boot-start.sh      开机异步启动流程
    timezone.sh        时区兜底
    a2a                命令行入口（status/start/stop/update/rollback/dns/doctor…）
  seed/                随包的载荷（musl 静态 agent2api-server + 面板 UI + VERSION）
  tools/               curl、cacert.pem
  webroot/             KernelSU 状态卡（status.json / lastlog.txt）
  zoneinfo/            时区库（约 400 个区）
  settings.conf.example 配置模板
apk-mod/               手机端 APK 改造
  src/                 改动过的 6 个前端源文件
  a2a-mobile-mod.patch 对上游 desktop-tauri/mobile 的完整 diff
  repack.py            把重新构建的 Web 产物塞回官方 APK
  a2a-mod.jks          APK 签名密钥库（口令 a2a-mod-2026）
  README-mod.md        APK 侧的详细说明与验证记录
docs/                  审计 / 修复报告
  2026-11-03-源码审计-Agent2API-Android17.md   第一轮完整源码审计（19 项发现）
  fix-verification-2026-11-03.md              第一轮 19 项修复的逐项复测记录
  fix-verify-2026-11-03.json                  第一轮复测原始输出
  2026-11-03_Agent2API-magisk31-独立复审.md    独立复审：13 项真解决 / 6 项部分修复 + 19 组新问题
  2026-11-03_Agent2API-magisk32-19组修复报告.md 本轮按复审报告逐条修复的正式报告与复验证据
test/run.sh            离线桩测试（不需要真机）
test/fix_verify.py     第一轮 19 项修复的复测夹具（历史保留）
test/verify_fixes.py   本轮 R01–R19 函数级隔离复验（32 项断言，需要 msys sh 或系统 sh）
test/verify_loop.py    本轮 R01/R15/R16/R17 主循环集成复验（8 个场景）
pack.py                打包脚本（自动从 module.prop 取版本号，文件名带 magisk.NN）
```

两个复验脚本的中间产物（夹具、用例、原始输出）都写在各自的 `out/` 目录里，不进版本库。

---

## 快速开始

### 1. 装模块

```bash
# Magisk / KernelSU 里刷入 dist/agent2api-magisk-vX.Y.Z-arm64.zip，重启
su -c 'sh /data/adb/agent2api/bin/a2a status'    # 看状态
su -c 'sh /data/adb/agent2api/bin/a2a doctor'    # 一键自检
```

面板：`http://127.0.0.1:3065/`（首次进去注册管理员）。

### 2. 装手机端 APK

```bash
adb uninstall com.agent2api.mobile     # 官方版签名不同，必须先卸
adb install -r Agent2API-3.1.2-mod.apk
```

首次启动会自动连上 `127.0.0.1:3065`。

---

## 版本语义

两个版本号是**独立**的：

- **模块壳**：`module.prop` 的 `version`（脚本与运行时）
- **服务端载荷**：`module/seed/VERSION`（上游 musl 静态二进制）

`a2a version` 会分别列出。升级载荷有两条路：

```bash
su -c 'sh /data/adb/agent2api/bin/a2a update'
```
或直接在**面板「设置 → 软件更新」**里点更新（守护会在 ~10 秒内自动重启生效）。

> 载荷分两种：**静态**（musl，无 `PT_INTERP`，不依赖 glibc 与系统 DNS）和**动态**（glibc + 随包 loader）。
> 模块按 `payload_dir_is_static` 自动分流：静态载荷不要求 `lib/ld-linux-aarch64.so.1`。

---

## 已知问题

- **APK 的硬件返回键会直接退出应用**。上游 Capacitor 8 的 `BridgeActivity` 不处理返回键，
  `@capacitor/app` 插件也没打进包；试过三种原生补丁均因 `Bridge.getWebView()` 返回 null 而失败。
  应用内左上角的 `‹` 返回是正常的。详见 `apk-mod/README-mod.md` 第 3.3 节。
- **cgroup 逃逸依赖设备**：只在 `/sys/fs/cgroup/cgroup.procs` 可写、且 `/proc/self/cgroup`
  里能匹配到 `apps`/`background` 等分组时生效；部分设备（cgroup v2 统一层级、厂商改写）不适用，属降级不影响运行。
- **Wi-Fi 判定只认 `wlan0/wlan1/swlan0` 的 IPv4**：纯 IPv6 网络或厂商自定义接口名会判成"不在 Wi-Fi"，
  `wifi_only=1` 时会被暂停。
- **本版仍然没有真机回归**：修复是在 Windows + msys `sh` 沙箱里用源码切片 + 桩驱动验证的
  （`test/verify_fixes.py` 32 项、`test/verify_loop.py` 8 个场景，全绿），Android 侧仍需实机验证
  启动 / 守活 / 升级回滚。msys `sh` 不等于 Android BusyBox `ash`。

---

## 构建

```bash
python pack.py          # → dist/agent2api-magisk-vX.Y.Z-magisk.NN-arm64.zip
dash test/run.sh        # 离线桩测试，不需要真机
python test/verify_fixes.py   # R01–R19 函数级复验（32 项；需要 msys sh 或设 A2A_SH）
python test/verify_loop.py    # 主循环集成复验（8 个场景；夹具由上一个脚本生成，先跑它）
```

两个复验脚本都按自身位置定位 `../module`，默认把中间产物写到 `test/verify_fixes/out/`、
`test/verify_loop/out/`；可用环境变量 `A2A_MODULE`、`A2A_VERIFY_OUT`、`A2A_SH`、`A2A_CURL` 覆盖。

APK 侧（需要 Node 20+，构建细节见 `apk-mod/README-mod.md`）：

```bash
cd desktop-tauri/mobile        # 上游仓库
npm ci && npx vite build --mode apk
python repack.py && zipalign -p -f 4 ... && apksigner sign ...
```

---
