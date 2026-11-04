# agent2api-magisk v3.4.0 第二轮修复报告（对应独立复审 RR-01..RR-12）

- 日期：2026-11-04
- 基线：`23b881d`（tag `v3.4.0-magisk.34`）→ 第一轮修复 `2ef0000` → 本轮修复（提交见第 7 节）
- 输入：`re-review/2026-11-04_复审-agent2api-v3.4.0-report.md`（结论「部分解决」）
- 范围：模块 shell（payload/common/updater/supervise/dns/customize）、APK 前端状态合并、
  重打包脚本、测试入口与签名发布流程。**不含**：真机 Android 验收、APK 重新签名分发、
  `Agent2API-musl` 关联仓库的 workflow。

## 1. 结论

复审提出的 12 项（RR-01..RR-12）全部在代码层处理完毕，并为每一项补了**能在旧代码上
失败、在新代码上通过**的负向回归。本机可执行的验证全部通过：

| 层 | 内容 | 结果 |
|---|---|---|
| 语法 | 17 个模块 shell 脚本 `sh -n` | 17/17 |
| 事务/DNS/CLI | `test/txn_test.sh` | 99/99 |
| 函数级复验 | `test/verify_fixes.py` | 37/37 |
| 主循环集成 | `test/verify_loop.py` | 8/8 |
| 路径转换 | `test/verify_paths.py` | 10/10 |
| 前端状态合并 | `test/verify_frontend.py` | 7/7 |
| 重打包 | `test/repack_test.py` | 21/21 |
| 签名拦截 | `test/sign_test.py` | 12/12 |
| **合计** | `sh test/run.sh --full` | **194 项断言，exit 0** |

**仍然不能宣称「已验收上线」**：真机上的 Magisk 时序、KSU 热安装、活服务停服、
VPN 路由抓包、以及 APK 换签名后的安装迁移都必须由设备/发布流程完成；第 6 节逐条列出
未覆盖面与验收方法。旧 ZIP（`adde5f2e…`）仍是 `2ef0000` 的产物，不能当作本轮验收包。

## 2. 逐项修复

### RR-01 回滚失败被忽略，仍 restart/commit/清 journal

- **根因**：`updater.sh` 健康失败分支用 `payload_rollback || printf`、`payload_data_rollback || printf`
  吞掉返回值，随后无条件 `svc_restart` → `svc_wait_health` → `payload_commit_old` →
  `payload_txn_clear`。只要回滚后的服务能起来（例如数据回滚失败但旧载荷能跑），
  就会把「新版数据 + 旧版载荷」当成成功提交，还删掉唯一回滚副本。
- **改法**（`module/libexec/updater.sh:610-645`）：显式捕获 `_upd_rbp` / `_upd_rbd`；
  任一失败即打印「回滚未完成（载荷=%s 数据=%s），服务保持停止，现场已保全」、
  写 `update.log` 的 `rollback incomplete payload_ok=… data_ok=…`、
  `payload_txn_write rollback-failed` 并 `return 1`；**不重启服务、不 commit、不清 journal**。
  只有两者都成功才进入原来的「重启 → 健康 → 提交」路径。
- **配套**：`payload_txn_recover` 把 `rollback-failed` 与 `rolling-back|rollback-blocked`
  同等对待（`payload.sh:240`），开机继续尝试收尾，而不是当成未知相位直接清掉。
- **负向验收**：`txn_test.sh` T8 注入「健康检查失败 + `data-prev` 备份被破坏」，
  断言 `rc=1`、`journal=rollback-failed`、无重启事件、载荷仍 `2.0.0`、数据回到
  `old-schema`、`data-prev` 仍在。旧代码在该用例下失败 3 条。

### RR-02 journal 恢复绕过活跃 update 锁

- **根因**：`payload_recover_interrupted` 见到 journal 就直接 `payload_txn_recover`，
  取锁逻辑只包住「无 journal 的旧启发式」分支。journal 内的 owner 判活只看
  journal 记录的 pid+startticks，挡不住**另一个刚启动、还没写 journal** 的更新进程，
  于是 supervisor 恢复与 updater 安装可以同时 rename 同一份载荷。
- **改法**（`module/libexec/common.sh:757-785`）：journal 分支先 `update_lock_is_self`
  判断是否已持有（updater 事务内调用直接复用），否则 `update_lock_acquire … 5`；
  取不到就记日志「拿不到 update 锁（有活跃更新事务），本轮不按 journal 恢复」并
  **零动作返回 0**；收尾后按需释放并还原 `UPDATE_LOCK_TOKEN/PATH`；恢复失败返回 1，
  不再叠加任何启发式动作。
- **负向验收**：T9 造 `switching` journal + 另一个活进程真持锁 → 不恢复、journal 原样、
  载荷仍缺失、旧载荷仍在、日志含「拿不到 update 锁」；删锁后再跑同一 journal
  能正常恢复（证明锁只是推迟，不是放弃）。

### RR-03 热安装入口把 boot 当安全条件，活服务下换数据

- **根因**：`customize.sh` 在 KSU 热安装时以 `payload_recover_interrupted boot` 调用恢复，
  boot 语义会跳过年龄门槛，且安装前不检查服务是否在跑 —— 服务正在读写 `/data` 时
  数据快照会被换回。
- **改法**（`module/customize.sh:139-190`）：取锁后先 `source libexec/control.sh`；
  新增停服块：服务在跑则记录 `_HOT_WAS_RUNNING=1` → `svc_stop` → 二次确认
  `svc_is_running` → `svc_kill_stray` / `svc_stray_pids` 非空即 `abort`
  「服务仍未停止，安装中止（不在活服务上替换载荷）」；恢复模式改为 `runtime`。
  清理函数上移为 trap，安装失败且原先在跑则自动 `svc_start` 拉回；安装成功后按
  `_HOT_WAS_RUNNING` 重新拉起并 `svc_wait_health 45`，三态提示。
- **负向验收**：T13 静态断言顺序（control.sh → 停服判定 → 恢复）、`runtime` 模式、
  中止文案与失败拉起路径；行为侧由 T1/T8 覆盖「停服之后才允许动数据」。

### RR-04 data 非空被当作已换入，复合故障时丢完整 restore

- **根因**：`payload_txn_recover_data` 用「`$DATADIR` 非空」判断换入已完成。
  若第一次 `mv` 之后、`mv restore → DATADIR` 之前中断，`DATADIR` 里是**新版数据**
  （非空），恢复逻辑据此认定完成，删掉 `tmp`/`aside` 并清 journal —— 快照再也回不去。
- **改法**（`module/libexec/payload.sh:126-200`）：判据改为 **aside 目录是否存在**。
  aside 在 → 说明第一次 rename 已发生：`DATADIR` 非空视为已就位（清中转），
  为空则 `mv tmp → DATADIR`，失败把 aside 放回；aside 不在 → 第一次 rename 未发生：
  把当前 `DATADIR`（升级后数据）挪到 `_ptd_up`，`mv tmp → DATADIR` 成功后删 `_ptd_up`，
  失败回退。`payload_txn_recover` 检查该函数返回值（`payload.sh:217-218`），
  失败时**保留 journal**（`:307-312`）等下次重试。
- **负向验收**：T10 三态（aside 缺 + 当前是新数据 + tmp 有旧快照 → 换回旧快照；
  DATADIR 缺 + aside 在 → 换入；DATADIR 已是快照 → 保持并清残留）。旧代码在 T10a 失败。

### RR-05 巡检补提交没有健康门控，删掉唯一旧载荷

- **根因**：`supervise_commit_pending` 只校验 pending / `CHILD_GENERATION` / 磁盘三方
  代次一致；主循环 60s 节流处无条件调用。子进程活着但 HTTP 一直失败
  （`running-unverified`）时，旧载荷与 pending 被当成「验证成功」删除。
- **改法**（`module/libexec/supervise.sh:364-380`）：函数新增健康门控 —— 调用方
  刚跑过联合健康检查时传 `verified`，否则内部先 `svc_http_health 3`；不通过就
  「健康检查未通过，本轮不提交事务旧载荷（保留回滚副本）」并返回 0。
  `start_child` 成功路径显式传 `verified`（`:674`，其内部已 `svc_wait_health 40`）。
- **负向验收**：T11 用 `sed` 提取真实函数体，`svc_http_health` 返 1 → 旧载荷与 pending
  都保留；返 0 → 正常提交删除。旧代码两条都失败。

### RR-06 下层 lastgood 无网络身份，旧 LAN DNS 优先

- **根因**：第一轮只删了 `dns_refresh_if_changed` 的「验活成功就 return」捷径，
  `dns_ensure` 仍然读**不带身份**的 `dns.lastgood`，并且候选顺序里旧 lastgood 排第一、
  只要它能连通就沿用 —— 切到 VPN 后仍把家里路由器的 DNS 当新网络结果。
- **改法**（`module/libexec/dns.sh:577-660`）：新增 `dns_net_identity()`
  （`<iface> <vpn 0/1> <netid|unknown>`）；`dns.lastgood.id` 与当前身份不一致即
  **不采用并删除** lastgood；成功发布时写回身份。
- **负向验收**：T12a 造 `lastgood.id="wlan0 0 100"`、当前 `tun0 1 101`、旧 DNS 仍可达 →
  断言不沿用 `192.168.1.1`、改用系统采样 `10.8.0.1`、新身份已写回；T12b 身份一致时
  仍走 lastgood（证明不是粗暴禁用）。旧代码 T12a 三条全失败。

### RR-07 `dns_ensure` 不读 `DNS_CACHE`，缓存恢复只在直接写入口生效

- **根因**：第一轮把「采样为空则用缓存」实现在 `dns_write` 的 auto 分支，但生产路径
  （supervise 启动、refresh）走的是 `dns_ensure`，它压根不读 `DNS_CACHE`，于是
  live 文件缺失 + 缓存有效时仍返回失败。
- **改法**（`module/libexec/dns.sh:590-660`）：新增 `dns_cache_list()`；候选从四级扩为五级，
  末尾固定追加 `_ecache`（缓存里的解析器）；只有能通过 `dns_liveness_ok` 才会发布，
  不把缓存当无条件真理；`DNS_NETID_CACHE` 与当前网络身份不一致时**整份缓存拒用**
  （换到 VPN 后缓存里往往是旧 LAN 解析器，正是 F-007 的同一个坑换了个入口）。
- **负向验收**：T12c 无采样、无静态、无 lastgood，仅 `DNS_CACHE=9.9.9.9` 且网络身份一致
  → 发布成功且内容为 `9.9.9.9`；T12d 缓存属于 wlan0/100、当前 tun0/101 → 拒绝兜底、
  live 保持缺失并记日志；缓存不可达时不发布（沿用原有还原语义）。

### RR-08 前端：失败的端点保留旧状态，开关仍然可点

- **根因**：`SettingsPage.tsx` 的 `load()` 用 `setState(current => ({...current, ...next}))`
  合并，服务端**没有返回**的键会保留上一次的已知值；某个端点读失败被省略后，
  该开关仍是「已知且可操作」，用户拨动只会重复失败。
- **改法**（`apk-mod/src/pages/SettingsPage.tsx:465-488`）：改为从空对象 `{}` 构造，
  只接受本次返回的键，再叠加 `pending` 里的在途乐观值；未返回的键变 `undefined`，
  渲染端 `disabled={!ready || value === undefined || busyIds.size > 0}` 直接禁用。
- **负向验收**：`test/verify_frontend.py` 直接切真实函数体，断言无 `{...current}`、
  从空对象构造、服务端覆盖、保留在途值、丢弃未返回键，并断言 disabled 表达式；
  旧代码 2 条失败。

### RR-09 `posix()` 无条件转盘符，破坏原生 POSIX 路径

- **根因**：两个 verify 脚本的 `posix()` 一律 `'/' + s[0].lower() + s[2:]`，
  `/tmp/repro.sh` 被改成 `//mp/repro.sh`，在 Linux/MSYS 上把测试本身跑坏。
- **改法**（`test/verify_fixes.py:53-60`、`test/verify_loop.py:44-51`）：只有当
  `len(s)>=2 and s[1]==':' and s[0].isalpha()` 时才转成 `/c/...`，其余原样返回。
- **负向验收**：`test/verify_paths.py` 10 条（`/tmp/repro.sh` 与 `/data/adb/agent2api`
  原样、`C:\Users\x\repro.sh` 与 `c:/…` → `/c/Users/x/repro.sh`、相对路径原样）。

### RR-10 / RR-11 重打包输出与输入同源、写入失败覆盖旧输出

- **根因**：`repack.py` 只比较字符串/`abspath`（大小写别名、硬链接都不等），
  然后 `open(out,'w')` 直接把源 APK 截成 0 字节；且直接写最终路径，中途失败会
  把上一次可用输出覆盖成半截。
- **改法**（`apk-mod/repack.py` 整体重写）：`same_file()` 用 `samefile` + `normcase(realpath)`
  双重判定拒绝同文件（含硬链接/大小写别名）；`inside()` 拒绝把输出写进 web 目录
  （否则输出会被再打进包）；打包抽成 `build()`，先写 `out.tmp.<pid>`，`verify()` 用
  `ZipFile.testzip()` + 条目数校验，再 `os.replace()` 原子替换；异常路径清理临时文件
  并打印「打包失败，未覆盖原有输出」。顺带保留 `resources.arsc` 的 STORED 与
  cordova 占位（旧实现两条都丢了）。
- **负向验收**：`test/repack_test.py` 21 条：同路径/硬链接/`BASE.APK` 大小写别名均被拒
  且源包 sha 不变、out 在 web 内被拒且无输出、正常打包成功（内容替换、新增资源、
  arsc STORED、签名条目删除、CRC 完整、无 tmp 残留）、缺 `index.html` 时旧输出 sha 不变、
  输出路径是目录时替换失败且不留 tmp。旧代码 7 条失败。

### RR-12 删除当前树私钥 ≠ 终结泄露；旧签名信任未迁移

- **根因**：`apk-mod/a2a-mod.jks` 连同口令进过 git，`git show 23b881d:…` 可完整取回；
  第一轮只删了工作树文件，历史仍带私钥，且文档里「升级它签的包会因签名不一致被拒」
  这句是**反的** —— 同密钥签的包恰恰能静默覆盖安装。
- **改法**：
  1. `apk-mod/sign-tool.sh`：`new` 生成仓库外的新 keystore（RSA 4096 / PKCS12 / 随机
     32 位口令 / 口令存 600 文件 / 拒绝写入仓库）；`fingerprint` 读证书 SHA-256；
     `check-fingerprint` 拦截泄露证书（`B18B0EB2…C0BF15`）与泄露 keystore 文件
     （sha256 `25cb9dbd…a472d`），命中返回 2。
  2. `apk-mod/signing.md`：写清影响面（同包名同证书可静默升级）、换钥匙流程、
     跨签名必须卸载重装的迁移节奏、发布检查清单、以及为什么「改写 git 历史」不能
     替代换钥匙。
  3. `apk-mod/README-mod.md` 签名章节改写（删掉错误结论，指向 sign-tool/signing.md）；
     `.gitignore` 追加 `*.pass`、`*.p12`。
- **负向验收**：`test/sign_test.py` 12 条（带冒号/小写无冒号均拒、其它放行、
  仓库内目标被拒且不留目录、生成后指纹可读回且不等于泄露值、不覆盖已有 keystore）。
- **仍需人工**：真机换签安装、旧包下架、仓库所有者决定是否清历史（见 signing.md 第 5 节）。

## 3. 新增/改写的测试

| 文件 | 作用 | 断言 |
|---|---|---|
| `test/txn_test.sh` | 新增 T8–T13：回滚失败保现场、恢复互斥、data 相位、补提交健康门控、DNS 身份与缓存（含跨网缓存拒绝）、热安装顺序 | 56 → 99 |
| `test/verify_paths.py` | 跨平台路径转换（RR-09） | 10 |
| `test/verify_frontend.py` | 开关页状态合并语义（RR-08） | 7 |
| `test/repack_test.py` | 重打包输入保护与原子输出（RR-10/11） | 21 |
| `test/sign_test.py` | 签名指纹拦截（RR-12） | 12 |
| `test/run.sh` | `--full` 改为验收模式：缺 python / 缺套件文件直接失败，不再 SKIP | — |

**回归有效性证据**：把上述新测试原样拷到第一轮修复（`2ef0000`）的工作树上运行，
得到 `txn 78/99`（21 失败）、`repack 14/21`（7 失败）、`frontend 5/7`（2 失败），
失败项正好是本轮修的那些行为；在新代码上全部通过。日志见
`docs/fixes-v3.4.0-20261104/evidence/old-code-{txn,repack,frontend}.txt`。

## 4. 验证环境与命令

```bash
cd fix
sh test/run.sh --full        # 194 项断言，exit 0（日志 `evidence/run-full-20261104.txt`）
```

- 环境：Windows 11 + Git Bash（MSYS）下的 POSIX sh；Python 3.12；JDK 25（keytool）。
- 未使用 Android 设备、未跑 gradle/APK 构建、未联网。

## 5. 时间线

| 时间 | 事件 |
|---|---|
| 11-04 上午 | 第一轮审计（19 项发现）与第一轮修复 `2ef0000` |
| 11-04 13:30 | 独立复审：结论「部分解决」，提出 RR-01..RR-12 |
| 11-04 13:52 | 二轮修复启动（读源码 → 事务 → 守护/DNS → 前端/测试/重打包 → 签名） |
| 11-04 14:40 | 全套 194 项断言通过；旧代码反向验证 21/7/2 失败 |

## 6. 未覆盖与真机验收清单

1. **Magisk 真机**：`a2a update` 成功/失败/断电重启、KSU 热安装停服、SELinux 与
   `/data` 挂载时序 —— 本机无 arm64 设备，全部为故障注入 + 真实源码切片。
2. **VPN DNS 抓包**：RR-06 只证明「不沿用旧网络的 lastgood」，真实流量是否仍走 LAN DNS
   需要设备上 `tcpdump` 验证（复审报告已注明不宣称已抓到泄漏）。
3. **APK 构建与换签**：`apk-mod/src` 的 6 个 TS 源文件未编译；新 keystore 未用于实际
   签名；旧包下架与用户迁移属发布流程。
4. **musl 关联仓库**（`84593320z/Agent2API-musl`）的 workflow 问题不在本仓范围。

## 7. 交付物

- 代码：本仓库工作树（分支 `audit-fixes-v3.4.0`），本轮提交 `21db64e`（父提交 `2ef0000`，
  基线 `23b881d`）。
- 报告：本文件；第一轮报告 `report.md` 已就地更正两处不实表述（语法文件数 15→17、
  前端 Node 验证引用基线脚本）。
- 补丁：`../audit-fixes-v3.4.0-round2.patch`（`2ef0000..21db64e`，123793 字节，
  sha256 `d4d5d901b00f86608b0156f21214b9909cd34437d19b078a48c601a7bed86cac`）；两轮合计补丁 `../audit-fixes-v3.4.0-all.patch`（`23b881d..21db64e`，
  223666 字节，sha256 `0106d495a54c9466c0037b2df83b032cae94c20cf988bc58e4ccf1b4e56372c6`）。
- 包：`dist/agent2api-magisk-v3.4.0-magisk.35-arm64.zip`（936 条目，18509944 字节，
  sha256 `b20817b65ef556d3d7d494d24465ba3aba9f3ee95f63bb65ac73bb2da5e8fdf2`），随
  GitHub Release `v3.4.0-magisk.35` 发布；`module.prop` 已随之升到 `v3.4.0 (magisk.35)`、
  `versionCode=2026110435`。构建 `21db64e` 时打出的 `magisk.34` 命名包仅本地留存，不发布。
  该包**未做真机安装验收**，不能对外称「已验收」；上一版 `magisk.34`（`adde5f2e…`，
  含 11 项已确认缺陷）已在 Release 说明中标注勿用。
