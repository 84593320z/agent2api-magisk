# 19 项修复的逐项复测记录（2026-11-03）

对象：`module/`（v3.3.0-beta.7 / magisk.31）
夹具：`test/fix_verify.py`（可用 `A2A_MODULE` 指模块目录、`A2A_WORK` 指沙箱目录、`A2A_SH_BIN` 指 sh/awk 所在目录）
原始结果：`docs/fix-verify-2026-11-03.json`

```
== 21 passed, 0 failed ==
```

## 怎么验的

每个用例把模块**真实函数** source 进独立沙箱，只替换 Android 专有依赖：

- `/data/adb/agent2api` 一类硬编码路径 → 沙箱根（`common.sh` 里的赋值整体重定向）
- `dumpsys` / `ip` / `busybox` → `fakebin` 里的桩（可控输出）
- `curl` → 本地 HTTP 服务（`/200` `/204` `/500` 三个端点）+ 真实 curl
- 子进程存活 / 启动代次 → 探针脚本（正常进程 / 已死进程两种）
- ELF 载荷 → 手搓 ELF64 aarch64（可指定 `PT_INTERP`、可放大解释器槽）

不是"读一遍代码说改好了"：断言的是**函数返回值、文件内容、进程状态**。

## 逐项对照

| 发现 | 断言 | 结果 |
|---|---|---|
| F-001 启动 `$$` 指向已退出父进程 | `service.sh` 有 `setsid sh .../boot-start.sh`、旧括号块消失、`boot-start.sh` 存在且会 `svc_start`；独立进程里 `proc_start_ticks $$` 有值；代次取不到时加锁被拒并给出明确原因 | PASS |
| F-002 健康检查前删旧载荷 | 切换后旧目录仍在、`update.pending` 指向它；提交后旧目录删除；marker 越界路径（`/etc`）不会被删 | PASS |
| F-003 插件改写 bionic 解释器 | `/apex/com.android.runtime/bin/linker64` → `other:…` 拒绝；`/lib/ld-linux-aarch64.so.1` → 改写成模块内 `ld.so` | PASS |
| F-004 死回收卡锁 | 僵死 `reaping` 持有者 + `wait=4` → 拿到锁；活着的持有者仍礼让 | PASS |
| F-005 快速崩溃绕过熔断 | 拉起成功分支不再 `FAILS=0`；巡检分支有 120 s 门槛；8 轮快速崩溃 → 6 轮后 `GIVEUP=1`，状态序列 `backoff×3 + dead` | PASS |
| F-006 `cfg_set` 反斜杠注入 | `gateway_key=abc\nallow_no_key=1` 写入后文件只有 1 行、`allow_no_key` 未被注入、读回值原样 | PASS |
| F-007 `trap` 被清 | `svc_start` / `svc_stop` 调用前后外层 `TERM` 处理器仍然在，且触发后确实回调 | PASS |
| F-008 版本比较 | `v4.0.0-beta.2 > v3.3.0-beta.6`、`beta.10 > beta.6`、正式版 > 预发布、低版本不误判 | PASS |
| F-009 DNS 验活 | HTTP 500 → 失败；204 / 200 → 成功；`curl` 缺失 → 失败（不再假装成功） | PASS |
| F-010 IPv6 只看 main 表 | main 空、`table 1010` 有 `default` → 判定可用；命令确实走 `ip -6 route show table all` | PASS |
| F-011 非原子覆盖 + 回滚丢 search/options | 现役文件是 `mv` 换入（无 `cp` 直写）；全候选失败后原文件逐字节还原（`search` / `options` 都在） | PASS |
| F-012 `host` 与固定 `127.0.0.1` 冲突 | `::1` → `http://[::1]:port/health`；`0.0.0.0`/`*`/`::` → 回环；局域网地址 → 自身 + 回环兜底；`127.0.0.1` 不重复 | PASS |
| F-013 `keep_awake` 不释放 | `disabled` / `paused` / 熔断三条路径都调用 `release_wake`；`keep_awake=0` 时运行期也释放 | PASS |
| F-014 静态载荷被按 glibc 校验 | 无 `PT_INTERP` 的 musl 载荷通过 `payload_validate`；glibc 载荷仍要求 loader/libc；更新器不往静态载荷塞 `lib` | PASS |
| F-015 自定义镜像被忽略 | `github_mirror=https://mirror.example` → 结果以该前缀开头；非法值回退官方地址 | PASS |
| F-016 停止失败先删身份 | 杀不掉时 `server.pid` / `server.start` 保留；杀干净后才删 | PASS |
| F-017 信号后继续执行 | 收到 `TERM` 后 `rc=1` 且**没有**继续安装（`UPD_ABORT` 生效） | PASS |
| F-018 zoneinfo 丢失 | 已提交被打断 → 恢复旧目录；未提交被打断 → 旧目录回填且不误删；`post-fs-data.sh` 有 `zoneinfo.old.*` 回填 | PASS |
| F-019 unzip 双拼 | `unzip` 在 PATH → `UNZIP="unzip"`；只有 busybox → `"busybox unzip"`；绝对路径 → `"<路径> unzip"` | PASS |

## 顺带复测的两处

- `module_desc_set` 的 `sed` 替换串转义（`&` / `|` 不再被当分隔符/反向引用）
- `pack.py` 的 `relpath(...).replace` 修正后，重建 zip 里 `libexec/*`、`service.sh` 等保持 `0755`

## 没验的部分（别当已验）

- **真机**：没有在 Android 设备上跑过启动 / 守活 / 升级回滚；沙箱只证函数语义。
- **Magisk 与 KernelSU 差异**：`boot-completed.sh` 只有 KSU 触发，Magisk 侧靠 `service.sh` 里的 `setsid` 独立进程。
- **glibc 动态载荷的完整链路**（loader 试跑、`LD_LIBRARY_PATH` 下的实际链接）只在沙箱里用桩 ELF 验了判定分支。
- **在线更新走真实 GitHub**：镜像拼接与版本比较是纯函数断言，没有真下载。
