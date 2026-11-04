# Agent2API-magisk v3.4.0 — 审计修复报告（F-001..F-011）

- **日期**：2026-11-04
- **基线**：`v3.4.0-magisk.34`（commit `23b881d`）
- **修复分支**：`audit-fixes-v3.4.0`（独立 git worktree，未动 main）
- **审计依据**：`docs/audit-v3.4.0-20261104/report/report.md`（11 项发现：5 高 / 6 中）
- **测试结果**：txn_test 56/56 · verify_fixes 37/37 · verify_loop 8/8 · `sh test/run.sh --full` 全过
- **打包验证**：`python pack.py` 两次构建 SHA256 一致
  （`adde5f2ed987a49e1c60a95540348756529d66cbc1cd4953600e7e2ccd865027`）

---

## 0. 总览

| 发现 | 严重度 | 一句话结论 | 修复文件 |
|---|---|---|---|
| F-001 | 高 | 更新健康失败时旧服务还活着就换数据目录 → 数据不一致 | updater.sh |
| F-002 | 高 | 快速重启窗口（120s）恢复被跳过 + sweep 误删旧载荷 | payload.sh / common.sh |
| F-003 | 高 | 数据回滚两次 rename 之间断电 → 开机数据目录空 | payload.sh / post-fs-data.sh |
| F-004 | 高 | 再刷入时 customize 删掉 pending 的旧载荷 → 无法回退 | customize.sh / common.sh |
| F-005 | 中 | CLI 无条件要求 LOADER，静态载荷被拒 | a2a |
| F-006 | 中 | 健康巡检分支拿不到更新锁就不重试提交（锁竞争死锁） | supervise.sh |
| F-007 | 中 | VPN 切换后旧 DNS 验活成功就沿用 → 路由外泄 | dns.sh |
| F-008 | 中 | 缓存有效但 live DNS 文件缺失时静默"成功" | dns.sh |
| F-009 | 中 | APK 开关页乱序响应覆盖写状态（伪 UI 成功） | SettingsPage.tsx / switches.ts |
| F-010 | 中 | README 主测试入口跑不通（引用已删文件）+ 测试硬编码个人路径 | test/run.sh 重写 + verify_*.py |
| F-011 | 高 | 仓库跟踪 APK 签名私钥 + README 公开口令 | 删 jks + .gitignore + 签名指南 |

核心思路：**把"猜现场"换成"记账本"**。旧代码靠目录命名启发式（`payload.new.*`、
120s 年龄门槛）猜事务进度，四类中断窗口全部猜错。新实现引入单行原子写的
**事务 journal**（`$RUNDIR/update.journal`，12 字段定长），配合严格的
**停服（quiesce）前置**与 **sweep 白名单**，让每个中断点都有确定性的开机收尾路径。

---

## 1. 事务 journal 状态机（F-001/F-002/F-003 的公共基础）

```
prepared → quiesced → snapshotted → switching → switched
        → started → verified → committed（清 journal）
                              ↘ await-verify（服务更新前就是停的，
                                  开机保留新载荷，等 supervise 提交）
任意阶段失败：
  → rolling-back（数据目录换入中）
  → rollback-blocked（停不下服务，保现场等开机）
```

- 文件：`$RUNDIR/update.journal`，单行 `v1 <txid> <phase> <pid> <startticks> <tag>
  <old_payload> <data_snap> <data_tmp> <data_aside> <epoch> <new_built>`；
  缺失字段写 `-`；tmp + rename 原子写；**写失败即调用失败**（journal 丢了等于丢事务）。
- `payload_txn_owner_alive`：`pid + /proc/<pid>/stat 第 22 字段（start ticks）` 双核判定，
  防 PID 复用。恢复入口（`payload_txn_recover`）在 runtime 模式发现 owner 活着就
  一律不插手，在 boot 模式无条件收尾。
- 逐相位开机语义（`payload_txn_recover`）：
  - `prepared|quiesced|snapshotted`：还没动持久状态 → 只清记录；
  - `verified|committed|await-verify`：新载荷已验证 → 保留新载荷，清记录；
  - `switching|switched|started|rolling-back|rollback-blocked`：完整回滚
    （载荷优先用 journal 记录的 `old_payload`，其次 `BACKUPDIR/prev`；
    `data_snap=1` 才恢复数据；`PAYLOAD_TXID` 临时设为 journal txid 以过快照身份校验）；
  - 未知 phase：只清记录不动现场（保守）。
- `payload_txn_recover_data(tmp, aside)`：幂等收尾数据目录换入——`DATADIR` 非空说明
  换入已完成（删中转）；空/缺失则把快照 `mv` 回去补完；补不上就把升级后的目录放回去，
  **任何路径都不会留下空 data**。

---

## 2. 逐项修复明细

### F-001 健康失败先停新版，再动数据（updater.sh）

- 旧行为：`upd_do_update` 健康失败分支直接 `payload_rollback` + `payload_data_rollback`，
  最后才 `svc_restart`——回滚窗口里**新版服务还活着**，仍在往"马上要被换掉/已被换掉"的
  数据目录写。
- 新行为：
  - 健康失败分支（updater.sh :596 附近）先 `upd_quiesce`：无条件 `svc_stop` →
    还活着 return 1 → `svc_kill_stray` → `svc_stray_pids` 非空 return 1；
  - 停不下来 → journal 写 `rollback-blocked`，`upd_transaction_finish 1` 后整体失败退出，
    **保留旧载荷、快照、现场全部材料**，等开机 `payload_txn_recover boot` 收尾；
  - 停得下来 → 正常回滚（payload → data → svc_restart → wait_health），
    回滚健康且 `payload_commit_old` 成功后清 journal。
- `upd_on_signal`（TERM/INT/HUP 陷阱）同样重写：先 quiesce 再回滚，用
  `_uos_payload_ok/_uos_data_ok` 记账，**两个都成功才清 journal**，否则留给开机。
- 事务各相位写入点：取锁后 `prepared`；停服后 `quiesced`；快照后 `snapshotted`
  （并 `TXN_DATA_SNAP=1`）；启动前 `started`；健康+`/proc/pid/exe` 双证据 `verified`；
  提交后 `committed`+清；更新前服务就是停的 → `await-verify`（配套 pending-verify 标记）。

### F-002 快速重启窗口 + sweep 误删（payload.sh / common.sh / post-fs-data.sh）

- 旧行为：`payload_recover_interrupted` 对 120s 内的 `payload.switching` 标记直接跳过；
  `sweep_stale_dirs` 无条件删 `payload.new.*`，包括 journal/pending 还引用的旧载荷。
- 新行为：
  - journal 存在 → `payload_txn_recover "$1"` 全权处理（boot 模式无年龄门槛）；
  - journal 缺失才走旧启发式，且 boot 模式对 switching 标记的 120s 门槛直接放行
    （common.sh `_pri_boot` 分支）；
  - `sweep_stale_dirs` 增加 `_ss_jkeep` 白名单：journal 的
    `old_payload/data_tmp/data_aside` 三字段 + `payload.switching` 第 4 字段（旧载荷去向）
    + pending 第 3 字段（原有）；命中白名单的目录一律跳过；`DATADIR.restore.*`
    从无条件删改为逐个对照白名单；
  - `post-fs-data.sh`：`payload_recover_interrupted boot` **移到 `ensure_layout` 之前**
    ——旧顺序会先建空 `DATADIR`，把"数据目录还在中转区"的现场吃掉。

### F-003 数据回滚中断补完（payload.sh）

- 旧行为：`payload_data_rollback` 的 `mv DATADIR → aside` 与 `mv restore → DATADIR`
  两步之间断电，开机 `ensure_layout` 建空 data + sweep 删中转 → 数据丢失
  （快照本体在 backup 里，属"自动恢复丢失"而非永久销毁，但用户视角就是数据没了）。
- 新行为：
  - `mv DATADIR → aside` 前：journal 若存在 → reload 后写 `TXN_DATA_TMP/TXN_DATA_ASIDE`
    + `rolling-back`（写失败中止整个回滚）；
  - 换入成功 / aside 放回成功 → 清 DATA 字段；放不回去 → 保留 aside 指针；
  - 开机 `payload_txn_recover` 先走 `payload_txn_recover_data`：`DATADIR` 非空→删中转；
    空/缺→rmdir 后把快照 mv 回来补完；补不上→把 aside 放回去（升级后的数据仍在）。

### F-004 customize 不再盲删（customize.sh）

- 旧行为：:132 拿锁后 `rm -rf "$APP_HOME"/payload.new.* "$APP_HOME"/payload.broken.*`
  ——pending 事务的旧载荷就叫 `payload.new.old.<pid>`，被一起删掉。
- 新行为：替换为 `payload_recover_interrupted boot` + `sweep_stale_dirs`。
  前者按 journal 语义收尾（该回滚回滚、该保留保留），后者只清**无主**目录。
  再刷入时 pending 事务的恢复材料完整保留。

### F-005 静态载荷可启动（a2a）

- 旧行为：`cmd_ensure_payload` 无条件 `[ ! -x "$LOADER" ]` 即拒——但 launch.sh 一直
  支持静态二进制（3.4.0 默认 seed 就是 musl 静态）。静态更新源会因"载荷缺失"启动失败。
- 新行为：按需 source payload.sh；`SERVER_BIN` 缺失才报"载荷缺失"；
  `payload_validate` 整体校验（内部已区分静态/动态）；仅 `! payload_dir_is_static`
  时才要求 LOADER 可执行。txn_test T5 七项断言覆盖三态。

### F-006 巡检分支补提交（supervise.sh）

- 旧行为：`supervise_commit_pending` 只在 `start_child` 成功后调用一次；服务一直健康时
  巡检分支永远不提交，锁竞争失败只能等重启。
- 新行为：健康巡检分支在受控重启块之后，以 `$RUNDIR/commit.last` 时间戳节流
  （≥60s）调用 `supervise_commit_pending`；启动处 `payload_recover_interrupted`
  改传 `runtime`（journal 主人活着就不插手）。

### F-007 网络变化必重算 DNS（dns.sh）

- 旧行为：`dns_refresh_if_changed` 网络变化后先 `dns_liveness_ok`，旧 DNS 验活成功
  就直接 return——wlan0→tun0 后 LAN 解析器（192.168.1.1）从 tun0 仍可直连，
  验活"成功"但全部流量绕过 VPN（路由外泄）。
- 新行为：
  - 删除验活捷径：iface/VPN/netid 任一变化 → 一律 `dns_ensure` 重算
    （验活结果仅记日志）；
  - 新增 `DNS_NETID_CACHE`（`$RUNDIR/dns-netid`），netid 变化纳入判定
    （非数字归一 unknown，接口名不变但网络切换也能捕获）；
  - `dns_collect_system` 第 5 步 ROM `resolv.conf` 兜底加 `[ "$_vpn" = "0" ]` 门控
    （VPN 下绝不读 ROM 解析器）。

### F-008 缓存恢复 live 文件（dns.sh）

- 旧行为：`dns_write auto` 采样失败且 `DNS_CACHE` 有效时 `rm _tmp; return 0`——
  返回成功但 live `resolv` 文件可能缺失/陈旧。
- 新行为：缓存有效则 `cp "$DNS_CACHE" "$_tmp"` 当作采样结果，走**正常发布路径**
  （验证→去重→原子落盘→回写缓存），`_dns_cache_hit=1` 记日志"发布最后可用配置"；
  采样函数返回非零也统一 `: >"$_tmp"` 清空后落同一条恢复路径（旧代码 return 1 同样不恢复）；
  缓存不可用才静态兜底（IPv6-only 分流保留）。
- 顺带修复（set -u 暴露的真实缺陷，审计清单外）：`dns_ip_usable` 里
  `for _lu in $_DNS_LOCAL` → `${_DNS_LOCAL:-}`——该变量只在 system/auto 采样分支赋值，
  static 兜底路径调用时未定义，任何 `set -u` 调用方会崩。

### F-009 APK 开关页并发契约（SettingsPage.tsx / switches.ts）

- 旧行为：`load` 直接 `setState(next)` 无序号防护；5s 轮询不看页面可见性；
  `toggle` 单 `busyId` + 全量响应合并——旧 GET 可在 PUT 确认后到达把界面改回旧值；
  两个不同开关并发时全量响应乱序互相覆盖；`saveSwitch` 响应缺字段时
  **拿请求值当回显（伪成功）**。
- 新行为（SettingsPage.tsx GatewaySwitches 重写）：
  - `loadSeq`：丢弃乱序 GET；
  - `epoch`：写开始/写完成/回滚各 +1，GET 捕获纪元，变了就丢弃；
  - `queueTail`：链式 Promise **全局写串行队列**（`.catch(()=>undefined)` 防断链）；
  - `pending` Map：仍在队列的键，GET/写响应合并时跳过这些键；
  - `busyIds` Set：任一写在途时**禁用全部开关**（响应是整份状态，必须防旧响应覆盖乐观值）；
  - 轮询仅在 `document.visibilityState === 'visible'` 时执行；
  - toggle 失败回滚时若同键还有后续排队写则不回滚（以最后一次为准）。
- `switches.ts saveSwitch`：响应缺该字段 → 抛"网关响应缺少 ${def.field}，未确认设置已生效"；
  回显值 ≠ next → 抛"网关回显 ${def.field}=… 与请求不一致"。伪成功 fallback 删除。
  `fetchSwitches` 按端点去重并发的行为保留。

### F-010 测试入口重建（test/run.sh 重写 + verify_*.py）

- 旧行为：`test/run.sh` 是 2.x 架构，cp 一个已不存在的 `module/bin/lib.sh`，
  README:186 推荐的 `dash test/run.sh` **从未跑通过**；`verify_fixes.py`/`verify_loop.py`
  硬编码作者个人机器的 sh.exe 路径。
- 新行为：
  - `test/run.sh` 三层：① `sh -n` 全部模块脚本（缺失文件 SKIP 不算失败）；
    ② `txn_test.sh`（`$SH_BIN`：A2A_SH > dash > sh，零硬编码）；
    ③ `--full` 时跑 Python verify 套件（python > python3，无则 SKIP）；
  - `verify_fixes.py` / `verify_loop.py` 头部 `_find_sh()`：A2A_SH →
    `shutil.which('sh')` → 常见 MSYS/Git 位置探测，找不到才退出并提示；
    `verify_fixes.py` CURL 同样 `shutil.which`；
  - `test/txn_test.sh` 新增（见 §3）。

### F-011 签名私钥出库（.gitignore / README-mod.md）

- 旧行为：`apk-mod/a2a-mod.jks`（2.7KB Java KeyStore，含 RSA 私钥）被 git 跟踪，
  README.md:107 明文公开口令 `a2a-mod-2026`。任何拿到仓库的人都能签出与
  "官方 mod"同签名的 APK（同包名覆盖安装 / 钓鱼分发）。
- 新行为：
  - `git rm --cached` + 删除文件；`.gitignore` 加 `*.jks`/`*.keystore`/`*.keystore.b64`；
  - README.md 目录树删 jks 行；README-mod.md 第 5 节重写：
    - **声明旧 key 已泄露作废**，已装用户不受影响（签名校验只在安装时发生），
      但后续版本必须换新 key；
    - `keytool -genkeypair` 生成指南 + `A2A_KEYSTORE/A2A_KEYSTORE_PASS/A2A_KEY_ALIAS`
      环境变量用法（`apksigner --ks-pass env:`，口令不进命令行历史/CI 日志）；
    - 警告：密钥绝不入库。

---

## 3. 回归测试

### test/txn_test.sh（新增，纯 POSIX，56 项断言）

stub OS/进程边界（`proc_start_ticks`/`pid_alive`/`space_require_kb`/`svc_*` 文件化状态），
source **真实** libexec 源码，在每个事务窗口注入故障：

| 用例 | 覆盖 | 关键断言 |
|---|---|---|
| T0 | journal 读写往返（10 项） | write rc / phase / txid / old_payload / new_built |
| T1 | 健康失败先停新版（8 项） | `MOVE_DATA_ASIDE` 前无 `BUG_SERVICE_ALIVE_AT_DATA_SWAP` |
| T1b | 停不下 → rollback-blocked（7 项） | 现场保全：载荷/快照/中转全在 |
| T2 | 切换中崩溃（mv 注入 exit 77）→ 开机恢复（9 项） | 不受 120s 门槛、旧载荷回归、generation 一致 |
| T3 | 数据回滚中断 → 开机补完（4 项） | 快照换入 DATADIR，无空 data |
| T4 | sweep 白名单（5 项） | journal 引用目录保留、无主目录照删 |
| T5 | 静态/动态载荷三态（7 项） | 静态无 loader 通过 / 动态 loader 644 拒 / SERVER_BIN 缺拒 |
| T6 | 网络变化必重算（2 项） | iface+vpn+netid 变化 → `dns_ensure` 被调（旧 DNS 验活成功也不豁免） |
| T7 | 缓存恢复 live（4 项） | 采样失败+缓存有效 → live 文件恢复；无缓存 → 静态兜底 |

### 既有套件回归

- `python test/verify_fixes.py`：37/37（R01–R19 函数级，在改后源码上全部通过——
  源码切片锚点用动态查找，journal 插入未破坏）；
- `python test/verify_loop.py`：8/8（主循环集成，虚拟时钟）；
- `sh test/run.sh --full`：三层全过（语法 15 文件 + txn 56 + verify 37+8）。

### 打包验证

`python pack.py` 两次构建 SHA256 完全一致：
`adde5f2ed987a49e1c60a95540348756529d66cbc1cd4953600e7e2ccd865027`
（18,506,773 bytes，936 项）。

---

## 4. 遗留与限制

1. **真机回归未做**：本机无 arm64 Android 设备。F-001/F-002/F-003 的修复已由
   故障注入测试覆盖（stub 服务状态文件），但 Magisk 环境（SELinux、`/data` 挂载时序、
   KSU 热安装路径）建议真机过一遍 `a2a update` + 断电重启场景。
2. **F-007 的 netid 采样**依赖 `dumpsys connectivity`（Android 7+）；极旧 ROM 归一为
   unknown，退化为 iface+vpn 二要素判定（不差于修复前）。
3. **F-009 前端**：TS 无类型检查环境（apk-mod 只有 6 个源文件，无完整构建项目），
   重写逻辑用 Node 摘函数体方式验证过并发契约（审计期 replay_ui.py），但未在真实
   APK 构建里编译。合并进上游构建前建议跑一次 `npm run build`。
4. **musl 构建仓库**（`84593320z/Agent2API-musl`）的 workflow 问题（浮动 tag、
   cargo 未 `--locked`、resolv 替换 n=0 不失败、UI 未注入模板）在审计报告里列为
   "关联构建仓库"项，不在本仓修复范围。

---

## 5. 复现命令

```bash
# 全部回归（不需要真机/root）
sh test/run.sh --full

# 只跑事务故障注入
sh test/txn_test.sh

# 打包可复现性
python pack.py && sha256sum dist/*.zip   # 跑两次比对
```
