# 复现材料说明

这些脚本是离线函数/故障注入的回放副本。审查工作区为`E:/AI/tmp/agent2api-audit-20261104`，脚本内MSYS形式为`/e/AI/tmp/agent2api-audit-20261104`。

- 移机时先克隆目标仓库到新工作区的`repo`，checkout `23b881d93c13dc2081df23dd59da5c3d0d95b7bd`；另外克隆上游v3.4.0到`upstream`。
- 把[更新脚本](<repro.sh>)放入`agent-update/repro.sh`，四个runtime脚本放入`agent-runtime`，[UI回放](<replay_ui.py>)和[产物检查](<inspect_artifacts.py>)放工作区根。
- 将脚本内原工作区前缀统一替换为新的绝对路径。更新repro.sh的SRC/OUT、runtime脚本source和APP_HOME，UI回放的Node可执行路径；Windows/MSYS与Linux路径不可混用。
- 更新脚本会重建其OUT/cases内fixture；固定SRC是读取目标源码，OUT必须始终是独立审计目录。初始样本为伪ELF，仅测试shell文件状态，不启动ARM程序。
- runtime脚本内CLI/巡检函数为生产函数摘录并配桩；不代表Android上运行了完整守护进程。UI函数由Python从原TSX摘取，Promise顺序由测试控制。
- 本地`python pack.py`后再执行产物检查；上游UI文件归一换行后比较。
- 原始输出固定在[更新日志](<../artifacts/update.txt>)、[运行时日志](<../artifacts/runtime.txt>)及[前端日志](<../artifacts/ui.txt>)。
