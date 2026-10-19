# Agent2API Magisk 模块 v3.1.2 修复与自查审阅报告

- 修复对象：`agent2api-magisk-v3.1.1-repo1-arm64`（审计报告见 `agent2api-magisk-v3.1.1-repo1-审计报告.md`）
- 产出：`E:\AI\work\agent2api\dist\agent2api-magisk-v3.1.2-arm64.zip`
  （645 条目 / 9.77 MB / sha256 `6754511e4d9ee63fe03286b823df3c9dd7ddfce6cb9644557cd51d5c0edfbc1e`）
- 源码树：`E:\AI\work\agent2api\v3.1.2\`（`build/` 模块源码、`test/run.sh` 桩测试、`pack.py` 打包脚本）
- 工作副本：`E:\AI\tmp\agent2api-analyze\`（`build/`、`extracted/` 原始解包、`dist/` 中间产物）
- 日期：2026-10-19

---

## 0. 结论摘要

审计报告的 3 个 P0、6 个 P1 全部修复；P2 修了 6 条、2 条按"不改更好"处理并说明理由；
2.1（`unshare -m`）按审计自己的建议延后，只做了低成本替代。

修完之后我对自己这轮改动做了一遍逆向审查（第 3 节），**又抓出 7 个问题**——
其中 4 个是我这轮新引入的、3 个是原代码里审计报告没提的。这些都已修掉。

验证手段：`dash -n` 语法检查 7/7 通过、37 项离线桩测试全过、zip 结构与权限位校验通过。
**真机行为仍未验证**（第 7 节给了逐条命令），这是本次交付唯一的空白。

| 指标 | 数值 |
|---|---|
| 变更文件 | 8 个（脚本 5 + 配置 2 + 文档 1） |
| 代码变更 | lib.sh +381/−60、ctl +168/−20、service.sh +136/−16、customize.sh +21/−5、uninstall.sh +6 |
| 桩测试 | 37 通过 / 0 失败 |
| 新增命令 | `ctl doctor`、`ctl clean` |
| 新增配置 | `AGENT2API_MAX_RSS_MB`、`AGENT2API_WATCHDOG`、`AGENT2API_OOM_SCORE_ADJ`、`AGENT2API_SNAPSHOT_MAX_MB`、`AGENT2API_KEEP_FAILED` |

---

## 1. 审计条目逐条对照

### 1.1 P0

| 编号 | 状态 | 实现位置 | 说明 |
|---|---|---|---|
| B1 日志轮转失效 | ✅ 已修 | `lib.sh: rotate_log` | 改 copytruncate：`cp` 后 `: >` 原地截断，inode 不变，写入方 fd 继续有效。桩测试专门模拟"持有 fd 的写入方"，验证轮转后写入仍落在原路径 |
| B2 卸载重装不自启 | ✅ 已修 | `uninstall.sh`、`customize.sh` | 双保险：卸载清 `disable` + `.installed`；首装判定改为 `[ -f MARKER ] && [ -d /data/adb/modules/agent2api ]`，模块目录不存在即视为全新安装 |
| B3 只读加固静默失效 | ✅ 已修 | `lib.sh: mount_chroot` | 只走两步法（`bind` → `remount,bind,ro`），挂载后做写测试（`EROFS` 是唯一可靠判据），失败落 warning |

### 1.2 P1

| 编号 | 状态 | 实现位置 | 说明 |
|---|---|---|---|
| B4 升级时旧服务杀不掉 | ✅ 已修 | `lib.sh: srv_pids / kill_by_scan` | 按 exe 路径特征扫描，不依赖 pidfile 与当前 `$ROOT`；`stop_server` 与 `stop_all` 双调用点 |
| B5 pidfile 丢失无法停 | ✅ 已修 | `lib.sh: stop_server` | `is_running` 为假的分支改走 `kill_by_scan`，不再直接 return |
| B6 空文件算术致命 | ✅ 已修 | `service.sh`、`lib.sh: notify_user` | `cat ... \| tr -dc '0-9'` + 空值兜底 |
| B7 setsid 失败无回退 | ✅ 已修（**两处**） | `lib.sh: spawn_supervisor`、`service.sh` 角色一 | 审计只提了 ctl 路径。开机路径（`service.sh` 角色一）同样直接 `spawn_detached`，同样会中招 —— 这条是我自查补的 |
| B8 `oom_score_adj=-1000` | ✅ 已修 | `lib.sh: start_server`、`service.sh` 轮询 | 改 `-900` 可配；RSS 看门狗每 60s 采样，连续 2 次超限优雅重启 |
| B9 全局 mount namespace | ⚠️ 部分（低成本替代） | `lib.sh: stop_supervisor` / `stop_all` | 未做 `unshare -m`（见第 5.1 节），但保证 KILL 路径后统一卸载，不残留挂载 |

### 1.3 P2

| 编号 | 状态 | 说明 |
|---|---|---|
| B10 版本不一致 | ⚠️ 按"标签化"处理（见第 4.1） | `VERSION` 保持 `3.1.0`（那是载荷的真实版本），改的是**显示语义**：`ctl status` 分列「模块壳 / 服务端载荷」，README 与 `module.prop` 都写明 |
| B11 IPv6 兜底是死代码 | ✅ 已修 | 检测 `/proc/net/ipv6_route` 的 v6 默认路由，命中则把 `2400:3200::1` 顶到兜底序列最前 |
| B12 `.failed` 归档堆积 | ✅ 已修 | `prune_failed_archives`（保留 2 份）+ `ctl clean [keep]` |
| B13 sha256 同源 / tar 穿越 | ✅ 修一半 + 文档 | 解包前审条目：`../`、绝对路径、绝对/越界符号链接直接拒绝（桩测试用真实恶意 tar 验证）；信任模型写进 README「已知限制」 |
| B14 `proc_uptime` 解析不稳 | ✅ 已修 | 先 `sed 's/.*) //'` 剥掉 `pid (comm)`，`starttime` 取第 20 字段；桩测试用含空格的 comm 验证 |
| B15 `resolv.conf` 非原子写 | ✅ 已修 | 变量里拼好，一次 `printf` 写入 |
| B16 端口占用无诊断 | ✅ 已修 | 连续两次确认「LISTEN 且能指到具体 pid」后写 `fatal` 停止重试，`status`/`doctor` 显示占位 pid 与命令行 |
| B17 缺 `/etc/localtime` | ✅ 已修 | 安装时建符号链接 + 启动时 `resolve_tz` 校验并回落 |
| B18 其他小问题 | ✅ 6 条 / ⚠️ 2 条 | 见下表 |

B18 细分：

| 子项 | 状态 |
|---|---|
| `cmd notification --user 0` | ✅ 带 `--user 0` 试一次，失败回落无参形式 |
| `HEALTH_WGET` 缓存失败结果 | ✅ 改为"找到才缓存"，并校验 busybox 真的编了 `wget` applet；都没有则降级为端口探测并记一次日志 |
| `_tick % 360` 依赖轮询间隔 | ✅ 改为按 `date +%s` 的真实 3600s |
| `db_snapshot` 无上限 | ✅ `AGENT2API_SNAPSHOT_MAX_MB`（默认 1024），超限跳过快照并明确说明 |
| 多个同名 server 二进制 | ✅ 计数并 warning，取第一个 |
| `_ver_gt` 两份实现 | ⚠️ 保留（见第 4.3） |
| `up < 20` 误计崩溃 | ✅ 改 45s |
| `module.prop` 缺 `updateJson` | ⚠️ 不加（见第 5.4） |

### 1.4 系统影响专项（第 2 节）

| 条目 | 状态 | 说明 |
|---|---|---|
| 2.1 全局 mount namespace | ⚠️ 延后 | 见 5.1 |
| 2.2 `oom_score_adj` | ✅ 已修 | `-900` + RSS 看门狗，把不可控的内核 OOM 变成可控重启 |
| 2.3 tmpfs 256MB | ✅ 已修 | 默认回落 `64m`，注释说明 tmpfs 吃 RAM |
| 2.4 chroot 内 root | ✅ 部分 | 新增「对外监听 + 零鉴权 = 拒绝启动」闸门（见 4.2）；降权默认值未改（见 5.3） |

### 1.5 优化建议（第 5 节）

| 条目 | 状态 |
|---|---|
| 5.1 体积裁剪 | ⚠️ 未做（见 5.2，删上游资源需要你拍板） |
| 5.2 健康检查自适应 | ✅ 已做：成功逐步退到 6 tick，失败立刻回 1 tick |
| 5.3 `ctl doctor` | ✅ 已做，13 项检查 + 小结 |
| 5.4 面板硬编码 3065 | ⚠️ 未做（见 5.5） |

---

## 2. 变更明细

### 2.1 `bin/lib.sh`（+381/−60）

| 函数 | 变更 |
|---|---|
| `rotate_log` | copytruncate + 非数字体积兜底 |
| `srv_pids` / `kill_by_scan` | 新增：按 exe 特征扫描并终止游离 server |
| `_port_inodes` / `port_listening` / `port_owned_by_server` / `port_owner_pid` | 重构：只认 LISTEN 状态；新增占位进程识别 |
| `gen_resolv` | 一次写入；v6 兜底提到最前；去重逻辑改内存集合 |
| `mount_chroot` | 只读加固两步法 + 写测试；tmpfs 默认 64m |
| `start_server` | `oom_score_adj` 可配（默认 −900）；启动前 `resolve_tz` |
| `stop_server` | 兜底走 `kill_by_scan` |
| `stop_supervisor` | KILL 分支释放锁并说明"挂载交给 stop_all" |
| `spawn_supervisor` | 存活确认 + 双 fork 兜底 + 失败返回 1 |
| `health_ok` | 工具链探测重写（busybox wget → curl → wget+timeout → 端口降级） |
| `rss_mb` / `mem_limit_mb` | 新增：RSS 看门狗数据源 |
| `lan_exposed` / `lan_exposed_unsafe` | 新增：对外监听与"裸奔"判定 |
| `resolve_tz` | 新增：时区校验 |
| `notify_user` | 空值算术加固 + `--user 0` 回落 |
| `update_extract` | 解包前审路径/符号链接；多二进制告警 |
| `db_snapshot` | 体积上限；`env.sh` 缺失不再导致整体失败 |
| `prune_failed_archives` | 新增：归档保留策略 |
| `DATA` | 允许 `AGENT2API_DATA_DIR` 覆盖（仅供离线桩测试，见 5.6） |

### 2.2 `service.sh`（+136/−16）

- 配置加载与安全闸门前移到 `boot_completed` 等待之前（开机第一秒就能给出结论，而不是干等 5 分钟）
- 安全闸门：对外监听 + 零鉴权 → 写 `fatal` + 通知 + 退出
- 自适应健康检查（2→6 tick 退避，失败回 1 tick），阈值 18 次 ≈ 3 分钟
- RSS 看门狗（每 6 tick，连续 2 次超限 → TERM → 3s → KILL）
- 端口冲突诊断（连续 2 次确认 → `fatal` 停止重试）
- 每小时 DNS 改为时间驱动
- `restarts` 空文件算术加固；崩溃判定 20s → 45s
- 开机路径补 setsid 失败的双 fork 兜底

### 2.3 `bin/ctl`（+168/−20）

- `proc_uptime` 解析修正
- `status`：壳/载荷分列、RSS 与看门狗阈值、端口占位者、LAN 暴露提示、归档份数与体积
- 新增 `doctor`（13 项检查：chroot / 只读加固 / 致命挂载 / 进程 / RSS / oom_score_adj / 守护 / 端口 / 健康 / 时区 / 磁盘 / 日志体积 / 更新层 / 安全）
- 新增 `clean [keep]`

### 2.4 其他

- `customize.sh`：FRESH 判定、`/etc/localtime` 符号链接、文案
- `uninstall.sh`：清 `disable` / `.installed` / `fatal`
- `module.prop`：`v3.1.2` / `31200`，描述里写明"壳版本 ≠ 载荷版本"
- `config/default.env`：监听地址安全说明、tmpfs 64m、看门狗/快照/归档配置项
- `README.md`：版本语义、`doctor`/`clean`、局域网直连的前置条件、更新层信任模型、v3.1.2 变更记录

---

## 3. 自查：这轮抓出并修掉的 7 个问题

写完之后我把改动当成别人的代码重读了一遍，逐函数对照调用点。以下按严重度排序。

### 3.1 【高】开机路径的 setsid 失败没兜底（B7 只修了一半）

审计的 B7 指向 `spawn_supervisor`（`ctl`/`action.sh` 走这条）。但**开机是另一条路径**：
Magisk 直接执行 `service.sh` → 角色一 → `spawn_detached service.sh --loop`。
这里同样会遇到 `setsid` EPERM，而且更致命 —— Magisk 不会重试，机器会停在
"模块已装、服务从没启动过"直到下次重启。

修法：角色一也加存活确认 + 双 fork 兜底。两处重复拉起由 `mkdir` 原子锁兜住。

### 3.2 【高】端口冲突诊断会误报（我自己引入的）

初版写的是 `up < 10 && port_listening && ! port_owned_by_server`，两个坑：

1. 判断前刚执行过 `rm -f "$PIDFILE"`，`port_owned_by_server` 必然为假 —— 条件退化成"端口在听就报冲突"；
2. `port_listening` 原来按端口号 grep `/proc/net/tcp`，**TIME_WAIT 的残留条目也会命中**。服务刚退出时端口处于 TIME_WAIT，会被判成"被别人占了"，进而写 `fatal` **永久停止重试** —— 比原来的无限退避更糟。

修法：
- `port_listening` 改为只认 `0A`（LISTEN）状态；
- 冲突判定改为"必须能通过 fd 反查到具体 pid"，查不到就不下结论；
- 连续两次确认才写 `fatal`。

### 3.3 【中】停机顺序会让服务在"半截根"里写数据

初版把 `umount_chroot` 放进了 `stop_supervisor` 的 KILL 分支（审计 5.9 的建议）。
但 KILL 守护时**服务进程还活着**（守护死了不会带走服务），此刻先卸掉它脚下的
`/var/lib`，它可能在 1~2 秒内写出半截 SQLite 事务。

修法：KILL 分支只杀 + 释放锁，卸载统一放在 `stop_all` 末尾（那时服务已被
`stop_server`/`kill_by_scan` 收掉）。审计的意图（不留残留挂载）依然满足。

### 3.4 【中】`db_snapshot` 在 `env.sh` 缺失时整体失败

桩测试抓到的：`tar -czf ... data env.sh`，只要 `env.sh` 不存在，tar 直接非零退出 ——
用户删掉 `env.sh` 想回默认配置时，升级会变成"没有快照硬上"。
修法：按存在的路径拼参数。

### 3.5 【中】健康检查的实际触发时间与文档不符

自适应节拍把失败间隔压到 1 tick（10s），原阈值 10 次意味着 **100 秒**就重启，
而注释和 README 写的是"3~5 分钟"。这种"文档与行为脱钩"正是审计在 B18 里批评过的类型。
修法：阈值改 18 次（≈3 分钟），文档同步。

### 3.6 【低】全局变量名冲突

`port_owned_by_server` 用了 `_pid`，而 `ctl status` / `doctor` 的调用方也在用 `_pid`
（shell 没有局部变量）。虽然当前调用顺序侥幸没出事，但这属于"靠运气"的设计。
修法：这几个函数改用 `_pob_*` / `_pop_*` 前缀。

### 3.7 【低】`ctl doctor` 的挂载检查会把警告级项算成异常

`dev/zero`、`dev/random`、`resolv.conf` 都是"失败也继续"的警告级挂载，但初版把它们
算进致命项统计，导致正常设备上也会出现 ✗，让 `doctor` 失去意义。
修法：只统计 6 个致命项，`resolv.conf` 单独作为 ⚠。

---

## 4. 与审计建议的三处偏离（附理由）

### 4.1 B10：没有把 `VERSION` 改成 3.1.1/3.1.2

审计建议"把 `VERSION` 对齐到实际载荷版本"。我的判断相反：**`VERSION` 现在是诚实的**
（内置载荷确实是 3.1.0），改它才会引入真正的错误：

- `ctl update check` 拿 `current_version` 与上游比。若把 `VERSION` 改成 3.1.1，
  而载荷其实是 3.1.0，用户会永远被告知"已是最新"，**再也收不到 3.1.1 的载荷更新**；
- `customize.sh` 的"底座/载荷倒挂仲裁"以 `VERSION` 为基准，虚高会让新底座误判
  "内置更高"，把用户已经装好的在线更新层降级掉。

所以只改**表述**：`module.prop` 写明 version 是壳版本，`ctl status` 分列
「模块壳 / 服务端载荷」，README 加一段说明。问题（"看起来像装错了"）解决了，
语义没有被污染。

### 4.2 2.4：不是"对外监听即拒绝"，而是"对外 + 零鉴权才拒绝"

审计写的是「`HOST != 127.0.0.1` 且未配 `PROXY_API_KEY` 就拒绝启动」。这会**死锁**：
面板是配置 Key / 管理员的唯一入口，拒绝启动 → 进不了面板 → 永远配不上 Key。

我的判据是「对外监听 **且** 既无 `PROXY_API_KEY` **且** 无 `ADMIN_USER`」——
这时面板的首次注册对局域网完全开放，任何人都能抢先注册成管理员，
拿到的还是 chroot 内的 uid 0，这才是真正的"裸奔"。有管理员或 Key 时只记 warning。
`fatal` 文件里给了两条可操作的出路（先回环初始化 / 直接预置凭据）。

### 4.3 B18：`_ver_gt` 没有合并成一份

`customize.sh` 由 Magisk 安装器 `source` 执行。如果它 `. lib.sh` 拿 `ver_gt`，
一旦 `lib.sh` 有任何语法错误，**整个安装会失败**（dash 对 source 到的语法错误是致命的）。
安装器脚本的价值在于"永远能装上去"，不值得为了 20 行去共享代码。

改为：两份实现保持同一算法（纯 shell 逐段比较），并在 `customize.sh` 注释里写明
"刻意重复，因为安装器必须自包含"。漂移风险用注释约束，而不是用耦合换。

---

## 5. 未做项与残余风险

### 5.1 `unshare -m` 私有命名空间（审计 2.1，架构级）

不做。收益是"挂载永不泄漏"，代价是 `ctl` 从外部看不到挂载，`_have_mount` 全线失效，
需要把状态改成守护写状态文件、`ctl` 读文件 —— 这是把整个挂载子系统重写一遍，
在没有真机回归的前提下风险远大于收益。

**残余风险**：守护被 `kill -9` 时挂载会短暂泄漏到 `stop_all` 执行前（毫秒~秒级）；
`customize.sh` 的 `OLDROOT` 循环仍是"事后补救"。已用"KILL 后统一卸载"把窗口压到最小。

### 5.2 体积裁剪（审计 5.1）

不做。删 i18n / tzdata 是**不可逆的内容裁剪**，会改变"全部 IANA 时区可用"的承诺，
而且面板语言可能被用户在设置里切换。这类"省 3MB"的收益（9.77 MB → 约 7 MB）
不值得擅自砍掉上游能力。如果确实要瘦身，建议单独做一版 `-slim` 包，由你决定。

### 5.3 默认降权（审计 2.4 后半段）

不做默认开启。`AGENT2API_RUN_UID` 依赖 busybox 的 `setuidgid`，且会 `chown -R` 数据目录；
对已有安装来说，这会在升级时改变文件属主，部分 ROM 的 SELinux 会直接拒绝 ——
属于"修一个安全问题、制造三个可用性问题"。保持 opt-in，但 README 里写清了风险。

### 5.4 `module.prop` 的 `updateJson`

不加。没有可用的 `update.json` 托管地址，随便填一个 URL 会让 Magisk 的模块更新检查
一直失败（比"没有更新检查"更糟）。等你有仓库/Pages 再加，格式：
`updateJson=https://.../update.json`。

### 5.5 面板里 6 处硬编码 3065（审计 5.4）

不改。逐处看过上下文：`islands/ui.js` 的两处是 `const G9=3065` 之类的**默认端口兜底**，
`login.html` 那处是注释，`m/mobile.js` 是"连接远程网关"时的默认端口提示 ——
都不是"用当前 origin 拼 URL"的场景，改 `location.port` 反而会让远程连接场景取错端口。
且这些是上游压缩产物，改了下次 `ctl update` 覆盖 ui 就没了。

### 5.6 新增的 `AGENT2API_DATA_DIR`

只为离线桩测试存在。风险评估：`DATA` 在 source `lib.sh` 时就已求值，`env.sh` 里写这个
变量不会改变 `DATA`；能设置进程环境变量的只有 root。**但它确实扩大了一点攻击面**，
如果你不想要，删掉那一行即可（测试脚本会改用固定路径）。

### 5.7 其他已知残余

| 项 | 影响 | 备注 |
|---|---|---|
| `kill_by_scan` 最坏耗时 | 10 × `_sleep 0.5`，无小数 sleep 的 ROM 上退化为 10s | 只在有游离进程时发生 |
| `port_owner_pid` 全 /proc 扫描 | 数百次 `ls`，约 1~2s | 只在失败路径调用 |
| `notify_user --user 0` | 部分 ROM 不认该参数 | 已有无参回落，失败静默 |
| 更新预检以 root 执行不可信二进制 | 设计如此 | 已在 README「信任模型」明确 |
| 健康探测工具全缺时 | 降级为端口探测，挡不住假死 | 记一次 warning |

---

## 6. 验证证据

### 6.1 语法检查

```
customize.sh OK / service.sh OK / post-fs-data.sh OK / uninstall.sh OK
action.sh OK / bin/ctl OK / bin/lib.sh OK      （dash -n，7/7）
```

### 6.2 离线桩测试（`test/run.sh`，37 项全过）

| 用例组 | 覆盖点 | 结果 |
|---|---|---|
| rotate_log | 原路径存活、截断为 0、`.1` 完整、**持有 fd 的写入方继续写原路径**、未超限不轮转 | 5/5 |
| ver_gt | 3.10 > 3.9、v 前缀、相等、缺段补零 | 4/4 |
| gen_resolv | 3 条 nameserver、优先序、options 行、首行生成标记 | 4/4 |
| resolve_tz | 错误回落、UTC 豁免、合法保持 | 3/3 |
| lan_exposed_* | 回环、裸奔、有 Key、有管理员、显式放行 | 5/5 |
| mem/rss | 显式阈值、自动区间、存活进程、不存在 pid | 4/4 |
| prune_failed_archives | 保留 2 份、保留的是最新 | 2/2 |
| db_snapshot | 超限拒绝（**校验原因**）、正常快照、env.sh 缺失不失败 | 3/3 |
| update_extract | `../`、绝对符号链接、越界相对符号链接、正常包放行（**真实构造恶意 tar**） | 4/4 |
| proc_uptime | comm 含空格的合成 stat | 1/1 |
| load_env | 坏 env.sh 不打死调用方、好 env.sh 生效 | 2/2 |

> 说明：桩测试第一轮出现过 2 个"失败"，排查后是**测试自身的假阳性**
> （MSYS 的 `$TMPDIR` 是 `C:\...` 反斜杠路径，tar 把它当转义符，导致所有用例都失败）。
> 修正后同时给"拒绝"类用例加了**原因断言** —— 否则"因为别的原因失败"也会被算成通过，
> 这正是第一轮 `../` 用例的假阳性来源。

### 6.3 zip 校验

```
条目 645（50 目录 0755 + 9 可执行 0755 + 586 普通 0644）
module.prop  version=v3.1.2  versionCode=31200
VERSION      3.1.0（载荷真实版本，刻意不动）
CRLF 文件    0        BOM 0        可疑文件（.py/.log/.zip） 0
关键文件权限  customize.sh/service.sh/post-fs-data.sh/uninstall.sh/action.sh/
              bin/ctl/bin/lib.sh/agent2api-server/ld-linux-aarch64.so.1  全部 0755
```

### 6.4 `ctl` 烟雾测试

`status` / `doctor` / `clean` / `version` / 未知子命令 全部正常输出、无 `not found`、
退出码符合预期（`doctor` 在服务未运行时返回 1）。

---

## 7. 真机验证清单（**必做**，本报告所有结论都止步于此）

```sh
M=/data/adb/modules/agent2api

# 0. 装完先自检：应当只有"服务未运行"类提醒
sh $M/bin/ctl doctor

# 1. B1 日志轮转（最该验的一条）
echo 'AGENT2API_LOG_MAX_MB=1' >> /data/adb/agent2api/env.sh
sh $M/bin/ctl restart
sleep 300
ls -l /data/adb/agent2api/logs/          # server.log 必须始终存在；.1 不应持续增长
# 反证：修复前这里会看到 server.log 消失、.1 一路变大

# 2. B3 只读加固
grep " $M/rootfs " /proc/mounts | cut -d' ' -f4     # 期望含 ro
touch $M/rootfs/.t 2>/dev/null && echo "未加固" && rm -f $M/rootfs/.t || echo "已只读"

# 3. B4/B5 孤儿进程：运行中直接升级模块，升级前后各跑一次
for p in /proc/[0-9]*; do e=$(readlink $p/exe 2>/dev/null) || continue
  case "$e" in *agent2api-server) echo "${p#/proc/} $e";; esac; done

# 4. B8 OOM
cat /proc/$(cat /data/adb/agent2api/agent2api.pid)/oom_score_adj   # 期望 -900

# 5. B16 端口冲突：先用别的东西占住 3065 再启动
sh $M/bin/ctl stop
( busybox nc -l -p 3065 & ) ; sleep 1
sh $M/bin/ctl start ; sleep 40
cat /data/adb/agent2api/fatal        # 期望写明"端口 3065 已被 pid=xxx 占用"
sh $M/bin/ctl status

# 6. B2 卸载重装（唯一能验状态机的方式）
#    Magisk 卸载模块 → 重启 → 重新刷本 zip → 重启 → ctl status 应为"运行中"

# 7. B9 挂载泄漏：ctl stop 后应为 0
grep -c "$M/rootfs" /proc/mounts

# 8. B12 归档清理
sh $M/bin/ctl clean
```

判定标准：1/2/4/5/6/7 必须全部符合预期；任何一条不符，先看 `ctl log` 与 `ctl srvlog`。

---

## 8. 回滚方案

- 行为异常：`sh $M/bin/ctl rollback`（删更新层回内置版本）
- 壳本身有问题：重刷 v3.1.1-repo1 的 zip 即可（`/data/adb/agent2api` 不动，账号/Key/日志全保留）
- 状态被写坏（`fatal` / `disable`）：`rm -f /data/adb/agent2api/{fatal,disable}` + `ctl start`

---

*本报告基于静态审查 + 离线桩测试。所有涉及内核挂载语义、`/proc` 行为、toybox/busybox
版本差异的结论，都需要按第 7 节在真机上复核一遍才算落实。*
