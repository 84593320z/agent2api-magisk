# 静态源码快照

基线 commit: 23b881d93c13dc2081df23dd59da5c3d0d95b7bd

## module/libexec/updater.sh:267-300
```text
267: upd_stop_service() { # 问题 2：停服并核实退出，必须发生在切换 payload 之前
268:   if [ "$UPD_WAS_RUNNING" = "1" ]; then
269:     # svc_stop 按 pidfile+cmdline 身份核验：TERM（supervisor 25s / server 10s）
270:     # 不退再 KILL，仍存活即报失败；这里再兜一层 supervisor 复核。
271:     svc_stop || { printf '服务停止失败（旧进程仍在），中止更新\n' >&2; return 1; }
272:     if svc_is_running; then
273:       printf '服务停止后 supervisor 仍存活，中止更新\n' >&2
274:       return 1
275:     fi
276:   fi
277:   # 服务端死了，它拉起的插件进程会成为孤儿继续写数据目录。数据快照（问题 1）
278:   # 要求完全静默：无论更新前是否在运行，快照前都必须清掉残留并核实。
279:   svc_kill_stray
280:   _uss_left=$(svc_stray_pids 2>/dev/null)
281:   if [ -n "$_uss_left" ]; then
282:     printf '仍有模块相关进程未退出（%s），中止更新\n' "$_uss_left" >&2
283:     return 1
284:   fi
285:   UPD_SERVICE_STOPPED=1
286:   return 0
287: }
288: 
289: upd_finish_service() { # 按更新前状态恢复运行；返回健康结果
290:   # 问题 2：停服已提前到 upd_stop_service（切换之前）。这里只负责
291:   # 「更新前在运行 -> 现在也必须在运行且健康」；更新前就是停止的直接返回 0
292:   # （「已安装未验证」是独立状态，见主流程的 pending-verify 分支）。
293:   if [ "$UPD_WAS_RUNNING" != "1" ]; then
294:     return 0
295:   fi
296:   # 置位在 svc_start 之前：启动期间被信号打断时，数据回滚判定要用它
297:   UPD_SERVICE_STARTED=1
298:   svc_start || return 1
299:   svc_wait_health 45
300:   return $?
```

## module/libexec/updater.sh:500-554
```text
500:   svc_is_running && UPD_WAS_RUNNING=1
501:   # 问题 2：完成阶段时序重排。旧顺序是「先切载荷 -> upd_finish_service 才停服」，
502:   # 切换窗口里旧服务端还拿着旧载荷跑，健康证据与磁盘状态脱节；新版迁移过
503:   # 数据库后回滚更是只剩「旧程序 + 新数据」。新时序：
504:   #   staging 完成 -> 停服并核实退出 -> 数据快照（问题 1）-> 原子切换 payload ->
505:   #   （更新前在运行）启动 + svc_wait_health 45 -> 成功才提交；
506:   #   任一步失败 -> 回滚载荷与数据 -> 按原状态重启旧版 -> 报错退出。
507:   printf '停止服务并核实退出…\n'
508:   upd_stop_service || { upd_fail '服务无法停止，更新中止（载荷与数据均未改动）'; return 1; }
509:   printf '制作数据快照…\n'
510:   payload_data_snapshot "$PAYLOAD_TXID" || { upd_fail '数据快照失败，中止更新（载荷未动，按原状态恢复服务）'; return 1; }
511:   [ "$PAYLOAD_DATA_SNAPSHOT_TAKEN" = "1" ] && UPD_DATA_SNAP=1
512:   printf '安装新载荷并校验…\n'
513:   payload_install_from "$_root" 1 || { upd_fail '新载荷安装失败，已恢复旧版'; return 1; }
514:   if [ "$UPD_INSTALLED" != "1" ]; then
515:     upd_fail '载荷提交状态缺失，恢复旧版'; return 1
516:   fi
517:   if [ "$UPD_WAS_RUNNING" = "1" ]; then
518:     _upd_verify_ok=0
519:     if upd_finish_service; then
520:       # 健康证据绑定（问题 3 的 updater 侧）：确认正在服务的进程确实是从新
521:       # 载荷路径 exec 出来的。切换用的是 rename：旧进程的 /proc/<pid>/exe
522:       # 会跟着 rename 指到被移走的目录，借此分辨「健康的是不是新版本」，
523:       # 防止更新窗口里被手工拉起的旧实例顶替健康证据。静态载荷 exe=服务端，
524:       # 动态载荷 exe=自带 loader，两者都在 $PAYLOAD 下，rename 后即失配。
525:       _upd_srv=$(svc_server_pid 2>/dev/null)
526:       _upd_exe=""
527:       [ -n "$_upd_srv" ] && _upd_exe=$(readlink "/proc/$_upd_srv/exe" 2>/dev/null)
528:       if [ -z "$_upd_srv" ] \
529:          || { [ "$_upd_exe" != "$SERVER_BIN" ] && [ "$_upd_exe" != "$LOADER" ]; }; then
530:         printf '健康检查命中的不是新载荷进程（exe=%s），按失败处理\n' "${_upd_exe:-未知}"
531:       else
532:         _upd_verify_ok=1
533:       fi
534:     fi
535:     if [ "$_upd_verify_ok" != "1" ]; then
536:       printf '新版健康检查失败，正在回滚载荷与数据…\n'
537:       payload_rollback || printf '载荷回滚失败，请执行 a2a doctor\n'
538:       if [ "$UPD_DATA_SNAP" = "1" ]; then
539:         payload_data_rollback || printf '数据快照恢复失败，快照保留在 %s，请执行 a2a doctor\n' "$BACKUPDIR/data-prev"
540:       fi
541:       svc_restart
542:       _upd_rb_ok=1
543:       if svc_wait_health 45; then
544:         printf '旧版已恢复并通过健康检查\n'
545:       else
546:         printf '旧版未通过健康检查，请执行 a2a doctor 和 a2a logs\n'
547:         _upd_rb_ok=0
548:       fi
549:       # R04：回滚成功后 pending 仍指着刚才失败的那一版。旧版已恢复可用，
550:       # 这笔事务的「旧载荷」（即失败的 v2）就该提交掉；否则 pending 永远
551:       # 悬空，下一次开机由守护拿着旧标记去提交，删的是别的代次的目录。
552:       if [ "$_upd_rb_ok" = "1" ] && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
553:         if payload_commit_old "rollback $$" "$PAYLOAD_TXID"; then
554:           upd_payload_committed
```

## module/libexec/payload.sh:265-305
```text
265:   [ -d "$_pa_tmp" ] || return 1
266:   [ ! -e "$_pa_old" ] && [ ! -e "$_pa_failed" ] || return 1
267:   # 问题 3：本笔切换的代次 ID（事务调用方预设 PAYLOAD_TXID；手动回滚等
268:   # 未预设的场景现场生成，保证每次切换的 txid 唯一）。
269:   _pa_txid=${PAYLOAD_TXID:-}
270:   [ -n "$_pa_txid" ] || _pa_txid=$(payload_txid_new)
271:   # 问题 6：首次 rename 前写「切换进行中」标记（txid+时间戳+旧载荷去向），
272:   # 切换完成/失败后删除。中断恢复只认这个标记且要求已过期（>120s），
273:   # 绝不因载荷瞬时缺失就判定上一事务死亡。
274:   printf '%s %s %s %s\n' "$_pa_txid" "$(now_epoch)" "$$" "$_pa_old" \
275:     >"$RUNDIR/payload.switching.tmp.$$" 2>/dev/null \
276:   && mv -f "$RUNDIR/payload.switching.tmp.$$" "$RUNDIR/payload.switching" 2>/dev/null || {
277:     rm -f "$RUNDIR/payload.switching.tmp.$$" 2>/dev/null
278:     echo "无法写入载荷切换标记"
279:     return 1
280:   }
281:   printf '%s\n' "$_pa_tag $$ $_pa_old" >"$RUNDIR/update.active" 2>/dev/null || {
282:     rm -f "$RUNDIR/payload.switching" 2>/dev/null
283:     return 1
284:   }
285:   if command -v upd_payload_before_move >/dev/null 2>&1; then
286:     # B2：钩子拒绝本笔切换时，两个事务标记必须一并清掉，否则会留下孤儿
287:     # payload.switching（误导中断恢复的过期判定）与悬空的 update.active。
288:     upd_payload_before_move "$_pa_old" "$_pa_tmp" || {
289:       rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
290:       return 1
291:     }
292:   fi
293:   if [ -d "$PAYLOAD" ] && ! mv "$PAYLOAD" "$_pa_old" 2>/dev/null; then
294:     rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
295:     echo "无法移开旧载荷"
296:     return 1
297:   fi
298:   if [ -e "$PAYLOAD" ] || ! mv "$_pa_tmp" "$PAYLOAD" 2>/dev/null; then
299:     # 旧载荷已经移走后，失败恢复不能因 PAYLOAD 非空而跳过。
300:     # 先把任何现存/嵌套的新目录隔离，再把旧目录移回固定位置。
301:     if [ -e "$PAYLOAD" ]; then
302:       mv "$PAYLOAD" "$_pa_failed" 2>/dev/null || {
303:         echo "切换失败且无法移开新载荷，旧版保留在 $_pa_old"
304:         return 1
305:       }
```

## module/libexec/payload.sh:350-380
```text
350:       fi
351:     else
352:       echo "代次文件写入失败，且无法移开新载荷；旧版保留在 $_pa_old"
353:     fi
354:     rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
355:     return 1
356:   fi
357:   if command -v upd_payload_commit >/dev/null 2>&1; then
358:     upd_payload_commit "$_pa_old" "$_pa_tmp"
359:   fi
360:   # 旧载荷绝不能在这里删：此刻服务端还没做健康检查，健康失败要回滚时
361:   # 这份同一事务的旧版本是唯一能立刻顶回去的副本（备份目录 prev 是上一代，
362:   # 不是这一次被换下来的那一份）。改成写 pending 标记，由
363:   # payload_commit_old 在健康通过/安装收尾后删除。
364:   # R02：pending 写不成/写不完整绝不能当成功。旧实现丢掉终端错误继续
365:   # return 0，调用方以为"旧载荷已登记待提交"，实际 marker 是空的：这份
366:   # 唯一能回滚的旧目录从此没有任何记账，下一轮 sweep 会把它当垃圾删掉。
367:   # 先写临时文件再 rename，pending 被外来者占成目录时这里会明确失败。
368:   # pending 格式："tag pid path txid startticks"。前三个字段保持旧格式
369:   # （a2a / post-fs-data 只读 $1-$3，向后兼容）；txid 供提交时的代次校验，
370:   # startticks 供中断恢复判定「pending 是否属于已死事务」（问题 3/6）。
371:   if ! printf '%s\n' "$_pa_tag $$ $_pa_old $_pa_txid $(proc_start_ticks $$ 2>/dev/null)" >"$RUNDIR/update.pending.tmp.$$" 2>/dev/null \
372:      || ! mv -f "$RUNDIR/update.pending.tmp.$$" "$RUNDIR/update.pending" 2>/dev/null; then
373:     rm -f "$RUNDIR/update.pending.tmp.$$" 2>/dev/null
374:     rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
375:     echo "无法登记待提交的事务旧载荷：$_pa_old（旧版仍在原处，请勿手工删除）"
376:     return 1
377:   fi
378:   rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
379:   # /data/a2a/ld.so 只是"插件解释器"这条旁路，真正的服务端是用绝对路径
380:   # $LOADER 起的，跟这个软链无关。切换已经成功却因为软链失败报整体失败，
```

## module/libexec/payload.sh:625-668
```text
625:   if [ ! -d "$BACKUPDIR/data-prev" ]; then
626:     # 无快照时跳过并记日志，不算失败（数据目录本来就可能是空的）
627:     log_to "$UPDLOG" "没有数据快照（$BACKUPDIR/data-prev），跳过数据回滚"
628:     return 0
629:   fi
630:   # 快照身份校验：只恢复「本笔事务」的快照。txid 对不上说明快照是上一代
631:   # 更新留下的 —— 用它覆盖现在的数据等于静默回退用户数据，必须拒绝。
632:   _pdr_want=${PAYLOAD_TXID:-}
633:   _pdr_have=$(awk 'NR==1{print $1; exit}' "$BACKUPDIR/data-prev.txid" 2>/dev/null)
634:   if [ -n "$_pdr_want" ] && [ -n "$_pdr_have" ] && [ "$_pdr_want" != "$_pdr_have" ]; then
635:     log_to "$UPDLOG" "数据快照属于其它事务（期望 $_pdr_want，实际 $_pdr_have），跳过数据回滚"
636:     return 1
637:   fi
638:   # 明确警告：这一步会用升级前的数据覆盖现在的数据目录
639:   log_to "$UPDLOG" "WARNING: 正在用升级前快照覆盖数据目录，升级期间对数据的写入会丢失"
640:   _pdr_kb=$(payload_size_kb "$BACKUPDIR/data-prev") || _pdr_kb=0
641:   space_require_kb "$APP_HOME" $((_pdr_kb + 16384)) || return 1
642:   _pdr_tmp="$DATADIR.restore.$$"
643:   rm -rf "$_pdr_tmp" 2>/dev/null
644:   mkdir -p "$_pdr_tmp" 2>/dev/null || return 1
645:   if ! cp -a "$BACKUPDIR/data-prev"/. "$_pdr_tmp"/ 2>/dev/null; then
646:     rm -rf "$_pdr_tmp" 2>/dev/null
647:     echo "数据快照复制失败，数据目录未动"
648:     return 1
649:   fi
650:   # 现场保全：升级后的数据先移开再换入快照（两次 rename 的窗口极小）；
651:   # 换入失败时原样放回，绝不把数据目录留在"不存在"的状态。
652:   _pdr_aside="$DATADIR.upgraded.$$"
653:   if [ -d "$DATADIR" ] && ! mv "$DATADIR" "$_pdr_aside" 2>/dev/null; then
654:     rm -rf "$_pdr_tmp" 2>/dev/null
655:     echo "无法移开当前数据目录，数据回滚中止"
656:     return 1
657:   fi
658:   if mv "$_pdr_tmp" "$DATADIR" 2>/dev/null; then
659:     rm -rf "$_pdr_aside" 2>/dev/null
660:     chmod 700 "$DATADIR" 2>/dev/null
661:     log_to "$UPDLOG" "数据已回滚到升级前快照（${_pdr_kb}KB）"
662:     return 0
663:   fi
664:   if [ -d "$_pdr_aside" ]; then
665:     mv "$_pdr_aside" "$DATADIR" 2>/dev/null || echo "严重：升级后数据在 $_pdr_aside，请手工恢复"
666:   fi
667:   rm -rf "$_pdr_tmp" 2>/dev/null
668:   return 1
```

## module/libexec/common.sh:755-830
```text
755:   _pri_valid=0
756:   payload_validate "$PAYLOAD" >/dev/null 2>&1 && _pri_valid=1
757:   if [ "$_pri_valid" = "1" ]; then
758:     # 载荷完好：切换早已完成或从未开始。只清掉可能残留的切换标记。
759:     if [ -f "$RUNDIR/payload.switching" ]; then
760:       rm -f "$RUNDIR/payload.switching" 2>/dev/null
761:       log_to "$SUPLOG" "清除残留的载荷切换标记（当前载荷完好）"
762:     fi
763:     return 0
764:   fi
765:   # 载荷不完整：收集「上一事务已死」的证据
766:   _pri_evidence=0
767:   _pri_reason=""
768:   if [ -f "$RUNDIR/payload.switching" ]; then
769:     _pri_sw_ts=$(awk 'NR==1{print $2; exit}' "$RUNDIR/payload.switching" 2>/dev/null)
770:     case "$_pri_sw_ts" in ''|*[!0-9]*) _pri_sw_ts=0 ;; esac
771:     _pri_age=$(( $(now_epoch) - _pri_sw_ts ))
772:     [ "$_pri_age" -lt 0 ] && _pri_age=0
773:     if [ "$_pri_age" -gt 120 ]; then
774:       _pri_evidence=1
775:       _pri_reason="切换标记已过期 ${_pri_age}s"
776:     else
777:       # 标记还新：可能真有事务在跑（或刚死），本轮不动
778:       log_to "$SUPLOG" "载荷不完整但切换标记仅 ${_pri_age}s（<=120s），跳过恢复等下轮"
779:       return 0
780:     fi
781:   fi
782:   if [ "$_pri_evidence" != "1" ] && [ -s "$RUNDIR/update.pending" ]; then
783:     # pending 属于已死事务：登记的 pid 已不存在或启动代次对不上
784:     _pri_pid=$(awk 'NR==1{print $2; exit}' "$RUNDIR/update.pending" 2>/dev/null)
785:     _pri_ticks=$(awk 'NR==1{print $5; exit}' "$RUNDIR/update.pending" 2>/dev/null)
786:     case "$_pri_pid$_pri_ticks" in
787:       ''|*[!0-9]*) ;;
788:       *)
789:         if ! pid_alive "$_pri_pid" \
790:            || [ "$(proc_start_ticks "$_pri_pid" 2>/dev/null)" != "$_pri_ticks" ]; then
791:           _pri_evidence=1
792:           _pri_reason="pending 属于已死事务（pid=$_pri_pid）"
793:         fi
794:         ;;
795:     esac
796:   fi
797:   if [ "$_pri_evidence" != "1" ]; then
798:     log_to "$SUPLOG" "载荷不完整但没有已死事务的证据，跳过恢复（避免误伤活跃事务）"
799:     return 0
800:   fi
801:   log_to "$SUPLOG" "检测到中断的载荷事务（$_pri_reason），尝试恢复"
802:   # 临界区：update 锁短超时。已持有（如 upd_recover_activation 在事务内调用）
803:   # 则直接复用；拿不到说明有活跃事务，本轮不动作。
804:   _pri_outer_token=${UPDATE_LOCK_TOKEN:-}
805:   _pri_outer_path=${UPDATE_LOCK_PATH:-}
806:   _pri_locked=0
807:   if ! update_lock_is_self "$RUNDIR/update.lock.d"; then
808:     if update_lock_acquire "$RUNDIR/update.lock.d" 5 >/dev/null 2>&1; then
809:       _pri_locked=1
810:     else
811:       log_to "$SUPLOG" "拿不到 update 锁（有活跃更新事务），本轮跳过载荷恢复"
812:       return 0
813:     fi
814:   fi
815:   for _old in "$APP_HOME"/payload.*.old.* "$APP_HOME"/payload.old "$APP_HOME"/payload.rollback.old "$BACKUPDIR/prev"; do
816:     [ -d "$_old" ] || continue
817:     if payload_validate "$_old" >/dev/null 2>&1; then
818:       # R09：移开"坏 current"失败时必须放弃这一次恢复。旧实现忽略 mv 的
819:       # 返回码继续往下 mv，old 会被嵌进坏目录（payload/下再套一层 old 名），
820:       # 结果 current 仍然坏、唯一回滚副本也被毁掉，函数还照样 return 0 报成功。
821:       if [ -e "$PAYLOAD" ]; then
822:         if ! mv "$PAYLOAD" "$APP_HOME/payload.incomplete.$$" 2>/dev/null; then
823:           log_to "$SUPLOG" "无法移开不完整的当前载荷，跳过本次恢复：$_old"
824:           continue
825:         fi
826:       fi
827:       if mv "$_old" "$PAYLOAD" 2>/dev/null && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
828:         payload_fix_perms "$PAYLOAD"
829:         log_to "$SUPLOG" "已恢复中断的载荷切换：$_old"
830:         rm -rf "$APP_HOME/payload.incomplete.$$"
```

## module/libexec/common.sh:873-900
```text
873: sweep_stale_dirs() {
874:   # pending 里记着还没提交的事务旧载荷：它可能正是唯一能回滚的副本，
875:   # 清理时必须跳过，否则"开机先清垃圾再恢复"会把恢复材料先删掉。
876:   _ss_keep=$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null | head -n 1)
877:   for _d in "$APP_HOME"/payload.new.* "$APP_HOME"/payload.old \
878:             "$APP_HOME"/payload.rollback.new "$APP_HOME"/payload.rollback.old \
879:             "$APP_HOME"/payload.rollback.old.* \
880:             "$APP_HOME"/payload.incomplete.* "$APP_HOME"/payload.broken.* \
881:             "$APP_HOME"/payload.interrupted.* "$APP_HOME"/payload.new.old.* \
882:             "$APP_HOME"/payload.rollback.failed.* \
883:             "$TMPD"/upd.* "$BACKUPDIR/lib.new"; do
884:     [ -e "$_d" ] || continue
885:     [ -n "$_ss_keep" ] && [ "$_d" = "$_ss_keep" ] && continue
886:     rm -rf "$_d" 2>/dev/null
887:   done
888:   # $TMPD 里除了 upd.* 还有解包残留
889:   # 切换标记是中断恢复的证据：载荷完好时它是残留垃圾可以清；载荷不完整时
890:   # 必须保留给 payload_recover_interrupted（它在 post-fs-data 里先于本函数
891:   # 执行，走到这里还留着说明恢复被跳过或没做成，留给下次开机再试）。
892:   if [ -f "$RUNDIR/payload.switching" ] && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
893:     rm -f "$RUNDIR/payload.switching" 2>/dev/null
894:   fi
895:   # 数据快照/回滚（问题 1）的可重建临时物：中断的快照副本与回滚中转目录。
896:   # data-prev（快照本体）与 DATADIR.upgraded.*（升级后数据的现场保全）绝不清。
897:   rm -rf "$BACKUPDIR/data-prev.new" 2>/dev/null
898:   rm -rf "$DATADIR".restore.* 2>/dev/null
899:   [ -d "$TMPD" ] && rm -rf "$TMPD"/* 2>/dev/null
900:   return 0
```

## module/customize.sh:122-143
```text
122: chmod 755 "$APP_HOME" "$BINDIR" "$LOGDIR" "$RUNDIR" \
123:           "$TMPD" "$HOMEDIR" "$BACKUPDIR" "$DLDIR" "$A2A_LIVE" 2>/dev/null \
124:   || abort "无法设置运行目录权限"
125: # 残留载荷清理推迟到取得 update.lock.d 之后（见下方）：提前删会把并发事务刚建好的
126: # payload.new.<pid> 当成垃圾清掉，对方事务就会半途而废。
127: 
128: . "$MODPATH/libexec/common.sh" || abort "无法加载 libexec/common.sh"
129: . "$MODPATH/libexec/payload.sh" || abort "无法加载 libexec/payload.sh"
130: 
131: # 沿用公共安装/更新锁；整个脚本只有这一处加锁。
132: update_lock_acquire "$RUNDIR/update.lock.d" || abort "另一个安装/更新事务正在运行，请稍后重试"
133: # 拿到锁之后再清残留：此时不可能有别人在写 payload.new.*。
134: rm -rf "$APP_HOME"/payload.new.* "$APP_HOME"/payload.broken.* 2>/dev/null
135: _INSTALL_TRANSACTION="$APP_HOME/.install.$$"
136: _ZONE_OLD="$APP_HOME/zoneinfo.old.$$"
137: _ZONE_COMMITTED=0
138: _ZONE_OLD_PRESENT=0
139: _INSTALL_SUCCESS=0
140: install_cleanup() {
141:   # 只要旧时区库已经被移开，就必须还原——不管新库有没有"提交"过。
142:   # 旧实现只在 _ZONE_COMMITTED=1 时还原，于是"移开旧库、新库还没 rename
143:   # 进来"这个窗口里被中断，两处都不存在，zoneinfo 直接丢失。
```

## module/post-fs-data.sh:22-72
```text
22: [ -f "$MODDIR/libexec/common.sh" ] || exit 0
23: . "$MODDIR/libexec/common.sh"
24: . "$MODDIR/libexec/dns.sh"
25: . "$MODDIR/libexec/payload.sh"
26: 
27: ensure_layout
28: 
29: # 权限：热安装/升级后模块目录是 0644，payload 里的可执行位要补回来，
30: # 否则 ld.so 跑不起来（报"Permission denied"）。
31: chmod 755 "$PAYLOAD" "$PLIB" "$LOADER" "$SERVER_BIN" 2>/dev/null
32: for _f in "$PLIB"/*.so*; do
33:   [ -e "$_f" ] && chmod 755 "$_f" 2>/dev/null
34: done
35: if [ -d "$MODDIR/libexec" ]; then
36:   chmod 755 "$MODDIR/libexec" 2>/dev/null
37:   for _f in "$MODDIR/libexec"/*; do
38:     [ -e "$_f" ] && chmod 755 "$_f" 2>/dev/null
39:   done
40: fi
41: chmod 700 "$CFGDIR" "$DATADIR" 2>/dev/null
42: 
43: # 运行期残留：pid / 锁 / stop 标记，一律清（这个时刻不可能有活进程）。
44: # boot.lock.d 与 hot-restart.req.lock.d 同属运行期锁：boot-worker / 热重启
45: # worker 都在本阶段之后才会被投递，此刻这两把锁必然 stale，与其余锁同口径
46: # 清掉，不留给 update_lock_acquire 的僵死回收慢慢兜底。
47: rm -f "$RUNDIR/stop" "$RUNDIR/server.pid" "$RUNDIR/server.start" "$RUNDIR/supervisor.pid" "$RUNDIR/supervisor.start" "$RUNDIR/hot-restart.state" "$RUNDIR/state" 2>/dev/null
48: rm -rf "$RUNDIR/lock" "$RUNDIR/service.lock.d" "$RUNDIR/hot-restart.lock.d" "$RUNDIR/update.lock.d" "$RUNDIR/boot.lock.d" "$RUNDIR/hot-restart.req.lock.d" 2>/dev/null
49: 
50: # 先恢复两次 rename 之间断电的现场，再清临时目录。
51: payload_recover_interrupted
52: # 时区库安装窗口被打断（旧库已移开、新库还没就位）时放回去。
53: if [ ! -e "$APP_HOME/zoneinfo" ]; then
54:   for _zo in "$APP_HOME"/zoneinfo.old.*; do
55:     [ -d "$_zo" ] || continue
56:     if mv -f "$_zo" "$APP_HOME/zoneinfo" 2>/dev/null; then
57:       log_to "$SUPLOG" "已恢复中断的时区库：$_zo"
58:     fi
59:     break
60:   done
61: fi
62: sweep_stale_dirs
63: # R01：这个时刻服务还没起来，一份"健康检查证据"都没有。在这里提交（删掉上一
64: # 事务留下的唯一可回滚副本）等于把"新载荷能跑"当成已知事实 —— 新载荷要是
65: # 起不来，回滚材料已经被自己删了。pending 原样保留，交给 supervise.sh 在首次
66: # 健康检查通过后提交。
67: if [ -s "$RUNDIR/update.pending" ]; then
68:   log_to "$SUPLOG" "保留事务旧载荷，等启动健康检查通过后再提交：$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null | head -n 1)"
69: fi
70: 
71: # glibc 运行时文件。
72: # 为什么放在 post-fs-data 而不是等 service.sh：glibc 一打开 resolv.conf 就
```

## module/libexec/a2a:101-115
```text
101:   # 改成：环境变量没有就看配置，配置也没有才说跟随系统，并带上系统属性。
102:   _tz_view="${TZ:-$(cfg_get tz "")}"
103:   [ -n "$_tz_view" ] || _tz_view="跟随系统（$(getprop persist.sys.timezone 2>/dev/null)）"
104:   say " 时区     : $_tz_view"
105:   say " 数据目录 : $DATADIR"
106:   say " 日志目录 : $LOGDIR"
107: }
108: 
109: cmd_start() { cmd_ensure_payload && svc_start; }
110: 
111: cmd_stop() {
112:   svc_stop && say "已停止" || { say "停止未完成，请查看 $SUPLOG"; return 1; }
113: }
114: 
115: cmd_restart() { svc_restart; }
```

## module/libexec/a2a:181-187
```text
181: cmd_ensure_payload() {
182:   if [ ! -f "$SERVER_BIN" ] || [ ! -x "$LOADER" ]; then
183:     say "载荷缺失（$PAYLOAD），请重新刷入模块 zip 恢复"
184:     return 1
185:   fi
186:   return 0
187: }
```

## module/libexec/launch.sh:27-41
```text
27: if [ ! -f "$SERVER_BIN" ]; then
28:   log_to "$SUPLOG" "启动失败：服务端二进制不存在：$SERVER_BIN"
29:   echo "启动失败：缺少 $SERVER_BIN，请重装模块" >&2
30:   exit 78
31: fi
32: # R05：先判定静态/动态，再决定要不要 loader。静态（musl）载荷没有 PT_INTERP，
33: # 本来就不需要 lib/ld-linux-aarch64.so.1；旧顺序在静态包上直接 78 退出，
34: # 而同一个包 payload_validate 是通过的，两条判定互相打架。
35: if ! payload_is_static; then
36:   if [ ! -x "$LOADER" ]; then
37:     log_to "$SUPLOG" "启动失败：loader 不存在或不可执行：$LOADER"
38:     echo "启动失败：缺少运行时 $LOADER，请重装模块" >&2
39:     exit 78
40:   fi
41: fi
```

## module/libexec/supervise.sh:364-410
```text
364: supervise_commit_pending() {
365:   _scp_disk=$(payload_generation_read)
366:   if [ -s "$RUNDIR/update.pending" ]; then
367:     _scp_line=$(head -n 1 "$RUNDIR/update.pending" 2>/dev/null) || _scp_line=""
368:     _scp_tag=$(printf '%s\n' "$_scp_line" | awk '{print $1" "$2}')
369:     _scp_txid=$(printf '%s\n' "$_scp_line" | awk '{print $4}')
370:     if [ -n "$_scp_txid" ] || [ -n "$_scp_disk" ] || [ -n "$CHILD_GENERATION" ]; then
371:       # 新式记账：三方代次完全一致才提交
372:       if [ -n "$_scp_txid" ] && [ "$_scp_txid" = "$CHILD_GENERATION" ] \
373:          && [ "$_scp_txid" = "$_scp_disk" ]; then
374:         if payload_commit_old "$_scp_tag" "$_scp_txid"; then
375:           log_to "$SUPLOG" "已提交代次 $_scp_txid 的事务旧载荷（$_scp_tag）"
376:         else
377:           log_to "$SUPLOG" "事务旧载荷暂未提交（代次 $_scp_txid），下一轮再试"
378:         fi
379:       else
380:         log_to "$SUPLOG" "pending 属于其它代次（pending=${_scp_txid:-无} 启动=${CHILD_GENERATION:-无} 磁盘=${_scp_disk:-无}），本轮不提交"
381:       fi
382:     elif [ -n "$_scp_tag" ]; then
383:       # 旧版遗留的 pending（无代次信息）：退回 tag 匹配
384:       if payload_commit_old "$_scp_tag"; then
385:         log_to "$SUPLOG" "已提交旧式记账的事务旧载荷（$_scp_tag）"
386:       else
387:         log_to "$SUPLOG" "事务旧载荷暂未提交（$_scp_tag），下一轮再试"
388:       fi
389:     fi
390:   fi
391:   # 问题 8：「已安装、未启动、未验证」的独立状态标记（更新前服务是停止的，
392:   # 更新只切载荷不做健康验证）。该代次现在通过了健康检查 -> 提交并清除标记；
393:   # 标记代次已不是磁盘代次时它不可能再被满足（代次从不回退），清掉防悬空。
394:   if [ -f "$RUNDIR/update.pending-verify" ]; then
395:     _scp_vtxid=$(awk 'NR==1{print $1; exit}' "$RUNDIR/update.pending-verify" 2>/dev/null)
396:     if [ -n "$_scp_vtxid" ] && [ "$_scp_vtxid" = "$CHILD_GENERATION" ] \
397:        && [ "$_scp_vtxid" = "$_scp_disk" ]; then
398:       log_to "$SUPLOG" "未验证安装（代次 $_scp_vtxid）已通过健康检查，提交并清除标记"
399:       if payload_commit_old "" "$_scp_vtxid"; then
400:         rm -f "$RUNDIR/update.pending-verify" 2>/dev/null
401:       else
402:         log_to "$SUPLOG" "pending-verify 对应提交未完成，保留标记下一轮重试"
403:       fi
404:     elif [ -n "$_scp_vtxid" ] && [ "$_scp_vtxid" != "$_scp_disk" ]; then
405:       log_to "$SUPLOG" "pending-verify 标记的代次（$_scp_vtxid）已不是当前代次（${_scp_disk:-无}），清除悬空标记"
406:       rm -f "$RUNDIR/update.pending-verify" 2>/dev/null
407:     fi
408:   fi
409:   return 0
410: }
```

## module/libexec/supervise.sh:479-549
```text
479:   # 4) 子进程还活着 → 巡检。运行状态由联合健康检查决定，不只看出进程存在。
480:   if [ -n "$CHILD" ] && child_alive; then
481:     if svc_http_health 3; then
482:       write_state running
483:     else
484:       write_state running-unverified
485:     fi
486:     _i=0
487:     # 30 秒节拍必须真的累计，否则 DNS/日志维护会每轮重复执行。
488:     while [ "$_i" -lt 30 ]; do
489:       [ -f "$RUNDIR/stop" ] && break
490:       [ "$STOP" = "1" ] && break
491:       child_alive || break
492:       sleep 5
493:       _i=$((_i + 5))
494:     done
495:     TICK=$((TICK + 1))
496:     # 上游在 Android headless 下不写文件日志（见 common.sh 的 APPLOG 注释），
497:     # 真实增长的是 server.log（上游 stderr + 启动器输出）和 supervisor.log。
498:     # APPLOG 仍轮转，只在文件意外出现时才动作（rotate_log 对不存在直接返回）。
499:     rotate_log "$APPLOG" "$LOG_MAX"
500:     rotate_log "$SRVLOG" "$LOG_MAX"
501:     rotate_log "$SUPLOG" "$LOG_MAX"
502:     # 进程活着不等于服务健康。连续 3 次联合检查失败才重启，启动给 60 秒宽限。
503:     _now=$(now_epoch)
504:     if [ $((_now - ${CHILD_START:-$_now})) -ge 60 ]; then
505:       if svc_http_health 3; then
506:         HEALTH_FAILS=0
507:         # 只有真的稳定跑过快速崩溃窗口（120s）才清零连续失败计数。
508:         if [ "$FAILS" -gt 0 ] && [ $((_now - ${CHILD_START:-_now})) -ge 120 ]; then
509:           log_to "$SUPLOG" "服务端已稳定运行 120s 以上，清零连续快速失败计数（原 $FAILS）"
510:           FAILS=0
511:         fi
512:       else
513:         _hrc=$?
514:         HEALTH_FAILS=$((HEALTH_FAILS + 1))
515:         log_to "$SUPLOG" "进程/端口/HTTP 联合健康检查连续失败 $HEALTH_FAILS/3（rc=$_hrc）"
516:       fi
517:       if [ "$HEALTH_FAILS" -ge 3 ]; then
518:         log_to "$SUPLOG" "服务进程存活但不健康，执行受控重启"
519:         if stop_child; then
520:           svc_kill_stray
521:           HEALTH_FAILS=0
522:           FAILS=$((FAILS + 1))
523:         else
524:           log_to "$SUPLOG" "不健康进程停止失败，下一轮继续观察，不重复启动"
525:         fi
526:         continue
527:       fi
528:     fi
529:     # 每轮先用轻量探测看 VPN/默认网卡变没变（不跑 dumpsys，几乎零开销），
530:     # 变了就立刻重算 DNS；这样开/关 VPN、切节点最多 30 秒就有反应。
531:     _vn_now=0
532:     dns_vpn_active 2>/dev/null && _vn_now=1
533:     _vn_old=$(cat "$DNS_VPN_CACHE" 2>/dev/null || echo 0)
534:     _if_now=$(dns_default_iface 2>/dev/null)
535:     _if_old=$(cat "$DNS_ACTIVE_CACHE" 2>/dev/null || echo "")
536:     if [ "$_vn_now" != "${_vn_old:-0}" ] || [ "${_if_now:-unknown}" != "${_if_old:-unknown}" ]; then
537:       log_to "$SUPLOG" "VPN/网卡变化（vpn=${_vn_old:-0}->$_vn_now iface=${_if_old:-?}->${_if_now:-?}），立即重算 DNS"
538:       dns_refresh_if_changed
539:       continue
540:     fi
541:     # 每 4 轮（≈2 分钟）刷一次 DNS：Wi-Fi 切流量、换热点都会变
542:     if [ $((TICK % 4)) -eq 0 ]; then
543:       dns_refresh_if_changed
544:       privacy_shield
545:       secure_files
546:       if [ "$(cfg_get keep_awake 0)" = "1" ]; then take_wake; else release_wake; fi
547:     fi
548:     continue
549:   fi
```

## module/libexec/supervise.sh:632-649
```text
632:   # 9) 拉起：前面几处已经放过 wake lock，这里按配置重新取回。
633:   if [ "$(cfg_get keep_awake 0)" = "1" ]; then take_wake; fi
634:   if start_child; then
635:     # 不能"一起来就清零"：那样"起来 → 30 秒内崩 → 再起来"永远停在 1 次，
636:     # 3 次退避和 6 次熔断都触发不了，等于把保护逻辑关掉。
637:     # 计数留到巡检分支里、确认稳定运行 120s 后再清。
638:     if [ "$FAILS" -gt 0 ]; then
639:       log_to "$SUPLOG" "本次拉起成功，但仍保留此前 $FAILS 次快速失败计数以观察稳定性"
640:     fi
641:     write_state running
642:     # R01（问题 3/8 修订）：到这里才算「新载荷真的跑起来了」—— start_child
643:     # 已通过进程/端口/HTTP 联合健康检查。提交点仍在启动路径，但删除动作统一
644:     # 走 payload_commit_old（内部自带 update 锁短超时与代次校验）：拿不到锁
645:     # 就本轮跳过、下轮重试，绝不死等；代次不匹配绝不提交。
646:     supervise_commit_pending
647:   else
648:     write_state starting-unhealthy
649:   fi
```

## module/libexec/dns.sh:169-240
```text
169: # 从系统里把当前 DNS 抓出来（只保留可用的 IPv4，多来源按优先级取第一个非空）
170: dns_collect_system() {
171:   _found=""
172:   _iface=$(dns_default_iface 2>/dev/null)
173:   _netid=$(dns_active_netid 2>/dev/null)
174:   _DNS_LOCAL=$(dns_local_addrs 2>/dev/null | tr '
175: ' ' ')
176:   _vpn=0
177:   case "$_iface" in tun*|ppp*|wg*) _vpn=1 ;; esac
178: 
179:   # VPN 出口下只认"隧道自己"的解析器：dnsresolver 里接口是 tun*/ppp*/wg* 的块。
180:   # 绝不能再回退到底层物理网卡（wlan0/rmnet）那一段 —— 那些地址走直连路由，
181:   # 查询会绕过隧道泄漏到局域网/运营商，等于把 VPN 的 DNS 策略拆了。
182:   if [ "$_vpn" = "1" ]; then
183:     _found=$(dns_from_resolver "$_iface" "" 2>/dev/null)
184:   else
185:     # 0) 出口网络真正在用的解析器（dnsresolver 分块，接口优先、netId 兜底）
186:     _found=$(dns_from_resolver "$_iface" "$_netid" 2>/dev/null)
187: 
188:     # 1) 同一 NetworkAgentInfo 的 DnsAddresses
189:     if [ -z "$_found" ]; then
190:       _found=$(dns_from_connectivity "$_iface" 2>/dev/null)
191:     fi
192: 
193:     # 2) 出口接口的 DHCP 属性
194:     if [ -z "$_found" ] && [ -n "$_iface" ]; then
195:       for _k in dns1 dns2 dns3 dns4; do
196:         _v=$(getprop "dhcp.$_iface.$_k" 2>/dev/null)
197:         [ -n "$_v" ] && _found="$_found $_v"
198:       done
199:     fi
200: 
201:     # 3) 老式全局属性
202:     if [ -z "$_found" ]; then
203:       for _k in net.dns1 net.dns2 net.dns3 net.dns4; do
204:         _v=$(getprop "$_k" 2>/dev/null)
205:         [ -n "$_v" ] && _found="$_found $_v"
206:       done
207:     fi
208:   fi
209: 
210:   # 4) 厂商 DNS 属性（仅非 VPN 且仍为空）
211:   if [ "$_vpn" = "0" ] && [ -z "$_found" ]; then
212:     _v=$(getprop 2>/dev/null \
213:          | sed -n 's/^\[[a-zA-Z0-9._]*[dD][nN][sS][a-zA-Z0-9._]*\]: \[\([0-9A-Fa-f][0-9A-Fa-f:.]*\)\]$/\1/p')
214:     [ -n "$_v" ] && _found="$_found $(printf '%s' "$_v" | tr '
215: ' ' ')"
216:   fi
217: 
218:   # 5) ROM 自带 resolv.conf 只作最后兜底
219:   if [ -z "$_found" ] && [ -r /system/etc/resolv.conf ]; then
220:     _v=$(sed -n 's/^[[:space:]]*nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' /system/etc/resolv.conf 2>/dev/null)
221:     [ -n "$_v" ] && _found="$_found $(printf '%s' "$_v" | tr '
222: ' ' ')"
223:   fi
224: 
225:   if [ -z "$_found" ] && [ "$_vpn" = "1" ]; then
226:     # 隧道没暴露自己的 DNS（透明代理类 VPN 很常见）。这时写公共解析器，
227:     # 让查询走默认路由进隧道，由 VPN 自己劫持/转发；仍然不碰底层网卡。
228:     _found=$(dns_static_list)
229:     # 只在“当前生效的首选”真的变了才写日志：这函数每 2 分钟跑一次，
230:     # 无脑 log 会把 supervisor.log 刷满。
231:     _vp_first=$(printf '%s' "$_found" | awk '{print $1}')
232:     _vp_cur=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$DNSFILE" 2>/dev/null | head -n 1)
233:     [ "$_vp_first" = "$_vp_cur" ] || log_to "$SUPLOG" "VPN 出口未暴露 DNS，改用公共解析器经隧道（不泄漏到底层网络）"
234:   fi
235: 
236:   for _s in $_found; do
237:     dns_ip_usable "$_s" || continue
238:     printf 'nameserver %s
239: ' "$_s"
240:   done
```

## module/libexec/dns.sh:282-300
```text
282:     auto)
283:       dns_collect_system >>"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
284:       # 只有 auto 能保留最后可用配置，或使用静态地址作首次启动兜底。
285:       if ! awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$_tmp" 2>/dev/null; then
286:         if [ -s "$DNS_CACHE" ] && awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$DNS_CACHE" 2>/dev/null; then
287:           rm -f "$_tmp" 2>/dev/null
288:           log_to "$SUPLOG" "暂时未取得活动网络 DNS；保留最后可用配置，不跳公共 DNS"
289:           return 0
290:         fi
291:         # 静态兜底也要分家族：IPv6-only / NAT64 网络上 v4 解析器根本到不了。
292:         _fb=$(cfg_get dns_static "223.5.5.5 119.29.29.29")
293:         if command -v ip >/dev/null 2>&1 \
294:            && ! ip -4 addr 2>/dev/null | grep -q 'inet .*scope global'; then
295:           _fb6=$(cfg_get dns_static_v6 "2400:3200::1 2402:4e00::")
296:           [ -n "$_fb6" ] && _fb="$_fb6 $_fb"
297:         fi
298:         for _s in $_fb; do
299:           dns_ip_usable "$_s" || continue
300:           printf 'nameserver %s
```

## module/libexec/dns.sh:659-705
```text
659:   return 1
660: }
661: 
662: # 每 2 分钟被 supervisor 调一次。变化就重来一遍兜底；没变化时按
663: # dns_verify_interval（默认 600s）抽检一次，避免每轮都发探测请求。
664: # 只在系统 DNS 变化时才重写，避免无意义的写盘
665: dns_refresh_if_changed() {
666:   [ "$(cfg_get dns_mode auto)" = "auto" ] || return 0
667:   # 只看「网卡/默认路由/VPN」三项变化（都靠 ip 命令，几十毫秒），
668:   # 不再每轮跑 dumpsys 采样——那才是以前体感卡顿的来源。
669:   _old_iface=$(cat "$DNS_ACTIVE_CACHE" 2>/dev/null)
670:   _new_iface=$(dns_default_iface 2>/dev/null)
671:   [ -f "$DNS_VPN_CACHE" ] && _old_vpn=$(cat "$DNS_VPN_CACHE" 2>/dev/null) || _old_vpn=0
672:   _new_vpn=0
673:   dns_vpn_active && _new_vpn=1
674: 
675:   _iv=$(cfg_get dns_verify_interval 600)
676:   case "$_iv" in ''|*[!0-9]*) _iv=600 ;; esac
677:   _stamp="$A2A_LIVE/.dnsverify"
678:   _now_s=$(date +%s 2>/dev/null)
679:   case "$_now_s" in ''|*[!0-9]*) _now_s=0 ;; esac
680:   _last=0
681:   [ -f "$_stamp" ] && _last=$(cat "$_stamp" 2>/dev/null)
682:   case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
683: 
684:   if [ "$_old_iface" != "${_new_iface:-unknown}" ] || [ "${_old_vpn:-0}" != "$_new_vpn" ]; then
685:     log_to "$SUPLOG" "网络变化：iface=${_old_iface:-unknown}->${_new_iface:-unknown} vpn=${_old_vpn:-0}->$_new_vpn"
686:     rm -f "$A2A_LIVE/dns.aaaa" 2>/dev/null
687:     if dns_liveness_ok; then
688:       # 现有 DNS 还能用就什么都不动——开关 VPN 时服务端零感知
689:       printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
690:       printf '%s' "${_new_iface:-unknown}" >"$DNS_ACTIVE_CACHE" 2>/dev/null
691:       printf '%s' "$_new_vpn" >"$DNS_VPN_CACHE" 2>/dev/null
692:       log_to "$SUPLOG" "现有 DNS 仍然可用，保持不动"
693:       return 0
694:     fi
695:     log_to "$SUPLOG" "现有 DNS 已不可用，进入分级兜底"
696:   elif [ "$_iv" -gt 0 ] && [ "$_now_s" -gt 0 ] && [ $((_now_s - _last)) -lt "$_iv" ]; then
697:     return 0
698:   elif dns_liveness_ok; then
699:     printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
700:     return 0
701:   else
702:     log_to "$SUPLOG" "DNS 定期验活失败，进入分级兜底"
703:   fi
704:   printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
705:   dns_ensure
```

## apk-mod/src/pages/SettingsPage.tsx:443-510
```text
443: function GatewaySwitches() {
444:   const [state, setState] = useState<SwitchState>({})
445:   const [ready, setReady] = useState(false)
446:   const [busyId, setBusyId] = useState<SwitchId | null>(null)
447:   const alive = useRef(true)
448: 
449:   const load = useCallback(async (silent: boolean) => {
450:     const next = await fetchSwitches()
451:     if (!alive.current) return
452:     setState(next)
453:     setReady(true)
454:     if (!silent && Object.keys(next).length === 0) {
455:       store.toast(t('读取网关开关失败：网关版本可能不支持'), 'err')
456:     }
457:   }, [])
458: 
459:   useEffect(() => {
460:     alive.current = true
461:     void load(false)
462:     const timer = window.setInterval(() => void load(true), 5000)
463:     const onVisible = () => {
464:       if (document.visibilityState === 'visible') void load(true)
465:     }
466:     document.addEventListener('visibilitychange', onVisible)
467:     return () => {
468:       alive.current = false
469:       window.clearInterval(timer)
470:       document.removeEventListener('visibilitychange', onVisible)
471:     }
472:   }, [load])
473: 
474:   const toggle = async (id: SwitchId, next: boolean) => {
475:     const prev = state[id]
476:     setState(current => ({ ...current, [id]: next }))
477:     setBusyId(id)
478:     try {
479:       const saved = await saveSwitch(id, next)
480:       if (!alive.current) return
481:       setState(current => ({ ...current, ...saved }))
482:       store.toast(next ? t('已开启') : t('已关闭'))
483:     } catch (error) {
484:       if (!alive.current) return
485:       setState(current => ({ ...current, [id]: prev }))
486:       store.toast(t('保存失败：{message}', { message: error instanceof Error ? error.message : String(error) }), 'err')
487:     } finally {
488:       if (alive.current) setBusyId(null)
489:     }
490:   }
491: 
492:   const renderGroup = (group: 'gateway' | 'protection', title: string) => {
493:     const defs = switchesOf(group)
494:     if (defs.length === 0) return null
495:     return (
496:       <div className='m-section' style={{ marginTop: 0 }}>
497:         <SectionHead title={title} />
498:         <div className='m-card'>
499:           {defs.map((def, index) => {
500:             const value = state[def.id]
501:             return (
502:               <div key={def.id} style={index === 0 ? undefined : { borderTop: '1px solid var(--m-line)' }}>
503:                 <SwitchRow
504:                   label={t(def.label)}
505:                   hint={t(def.hint)}
506:                   checked={value === true}
507:                   // 还没读到值（端点失败 / 老网关）就锁住：宁可显示灰的，也不给一个
508:                   // 拨了没反应的开关 —— 那是最难查的静默失败
509:                   disabled={!ready || value === undefined || busyId === def.id}
510:                   onChange={next => void toggle(def.id, next)}
```

## apk-mod/src/api/switches.ts:153-191
```text
153: export async function fetchSwitches(signal?: AbortSignal): Promise<SwitchState> {
154:   const paths = Array.from(new Set(SWITCH_DEFS.map(def => def.path)))
155:   const bodies = new Map<string, unknown>()
156:   await Promise.all(
157:     paths.map(async path => {
158:       try {
159:         bodies.set(path, await apiCall(path, { signal, quiet: true }))
160:       } catch {
161:         bodies.set(path, undefined)
162:       }
163:     }),
164:   )
165:   const state: SwitchState = {}
166:   for (const def of SWITCH_DEFS) {
167:     const value = pick(bodies.get(def.path), def)
168:     if (value !== undefined) state[def.id] = value
169:   }
170:   return state
171: }
172: 
173: /**
174:  * 写一个开关。返回**同端点上所有开关**的新值（响应体是整份状态）。
175:  *
176:  * 调用方负责乐观更新与失败回滚：这里只在网络/接口失败时抛错。
177:  */
178: export async function saveSwitch(id: SwitchId, next: boolean): Promise<SwitchState> {
179:   const def = SWITCH_DEFS.find(item => item.id === id)
180:   if (!def) return {}
181:   const body = await apiCall(def.path, { method: 'PUT', body: { [def.field]: next } })
182:   const state: SwitchState = {}
183:   for (const item of SWITCH_DEFS) {
184:     if (item.path !== def.path) continue
185:     const value = pick(body, item)
186:     if (value !== undefined) state[item.id] = value
187:   }
188:   // 后端回了 200 但响应体里没有这个字段（老版本）：按用户拨的值显示，别让开关弹回去
189:   if (state[id] === undefined) state[id] = next
190:   return state
191: }
```

## test/run.sh:17-39
```text
17: HERE=$(cd "$(dirname "$0")" && pwd)
18: SRC="$HERE/../module"
19: # 刻意用 POSIX 字面路径：$TMPDIR 在 MSYS 下会展开成 C:\... 反斜杠路径，
20: # tar 会把反斜杠当转义符，导致所有用例都"失败"（假阳性）。
21: WORK="/tmp/a2a-test.$$"
22: rm -rf "$WORK"; mkdir -p "$WORK" || exit 1
23: 
24: MODDIR="$WORK/mod"
25: mkdir -p "$MODDIR/bin" "$MODDIR/rootfs/usr/share/zoneinfo/Asia" "$MODDIR/rootfs/etc"
26: cp "$SRC/bin/lib.sh" "$MODDIR/bin/lib.sh"
27: : > "$MODDIR/rootfs/usr/share/zoneinfo/Asia/Shanghai"
28: 
29: export AGENT2API_DATA_DIR="$WORK/data"
30: mkdir -p "$AGENT2API_DATA_DIR/logs" "$AGENT2API_DATA_DIR/data"
31: 
32: # 桩：Android 命令在开发机上不存在
33: getprop() { case "${1:-}" in net.dns1) echo 1.1.1.1 ;; *) echo "" ;; esac; }
34: dumpsys() { echo "  DNS servers: [ /9.9.9.9 /8.8.4.4 ]"; }
35: cmd() { return 0; }
36: 
37: MODDIR=$MODDIR
38: . "$MODDIR/bin/lib.sh"
39: 
```

## README.md:99-116
```text
99:   tools/               curl、cacert.pem
100:   webroot/             KernelSU 状态卡（status.json / lastlog.txt）
101:   zoneinfo/            时区库（约 400 个区）
102:   settings.conf.example 配置模板
103: apk-mod/               手机端 APK 改造
104:   src/                 改动过的 6 个前端源文件
105:   a2a-mobile-mod.patch 对上游 desktop-tauri/mobile 的完整 diff
106:   repack.py            把重新构建的 Web 产物塞回官方 APK
107:   a2a-mod.jks          APK 签名密钥库（口令 a2a-mod-2026）
108:   README-mod.md        APK 侧的详细说明与验证记录
109: docs/                  审计 / 修复报告
110:   2026-11-03-源码审计-Agent2API-Android17.md   第一轮完整源码审计（19 项发现）
111:   fix-verification-2026-11-03.md              第一轮 19 项修复的逐项复测记录
112:   fix-verify-2026-11-03.json                  第一轮复测原始输出
113:   2026-11-03_Agent2API-magisk31-独立复审.md    独立复审：13 项真解决 / 6 项部分修复 + 19 组新问题
114:   2026-11-03_Agent2API-magisk32-19组修复报告.md 本轮按复审报告逐条修复的正式报告与复验证据
115: test/run.sh            离线桩测试（不需要真机）
116: test/fix_verify.py     第一轮 19 项修复的复测夹具（历史保留）
```

## README.md:180-195
```text
180: 
181: ---
182: 
183: ## 构建
184: 
185: ```bash
186: python pack.py          # → dist/agent2api-magisk-vX.Y.Z-magisk.NN-arm64.zip
187: dash test/run.sh        # 离线桩测试，不需要真机
188: python test/verify_fixes.py   # R01–R19 函数级复验（32 项；需要 msys sh 或设 A2A_SH）
189: python test/verify_loop.py    # 主循环集成复验（8 个场景；夹具由上一个脚本生成，先跑它）
190: ```
191: 
192: 两个复验脚本都按自身位置定位 `../module`，默认把中间产物写到 `test/verify_fixes/out/`、
193: `test/verify_loop/out/`；可用环境变量 `A2A_MODULE`、`A2A_VERIFY_OUT`、`A2A_SH`、`A2A_CURL` 覆盖。
194: 
195: APK 侧（需要 Node 20+，构建细节见 `apk-mod/README-mod.md`）：
```

## test/verify_fixes.py:18-34
```text
18: # 默认按脚本自身位置定位源码（脚本放 <repo>/test/ 下即可直接跑）；
19: # 也可用环境变量 A2A_MODULE / A2A_VERIFY_OUT 覆盖。
20: ROOT = Path(os.environ.get('A2A_VERIFY_OUT') or (Path(__file__).resolve().parent / 'out'))
21: SRC = Path(os.environ.get('A2A_MODULE') or (Path(__file__).resolve().parent.parent / 'module'))
22: BIN = Path(r'C:/Users/Y-H/.dsh/profiles/desktop/node_modules/@dsh-ops/bash-win32-x64/usr/bin')
23: # Windows 用 msys sh，其它平台可设 A2A_SH 指向系统 sh。
24: SH = os.environ.get('A2A_SH') or str(BIN / 'sh.exe')
25: SHX = '/' + str(BIN).replace('\\', '/')[0].lower() + str(BIN).replace('\\', '/')[2:]
26: CURL = os.environ.get('A2A_CURL') or '/ucrt64/bin/curl'
27: ROOT.mkdir(parents=True, exist_ok=True)
28: obs, results, summary = [], {}, []
29: 
30: 
31: def posix(p):
32:     s = str(p).replace('\\', '/')
33:     return '/' + s[0].lower() + s[2:]
34: 
```

## test/verify_loop.py:14-24
```text
14: 
15: ROOT = Path(os.environ.get('A2A_VERIFY_OUT') or (Path(__file__).resolve().parent / 'out'))
16: SRC = Path(os.environ.get('A2A_MODULE') or (Path(__file__).resolve().parent.parent / 'module'))
17: BIN = Path(r'C:/Users/Y-H/.dsh/profiles/desktop/node_modules/@dsh-ops/bash-win32-x64/usr/bin')
18: SH = os.environ.get('A2A_SH') or str(BIN / 'sh.exe')
19: ROOT.mkdir(parents=True, exist_ok=True)
20: results, summary = {}, []
21: 
22: 
23: def posix(p):
24:     s = str(p).replace('\\', '/')
```

## apk-mod/repack.py:1-25
```text
1: #!/usr/bin/env python3
2: """把重新构建的 Web 产物打进官方 APK，并保留原有的压缩方式。
3: 
4: 为什么用 Python 重写 zip 而不是 gradle 重编：
5:   · 本次改动全在 `assets/public/`（Capacitor 的 Web 根），原生层一行没动；
6:   · 重编需要完整 Android SDK + AGP + 网络拉依赖，改一行 JS 却要几分钟；
7:   · zip 重写能把「哪些条目必须 STORED」这种细节钉死（resources.arsc 必须
8:     STORED，否则 Android 11+ 装不上 —— 这是最常见的自打包翻车点）。
9: 
10: 旧签名（META-INF/*.RSA|*.SF|*.MF）必须删掉：留着它们 apksigner 会拒绝，
11: 或者签出「双签名」的坏包。
12: """
13: import os
14: import sys
15: import zipfile
16: 
17: ORIG = r"E:\AI\work\agent2api\apk\Agent2API-3.1.0.apk"
18: WEB = r"E:\AI\tmp\a2a-src\desktop-tauri\mobile\android-www"
19: OUT = r"E:\AI\work\agent2api\apk\Agent2API-3.1.2-mod-unsigned.apk"
20: 
21: # 原包里这几个 0 字节占位是 Capacitor 的 cordova 兼容层产物，构建产物里没有，
22: # 原样带上，免得哪天 WebView 侧真去 require 它们
23: EXTRA = ["cordova.js", "cordova_plugins.js"]
24: 
25: SIG_SUFFIX = (".RSA", ".SF", ".MF", ".DSA", ".EC")
```
