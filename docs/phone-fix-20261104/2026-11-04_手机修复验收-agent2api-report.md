# Agent2API 手机插件与运行稳定性修复验收

## 1. 结果
已在连接手机完成实际修复。原来的插件启动 `No such file or directory (os error 2)` 已由新版插件真实安装及进程握手验证消除。`agent2api-providers 3.4.1` 与 `agent2api-web-providers 3.4.2` 在主动服务重启后均为 running，crashes=0、lastError=null，兼容错误为空。插件二进制与官方归档逐字节一致，平台返回 signed=true。主服务仍为 3.4.1、模块 magisk.36，本交付是该版本的本地 phonefix 构建。

[授权范围](scope.md) · [时间线](timeline.md) · [证据哈希](evidence.sha256)

## 2. 根因及修复
| Finding | 严重度 | 位置 | 机制与修复 | Evidence | 置信度 / 状态 |
|---|---|---|---|---|---|
| F01 | high 可用性 | module/libexec/plugin_spawn.c、launch.sh、plugin.sh | 新插件落地后直接 spawn，Android 缺官方 ELF 的 /lib/ld-linux-aarch64.so.1；原预扫描赶不上安装后立即启动。改为 server loader 的 --preload 同步处理受控插件 ELF，用现有 loader / libraries 启动，保留签名包字节。 | E01/E02/E03 | high / 手机已修复 |
| F02 | medium | module/libexec/common.sh、supervise.sh | supervisor 继承 KernelSU 缓存 TMPDIR；here-doc 依赖隐式临时文件。ensure_layout 校验运行 tmp 后 export TMPDIR，状态 JSON 改 printf 原子写。 | E04/E05/E07 | high 修复效果 / 原临时目录报错归因有推断 |
| F03 | high 可用性 | module/META-INF/com/google/android/update-binary | fallback 安装器 TMPD 与同 shell source 的 runtime TMPD 同名，清理指向运行目录。独立 _A2A_INSTALL_TMP，正负对照验证。 | E04/E05 | high / 本地修复，手机未执行整轮 fallback 安装 |

桥接仅由当前 glibc server 的 loader 加载，未设置全局 LD_PRELOAD；Android/bionic 子程序不会继承该 preload。受控路径经 canonical/root 边界、X_OK、ELF64LE AArch64/PT_INTERP 判断，覆盖 execve/execvp/execv/execvpe/posix_spawn/posix_spawnp；pidfd_spawnp 仅存在原 libc 符号时转发。保持 argv0、带空格参数、envp、cwd、stdio、spawn actions/attributes。

## 3. 验收
| 项目 | 结果 |
|---|---|
| 主服务 | 127.0.0.1:3065 /health status=ok；服务重启后 shim 映射存在，TMPDIR=/data/adb/agent2api/tmp |
| 两插件 | signed=true、enabled=true、entryPresent=true、updateRequired=false，两个 host running=true/crashes=0 |
| 原生六入口 | 6/6；无 shim ENOENT=2、无执行权限 EACCES=13 负对照成立 |
| 重复启动 | 顺序 spawnp 50/50，无挂起或异常退出 |
| 完整原套 | 535/535 与 19 个 shell 语法检查 |
| 追加 runtime | 6/6，集成 --full 后总 541 项行为断言 |
| 插件完整性 | providers b8b4f0d16255c3efd9794f5d69c4390a2042d72bee9ca96ce48e75501078b5d4；web 0505a5fb12503de2957df6d1e632a3fc6eff89f23c01935e379cd50394bbf165 |

providers 的公开目录主机汇总为 36 项；这是网关目录统计，不将它解读成每账号模型业务调用验收。既有更新冷却仍保留，安装走官方 /api/plugins/install，不更改数据库、backoff 或验签流程。

## 4. Evidence
| E-id | source_ref | content_hash SHA-256 |
|---|---|---|
| E01 | [bridge-smoke-test.txt](evidence/bridge-smoke-test.txt) | `66db2a107d4078a2d36432e865f5cedf856cc20edaef5e6b87745b27b2d16d38` |
| E02 | [bridge-repeat.txt](evidence/bridge-repeat.txt) | `6b7df1731b420a3ffd663e4849ea7908467217f622d07a6894d53001b17cf25b` |
| E03 | [final-phone-acceptance.json](evidence/final-phone-acceptance.json) | `c62981db03021ae4920032c80710082b54bc64d52e34938a1163601479c81422` |
| E04 | [phone-runtime-results.json](evidence/phone-runtime-results.json) | `bcb86789acb87e2f371900af2235f67c152d9f6271cc499c38a75d01472ec451` |
| E05 | [review-temp.md](evidence/review-temp.md) | `93afd8e688efad21894a5066eef5968a612646dd59aa7e57b337bf4927e15fa0` |
| E06 | [full-regression-integrated.txt](evidence/full-regression-integrated.txt) | `69a200916384c7e5587633d72e7022d6d3daf8cfa02713cacb5ec0d84d029854` |
| E07 | [stability-after-restart.txt](evidence/stability-after-restart.txt) | `b5aca5715581faffc62a00bbb5c57ded3f4528368be2f5a01f00d35f889bb8fa` |

repro_command：源码回归 `NODE_BINARY=/path/to/node sh test/run.sh --full`；单独运行 `python test/phone_runtime_test.py`。ARM64 真机 harness 源码位于 test/phone_bridge_harness.c，使用设备现有 glibc loader 的 --preload 做 E01 的六入口及正负对照；设备路径及原始 stdout 已记录在证据。需 root 与与本案一致的 ARM64 glibc 环境。

## 5. Path
- P01 / callflow：官方下载归档 → 网关官方导入 → 同步 spawn → loader-local bridge → glibc loader + plugin → JSON 协议握手 → 两 host running（F01/E01/E03）。
- P02 / callflow：ensure_layout 建立校验 tmp → export TMPDIR → supervisor printf 原子状态 → 主服务重启健康（F02/E04/E07）。
- P03 / solve：fallback 私有安装变量 → source customize 不污染安装清理目标 → 保 runtime（F03/E04/E05）。

## 6. 使用与复现
当前手机已部署，无需再次安装。其他相同布局设备可在模块管理器安装交付的 phonefix ZIP；ZIP 与补丁及 SHA 清单一起提供。本轮不改变模块版本元数据，文件名带 phonefix 以区别已发布 magisk.36。当前配置、账号及旧插件已保留，设备备份路径见 scope。

原生桥接重建：`python test/build_plugin_bridge.py --zig /path/to/zig`，固定 Zig 0.13.0、aarch64-linux-gnu.2.17。完整源码打包：`python pack.py`。shell 与桥接在手机部署时逐文件 SHA 校验。

## 7. 覆盖边界
验收包括真实插件安装/握手、服务重启，不包括整机重启或各账号真实模型转发。realpath 在 fork 后不是严格 async-signal-safe，50 次顺序测试只证明本次观察；没有宣称线程/fork 全场景证明。插件自己的二次 helper 派生不继承 shim。loader 已起而插件依赖缺失时可能表现为异步退出，不等同原生 spawn 的同步错误语义。磁盘、内存及 loopback 监听现场正常，未做无证据的资源参数调整。ATT&CK：n/a，本任务为应用兼容性及可靠性修复。
