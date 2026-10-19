# Agent2API Magisk 模块 v3.1.1-repo1 审计报告

- 审计对象：`agent2api-magisk-v3.1.1-repo1-arm64.zip`（10.2 MB 压缩 / 23 MB 解压 / 645 条目）
- 上游项目：https://github.com/Agent2API/agent2api （MIT + 附加使用声明）
- 审计日期：2026-10-19
- 审计范围：模块壳（7 个 shell 脚本 + module.prop + default.env + rootfs 运行时），不含上游 Rust 服务端源码
- 前提约束：**已 root 手机常驻挂载，不得影响 Android 系统本身**

---

## 0. 结论摘要

整体质量**明显高于同类 Magisk 模块的平均水平**：数据与模块包物理分离、mount 失败分级（fail-fast）、原子 mkdir 锁、PID 身份双重校验（cmdline + exe）、热更新走「sha256 → 预检 → 快照 → 激活 → 健康验证 → 自动回滚」的完整流水线。这些设计不是随手写的。

但仍有 **3 个会导致功能实际失效的 P0 缺陷**、**6 个 P1 缺陷**，以及若干与「不影响系统」直接冲突的默认值问题。其中两个 P0 属于「看起来在工作、其实已经坏了」的类型，最难被发现。

| 级别 | 编号 | 问题 | 影响 |
|---|---|---|---|
| P0 | B1 | 日志轮转用 `mv`，写入方长期持有 fd | 首次轮转后 `server.log` 消失、`.1` **无上限增长**，可涨到数 GB 吃满 /data |
| P0 | B2 | 卸载保留 `$DATA`（含 `disable` + `.installed`） | **卸载后重装，服务永久静默不自启**，必须手动 `ctl start` |
| P0 | B3 | 单步 `mount -o bind,ro` 内核层面忽略 `MS_RDONLY` | 只读加固可能**静默失效**，且日志仍打印"已加固"，形成虚假安全感 |
| P1 | B4 | 升级时 `ctl stop` 用的是新模块路径 | 旧 server **杀不掉**（exe 路径校验不匹配），带挂载存活到重启 |
| P1 | B5 | `stop_server` 以 pidfile 身份校验为前置条件 | pidfile 丢失/损坏时**无法停止**孤儿进程，占端口后进入无限重启退避 |
| P1 | B6 | `$RESTARTS` / `last_notify` 空文件参与算术 | mksh 下算术展开报错，**可能直接打死守护进程** |
| P1 | B7 | `setsid` 失败无回退 | 守护**静默不启动**，且 `disable` 已被清掉，只能等下次开机 |
| P1 | B8 | `oom_score_adj=-1000` | 服务永不参与 OOM 回收，内存泄漏时**系统去杀别的进程**（含 system_server） |
| P1 | B9 | 全部 mount 落在全局 mount namespace | 守护被 `kill -9` 时挂载泄漏，Magisk 升级/卸载报 EBUSY |
| P2 | B10~B18 | 版本基准、IPv6 DNS 兜底、`.failed` 归档堆积、tar 路径穿越、DNS 非原子写等 | 见第 4 节 |

---

## 1. 已核验通过的项（不用改）

这些我逐项验证过，避免你在无关的地方浪费精力：

| 检查项 | 结果 |
|---|---|
| 脚本换行符 | 7 个脚本 + module.prop + default.env **全部 LF**，无 CRLF（Windows 打包最常见的致命坑，此包干净） |
| zip 内权限位 | `customize.sh`/`service.sh`/`post-fs-data.sh`/`action.sh`/`uninstall.sh`/`bin/ctl`/`bin/lib.sh` 均为 **0755**，其余 0644，正确 |
| 二进制架构 | ELF64 / little-endian / `e_machine=0xB7`（aarch64）/ 已 strip（无 `.symtab`） |
| 动态依赖 | `NEEDED` = `libgcc_s.so.1` `libm.so.6` `libc.so.6` —— rootfs 内**全部存在** |
| glibc 版本 | 二进制最高要求 `GLIBC_2.34`，rootfs 实际为 **Debian GLIBC 2.36-9+deb12u14**，余量充足 |
| 解释器路径 | `/lib/ld-linux-aarch64.so.1`，与 rootfs 内 `ld-linux-aarch64.so.1` 一致（GLIBC 2.36） |
| 不挂 `/sys` | **这是本模块最正确的决策之一**。很多 chroot 模块把 `/sys` bind 进去，一旦被带成全局只读，整机传感器/热控/充电全部异常。这里明确放弃，读不到 cgroup 就退回 `num_cpus`，代价可接受 |
| 默认监听 | `AGENT2API_HOST=127.0.0.1`，默认不对外；`ALLOW_NO_KEY` 默认关闭（fail-closed） |
| 数据隔离 | `data/` 与 `logs/` bind 进 chroot 的 `/var/lib` `/var/log`，模块包本体只读，刷模块不动数据 |
| 并发保护 | `mkdir` 原子锁 + `pid_matches`（cmdline）+ `server_pid_ok`（cmdline + exe）双重校验，PID 复用不会误杀 |
| 热更新 | sha256 → ELF 架构校验 → chroot 内 `--version` 预检 → 数据快照 → 激活 → 120s 健康验证 → 自动回滚，链路完整 |

---

## 2. 「不影响 Android 系统」专项评估

用户的核心诉求是「不能影响系统本身」。当前设计总体是**容器化**的，污染面可控，但有 4 处需要收紧。

### 2.1 全局 mount namespace（B9）

`mount_chroot` 的所有 `mount` 都直接作用于**全局命名空间**，没有 `unshare -m`。后果：

- 挂载点虽然都在 `/data/adb/modules/agent2api/rootfs/` 下（路径隔离良好），但**任何**进程都能在 `/proc/mounts` 里看到它们；
- 守护进程被 `kill -9`（`stop_supervisor` 在 15s 超时后就是这么干的）时 `trap` 不执行，**挂载全部泄漏**，直到重启；
- 泄漏状态下 Magisk 升级/卸载模块时 `rm -rf` 会 EBUSY —— `customize.sh` 里的 `OLDROOT` 卸载循环就是为这个打的补丁，但那是**事后补救**，不是根治。

**建议（架构级，可选）**：守护进程用 `unshare -m` 启动，挂载只存在于私有命名空间，进程一死内核自动回收，永远不会有 EBUSY 和泄漏。代价是 `ctl` 从外部看不到挂载，`_have_mount` 判断失效——需要把状态改为由守护进程写状态文件、`ctl` 读文件。改动量中等，收益是彻底消除「模块影响 Magisk 自身」这一类问题。

**低成本替代**：保持现状，但在 `stop_supervisor` 的 `kill -9` 分支里补一次 `umount_chroot`（见 5.9 补丁）。

### 2.2 `oom_score_adj=-1000`（B8）

`lib.sh:437` 给服务进程写了 `-1000`，即 `OOM_SCORE_ADJ_MIN`，**内核永不回收**。

这是把双刃剑：好处是内存压力下服务不被 lmkd 干掉；坏处是**一旦服务泄漏内存（SSE 长连接、请求日志缓存、连接池），内核会去杀别的进程**——包括 launcher、system_server、输入法。用户看到的是「手机莫名重启/桌面重载」，而不是「网关挂了」，极难归因。

而网关这类长驻 + 大量 SSE + 请求报表缓存的进程，恰恰是容易缓慢泄漏的类型。

**建议**：
1. `-1000` 改为 `-900`（仍在 lmkd 的 native/系统保护档之上，但极端压力下可被回收）；
2. 在守护循环里加 RSS 看门狗：超过阈值（如 512 MB 或设备 RAM 的 8%）记录并主动重启，把不可控的内核 OOM 变成可控的优雅重启。

### 2.3 tmpfs 256MB（`AGENT2API_TMPFS_SIZE`）

`mount -t tmpfs -o size=256m` 挂在 `/data/.../rootfs/tmp`。**tmpfs 占的是 RAM 不是磁盘**，上限 256 MB 意味着最坏情况多占 256 MB 物理内存。v3.1.0 是 64m，v3.1.1 提到 256m 属于过度放宽。

**建议**：默认回到 `64m`，在 README 里说明「只有跑大批量导入/导出才需要调大」。

### 2.4 chroot 内 root 权限

服务在 chroot 内以 **uid 0** 运行，且 `/data/adb/agent2api/data` 可写。虽然 rootfs 只读（如果 B3 修好），但一旦网关被攻破（面板是明文 HTTP，`HOST=0.0.0.0` 时暴露到局域网），攻击者拿到的是**整机 root**，不是应用沙箱。

模块已经提供了 `AGENT2API_RUN_UID` 降权，但标注「实验性」且依赖 busybox 的 `setuidgid`，默认不开。

**建议**：
- 把降权从「实验性」提升为「推荐」，默认 uid 用 `2000`（shell）或专门的 `10000`；
- 至少做到：当 `AGENT2API_HOST != 127.0.0.1` 时，若未配置 `AGENT2API_PROXY_API_KEY`，**拒绝启动**并在日志里说明原因（现在只是默认 fail-closed 拒绝 `/v1/*`，面板本身仍暴露）。

---

## 3. P0 缺陷详述

### B1 · 日志轮转从第二次开始就永久失效

**位置**：`bin/lib.sh:95-100`（`rotate_log`）+ `service.sh:450`（`>> "$SRVLOG"`）+ `service.sh:109-111, 155-156`

```sh
rotate_log() {
  [ -f "$1" ] || return 0
  _sz=$(wc -c < "$1" 2>/dev/null || echo 0)
  [ "${_sz:-0}" -gt "$2" ] && mv -f "$1" "$1.1" 2>/dev/null
  return 0
}
```

**失效链路**：

1. `start_server` 用 `) </dev/null >> "$SRVLOG" 2>&1 &` 启动服务，**这个 fd 由子进程继承并长期持有**；
2. 第一次超过 16 MB，`mv server.log server.log.1` —— inode 被改名，**服务继续往同一个 inode 追加**，也就是继续写 `server.log.1`；
3. `server.log` 这个路径**已经不存在了**；
4. 下一次 `rotate_log` 执行 `[ -f "$SRVLOG" ] || return 0` —— 直接返回；
5. 于是 `server.log.1` 以服务写入的速度无限增长，直到下一次服务重启（重启时才重新创建 `server.log`）。

`app.log` 同理：如果上游用常驻 appender（tracing/log4rs 的默认行为就是持有 fd），也会中招。`module.log` 不受影响，因为 `log()` 每次都是 `>>` 重新打开。

**后果**：手机连续运行几周，`/data/adb/agent2api/logs/server.log.1` 可以涨到几个 GB，吃满 `/data` 后引发**整机级**故障（相机存不了照片、应用无法更新）。这已经超出「模块自身」范畴，属于会影响系统的缺陷。

**修复**（copytruncate，写入方 fd 保持有效）：

```sh
rotate_log() {
  [ -f "$1" ] || return 0
  _sz=$(wc -c < "$1" 2>/dev/null || echo 0)
  [ "${_sz:-0}" -gt "$2" ] || return 0
  # 不能 mv：server.log 的 fd 由服务继承并长期持有，app.log 多半也是常驻 appender。
  # mv 之后写入方继续写 .1，且原路径消失 → 下一轮 [ -f ] 直接返回，轮转永久失效。
  # 用 copy + 原地截断：inode 不变，写入方 fd 继续有效，体积立刻归零。
  cp -f "$1" "$1.1" 2>/dev/null && : > "$1" 2>/dev/null
  return 0
}
```

**验证方法**（真机）：

```sh
# 把上限调到 1MB，跑一会观察
echo 'AGENT2API_LOG_MAX_MB=1' >> /data/adb/agent2api/env.sh
sh /data/adb/modules/agent2api/bin/ctl restart
sleep 300
ls -l /data/adb/agent2api/logs/     # 修好后 server.log 应该始终存在且体积回落
```

---

### B2 · 卸载后重装，服务永久静默不自启

**位置**：`uninstall.sh:6` + `customize.sh:28-30, 52`

**失效链路**：

1. `uninstall.sh` → `stop_all` → `touch "$DATA/disable"`；
2. 卸载**故意保留** `/data/adb/agent2api`（含 `data/`、`env.sh`、`disable`、`.installed`）；
3. 用户重装同一个模块 → `customize.sh` 判断 `MARKER=/data/adb/agent2api/.installed` **仍存在** → `FRESH=0`；
4. `_WAS_RUNNING` 检测的是 supervisor 进程，此时当然没有 → `0`；
5. `{ [ "$FRESH" = "1" ] || [ "$_WAS_RUNNING" = "1" ]; } && rm -f disable` → **条件不成立，`disable` 留着**；
6. 重启后 `service.sh` 正常拉起守护，守护循环第一行 `[ -f "$DATA/disable" ]` → 立即退出。

**现象**：模块显示「已安装」、`ctl status` 显示「服务：未运行 / 守护：未运行」、`module.log` 里只有一行「检测到 disable 标记，守护进程退出」。用户完全不知道为什么，重刷模块、重启都没用，必须手动 `ctl start`。

这是一个**纯状态机设计漏洞**：`FRESH` 的语义被写成了「这个数据目录有没有被初始化过」，但真正需要的是「这次是不是一次全新安装（而不是升级）」。

**修复**（两处都建议改，互为兜底）：

```sh
# customize.sh，替换原来的 FRESH 判定
MARKER=/data/adb/agent2api/.installed
FRESH=1
[ -f "$MARKER" ] && FRESH=0
# 卸载后 $DATA 会被保留（含 disable 与 .installed），此时重装 FRESH 会被误判为 0，
# 导致 disable 残留、服务永远不自启。模块目录不存在 = 全新安装（不是升级）。
[ -d /data/adb/modules/agent2api ] || FRESH=1
```

```sh
# uninstall.sh，语义上更干净：模块都没了，"已安装"标记就不该留
stop_all
release_supervisor_lock
rm -f "$DATA/disable" "$DATA/.installed" 2>/dev/null
```

---

### B3 · rootfs 只读加固可能静默失效

**位置**：`bin/lib.sh:282-291`

```sh
if ! mount -o bind,ro "$ROOT" "$ROOT" 2>/dev/null; then
  if mount -o bind "$ROOT" "$ROOT" 2>/dev/null; then
    mount -o remount,bind,ro "$ROOT" "$ROOT" 2>/dev/null || \
      log "warning: rootfs 只读加固失败（remount 失败，继续，风险=可写二进制）"
  else
    log "warning: rootfs 只读加固失败（bind 失败，继续，风险=可写二进制）"
  fi
fi
```

**问题**：Linux 的 `mount(2)` 在**同一次调用**里同时带 `MS_BIND | MS_RDONLY` 时，`MS_RDONLY` 会被**忽略**（只读 bind 必须由 `MS_REMOUNT | MS_BIND | MS_RDONLY` 二次调用生效）。util-linux 的 `mount -o bind,ro` 是用户态自己拆成两次 syscall 才实现只读的。

Android 上的 `mount` 是 **toybox**，不同版本行为不一致：
- 如果该版本 toybox 不自行拆分 → `mount -o bind,ro` **返回 0（成功）**，但实际**仍是可写**；
- 于是 `if !` 分支不进入，**两步兜底根本不会执行，也不会有任何 warning**；
- 日志里只会看到 `rootfs 只读加固` 的正面描述，形成**虚假安全感**。

**修复**：直接走确定有效的两步法，并在挂载后做一次**写测试**（只读挂载对 root 也是 EROFS，写测试是唯一可靠的判据）：

```sh
if ! _have_mount "$ROOT"; then
  if mount -o bind "$ROOT" "$ROOT" 2>/dev/null; then
    mount -o remount,bind,ro "$ROOT" "$ROOT" 2>/dev/null || \
      log "warning: rootfs remount,ro 失败（继续，风险=二进制可写）"
  else
    log "warning: rootfs bind 失败（继续，风险=二进制可写）"
  fi
  # 写测试：只读挂载连 root 都写不进去，这是唯一可靠的验证
  if : > "$ROOT/.rotest" 2>/dev/null; then
    rm -f "$ROOT/.rotest" 2>/dev/null
    log "warning: rootfs 仍可写 —— 只读加固未生效（toybox mount 忽略 bind,ro）"
  else
    log "rootfs 只读加固已生效"
  fi
fi
```

**验证方法**：

```sh
grep rootfs /proc/mounts          # 看第 4 字段是否含 ro
touch /data/adb/modules/agent2api/rootfs/x && echo "没加固" || echo "已只读"
```

---

## 4. P1 / P2 缺陷

### B4 · 升级模块时旧服务根本没被停掉

`customize.sh:48-51` 执行的是 `sh "$MODPATH/bin/ctl" stop`，而安装期的 `$MODPATH` 是 **`/data/adb/modules_update/agent2api`**（Magisk 的暂存目录），于是 `lib.sh` 里的 `$ROOT` 指向**新**的 rootfs。

`stop_server` → `is_running` → `server_pid_ok` → `readlink /proc/<pid>/exe` 必须匹配 `$ROOT/opt/agent2api/*`。旧服务的 exe 在 `/data/adb/modules/agent2api/rootfs/...`，**永远匹配不上**，于是 `is_running` 返回 false，`stop_server` 直接 `rm -f "$PIDFILE"` 走人 —— **旧 server 进程原地存活**。

`stop_supervisor` 没事（它按 cmdline 匹配，与路径无关），所以守护死了、服务活着，是个很难察觉的**半停状态**：

- 旧服务继续占着 3065 端口、继续写 SQLite；
- `OLDROOT` 卸载循环遇到 busy，退化成 `umount -l`（lazy），Magisk 随后 `rm -rf` 成功；
- 旧服务的 `/opt/agent2api/ui` 和数据库 bind 被抽走，它会在一个残缺的根里继续跑，直到重启。

**修复**：加一个不依赖路径的兜底清理，并在 `stop_server` 里也用它。

```sh
# 兜底：按 exe 特征扫描（不依赖 pidfile、不依赖 $ROOT 路径，跨模块目录版本都能命中）
kill_by_scan() {
  for _p in /proc/[0-9]*; do
    _q=${_p#/proc/}
    [ "$_q" = "$$" ] && continue
    _exe=$(readlink "$_p/exe" 2>/dev/null) || continue
    case "$_exe" in
      */rootfs/opt/agent2api/agent2api-server)
        log "scan: 发现游离 server pid=$_q（$_exe），终止"
        kill -TERM "$_q" 2>/dev/null
        ;;
    esac
  done
  _sleep 2
  for _p in /proc/[0-9]*; do
    _q=${_p#/proc/}
    _exe=$(readlink "$_p/exe" 2>/dev/null) || continue
    case "$_exe" in
      */rootfs/opt/agent2api/agent2api-server) kill -9 "$_q" 2>/dev/null ;;
    esac
  done
}
```

调用点：`stop_all` 末尾加一次 `kill_by_scan`（成本 < 10 ms，收益是彻底消灭孤儿进程）。

### B5 · pidfile 丢失后无法停止服务

`stop_server:458`：`is_running || { rm -f "$PIDFILE"; return 0; }`。

如果 pidfile 被误删、`/data` 被清理工具动过、或 exe 路径因挂载变化读不出来，`is_running` 为假 → 直接返回，**孤儿进程活着**。之后 `ctl start` 拉起新守护 → 新服务 bind 3065 失败 → 退出 → 退避重启，无限循环，`ctl stop` 也停不掉。

修 B4 的 `kill_by_scan` 同时解决这一条（在 `is_running` 为假的分支里调一次）。

### B6 · 空文件让算术展开报错

`service.sh:191-192`：

```sh
_rs=$(cat "$RESTARTS" 2>/dev/null || echo 0)
echo $((_rs + 1)) > "$RESTARTS" 2>/dev/null
```

如果 `$RESTARTS` 存在但为**空文件**（`cat` 成功、输出空串、`||` 不触发），`_rs=""`，展开成 `$(( + 1))` → mksh 报 `bad number`。mksh 在非交互模式下对算术语法错误是**致命**的，守护进程会直接退出，且没有任何日志（因为 `log` 在下一行）。

`lib.sh:566-567` 的 `notify_user` 同样：

```sh
_last=$(cat "$DATA/last_notify" 2>/dev/null || echo 0)
[ "$((_now - _last))" -lt 3600 ] && return 0
```

**修复**：

```sh
_rs=$(cat "$RESTARTS" 2>/dev/null | tr -dc '0-9')
[ -n "$_rs" ] || _rs=0
_last=$(cat "$DATA/last_notify" 2>/dev/null | tr -dc '0-9')
[ -n "$_last" ] || _last=0
```

### B7 · `setsid` 失败没有回退，守护静默不启动

`lib.sh:499-507`：

```sh
if command -v setsid >/dev/null 2>&1; then
  setsid "$@" </dev/null >/dev/null 2>&1 &
```

`setsid(2)` 在调用者**已经是进程组组长**时返回 `EPERM`，toybox 的 `setsid` 会 `perror_exit` 直接退出，**不会 exec 目标程序**。此时：

- 守护没起来；
- `spawn_detached` 的退出码被丢弃，调用方不知道；
- `action.sh` / `ctl restart` 已经把 `$DATA/disable` 删了，所以连「下次开机自动恢复」都要等重启。

`ctl restart` 有 `supervisor_running` 轮询会打印「重启失败」，但 `action.sh` 和 `customize.sh` 里没有。

**修复**：`spawn_supervisor` 里加存活确认 + 无 setsid 兜底：

```sh
spawn_supervisor() {
  spawn_detached "$MODDIR/service.sh"
  _i=0
  while [ "$_i" -lt 5 ]; do
    supervisor_running && return 0
    _sleep 1; _i=$((_i + 1))
  done
  # setsid 可能因 EPERM 失败（调用者已是进程组组长），裸后台再拉一次；
  # 双重拉起由 mkdir 原子锁兜住，不会产生两个守护。
  log "warning: setsid 拉起守护失败，改用裸后台重试"
  "$MODDIR/service.sh" </dev/null >/dev/null 2>&1 &
  return 0
}
```

### B8 · `oom_score_adj=-1000`

见 2.2。改 `-900` + RSS 看门狗。

### B9 · 全局 mount namespace

见 2.1。至少补 `kill -9` 分支的 `umount_chroot`。

### B10 · `VERSION` 与 `module.prop` 版本不一致

- `module.prop`：`version=v3.1.1-repo1`，`versionCode=31101`
- `rootfs/opt/agent2api/VERSION`：**`3.1.0`**

`base_version()` 返回 `3.1.0`，所以：

- `ctl status` 显示「服务端：3.1.0」——如果内置载荷确实是 3.1.0，这没问题，但**容易让人以为装错了**；
- `ctl update check` 会把上游 3.1.1 报成「发现新版本」，然后下载一个和模块同版本号的载荷（无害，但会让人困惑）；
- `customize.sh` 的「底座/载荷倒挂仲裁」以 3.1.0 为基准判断，如果哪天发了 v3.1.1 的模块但载荷仍是 3.1.0，仲裁逻辑会误判。

**建议**：把 `VERSION` 对齐到实际载荷版本，并在 `module.prop` 的 description 里区分「模块壳版本」与「载荷版本」。如果载荷确实就是 3.1.0，那 `customize.sh:102` 的 `ui_print "- v3.1.1：..."` 也应说明这是壳的版本。

### B11 · IPv6 DNS 兜底永远落在第 4 位（无效）

`lib.sh:240-242`：

```sh
if ! grep -q '^nameserver.*:' "$_rf" && [ "$(grep -c '^nameserver' "$_rf")" -lt 5 ]; then
  _add_ns 2400:3200::1
fi
```

glibc 的 `MAXNS=3`，只消费**前 3 个** nameserver。而这段逻辑是在已经补满 3 个 IPv4 兜底之后**追加**，所以 `2400:3200::1` 永远排在第 4 位，**永远不会被 glibc 使用**。注释里写「IPv6 兜底」，实际是死代码。

真正需要它的场景是 **IPv6-only 网络**：此时 `dumpsys` 大概率能拿到 v6 DNS，轮不到这条兜底；但如果 `dumpsys` 被 SELinux 挡住、props 又为空，就会走到「3 个 IPv4 公网 DNS + 第 4 个 v6」——在纯 v6 网络里全部不可达。

**建议**：要么删掉（承认它是装饰），要么改成「检测到默认路由是 v6 时，把 v6 DNS 插到第 1 位」。

### B12 · 更新层归档堆积

`lib.sh:763` 的 `$UPDDIR.old` 有清理（每次激活前 `rm -rf`），但 `lib.sh:796` 的 `$UPDDIR.failed.<ts>` **只增不减**，每次回滚留一份 12 MB 二进制 + 6 MB ui。连续失败几次就是几十 MB。`ctl status` 只会提示「存在回滚归档（可手动清理）」，没有 `ctl clean`。

**建议**：加 `ctl clean [keep]`，默认只保留最近 2 份 `.failed.*`。

### B13 · 安全模型：sha256 与包同源，防不了投毒

`fetch_to` 下载 `pkg.tar.gz` 和 `pkg.tar.gz.sha256` 来自**同一个 URL 前缀**（同一个仓库/镜像）。这意味着 sha256 只能防传输损坏，**防不了恶意仓库或恶意镜像**。而 `update_preflight` 会以 **root** 在 chroot 内**执行**这个二进制来跑 `--version`——即在任何签名校验之前就执行了不可信代码。

叠加 `AGENT2API_REPO`（可指向任意 fork）和 `AGENT2API_UPDATE_ALLOW_UNVERIFIED=1`，这实际上是一条**设计上的 root RCE 通道**。对 root 模块来说可以接受（用户自己选的），但应当明确写在 README 里，而不是只在注释里说「sha256 校验」。

另外 `update_extract` 用 `tar -xzf` 以 root 解包**未校验**的包，`tar` 的路径穿越（`../../`）可写任意位置。建议解包后校验所有条目都在 `$_xdir` 下（busybox tar 的 `-C` 不防穿越）。

### B14 · `proc_uptime` 解析 `/proc/<pid>/stat` 不稳

`bin/ctl:17`：`set -- $(cat "/proc/$1/stat")`。`stat` 的第 2 字段是 `(comm)`，**comm 里可以有空格和括号**，一旦出现，后续字段全部错位，`${22}` 取到的不是 `starttime`，算出来的 uptime 会是天文数字或负数。

`agent2api-server` 的 comm 是 `agent2api-serve`（15 字符截断）没有空格，所以现在能跑。但这是**靠运气**，不是靠设计。正确做法是 `sed 's/.*) //'` 先剥掉前两字段：

```sh
_st=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20)
```

（剥掉 `pid (comm) ` 之后，`state` 变成第 1 个字段，`starttime` 是原第 22 → 新第 20。）

### B15 · `resolv.conf` 非原子写

`gen_resolv` 用 `: > "$_rf"` 清空再逐行追加。如果服务正在 `getaddrinfo`，可能读到「只有注释行」的空文件 → 一次 DNS 失败。因为是 bind 挂载，**不能用 rename 替换**（会断掉 bind），只能原地写。建议先在内存拼好，再一次 `printf` 写入（单次 write 仍有窗口但小得多），或者接受这个毫秒级窗口并在 README 说明。

### B16 · 端口被占时无限退避，无明确诊断

3065 被别的应用占用时，服务 bind 失败退出 → `fails` 累加 → 30s/120s 退避，**永不停止**，每小时一条通知。日志里只有 `rc=1`，没有「端口被占用」的判断。

**建议**：启动失败后检查 `port_listening && ! port_owned_by_server`，命中就写 `$FATALFILE` 并停止重试，`ctl status` 直接显示「3065 被 <pid> 占用」。

### B17 · 缺少 `/etc/localtime`

rootfs 有完整 tzdata（342 个文件 / 1.1 MB），但没有 `/etc/localtime`。`TZ=Asia/Shanghai` 生效时没问题；一旦用户把 `TZ_NAME` 写错（比如 `Asia/Shanghia`），chrono 会退回 `/etc/localtime` → 不存在 → **静默变 UTC**，报表时间全错 8 小时。

**建议**：在 `customize.sh` 里 `ln -sf /usr/share/zoneinfo/Asia/Shanghai "$MODPATH/rootfs/etc/localtime"`，并在 `service.sh` 里校验 `[ -f "$ROOT/usr/share/zoneinfo/$TZ_NAME" ]`，不存在就记 warning 并回落 `Asia/Shanghai`。

### B18 · 其他小问题

| 位置 | 问题 |
|---|---|
| `lib.sh:566` | `notify_user` 在部分 ROM 需要 `cmd notification post --user 0`，否则静默失败（当前失败即静默，无感） |
| `lib.sh:549-552` | `HEALTH_WGET` 首次探测若 busybox 不可用会缓存成 `wget`，之后即使 busybox 出现也不再重试 |
| `lib.sh:178` | `_tick % 360` 的「每小时」依赖 `POLL_SECS=10`；用户改成 5 就变 30 分钟，注释与行为脱钩 |
| `lib.sh:750` | `db_snapshot` 对 `data/` 全量 tar，无大小上限、无超时；请求日志积累到几百 MB 时 `ctl update` 会卡在「停止服务并快照数据 ...」很久 |
| `lib.sh:688` | `find "$_xdir" -type f -name agent2api-server` 不校验是否唯一，包内若有多个同名文件取第一个 |
| `customize.sh:56` | `_ver_gt` 与 `lib.sh:581` 的 `ver_gt` 是两份独立实现（一份 sed 一份 awk），行为可能漂移，建议合并 |
| `service.sh:185` | `up < 20` 才算快退，但冷启动慢的机器上正常重启也可能 < 20s，会误计一次「崩溃」 |
| `module.prop` | 缺 `updateJson`，Magisk 无法检查模块壳自身的更新 |

---

## 5. 优化建议（非缺陷）

### 5.1 体积

解压后 23 MB，分布：二进制 12 MB（已 strip，Rust 正常水平）、ui 6.1 MB、glibc 3.2 MB、tzdata 1.1 MB。

- **ui 6.1 MB 里 i18n 占 2.3 MB**（6 种语言 × 19 个文件）。手机端实际只需要 `zh-Hans` + 一种兜底，`en/ja/ko/pt-BR/zh-Hant` 可按需裁剪，直接省 1.9 MB；
- **tzdata 1.1 MB / 342 文件**：只保留 `Asia/Shanghai`、`Asia/Taipei`、`UTC` + `posixrules`，可省约 1 MB，但要同步改 README（现在写的是「全部 IANA 区名可用」）；
- `islands/` 1.4 MB 是上游的独立组件包，确认面板用得到再留。

省 3 MB 对 `/data` 意义不大，但对**模块 zip 的下载成功率**（国内直连 GitHub）有意义。

### 5.2 健康检查自适应

现在固定「每 2 tick 探一次」。可以按状态调整：连续成功 → 退到每 6 tick；一旦失败 → 回到每 1 tick 快速确认。既省电又更快发现假死。

### 5.3 增加 `ctl doctor`

一键自检，把现在散落在各处的判断收拢：

```
ctl doctor
  ✓ rootfs 只读加固：已生效
  ✓ 挂载：proc/dev/resolv/tmpfs/data/logs 全部就位（9/9）
  ✓ 端口 3065：本服务持有
  ✓ /health：200 (12ms)
  ✓ glibc：2.36，二进制要求 ≤2.34
  ✓ 磁盘：/data 剩余 42.1 GB，日志占用 18 MB
  ⚠ 内存：RSS 412 MB（阈值 512 MB）
  ⚠ 更新层 .failed 归档 3 份，占用 54 MB（ctl clean）
```

### 5.4 面板侧

`login.html` / `m/mobile.js` / `islands/ui.js` 里仍有硬编码 `3065`（共 6 处）。改端口后这些地方会指向错误地址。建议统一读 `location.port`。

---

## 6. 修复优先级建议

| 顺序 | 内容 | 工作量 | 理由 |
|---|---|---|---|
| 1 | B1 日志轮转改 copytruncate | 3 行 | 唯一会导致**整机**故障（/data 写满）的缺陷 |
| 2 | B2 重装不自启 | 2 行 | 用户 100% 会遇到，且完全无法自行诊断 |
| 3 | B3 只读加固 + 写测试 | 8 行 | 安全承诺与实际不符 |
| 4 | B4/B5 `kill_by_scan` | 15 行 | 消灭孤儿进程，同时修好升级与 pidfile 丢失两个场景 |
| 5 | B8 `oom_score_adj` 改 -900 + RSS 看门狗 | 20 行 | 直接对应「不影响系统」 |
| 6 | B6/B7 算术加固 + setsid 回退 | 10 行 | 低成本消灭两个静默失败 |
| 7 | B12 `ctl clean` + B16 端口冲突诊断 | 30 行 | 可观测性 |
| 8 | B10/B11/B17 版本与 DNS 一致性 | 10 行 | 正确性收尾 |
| 9 | 2.1 `unshare -m` 私有命名空间 | 较大 | 架构级，可延后 |

---

## 7. 附录：真机验证清单

按顺序执行，每条都能独立确认一个结论：

```sh
M=/data/adb/modules/agent2api

# 1. 换行符 / 权限（应全为 LF，脚本 0755）
file $M/*.sh $M/bin/*

# 2. 只读加固是否真的生效（B3）
grep " $M/rootfs " /proc/mounts        # 第 4 字段应含 ro
touch $M/rootfs/.t 2>/dev/null && echo "未加固" && rm -f $M/rootfs/.t || echo "已只读"

# 3. 日志轮转（B1）：把上限压到 1MB，跑 5 分钟后看 server.log 是否还在
grep LOG_MAX $M/../agent2api/env.sh
ls -l /data/adb/agent2api/logs/

# 4. 卸载重装（B2）：卸载 → 重装 → 重启 → ctl status
grep -c disable /data/adb/agent2api/env.sh 2>/dev/null; ls /data/adb/agent2api/disable

# 5. 孤儿进程（B4）：升级模块前后各跑一次
for p in /proc/[0-9]*; do
  e=$(readlink $p/exe 2>/dev/null) || continue
  case "$e" in *agent2api-server) echo "${p#/proc/} $e";; esac
done

# 6. OOM 保护（B8）
cat /proc/$(cat /data/adb/agent2api/agent2api.pid)/oom_score_adj

# 7. 挂载是否泄漏（B9）
grep -c "$M/rootfs" /proc/mounts       # 服务停止后应为 0

# 8. 内存与日志占用
du -sh /data/adb/agent2api/*
```

---

*报告基于静态审计 + 二进制解析。标注「需实测确认」的项（主要是 toybox 对 `bind,ro` 的处理）已在 B3 给出验证命令。*
