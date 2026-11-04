# 2026-11-04 Agent2API 临时目录与插件启动修复独立评审

## 结论

本轮仅只读审查生产副本；新增本评审与独立测试脚本，未运行 ADB、未写手机、未修改生产文件。已加载 `code-audit` 及 `docs-generator`，并读取真实 skill 目录的代码审计指导及 Evidence→Finding→Path 约定；文档 flavor=null。修复副本的 TMPDIR 归一化、status JSON printf、fallback 安装临时变量隔离三处改动符合根因。初次 Python→MSYS 子进程动态回归被宿主启动权限错误阻断；静态生产契约通过。后续父代理运行暴露的 awk 正则报错已定位为 Windows `sh -c` 命令参数的反斜杠传输问题，而非生产 json_escape 缺陷；原生产函数以真实 LF 脚本运行的字节输出验证通过。完整回归改真实文件执行/source 后，父代理复跑退出0；本代理已读取 [phone-runtime-results.json](<phone-runtime-results.json>) 核对最终 **6 PASS、0 FAIL、0 BLOCKED**，四份生产源哈希一致。

## 范围与证据

- 发布基线：[模块源码](<../upgrade-3.4.1/module>)、[supervisor 既有日志](<../phone-plugin-diagnosis/supervisor.txt>)。
- 修复副本：[common.sh](<../phone-repair/module/libexec/common.sh>)、[supervise.sh](<../phone-repair/module/libexec/supervise.sh>)、[launch.sh](<../phone-repair/module/libexec/launch.sh>)、[fallback 安装器](<../phone-repair/module/META-INF/com/google/android/update-binary>)、[plugin_spawn.c](<../phone-repair/module/libexec/plugin_spawn.c>)。
- 独立测试：[phone_runtime_test.py](<../phone-repair/test/phone_runtime_test.py>)。测试仅读取生产代码；执行时抽取目标函数与赋值片段，rm/chmod 等操作使用 shell mock，不执行完整安装器。
- 现场 `/proc/supervisor/environ` 的 `TMPDIR=/data/user/0/me.weishu.kernelsu/cache` 是父代理提供的当前取证，本代理未连接手机核验。

### E-001：日志时序与直接临时文件使用点

- source_type: log + file；observed_at: 2026-11-04；linked_workitem: 临时目录根因。
- [supervisor.txt:142–155](<../phone-plugin-diagnosis/supervisor.txt#L142-L155>)：首次健康启动后两次 `can't create temporary file : No such file or directory`，退出时再出现一次。
- 发布 [supervise.sh:169–186](<../upgrade-3.4.1/module/libexec/supervise.sh#L169-L186>) 的 status_json_write 使用 `cat <<EOF`；健康后 write_state、巡检 write_state、cleanup write_state stopped 都调用它。当前物理第 660 行是 continue，不能把 mksh 函数执行报错的 `[660]` 当成直接创建临时文件的操作行。
- 发布 [common.sh:114–125](<../upgrade-3.4.1/module/libexec/common.sh#L114-L125>) 只创建 TMPD；[control.sh:159–163](<../upgrade-3.4.1/module/libexec/control.sh#L159-L163>) 直接继承外层环境拉起 supervisor。[launch.sh:120](<../upgrade-3.4.1/module/libexec/launch.sh#L120>) 的 TMPDIR 仅在 server 子进程生效。
- content_hash: 基线 common=150823b160aa69854d1d7d1f3c3c4f5ed5af921cae8fceb4fda67309c1667e46；基线 supervise=935b2f462d8ee27a75289456d21aa483cece1c0a31269e0bb55690bd94386132。

### E-002：DNS header here-doc 假设的反证

- source_type: file；status: observed；supersedes: none。
- 发布源码和发布 ZIP 的 DNS header 均由 [dns.sh:625](<../upgrade-3.4.1/module/libexec/dns.sh#L625>)、[dns.sh:725](<../upgrade-3.4.1/module/libexec/dns.sh#L725>) 的 sed 读取。DNS 文件没有 here-doc。lastgood/cache 写入由 printf/awk 完成。
- [common.sh:952](<../upgrade-3.4.1/module/libexec/common.sh#L952>) 仅删除 TMPD 子项；[payload.sh:768–773](<../upgrade-3.4.1/module/libexec/payload.sh#L768-L773>) 仅删除受约束 payload 旧目录；日志首次报错早于事务提交日志。故不能归因于“提交日志后清掉 TMPDIR”，也不能将空 lastgood identity 直接解释为 DNS header here-doc 失败。

### E-003：fallback 同 shell 变量冲突

- source_type: file；linked_workitem: 安装清理生命周期。
- 发布 [update-binary:67](<../upgrade-3.4.1/module/META-INF/com/google/android/update-binary#L67>) 把 TMPD 用作安装解包目录，97 导出 TMPDIR，130 同 shell source customize；[customize.sh:20](<../upgrade-3.4.1/module/customize.sh#L20>) 与 common 重赋 TMPD 为持久 runtime tmp；返回 [update-binary:133](<../upgrade-3.4.1/module/META-INF/com/google/android/update-binary#L133>) 后 `rm -rf "$TMPD"` 删除错误目录。
- 修复改为 `_A2A_INSTALL_TMP`，最终清理也指向它；曾发现修复中间态把 TMPDIR 误替换成 `_A2A_INSTALL_TMPIR`，已通知父代理且当前修复版97行恢复 `export TMPDIR="$_A2A_INSTALL_TMP"`。

### E-004：回归脚本和宿主执行结果

- source_type: command；linked_workitem: 独立回归。
- Python AST 语法校验及完整 json_escape 抽取校验：PASS（不写 pyc）。
- 初次完整运行：五个动态用例在任何测试命令执行前均遇到宿主 MSYS shell 启动失败，返回码 3221225794。错误原文：

```text
*** fatal error - NtCreateDirectoryObject(\BaseNamedObjects\msys-2.0S5-55a3fba83ad08e1d): 0xC0000022
```

- 未通过改 shell 绕过权限；脚本已新增单次 preflight，并将启动失败报告为 BLOCKED 而不是断言 FAIL，避免重复启动失败进程。
- 历史 `--static-only` 结果：1 PASS、0 FAIL、5 BLOCKED；脚本退出码2表示存在未执行动态项。**最终父代理完整回归：退出0，6 PASS、0 FAIL、0 BLOCKED**；见 [phone-runtime-results.json](<phone-runtime-results.json>)，本代理已逐项读取核对。
- 静态契约覆盖：status 无 heredoc、ensure_layout 在目录可用检查后导出持久 TMPDIR、fallback 导出 TMPDIR 名称正确且最终清理不再引用 TMPD。
- 动态用例覆盖：原生产 printf 的 running/running-unverified/stopped JSON、引号/反斜杠/换行/tab 转义、坏 TMPDIR；ensure_layout 改写并对子进程 export；无效 TMPD 返回1；同 shell source 精确赋值片段后的安装清理；旧行为负对照。
- 父代理后续执行初版出现三个 FAIL：status awk `gsub(/\/, "\\\\")` 的 `unterminated regexp`，以及两处 `/dev/stdin` 不存在。独立提取原生产函数写真实 LF [inspect-json-escape.sh](<review/inspect-json-escape.sh>) 并由 sh 文件参数执行，三个输出的十六进制分别为：反斜杠输入 `61 5c 5c 62`、双引号输入 `61 5c 22 62`、换行输入 `61 5c 6e 62`；证明原函数正确。原158行 regex 反斜杠2个、replacement4个，159行 quote replacement3个。直接 inline 命令复现错误，故属于传输层二次转义。新版 run() 写 LF case.sh 再执行；fallback source 真正赋值 fixture，不依赖 /dev/stdin。两类临时文件均限定 review scratch，退出清理。
- 父代理另行反馈：真机六个 spawn/exec 入口、argv0/空格/env/stdio/chdir 均通过；无 shim 的 ENOENT=2 与 chmod0644 的 EACCES=13 负对照通过；server 健康且映射 shim，supervisor TMPDIR 正常。这些为父代理运行结果，本代理未连接手机复测。
- 测试源哈希：common=194f657878dbaaa3f789a6ee18a5d19ee3cdb48d60da1f228b5fca1ba04e1e56；supervise=a593939393bee87316656e2c62d636018dd8b5028a93d507ea218b8937dec4e4；fallback=c0b91dcfbca346249c202e9f8cb48275c3816aeb17e6ed30581ed4e18fa4d9ce；customize=63ec14190495593f2b56883fcdd0f888e1c41f155896ac378d4d2b90334bc421。

## Finding

### F-001：运行期依赖管理器 cache（高置信、validated 静态数据流）

- severity: medium；category: design；evidence_ids: E-001。
- Path：管理器安装/启动上下文 → control setsid supervisor → supervisor 继承 TMPDIR → status_json_write mksh here-doc 隐式文件创建。
- 修复副本 ensure_layout 内检查 TMPD 存在/可写后 export，且 status printf 消除该隐式文件依赖，改动正确。
- 仍需明确：ENOENT 证明实际使用目录路径在报错时不可用，但已有日志未识别删除者；不能声称“DNS 清理删 KSU cache”。ensure_layout 的 return1 在部分调用点未检查，目录异常时仍可能继续，应由入口显式处理失败。

### F-002：fallback 清理删持久 tmp（高置信、validated 静态数据流）

- severity: medium；category: other；evidence_ids: E-003。
- Path：安装 TMPD → source customize → 同名 TMPD 被重赋 → 返回安装器清理 runtime TMPD。
- `_A2A_INSTALL_TMP` 修复切断冲突；这是与本次 KSU App cache 分开的真实清理问题。

### F-003：C 插件桥接审查（candidate，按修订持续变化）

- evidence_ids: plugin_spawn.c 76be0a0159d8533fe12ff2ce1c7a9c7fb365df546bacbe8e9df2ca8a5fb88a20 与 1b93b6c6b9a609859942990e40d1714d65f477a3d7f33fb0085d6cf2bac2bb89 读取快照。
- 已有 posix_spawnp/pidfd_spawnp 将 file_actions、attr、envp 原指针透传，且 loader 为绝对路径；未见丢失 cwd、dup2/close、stdio 的实现问题。wrap 的 MAX_ARGS+8 容量足够，--argv0 保留插件 argv0。
- 初版只覆盖 execvp/execve/spawnp/pidfd_spawnp；必须补 Rust 实际入口 posix_spawn/execvpe/execv，并检查 pidfd_spawn 是否由目标使用。不能只新增 dlsym 指针而未实现导出 hook。
- 中间版 eligible 内 realpath 到栈 canonical，却只返回布尔值，wrap 仍使用原 file；应让每个 hook 持有并传递同一 canonical 路径。前缀末尾 slash 校验正确，原 O_NOFOLLOW 仅保护最终路径分量，不能替代中间目录解析。
- 读取 ELF+可读判断没有保留原执行位语义；应检查 X_OK，避免 loader 运行原本不可执行文件。loader 的同步 spawn 成功仅代表 loader exec 成功；插件缺依赖会成为子进程退出，而非原生同步 ENOENT。
- `ld.so --preload` 只用于 server 且未 export LD_PRELOAD，避免向 bionic 子进程继承该 preload 的设计成立。插件自身未 preload shim，嵌套派生 glibc helper 是覆盖边界。
- **realpath 死锁判断**：realpath(path,栈buf) 没有显式要求分配输出内存，优于 NULL 参数；但 realpath 非 POSIX async-signal-safe API，glibc canonicalize 的 scratch_buffer 在极端路径可增长。仅凭当前实现不能高置信断言必然 malloc 死锁，列为 fork 后路径压测项而非已证实阻断。posix_spawn wrapper 的 eligible 在父侧运行；exec hook 可能位于 fork 子侧，要区分。

## 复现命令

```powershell
# 完整回归：在可启动 sh 的环境运行，退出0才表示所有项完成。
& 'E:/AI/tools/re-venv/Scripts/python.exe' 'E:/AI/tmp/agent2api-audit-20261104/reverify/phone-repair/test/phone_runtime_test.py'
# 宿主 shell 被阻断时，仅静态检查；预期退出2、动态项BLOCKED。
& 'E:/AI/tools/re-venv/Scripts/python.exe' 'E:/AI/tmp/agent2api-audit-20261104/reverify/phone-repair/test/phone_runtime_test.py' --static-only
```

## 交接验收

- [x] 发布源码与 ZIP 交叉检查；DNS here-doc 假设反证。
- [x] TEMP/TMPDIR 与父子进程生命周期区分；不把 server 环境当 supervisor 环境。
- [x] fallback 同 shell 变量冲突及修复审查。
- [x] 新增只读回归脚本；最终主机 sh 生产片段回归6项全过，原始宿主阻断及传输问题保留历史记录。
- [x] 父代理现场 supervisor TMPDIR 正常；server 健康并映射 shim；C 六入口及 argv0/空格/env/stdio/chdir 正对照和 ENOENT/EACCES 负对照通过。
- [x] 父代理反馈经网关 `/api/plugins/install` 安装官方 providers 3.4.1、web 3.4.2 成功：两操作 `done=true/error=null`，host `running=true/crashes=0/lastError=null`，providers=36。
- [ ] 服务重启后的持久验证由父代理继续；本代理未执行设备操作。
- [ ] mksh 离线全套、缺依赖及 fork 后压力仍属扩展验证范围；主机 sh 结果不冒充 mksh 全套，C 中间快照审查不冒充最终源码发版审查。
