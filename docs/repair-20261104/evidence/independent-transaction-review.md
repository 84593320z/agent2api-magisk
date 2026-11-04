# 事务修复只读复核

## 结论

对指定 diff 独立确认两项恢复幂等回归；初版新增 21 项边界测试全部通过，但未覆盖这两个窗口。主审收到证据后已修复两项，最终使用原 probe 重跑均恢复 rc=0、old-schema、journal 清空；当前未留下这两项高置信未修问题。本报告记录最初审查快照及后续观察，避免把并行修改后的代码误当成同一版本。

- 基线：`f8e474d59c885e247cbeb179cf2e8f99a4ddbbb4`。
- 最初 payload 源 SHA-256：`32ea286f3a9ebae013741fa7f34ccdf41479247565f59966b270136bb08025cf`。
- 范围：`module/libexec/payload.sh`、`updater.sh`、`supervise.sh`、`module/customize.sh`、`post-fs-data.sh`、新增 `test/recovery_boundary*`；common.sh 和 txn_test.sh 仅作为调用关系与现有测试 stub 背景。
- 全程未修改 repair 内任何源码、测试或配置；只在本证据目录新增脚本、日志和隔离运行数据；未远端提交或发布。
- 已先读技能目录，加载 code-audit、docs-generator；普通 Shell 源码未使用 REA。未安装 Semgrep/shellcheck；采用 diff 人工状态机复核及生产函数故障注入。

## F1：首次 data rename 返回失败后，已删除的 tmp 指针使恢复永久失败

**最初位置**：`module/libexec/payload.sh:140-170` 的 `payload_txn_recover_data()`、`:211-214` 的失败即返回；生产该现场的是 `payload_data_rollback():985-988`。

**Evidence → Finding → Path**：

1. 生产函数先写 rolling-back journal，登记 `data.restore.<pid>` 与 `data.upgraded.<pid>`。
2. 注入第一次 `mv "$DATADIR" "$_pdr_aside"` 返回 1；原函数删除 tmp，保留带路径的 journal；backup/data-prev 仍完整、txid 匹配。
3. 移除注入后执行 `payload_recover_interrupted boot`：修复版因 tmp 与 aside 均不存在返回 1，拒绝回退到完整 snapshot；新启动门控随之阻止服务。
4. 同样现场用基线 payload 函数恢复成功。

首次修复版实测：

```text
FIRST rc=1 data=new-schema journal=rolling-back snapshot=yes
RESULT first-rename-failure recovery_rc=1 data=new-schema journal=rolling-back snapshot=yes
```

基线实测：

```text
RESULT first-rename-failure recovery_rc=0 data=old-schema journal= snapshot=yes
```

**建议**：首次 rename 失败保留 tmp 供恢复重放，或清除已失效的 tmp/aside 指针并明确保留 snapshot-needed 状态，使下次回退到 txid 匹配快照。不能把仅保全现场当恢复成功。

**并行修复观察**：最后一次运行已输出“无法移开当前数据目录，保留快照副本等待重试”，随后恢复 rc=0、old-schema、journal 清空。即该项已被主审同步修复；未替主审进行全回归。

## F2：旧载荷已归位但 journal 未清时再中断，重试误判当前旧载荷为新载荷

**最初位置**：`module/libexec/payload.sh:254-258` 的 generation/built 判据、`:274-278` 的旧目录 rename、`:283` 新增 `cur_new=0` 条件，以及 `:311-312` 的最后收尾。

**Evidence → Finding → Path**：

1. 造合法 new 当前载荷、合法 old 事务目录、升级前 data snapshot，并写 started journal 和本事务 generation。
2. 第一次 boot 恢复正常把 old 目录移回 payload、data 回滚成功。
3. 在最后清 journal 前注入进程退出 91（仅覆盖 `payload_txn_clear`，不改变恢复内部逻辑）。此刻旧载荷和数据均已恢复，但 generation 仍为原事务 txid，事务 old 路径已经被 rename 消耗。
4. 第二次 boot 因 generation 相同把当前 old 误判为 new；新增条件拒绝“当前完整、旧目录已耗尽”的路径，转而强制 backup/prev。
5. 当 backup/prev 不存在时，恢复 rc=1 并保持 rolling-back，尽管 old/old-schema 已恢复；该现场不需要 backup/prev 才能完成第一次恢复。若备份存在，则还有额外重复载荷回滚和空间/复制失败机会。

修复版实测：

```text
MID injected=91 payload=old data=old-schema journal=rolling-back dsnap=restored generation=tx-resume oldpath=no
RESULT old-payload-retry rc=1 payload=old data=old-schema journal=rolling-back
```

基线实测：

```text
MID injected=91 payload=old data=old-schema journal=rolling-back dsnap=1 generation=tx-resume oldpath=no
RESULT old-payload-retry rc=0 payload=old data=old-schema journal=
```

**建议**：为 payload 恢复引入持久身份与完成状态。仅在 rename 后写 restored 标记仍有“rename 已成、标记未落盘”窗口；需预先记录旧载荷 built/hash 等身份，或其他可重复判定的两阶段状态，在恢复中更新 generation 并覆盖任意命令间中断。不要简单撤销 cur_new 检查而重新允许未验证的新载荷被当旧载荷提交。

**最终修复复核**：主审在旧 payload rename 前写入与 txid 匹配的目录内 `.a2a-rollback-txid`，标记随目录 rename 进入当前 payload，恢复优先使用此身份而非仅信全局 generation；rollback staging 也预写。收到修复通知后仅重跑原 probe：`MID injected=91 payload=old data=old-schema journal=rolling-back dsnap=restored generation=tx-resume oldpath=no`，随后 `RESULT old-payload-retry rc=0 payload=old data=old-schema journal=`。F1 同次原 probe 也 `recovery_rc=0 data=old-schema journal=`。主审新增 marker 写失败、rename 后立即中断等 4 用例并运行 25 边界和 full 回归；本 child 未重复该全回归。

## 新增测试及其盲点

`recovery_boundary_test.py` 以证据目录 A2A_BOUNDARY_OUT 隔离运行，21/21 PASS，覆盖数据/载荷复制失败、snapshot 丢失、信号失败门控、孤儿写者、customize 恢复失败、快照身份、两次 rename 中断、数据恢复完成持久化、矛盾现场、supervisor 和 boot 失败门控。

- `first-rename` 用例是在首次 rename 调用前退出，不是首次 rename 返回失败后触发清理；因此未覆盖 F1。
- `recovered-data-retry` 用例只造当前 old 载荷且无“本事务新 generation + 已耗尽 old 路径”的组合；因此未覆盖 F2。

## 独立复现

在 repair 目录用本机 Python 3.12 和已发现的 bundled bash：

```bash
PYTHONIOENCODING=utf-8 python E:/AI/tmp/agent2api-audit-20261104/reverify/repair-evidence/transaction-review/run_review.py
```

运行器读取 repair 当前函数，因此并行修复后结果可能改变；它同时通过 git show 提取固定基线 payload，输出对照日志。未导出整仓或修改生产文件。

- `run_review.py`：生成 probe、生产函数故障注入、git show 基线对照。
- `probe.sh`：两个独立用例；OS/进程边界沿用现有测试 stub；被审 payload 函数原文 source。
- `probe.log`：最终修复版原 probe 运行结果（F1、F2 均通过）。
- `baseline-payload.sh`、`baseline-probe.sh`、`baseline.log`：固定基线 payload 与同场景对照。
- `boundary-suite/results.json`：新增边界测试 21/21 PASS 完整明细。

## 剩余局限

仅本轮指定 diff 和针对性窗口；未做泛泛审计、全回归、Android 真机进程/文件系统验证或实际断电持久性验证。所有动态结果为 Windows bundled POSIX shell + 临时目录真实文件操作 + 现有进程控制 stub。工作树由其他审查者同步修改，报告用最初源 hash 和逐次运行观察区分状态。
