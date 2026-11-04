#!/system/bin/sh
# Agent2API 模块 · 载荷事务、完整备份与恢复
# 任意复制/校验/切换失败都返回非零；不在原载荷上做不完整覆盖。

payload_file() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1 | tr -d '\r'; }
payload_version() { payload_file ver "$PAYLOAD/VERSION"; }
payload_built() { payload_file built "${1:-$PAYLOAD}/VERSION"; }

# ---------------------------------------------------------------------------
# 事务/代次 ID（问题 3）
# 时间戳+随机数，用于把「健康证据」绑定到具体一次载荷切换：切换时原子写入
# 代次文件，pending 携带同一 txid；提交前必须三方一致（pending txid ==
# 子进程启动时代次 == 磁盘当前代次），防止删错别的代次的旧载荷。
# ---------------------------------------------------------------------------
payload_txid_new() {
  _tx_ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
  case "$_tx_ts" in ''|*[!0-9-]*) _tx_ts=$(now_epoch 2>/dev/null) ;; esac
  _tx_r=$(head -c 4 /dev/urandom 2>/dev/null | od -An -tx1 2>/dev/null | tr -d ' \t\r\n')
  case "$_tx_r" in ????????) ;; *) _tx_r=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-') ;; esac
  case "$_tx_r" in ''|*[!0-9a-fA-F]*) _tx_r="fb$$$(now_epoch 2>/dev/null)" ;; esac
  printf '%s-%s-%s' "$_tx_ts" "$$" "$_tx_r"
}

# 读当前代次 txid；没有代次文件（旧版安装）时输出空串并返回 0
payload_generation_read() {
  [ -r "$RUNDIR/payload.generation" ] || return 0
  awk 'NR==1{print $1; exit}' "$RUNDIR/payload.generation" 2>/dev/null
}

# 原子写代次文件：内容一行 "txid epoch tag pid"
payload_generation_write() { # $1=txid $2=事务标签
  printf '%s %s %s %s\n' "$1" "$(now_epoch)" "${2:-update}" "$$" \
    >"$RUNDIR/payload.generation.tmp.$$" 2>/dev/null \
  && mv -f "$RUNDIR/payload.generation.tmp.$$" "$RUNDIR/payload.generation" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 事务 journal（F-001/F-002/F-003）
# 单行、定长字段、tmp+rename 原子落盘。它是「跨重启唯一可信的进度记录」：
# 磁盘上的 payload/data 目录只能证明"现在长什么样"，journal 才能证明
# "上一笔事务走到了哪一步、还有什么没收尾"。
#
#   v1 <txid> <phase> <pid> <startticks> <tag> <old_payload> <data_snap>
#      <data_tmp> <data_aside> <epoch> <new_built>
#
# phase 取值（严格递进的提交状态机）：
#   prepared        已取锁、写 update.active，尚未动任何持久状态
#   quiesced        服务已停并核实无残留写者
#   snapshotted     数据快照已就位（data_snap=1）
#   switching       切换标记已写，第一次 rename 可能已发生
#   switched        新载荷已通过身份校验、代次已落盘
#   started         已尝试启动新载荷（服务可能写过数据）
#   verified        新载荷通过健康检查，等待提交
#   committed       已提交（正常收尾，journal 随即删除）
#   await-verify    有意保留的「已安装未验证」（更新前服务就是停的），
#                   开机保留新载荷，交给 supervise 按 pending-verify 提交
#   rolling-back    正在回滚（payload + data）
#   rollback-blocked 停不下来，回滚推迟到下次开机
# 未知 phase 一律只清 journal 不动现场；字段缺失写 "-"。
# ---------------------------------------------------------------------------
A2A_TXN_JOURNAL="$RUNDIR/update.journal"

# 写 journal：$1=phase；其余字段取全局（调用方设置，未设置则记 "-"）。
# 写失败必须让调用方失败：journal 是恢复的依据，静默丢失等于丢事务。
payload_txn_write() { # $1=phase
  _ptw_phase=${1:-unknown}
  _ptw_tmp="$A2A_TXN_JOURNAL.tmp.$$"
  mkdir -p "$RUNDIR" 2>/dev/null
  printf 'v1 %s %s %s %s %s %s %s %s %s %s %s\n' \
    "${PAYLOAD_TXID:--}" "$_ptw_phase" "$$" "$(proc_start_ticks $$ 2>/dev/null)" \
    "${TXN_TAG:--}" "${TXN_OLD_PAYLOAD:--}" "${TXN_DATA_SNAP:-0}" \
    "${TXN_DATA_TMP:--}" "${TXN_DATA_ASIDE:--}" "$(now_epoch)" \
    "${TXN_NEW_BUILT:--}" >"$_ptw_tmp" 2>/dev/null \
  && mv -f "$_ptw_tmp" "$A2A_TXN_JOURNAL" 2>/dev/null || {
    rm -f "$_ptw_tmp" 2>/dev/null
    return 1
  }
  return 0
}

payload_txn_field() { # $1=字段号（1..12）
  [ -s "$A2A_TXN_JOURNAL" ] || return 0
  awk -v n="$1" 'NR==1{print $n; exit}' "$A2A_TXN_JOURNAL" 2>/dev/null
}

payload_txn_phase() { payload_txn_field 3; }

payload_txn_clear() {
  rm -f "$A2A_TXN_JOURNAL" "$A2A_TXN_JOURNAL".tmp.* 2>/dev/null
  return 0
}

# journal 登记的进程是否还活着（pid + 启动代次双核，防 PID 复用）
payload_txn_owner_alive() {
  _pto_pid=$(payload_txn_field 4)
  _pto_ticks=$(payload_txn_field 5)
  case "$_pto_pid$_pto_ticks" in ''|*[!0-9]*) return 1 ;; esac
  pid_alive "$_pto_pid" 2>/dev/null || return 1
  [ "$(proc_start_ticks "$_pto_pid" 2>/dev/null)" = "$_pto_ticks" ]
}

# 把 journal 当前字段读回 TXN_* 全局。给「需要重写 journal 但不应丢失既有
# 字段」的路径用（如数据回滚只更新 tmp/aside 与 phase；a2a 手动回滚时
# 事务上下文并不在环境里，不回填就会把 old_payload 顶成 "-"）。
payload_txn_reload() {
  [ -s "$A2A_TXN_JOURNAL" ] || return 1
  TXN_TAG=$(payload_txn_field 6); [ "$TXN_TAG" = "-" ] && TXN_TAG=""
  TXN_OLD_PAYLOAD=$(payload_txn_field 7); [ "$TXN_OLD_PAYLOAD" = "-" ] && TXN_OLD_PAYLOAD=""
  TXN_DATA_SNAP=$(payload_txn_field 8)
  TXN_DATA_TMP=$(payload_txn_field 9); [ "$TXN_DATA_TMP" = "-" ] && TXN_DATA_TMP=""
  TXN_DATA_ASIDE=$(payload_txn_field 10); [ "$TXN_DATA_ASIDE" = "-" ] && TXN_DATA_ASIDE=""
  TXN_NEW_BUILT=$(payload_txn_field 12); [ "$TXN_NEW_BUILT" = "-" ] && TXN_NEW_BUILT=""
  return 0
}

# 数据目录换入的中断收尾：可重复执行（幂等），绝不把 data 留成空目录。
# $1=data_tmp（快照副本，换入前临时名） $2=data_aside（升级后数据移开的位置）
#
# 「换入做到哪一步」只能看 aside 目录在不在，不能看 $DATADIR 是不是非空：
#   · aside 在      → 第一次 rename（DATADIR -> aside）已完成，$DATADIR 要么
#                     不存在（两次 rename 之间），要么已经是换进来的快照；
#   · aside 不在    → 第一次 rename 还没发生（或失败），$DATADIR 仍是升级后的
#                     数据，$_ptd_tmp 是唯一的升级前快照，必须真的换进去。
# 旧实现用「$DATADIR 非空 = 已就位」判断：换入还没开始时 $DATADIR 本来就非空，
# 于是把唯一快照删掉、回滚等于没做，还把错误的数据当成已恢复（RR-04）。
# restored 是持久化的数据完成状态；进程重启后也不得重新复制快照。
payload_data_mark_restored() {
  if [ -s "$A2A_TXN_JOURNAL" ]; then
    payload_txn_reload || return 1
    PAYLOAD_TXID=$(payload_txn_field 2)
    TXN_DATA_SNAP=restored
    TXN_DATA_TMP=""
    TXN_DATA_ASIDE=""
    payload_txn_write rolling-back || return 1
  fi
  PAYLOAD_DATA_RECOVERED=1
  return 0
}

payload_txn_recover_data() {
  _ptd_tmp=${1:-}
  _ptd_aside=${2:-}
  PAYLOAD_DATA_RECOVERED=0
  [ -n "$_ptd_tmp$_ptd_aside" ] || return 0
  if [ -n "$_ptd_tmp" ] && [ -d "$_ptd_tmp" ]; then
    # tmp 尚在意味着第二次 rename 未完成；data 和 aside 同时在是矛盾现场，
    # 不能仅凭 data 非空宣布成功并销毁唯一快照。
    if [ -n "$_ptd_aside" ] && [ -d "$_ptd_aside" ]; then
      if [ -d "$DATADIR" ]; then
        rmdir "$DATADIR" 2>/dev/null || return 1
      fi
    else
      [ -n "$_ptd_aside" ] || return 1
      if [ -d "$DATADIR" ]; then
        mv "$DATADIR" "$_ptd_aside" 2>/dev/null || return 1
      fi
    fi
    if ! mv "$_ptd_tmp" "$DATADIR" 2>/dev/null; then
      # 放回升级后的现场只是保全，不是回滚成功。保留 tmp 供下次重试。
      if [ -d "$_ptd_aside" ] && [ ! -e "$DATADIR" ]; then
        mv "$_ptd_aside" "$DATADIR" 2>/dev/null || true
      fi
      return 1
    fi
  elif [ -n "$_ptd_tmp" ] && [ -d "$_ptd_aside" ] && [ -d "$DATADIR" ]; then
    # 第二次 rename 已完成，tmp 被移动进 data；aside 保留到完成记录落盘。
    :
  else
    # 路径丢失、仅剩 aside 或无法确认身份时保留记录，禁止猜测成功。
    return 1
  fi
  chmod 700 "$DATADIR" 2>/dev/null
  payload_data_mark_restored || return 1
  rm -rf "$_ptd_aside" 2>/dev/null
  log_to "$UPDLOG" "中断数据换入已完成并持久记录，禁止重复复制快照"
  return 0
}

# 按 journal 收尾一笔中断的事务。$1=boot|runtime：
#   boot    开机（post-fs-data）：此刻锁已清、不可能有活的事务进程；
#   runtime supervise / 安装脚本运行期：journal 主人活着就什么都不做。
# 返回 0=已处理（或无需处理），1=没有 journal（调用方走旧逻辑）或处理失败。
payload_txn_recover() {
  _ptr_mode=${1:-runtime}
  [ -s "$A2A_TXN_JOURNAL" ] || return 1
  if [ "$_ptr_mode" != "boot" ] && payload_txn_owner_alive; then
    log_to "$SUPLOG" "更新事务仍在运行（pid=$(payload_txn_field 4)），跳过恢复"
    return 0
  fi
  _ptr_phase=$(payload_txn_phase)
  _ptr_txid=$(payload_txn_field 2)
  _ptr_old=$(payload_txn_field 7)
  _ptr_dsnap=$(payload_txn_field 8)
  _ptr_dtmp=$(payload_txn_field 9)
  _ptr_daside=$(payload_txn_field 10)
  _ptr_newbuilt=$(payload_txn_field 12)
  [ "$_ptr_old" = "-" ] && _ptr_old=""
  [ "$_ptr_dtmp" = "-" ] && _ptr_dtmp=""
  [ "$_ptr_daside" = "-" ] && _ptr_daside=""
  [ "$_ptr_newbuilt" = "-" ] && _ptr_newbuilt=""
  # 回填 TXN_* 全局：后续 payload_data_rollback 等函数重写 journal 时，
  # 本笔事务的字段不能被 "-" 顶掉（字段丢 = 恢复材料丢）。
  payload_txn_reload
  PAYLOAD_TXID="$_ptr_txid"
  log_to "$UPDLOG" "发现中断的事务 journal（phase=$_ptr_phase txid=$_ptr_txid），开始收尾"

  # 数据目录的换入/移开独立于载荷：先收干净，别让后面的流程见到"空 data"。
  # 返回值必须看：换入失败还继续往下清 journal，等于把唯一的升级前快照
  # 当成已恢复（RR-04）。失败就先记下，收尾时保留 journal 等下次重试。
  _ptr_drc=0
  payload_txn_recover_data "$_ptr_dtmp" "$_ptr_daside" || {
    log_to "$UPDLOG" "中断数据换入失败，保留 journal 与全部恢复材料"
    return 1
  }

  case "$_ptr_phase" in
    prepared|quiesced|snapshotted)
      # 没进入切换：当前载荷就是旧的，数据也没被覆盖过。清记录即可。
      log_to "$UPDLOG" "事务未进入切换阶段（$_ptr_phase），仅清理记录"
      payload_txn_clear
      return 0
      ;;
    verified|committed)
      # 健康证据已拿到：保留新载荷。旧载荷交给 supervise 首轮健康后提交。
      log_to "$UPDLOG" "事务已通过健康检查（$_ptr_phase），保留新载荷"
      payload_txn_clear
      return 0
      ;;
    await-verify)
      # 有意为之的「已安装未验证」（更新前服务就是停止的，问题 8）：保留
      # 新载荷，交给 supervise 按 pending-verify 标记在健康启动后提交。
      log_to "$UPDLOG" "事务处于已安装待验证状态，保留新载荷等 supervise 提交"
      payload_txn_clear
      return 0
      ;;
    rolling-back|rollback-blocked|rollback-failed)
      # 回滚进行中 / 上次回滚没做完：走下面的完整回滚路径（幂等）。
      ;;
    switching|switched|started)
      # 切换后、健康验证前中断：按"未验证"处理，回滚到旧载荷。
      ;;
    *)
      log_to "$UPDLOG" "未知事务阶段 $_ptr_phase，仅清理记录不动现场"
      payload_txn_clear
      return 0
      ;;
  esac

  # ---- 载荷收尾 ----
  _ptr_cur_ok=0
  payload_validate "$PAYLOAD" >/dev/null 2>&1 && _ptr_cur_ok=1
  # 当前载荷是否就是本笔事务的新载荷：代次一致或 built 一致都算。
  _ptr_cur_new=0
  if [ -n "$_ptr_txid" ] && [ "$_ptr_txid" != "-" ] \
     && [ "$(payload_generation_read)" = "$_ptr_txid" ]; then
    _ptr_cur_new=1
  elif [ -n "$_ptr_newbuilt" ] && [ "$(payload_built)" = "$_ptr_newbuilt" ]; then
    _ptr_cur_new=1
  fi

  # 完成标记随旧目录原子换入，覆盖尚未来得及更新的全局 generation。
  # 先写标记再 rename：任意指令间中断都能区分已回滚的目录与新版。
  if [ "$_ptr_cur_ok" = "1" ] && [ -n "$_ptr_txid" ] && [ "$_ptr_txid" != "-" ] \
     && [ "$(cat "$PAYLOAD/.a2a-rollback-txid" 2>/dev/null)" = "$_ptr_txid" ]; then
    _ptr_cur_new=0
  fi

  if [ "$_ptr_cur_new" = "0" ] && [ "$_ptr_cur_ok" = "1" ]; then
    # 已经是旧载荷（第一次 rename 前中断），无需再动。
    log_to "$UPDLOG" "当前载荷未参与切换，保持不动"
  elif [ -n "$_ptr_old" ] && [ -d "$_ptr_old" ] \
       && payload_validate "$_ptr_old" >/dev/null 2>&1; then
    printf '%s\n' "$_ptr_txid" >"$_ptr_old/.a2a-rollback-txid.tmp" 2>/dev/null \
      && mv -f "$_ptr_old/.a2a-rollback-txid.tmp" "$_ptr_old/.a2a-rollback-txid" 2>/dev/null || return 1
    if [ -e "$PAYLOAD" ]; then
      _ptr_bad="$APP_HOME/payload.interrupted.$$"
      rm -rf "$_ptr_bad" 2>/dev/null
      if ! mv "$PAYLOAD" "$_ptr_bad" 2>/dev/null; then
        log_to "$UPDLOG" "无法移开中断载荷，旧版保留在 $_ptr_old，下次再试"
        return 1
      fi
    fi
    if mv "$_ptr_old" "$PAYLOAD" 2>/dev/null \
       && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
      payload_fix_perms "$PAYLOAD" 2>/dev/null
      log_to "$UPDLOG" "已回滚中断的载荷切换：$_ptr_old"
      rm -rf "$APP_HOME/payload.interrupted.$$" 2>/dev/null
    else
      log_to "$UPDLOG" "回滚中断载荷失败，旧版仍在 $_ptr_old"
      return 1
    fi
  elif [ "$_ptr_cur_ok" = "1" ] && [ "$_ptr_cur_new" = "0" ]; then
    # 当前载荷完整但无法确认是新是旧、也没有事务旧目录：保守保留当前。
    log_to "$UPDLOG" "事务旧载荷不存在，当前载荷完整，保留当前载荷"
  else
    if payload_rollback >/dev/null 2>&1; then
      log_to "$UPDLOG" "已用完整备份恢复中断的载荷"
    else
      log_to "$UPDLOG" "中断的载荷无法自动恢复，请手工处理 $PAYLOAD"
      return 1
    fi
  fi

  # ---- 数据收尾：journal 明确记了快照才恢复（快照 txid 校验在函数内部）----
  if [ "$_ptr_dsnap" = "1" ] && [ "${PAYLOAD_DATA_RECOVERED:-0}" != "1" ]; then
    PAYLOAD_TXID="$_ptr_txid"
    if ! payload_data_rollback; then
      log_to "$UPDLOG" "数据快照恢复失败，快照保留在 $BACKUPDIR/data-prev"
      return 1
    fi
    # 数据快照这条独立路径成功就等于数据已还原，不再要求下面那个判据。
    _ptr_drc=0
  fi

  if [ "$_ptr_drc" != "0" ]; then
    log_to "$UPDLOG" "数据目录仍未收尾，journal 保留到下次重试（快照见 $_ptr_dtmp）"
    return 1
  fi

  live_link_refresh 2>/dev/null
  payload_txn_clear
  log_to "$UPDLOG" "中断事务已收尾（phase=$_ptr_phase）"
  return 0
}

# 目录里的主程序是不是 musl 静态链接（没有 glibc 解释器字符串）。
# 用途：静态载荷不需要 lib/ld-linux-aarch64.so.1 与 libc.so.6，
# 判定载荷完整性时必须先区分，否则正常的静态包会被判成坏包。
payload_dir_is_static() { # $1=载荷目录
  [ -f "$1/agent2api-server" ] || return 1
  grep -qa 'ld-linux-aarch64' "$1/agent2api-server" 2>/dev/null && return 1
  grep -qa 'ld-linux' "$1/agent2api-server" 2>/dev/null && return 1
  return 0
}

loader_smoke() { # $1=载荷目录；静态载荷没有解释器可试，直接算通过
  payload_dir_is_static "$1" && return 0
  _ls_loader="$1/lib/ld-linux-aarch64.so.1"
  [ -x "$_ls_loader" ] || return 1
  "$_ls_loader" --version >/dev/null 2>&1
}

payload_validate() { # $1=目录 $2=soft
  _d="$1"; _soft="${2:-}"
  [ -d "$_d" ] || { echo "目录不存在"; return 1; }
  [ -s "$_d/agent2api-server" ] || { echo "缺少 agent2api-server"; return 1; }
  elf_magic_ok "$_d/agent2api-server" || { echo "agent2api-server 不是 ELF"; return 1; }
  _arch=$(elf_arch "$_d/agent2api-server")
  [ "$_arch" = "aarch64" ] || { echo "架构不对（$_arch，需要 aarch64）"; return 1; }
  # 只有动态载荷才需要自带 glibc。静态主程序没有 PT_INTERP，
  # 强求 lib/ld-linux-aarch64.so.1 会把合法静态包判成坏包，
  # 进而让安装/回滚/中断恢复全部拒绝静态载荷。
  if [ "$_soft" != "soft" ] && ! payload_dir_is_static "$_d"; then
    [ -s "$_d/lib/ld-linux-aarch64.so.1" ] || { echo "缺少动态链接器"; return 1; }
    [ -s "$_d/lib/libc.so.6" ] || { echo "缺少 libc"; return 1; }
  fi
  [ -d "$_d/ui" ] && [ -s "$_d/ui/index.html" ] || { echo "UI 不完整"; return 1; }
  return 0
}

payload_fix_perms() {
  _d="$1"
  # R05：静态（musl）载荷没有 lib/ 目录。把 chmod lib 当硬失败，会让
  # "payload_validate 已经通过"的静态包在权限阶段被判死，安装/更新/回滚
  # 全都走不下去。动态载荷该有的检查一条不少，静态载荷按实际布局处理。
  chmod 755 "$_d" "$_d/agent2api-server" 2>/dev/null || return 1
  if [ -d "$_d/lib" ]; then
    chmod 755 "$_d/lib" 2>/dev/null || return 1
    for _f in "$_d/lib/"*.so*; do
      [ -e "$_f" ] || continue
      chmod 755 "$_f" 2>/dev/null || return 1
    done
  fi
  [ ! -e "$_d/VERSION" ] || chmod 644 "$_d/VERSION" 2>/dev/null || return 1
  chmod_tree "$_d/ui" 755 644 || return 1
  return 0
}

# owner 通过硬链接原子发布，内容始终完整；stale 回收由第二把短命互斥锁串行化。
# 回收前后都核对完整 owner 代次，绝不按路径盲删另一个事务刚取得的锁。
UPDATE_LOCK_TOKEN=""
UPDATE_LOCK_PATH=""
update_lock_acquire() { # $1=锁目录 $2=竞争/回收重试秒数，活动事务始终不强制抢占
  _ul_lock="${1:-$RUNDIR/update.lock.d}"
  _ul_parent=${_ul_lock%/*}
  [ "$_ul_parent" != "$_ul_lock" ] || _ul_parent=$RUNDIR
  mkdir -p "$_ul_parent" "$_ul_lock" 2>/dev/null || return 1
  _ul_start=$(proc_start_ticks $$ 2>/dev/null) || _ul_start=""
  case "$_ul_start" in ''|*[!0-9]*) say "无法确认当前进程身份，取消加锁"; return 1 ;; esac
  _ul_wait=${2:-120}
  case "$_ul_wait" in ''|*[!0-9]*) _ul_wait=120 ;; esac
  _ul_n=0
  while [ "$_ul_n" -lt "$_ul_wait" ]; do
    _ul_token="$$.$_ul_start.$(now_epoch).$_ul_n"
    _ul_claim="$_ul_parent/.update.claim.$_ul_token"
    _ul_guard_claim="$_ul_parent/.update.reap.claim.$_ul_token"
    rm -f "$_ul_claim" "$_ul_guard_claim" 2>/dev/null
    if ! printf '%s %s %s\n' "$$" "$_ul_start" "$_ul_token" >"$_ul_claim" 2>/dev/null; then
      rm -f "$_ul_claim"; return 1
    fi
    if ln "$_ul_claim" "$_ul_lock/owner" 2>/dev/null; then
      if [ "$(cat "$_ul_lock/owner" 2>/dev/null)" = "$(cat "$_ul_claim" 2>/dev/null)" ]; then
        UPDATE_LOCK_TOKEN=$_ul_token
        UPDATE_LOCK_PATH=$_ul_lock
        rm -f "$_ul_claim"
        return 0
      fi
      rm -f "$_ul_lock/owner" 2>/dev/null
    fi
    _ul_seen=$(cat "$_ul_lock/owner" 2>/dev/null) || _ul_seen=""
    _ul_owner=$(printf '%s\n' "$_ul_seen" | awk '{print $1}')
    _ul_oldstart=$(printf '%s\n' "$_ul_seen" | awk '{print $2}')
    if [ -n "$_ul_owner" ] && [ -n "$_ul_oldstart" ] && pid_alive "$_ul_owner" \
       && [ "$(proc_start_ticks "$_ul_owner" 2>/dev/null)" = "$_ul_oldstart" ]; then
      rm -f "$_ul_claim" "$_ul_guard_claim" 2>/dev/null
      say "另一个安装/更新事务正在运行（pid=$_ul_owner）"
      return 1
    fi

    # stale owner 可能存在。先原子取得回收权，再核验它仍是刚才看到的代次。
    printf '%s\n' "$_ul_token" >"$_ul_guard_claim" 2>/dev/null || {
      rm -f "$_ul_claim" "$_ul_guard_claim"; return 1;
    }
    if ! ln "$_ul_guard_claim" "$_ul_lock/reaping" 2>/dev/null; then
      # 回收权也可能被一个已经死掉的回收者占着（拿到 reaping 之后、
      # 删 owner 之前被杀）。reaping 里存的就是它的 token：pid.start.epoch.n，
      # pid 与启动代次都对不上时判定僵死，直接摘掉标记重试，
      # 否则这个锁会永久卡死，任何安装/更新/回滚都进不来。
      _ul_rtok=$(cat "$_ul_lock/reaping" 2>/dev/null) || _ul_rtok=""
      _ul_rpid=$(printf '%s\n' "$_ul_rtok" | awk -F. '{print $1}')
      _ul_rstart=$(printf '%s\n' "$_ul_rtok" | awk -F. '{print $2}')
      case "$_ul_rpid$_ul_rstart" in
        ''|*[!0-9]*) ;;
        *)
          if ! pid_alive "$_ul_rpid" \
             || [ "$(proc_start_ticks "$_ul_rpid" 2>/dev/null)" != "$_ul_rstart" ]; then
            # R08：摘除前必须确认 reaping 还是刚才读到的这一份。回收权在持有
            # 期间别人不能新建，但"读到 → 判定僵死 → 删"之间若发生过期删除＋
            # 重建，盲删就会把新一代活着的回收者的标记删掉。
            _ul_rnow=$(cat "$_ul_lock/reaping" 2>/dev/null) || _ul_rnow=""
            if [ "$_ul_rnow" != "$_ul_rtok" ] || [ -z "$_ul_rnow" ]; then
              rm -f "$_ul_claim" "$_ul_guard_claim" 2>/dev/null
              _ul_n=$((_ul_n + 1)); continue
            fi
            log_to "$SUPLOG" "回收僵死的 reaping 标记（pid=$_ul_rpid 已不在或已复用）"
            rm -f "$_ul_lock/reaping" 2>/dev/null
            rm -f "$_ul_claim" "$_ul_guard_claim" 2>/dev/null
            _ul_n=$((_ul_n + 1)); continue
          fi
          ;;
      esac
      rm -f "$_ul_claim" "$_ul_guard_claim" 2>/dev/null
      _ul_n=$((_ul_n + 1)); sleep 1; continue
    fi
    _ul_current=$(cat "$_ul_lock/owner" 2>/dev/null) || _ul_current=""
    if [ "$_ul_current" = "$_ul_seen" ] && [ -n "$_ul_seen" ]; then
      _ul_owner=$(printf '%s\n' "$_ul_current" | awk '{print $1}')
      _ul_oldstart=$(printf '%s\n' "$_ul_current" | awk '{print $2}')
      if ! pid_alive "$_ul_owner" || [ "$(proc_start_ticks "$_ul_owner" 2>/dev/null)" != "$_ul_oldstart" ]; then
        rm -f "$_ul_lock/owner" 2>/dev/null
      fi
    fi
    # 无 owner 的旧空锁也可直接重试；原子 ln 会选出唯一获胜者。
    rm -f "$_ul_lock/reaping" "$_ul_guard_claim" "$_ul_claim" 2>/dev/null
    _ul_n=$((_ul_n + 1))
  done
  say "更新锁正被另一个回收者处理，请稍后重试"
  return 1
}
update_lock_is_self() { # $1=锁目录；锁是否由当前进程（同 pid 同启动代次）持有
  _uls_owner=$(cat "$1/owner" 2>/dev/null) || return 1
  [ -n "$_uls_owner" ] || return 1
  _uls_pid=$(printf '%s\n' "$_uls_owner" | awk '{print $1}')
  _uls_ticks=$(printf '%s\n' "$_uls_owner" | awk '{print $2}')
  [ "$_uls_pid" = "$$" ] || return 1
  [ -n "$_uls_ticks" ] || return 1
  _uls_self=$(proc_start_ticks $$ 2>/dev/null) || return 1
  [ -n "$_uls_self" ] || return 1
  [ "$_uls_ticks" = "$_uls_self" ] || return 1
  return 0
}

update_lock_release() {
  _ur_lock="${1:-$RUNDIR/update.lock.d}"
  _ur_owner=$(cat "$_ur_lock/owner" 2>/dev/null) || _ur_owner=""
  [ -n "$_ur_owner" ] || return 0
  _ur_pid=$(printf '%s\n' "$_ur_owner" | awk '{print $1}')
  _ur_ticks=$(printf '%s\n' "$_ur_owner" | awk '{print $2}')
  _ur_token=$(printf '%s\n' "$_ur_owner" | awk '{print $3}')
  # R07：判断"这把锁是不是我持有的"要按 owner 里的 pid + 启动代次，而不是读
  # 一个会被嵌套调用冲掉的全局 token（临界区内收到 TERM → handler 再调
  # svc_stop → 内层 release 把 token 清空，外层就再也释放不掉）。旧实现随后
  # update/service 两把 owner 双双残留，下一次安装直接"另一个事务正在运行"。
  _ur_self_ticks=$(proc_start_ticks $$ 2>/dev/null) || _ur_self_ticks=""
  [ "$_ur_pid" = "$$" ] || return 0
  [ -n "$_ur_self_ticks" ] || return 0
  [ "$_ur_ticks" = "$_ur_self_ticks" ] || return 0
  # 同一个 pid 在释放前可能已经重新取过锁（token 变了），那就不是我们这一代。
  if [ -n "$UPDATE_LOCK_TOKEN" ] && [ "$_ur_token" != "$UPDATE_LOCK_TOKEN" ]; then
    return 0
  fi
  rm -f "$_ur_lock/owner" 2>/dev/null || return 1
  # service.lock.d 常嵌套在 update.lock.d 事务内。只清当前锁对应的 token，
  # 内层释放不能抹掉外层身份，否则外层 owner 会遗留到进程退出。
  if [ "$UPDATE_LOCK_PATH" = "$_ur_lock" ]; then
    UPDATE_LOCK_TOKEN=""
    UPDATE_LOCK_PATH=""
  fi
  return 0
}

payload_backup() {
  [ -d "$PAYLOAD" ] || return 0
  payload_validate "$PAYLOAD" >/dev/null 2>&1 || return 1
  rm -rf "$BACKUPDIR/prev.new" 2>/dev/null
  mkdir -p "$BACKUPDIR/prev.new" 2>/dev/null || return 1
  if ! cp -R "$PAYLOAD"/. "$BACKUPDIR/prev.new"/ 2>/dev/null; then
    rm -rf "$BACKUPDIR/prev.new" 2>/dev/null
    echo "备份复制失败（可能空间不足）"
    return 1
  fi
  if ! payload_validate "$BACKUPDIR/prev.new" >/dev/null 2>&1; then
    rm -rf "$BACKUPDIR/prev.new" 2>/dev/null
    echo "备份校验失败，保留原备份"
    return 1
  fi
  rm -rf "$BACKUPDIR/prev.old" 2>/dev/null
  if [ -d "$BACKUPDIR/prev" ] && ! mv "$BACKUPDIR/prev" "$BACKUPDIR/prev.old" 2>/dev/null; then
    rm -rf "$BACKUPDIR/prev.new" 2>/dev/null
    echo "旧备份无法轮换，保留现场"
    return 1
  fi
  if ! mv "$BACKUPDIR/prev.new" "$BACKUPDIR/prev" 2>/dev/null; then
    [ -d "$BACKUPDIR/prev.old" ] && mv "$BACKUPDIR/prev.old" "$BACKUPDIR/prev" 2>/dev/null
    return 1
  fi
  rm -rf "$BACKUPDIR/prev.old" 2>/dev/null
  return 0
}

payload_size_kb() {
  du -sk "$1" 2>/dev/null | awk 'NR == 1 && $1 ~ /^[0-9]+$/ {print $1; found=1} END {if (!found) exit 1}'
}

# 将已校验的 staging 目录切入 $PAYLOAD。目标已存在时绝不把 mv 的“目录嵌套”当成功。
payload_activate_staged() { # $1=staging $2=事务标签
  _pa_tmp=$1
  _pa_tag=${2:-update}
  _pa_old="$APP_HOME/payload.${_pa_tag}.old.$$"
  # 切换需要暂存坏载荷，预先保留唯一且不会嵌套的恢复位置。
  _pa_failed="$APP_HOME/payload.${_pa_tag}.failed.$$"
  _pa_ver=$(payload_file ver "$_pa_tmp/VERSION")
  _pa_built=$(payload_file built "$_pa_tmp/VERSION")
  [ -d "$_pa_tmp" ] || return 1
  [ ! -e "$_pa_old" ] && [ ! -e "$_pa_failed" ] || return 1
  # 问题 3：本笔切换的代次 ID（事务调用方预设 PAYLOAD_TXID；手动回滚等
  # 未预设的场景现场生成，保证每次切换的 txid 唯一）。
  _pa_txid=${PAYLOAD_TXID:-}
  [ -n "$_pa_txid" ] || _pa_txid=$(payload_txid_new)
  if [ "$_pa_tag" = "rollback" ] && [ -s "$A2A_TXN_JOURNAL" ]; then
    printf '%s\n' "$_pa_txid" >"$_pa_tmp/.a2a-rollback-txid.tmp" 2>/dev/null \
      && mv -f "$_pa_tmp/.a2a-rollback-txid.tmp" "$_pa_tmp/.a2a-rollback-txid" 2>/dev/null || return 1
  fi
  # 问题 6：首次 rename 前写「切换进行中」标记（txid+时间戳+旧载荷去向），
  # 切换完成/失败后删除。中断恢复只认这个标记且要求已过期（>120s），
  # 绝不因载荷瞬时缺失就判定上一事务死亡。
  printf '%s %s %s %s\n' "$_pa_txid" "$(now_epoch)" "$$" "$_pa_old" \
    >"$RUNDIR/payload.switching.tmp.$$" 2>/dev/null \
  && mv -f "$RUNDIR/payload.switching.tmp.$$" "$RUNDIR/payload.switching" 2>/dev/null || {
    rm -f "$RUNDIR/payload.switching.tmp.$$" 2>/dev/null
    echo "无法写入载荷切换标记"
    return 1
  }
  printf '%s\n' "$_pa_tag $$ $_pa_old" >"$RUNDIR/update.active" 2>/dev/null || {
    rm -f "$RUNDIR/payload.switching" 2>/dev/null
    return 1
  }
  # F-002/F-003：journal 先于第一次 rename 落盘。rename 窗口里磁盘形态
  # 不可判定，开机恢复只认 journal 的 phase + old_payload/new_built。
  # 仅在「前进方向的前置相位」（无 journal 或 prepared/quiesced/snapshotted）
  # 才写：恢复/回滚期间的二次 activate 不覆盖 journal——已有记录描述的
  # 才是真正的事务现场（例如回滚事务的 old_payload 指向健康旧版，不能
  # 被本次搬开的坏载荷顶掉）。
  case "$(payload_txn_phase)" in
    ''|prepared|quiesced|snapshotted)
      TXN_TAG=${_pa_tag}
      TXN_OLD_PAYLOAD=${_pa_old}
      TXN_NEW_BUILT=${_pa_built}
      payload_txn_write switching || {
        rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
        echo "无法写入事务 journal"
        return 1
      }
      ;;
  esac
  if command -v upd_payload_before_move >/dev/null 2>&1; then
    # B2：钩子拒绝本笔切换时，两个事务标记必须一并清掉，否则会留下孤儿
    # payload.switching（误导中断恢复的过期判定）与悬空的 update.active。
    upd_payload_before_move "$_pa_old" "$_pa_tmp" || {
      rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
      return 1
    }
  fi
  if [ -d "$PAYLOAD" ] && ! mv "$PAYLOAD" "$_pa_old" 2>/dev/null; then
    rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
    echo "无法移开旧载荷"
    return 1
  fi
  if [ -e "$PAYLOAD" ] || ! mv "$_pa_tmp" "$PAYLOAD" 2>/dev/null; then
    # 旧载荷已经移走后，失败恢复不能因 PAYLOAD 非空而跳过。
    # 先把任何现存/嵌套的新目录隔离，再把旧目录移回固定位置。
    if [ -e "$PAYLOAD" ]; then
      mv "$PAYLOAD" "$_pa_failed" 2>/dev/null || {
        echo "切换失败且无法移开新载荷，旧版保留在 $_pa_old"
        return 1
      }
    fi
    if [ -d "$_pa_old" ]; then
      mv "$_pa_old" "$PAYLOAD" 2>/dev/null || {
        echo "切换失败，旧版保留在 $_pa_old"
        return 1
      }
      echo "切换失败，已恢复旧版"
    else
      echo "切换失败，旧版目录不存在"
      return 1
    fi
    rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
    return 1
  fi
  if command -v upd_payload_after_move >/dev/null 2>&1; then
    upd_payload_after_move "$_pa_old" "$_pa_tmp"
  fi
  # 版本/构建身份和意外嵌套都必须核验，不能只信 mv 的返回码。
  if [ -e "$PAYLOAD/${_pa_tmp##*/}" ] \
     || [ "$(payload_file ver "$PAYLOAD/VERSION")" != "$_pa_ver" ] \
     || [ "$(payload_file built "$PAYLOAD/VERSION")" != "$_pa_built" ] \
     || ! payload_validate "$PAYLOAD" >/dev/null 2>&1; then
    if mv "$PAYLOAD" "$_pa_failed" 2>/dev/null; then
      if [ -d "$_pa_old" ] && mv "$_pa_old" "$PAYLOAD" 2>/dev/null; then
        echo "切换后身份校验失败，已恢复旧版"
      else
        echo "切换后身份校验失败，旧版保留在 $_pa_old"
      fi
    else
      echo "切换后身份校验失败，且无法移开新载荷；旧版保留在 $_pa_old"
    fi
    rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
    return 1
  fi
  # 问题 3：代次文件在切换校验通过后、pending 登记前原子落盘。提交链路
  # 要求「pending txid == 启动代次 == 磁盘代次」三方一致；中断恢复也依赖
  # 「代次只在校验通过后才更新」来保持与磁盘上的载荷一致。
  if ! payload_generation_write "$_pa_txid" "$_pa_tag"; then
    # 代次写不进去 = 提交链路失去代次绑定，按切换失败处理，恢复旧版
    if mv "$PAYLOAD" "$_pa_failed" 2>/dev/null; then
      if [ -d "$_pa_old" ] && mv "$_pa_old" "$PAYLOAD" 2>/dev/null; then
        echo "代次文件写入失败，已恢复旧版"
      else
        echo "代次文件写入失败，旧版保留在 $_pa_old"
      fi
    else
      echo "代次文件写入失败，且无法移开新载荷；旧版保留在 $_pa_old"
    fi
    rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
    return 1
  fi
  # 代次已落盘：journal 推进到 switched（新载荷在位、尚未健康验证）。
  # 只推进自己刚写的 switching；写失败不回滚已就位的好载荷——journal
  # 停在 switching，开机恢复按「未验证」处理（回滚），语义仍保守正确。
  case "$(payload_txn_phase)" in
    switching)
      payload_txn_write switched \
        || log_to "$UPDLOG" "journal 推进到 switched 失败（保持 switching）"
      ;;
  esac
  if command -v upd_payload_commit >/dev/null 2>&1; then
    upd_payload_commit "$_pa_old" "$_pa_tmp"
  fi
  # 旧载荷绝不能在这里删：此刻服务端还没做健康检查，健康失败要回滚时
  # 这份同一事务的旧版本是唯一能立刻顶回去的副本（备份目录 prev 是上一代，
  # 不是这一次被换下来的那一份）。改成写 pending 标记，由
  # payload_commit_old 在健康通过/安装收尾后删除。
  # R02：pending 写不成/写不完整绝不能当成功。旧实现丢掉终端错误继续
  # return 0，调用方以为"旧载荷已登记待提交"，实际 marker 是空的：这份
  # 唯一能回滚的旧目录从此没有任何记账，下一轮 sweep 会把它当垃圾删掉。
  # 先写临时文件再 rename，pending 被外来者占成目录时这里会明确失败。
  # pending 格式："tag pid path txid startticks"。前三个字段保持旧格式
  # （a2a / post-fs-data 只读 $1-$3，向后兼容）；txid 供提交时的代次校验，
  # startticks 供中断恢复判定「pending 是否属于已死事务」（问题 3/6）。
  if ! printf '%s\n' "$_pa_tag $$ $_pa_old $_pa_txid $(proc_start_ticks $$ 2>/dev/null)" >"$RUNDIR/update.pending.tmp.$$" 2>/dev/null \
     || ! mv -f "$RUNDIR/update.pending.tmp.$$" "$RUNDIR/update.pending" 2>/dev/null; then
    rm -f "$RUNDIR/update.pending.tmp.$$" 2>/dev/null
    rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
    echo "无法登记待提交的事务旧载荷：$_pa_old（旧版仍在原处，请勿手工删除）"
    return 1
  fi
  rm -f "$RUNDIR/update.active" "$RUNDIR/payload.switching" 2>/dev/null
  # /data/a2a/ld.so 只是"插件解释器"这条旁路，真正的服务端是用绝对路径
  # $LOADER 起的，跟这个软链无关。切换已经成功却因为软链失败报整体失败，
  # 会让调用方回滚一份正确落地的新载荷，反而更糟 —— 降级为告警。
  live_link_refresh || echo "警告：动态链接器软链刷新失败（插件可能暂时不可用，重启后自动重试）"
  return 0
}

# 提交事务旧载荷：只有当前载荷被证明完整时才删，删的是 pending 里记录的
# 那一个路径，绝不按通配符批量删（避免误删别人的回滚副本）。
# 问题 3：这是全模块唯一的旧载荷删除路径（updater 的提交与 supervise 的
# 健康后重试都走这里），内部自带 update 锁（已持有则复用，短超时获取，
# 拿不到就返回 1 让调用方下轮重试，绝不死等）与代次校验（pending 的 txid
# 必须等于磁盘当前代次）。$1 期望"tag pid"（a2a 回滚路径在用），$2 期望
# txid；两者都可选，不匹配时一个字节都不动。
payload_commit_old() { # $1=期望的事务标记"tag pid"（可选） $2=期望 txid（可选）
  _pco_marker="$RUNDIR/update.pending"
  [ -s "$_pco_marker" ] || return 0
  # 临界区：update 锁。supervise 调用时未持锁（短超时获取）；updater / a2a
  # 调用时已持锁（update_lock_is_self 命中则直接复用，不重复获取）。
  _pco_outer_token=${UPDATE_LOCK_TOKEN:-}
  _pco_outer_path=${UPDATE_LOCK_PATH:-}
  _pco_locked=0
  if ! update_lock_is_self "$RUNDIR/update.lock.d"; then
    if update_lock_acquire "$RUNDIR/update.lock.d" 5 >/dev/null 2>&1; then
      _pco_locked=1
    else
      log_to "$SUPLOG" "提交拿不到 update 锁（有活跃事务），本轮跳过"
      return 1
    fi
  fi
  _pco_rc=0
  # 锁内重读：取锁之前读到的内容可能已被别的事务改写
  _pco_line=$(head -n 1 "$_pco_marker" 2>/dev/null) || _pco_line=""
  if [ -z "$_pco_line" ]; then
    # 取锁期间已被别处提交完（marker 被清）：按已提交收场
    :
  else
    _pco_path=$(printf '%s\n' "$_pco_line" | awk '{print $3}')
    if [ -z "$_pco_path" ]; then
      log_to "$SUPLOG" "pending 内容不完整，保留待人工检查"
      _pco_rc=1
    else
      # R03：pending 是全局唯一的一份。调用方给出期望标记时先核对"tag pid"，
      # 对不上就不动。
      if [ -n "${1:-}" ]; then
        _pco_have=$(printf '%s\n' "$_pco_line" | awk '{print $1" "$2}')
        if [ "$_pco_have" != "$1" ]; then
          log_to "$SUPLOG" "pending 属于另一笔事务（期望 $1，实际 ${_pco_have:-空}），跳过提交"
          _pco_rc=1
        fi
      fi
      if [ "$_pco_rc" = "0" ]; then
        # 问题 3：代次校验。pending 的 txid 必须与磁盘当前代次一致；
        # 调用方显式给出期望 txid 时也必须一致。任一侧有代次信息就强制
        # 校验（两侧都没有 = 旧版遗留的 pending，退回 tag 匹配）。
        _pco_txid=$(printf '%s\n' "$_pco_line" | awk '{print $4}')
        _pco_gen=$(payload_generation_read)
        if [ -n "${2:-}" ] && [ "$_pco_txid" != "$2" ]; then
          log_to "$SUPLOG" "pending 代次与调用方期望不符（期望 ${2:-无}，实际 ${_pco_txid:-无}），跳过提交"
          _pco_rc=1
        elif [ -n "$_pco_txid" ] || [ -n "$_pco_gen" ]; then
          if [ "$_pco_txid" != "$_pco_gen" ]; then
            log_to "$SUPLOG" "pending 代次与磁盘当前代次不符（pending=${_pco_txid:-无} 磁盘=${_pco_gen:-无}），跳过提交"
            _pco_rc=1
          fi
        fi
      fi
      if [ "$_pco_rc" = "0" ]; then
        # 只接受本模块自己的临时目录名，挡住 marker 被写坏导致的任意删除。
        case "$_pco_path" in
          "$APP_HOME"/payload.*.old.*|"$APP_HOME"/payload.old)
            if ! payload_validate "$PAYLOAD" >/dev/null 2>&1; then
              log_to "$SUPLOG" "当前载荷不完整，保留事务旧载荷：$_pco_path"
              _pco_rc=1
            elif ! rm -rf "$_pco_path" 2>/dev/null || [ -e "$_pco_path" ]; then
              # R02：删除失败（只读挂载/权限/目录里有删不掉的项）不能假装
              # 提交成功，更不能把 marker 一起删掉 —— marker 是这笔待提交
              # 旧载荷的唯一线索。
              log_to "$SUPLOG" "事务旧载荷删除失败，保留 pending 稍后重试：$_pco_path"
              _pco_rc=1
            elif ! rm -f "$_pco_marker" 2>/dev/null; then
              _pco_rc=1
            fi
            ;;
          *)
            rm -f "$_pco_marker" 2>/dev/null
            ;;
        esac
      fi
    fi
  fi
  if [ "$_pco_locked" = "1" ]; then
    update_lock_release "$RUNDIR/update.lock.d"
    UPDATE_LOCK_TOKEN=$_pco_outer_token
    UPDATE_LOCK_PATH=$_pco_outer_path
  fi
  return "$_pco_rc"
}

payload_install_from() { # $1=源目录 $2=force；调用者须全程持 update.lock.d
  _src="$1"; _force="${2:-0}"
  _err=$(payload_validate "$_src") || { echo "校验失败：$_err"; return 1; }
  _newver=$(payload_file ver "$_src/VERSION")
  _newbuilt=$(payload_file built "$_src/VERSION")
  _curver=$(payload_version); _curbuilt=$(payload_built)
  if [ "$_force" != "1" ] && [ -n "$_curbuilt" ] && [ -n "$_newbuilt" ]; then
    if [ "$_newbuilt" = "$_curbuilt" ] && [ "$_newver" = "$_curver" ]; then
      echo "已是最新（$_curver），跳过"; return 0
    fi
    if ! ts_newer_eq "$_newbuilt" "$_curbuilt"; then
      echo "源比现有旧，跳过（要降级请加 --force）"; return 0
    fi
  fi
  _src_kb=$(payload_size_kb "$_src") || { echo "无法计算载荷大小"; return 1; }
  _need_kb=$((_src_kb * 2 + 16384))
  if payload_validate "$PAYLOAD" >/dev/null 2>&1; then
    _cur_kb=$(payload_size_kb "$PAYLOAD") || { echo "无法计算现有载荷大小"; return 1; }
    # 新 staging、新备份、旧载荷/切换副本同时存在时，预留三份加新载荷余量。
    _need_kb=$((_src_kb * 2 + _cur_kb * 2 + 16384))
  fi
  space_require_kb "$APP_HOME" "$_need_kb" || return 1

  echo "安装载荷：${_newver:-unknown}（built=${_newbuilt:-unknown}）"
  _tmp="$APP_HOME/payload.new.$$"
  rm -rf "$_tmp" 2>/dev/null
  mkdir -p "$_tmp" 2>/dev/null || return 1
  if ! cp -R "$_src"/. "$_tmp"/ 2>/dev/null; then
    rm -rf "$_tmp" 2>/dev/null; echo "拷贝失败（可能空间不足）"; return 1
  fi
  _err=$(payload_validate "$_tmp") || { rm -rf "$_tmp" 2>/dev/null; echo "拷贝后校验失败：$_err"; return 1; }
  payload_fix_perms "$_tmp" || { rm -rf "$_tmp" 2>/dev/null; echo "载荷权限修复失败"; return 1; }
  loader_smoke "$_tmp" || { rm -rf "$_tmp" 2>/dev/null; echo "动态链接器无法执行"; return 1; }
  # 有完整旧版才备份；备份失败绝不继续破坏现场。
  if [ -d "$PAYLOAD" ]; then
    if payload_validate "$PAYLOAD" >/dev/null 2>&1; then
      payload_backup || { rm -rf "$_tmp" 2>/dev/null; echo "旧载荷备份失败"; return 1; }
    else
      echo "旧载荷目录不完整（首次安装或上次中断），移到 payload.broken.$$ 后继续"
      if ! mv "$PAYLOAD" "$APP_HOME/payload.broken.$$" 2>/dev/null; then
        rm -rf "$PAYLOAD" 2>/dev/null
      fi
    fi
  fi
  # activate 会写事务 journal；无外层事务（customize 安装等）时没人负责
  # 推进/清除它，留着会让下次开机把全新安装当成"未验证切换"回滚掉。
  _pi_jrn=0; [ -s "$A2A_TXN_JOURNAL" ] && _pi_jrn=1
  payload_activate_staged "$_tmp" new || {
    [ "$_pi_jrn" != "1" ] && payload_txn_clear
    rm -rf "$_tmp" 2>/dev/null; return 1
  }
  [ "$_pi_jrn" != "1" ] && payload_txn_clear
  echo "载荷已切换：${_curver:-none} -> ${_newver:-unknown}"
  return 0
}

payload_rollback() { # 调用者须全程持 update.lock.d
  [ -d "$BACKUPDIR/prev" ] || { echo "没有可回滚的完整备份"; return 1; }
  payload_validate "$BACKUPDIR/prev" >/dev/null 2>&1 || { echo "备份不完整，无法回滚"; return 1; }
  _rb_kb=$(payload_size_kb "$BACKUPDIR/prev") || { echo "无法计算备份大小"; return 1; }
  space_require_kb "$APP_HOME" $((_rb_kb + 16384)) || return 1
  _tmp="$APP_HOME/payload.rollback.new.$$"
  rm -rf "$_tmp" 2>/dev/null
  mkdir -p "$_tmp" 2>/dev/null || return 1
  cp -R "$BACKUPDIR/prev"/. "$_tmp"/ 2>/dev/null || { rm -rf "$_tmp"; echo "回滚复制失败"; return 1; }
  payload_validate "$_tmp" >/dev/null 2>&1 || { rm -rf "$_tmp"; echo "回滚校验失败"; return 1; }
  payload_fix_perms "$_tmp" || { rm -rf "$_tmp"; echo "回滚权限修复失败"; return 1; }
  loader_smoke "$_tmp" || { rm -rf "$_tmp"; echo "回滚运行时不可用"; return 1; }
  _rb_jrn=0; [ -s "$A2A_TXN_JOURNAL" ] && _rb_jrn=1
  payload_activate_staged "$_tmp" rollback || {
    # 无事务上下文的手动回滚：清掉 activate 写下的 journal，否则下次开机
    # 会把这次已完成的回滚当成"未完成切换"再回滚回去。
    [ "$_rb_jrn" != "1" ] && payload_txn_clear
    rm -rf "$_tmp" 2>/dev/null; return 1
  }
  [ "$_rb_jrn" != "1" ] && payload_txn_clear
  echo "已回滚到 $(payload_version)"
  return 0
}

# ---------------------------------------------------------------------------
# 数据快照与恢复（问题 1）
# 旧事务只备份/回滚 payload：新版迁移过数据库后回滚 = 旧程序 + 新数据。
# 现在在「停服并核实退出之后、切换载荷之前」把 $DATADIR 完整快照到
# $BACKUPDIR/data-prev（与 payload 备份 prev 同级），回滚时一并恢复。
# ---------------------------------------------------------------------------
PAYLOAD_DATA_SNAPSHOT_TAKEN=0

payload_data_snapshot() { # $1=txid（日志/身份标记用）；前提：服务已停止并核实退出，调用者持 update 锁
  # 一致性说明：数据目录里的 SQLite 文件（agent2api.db 与 -wal/-shm）必须
  # 逐字节原样复制。服务已停止（无任何进程持有这些文件，孤儿写入者已由
  # upd_stop_service 核实清零）时，整目录复制就是一致性快照 —— 不需要
  # sqlite3 .backup，也不需要文件系统级快照。
  [ -d "$DATADIR" ] || { log_to "$UPDLOG" "数据目录不存在，跳过数据快照"; return 0; }
  # 防御：调用方违约（服务还在跑）时拒绝快照，绝不复制一份不一致的数据
  if command -v svc_is_running >/dev/null 2>&1 && svc_is_running; then
    echo "服务仍在运行，拒绝做数据快照（调用顺序违约）"
    return 1
  fi
  _pds_empty=1
  for _pds_f in "$DATADIR"/* "$DATADIR"/.[!.]* "$DATADIR"/..?*; do
    [ -e "$_pds_f" ] || continue
    _pds_empty=0
    break
  done
  if [ "$_pds_empty" = "1" ]; then
    log_to "$UPDLOG" "数据目录为空，跳过数据快照"
    return 0
  fi
  _pds_kb=$(payload_size_kb "$DATADIR") || { echo "无法计算数据目录大小"; return 1; }
  space_require_kb "$APP_HOME" $((_pds_kb + 16384)) || return 1
  rm -rf "$BACKUPDIR/data-prev.new" 2>/dev/null
  mkdir -p "$BACKUPDIR/data-prev.new" 2>/dev/null || { echo "无法创建快照目录"; return 1; }
  # cp -a 保留权限/属主/时间戳（db 与 key 文件是 600/700），轮换用 rename 不占额外空间
  if ! cp -a "$DATADIR"/. "$BACKUPDIR/data-prev.new"/ 2>/dev/null; then
    rm -rf "$BACKUPDIR/data-prev.new" 2>/dev/null
    echo "数据快照复制失败（可能空间不足）"
    return 1
  fi
  # 核验：关键数据库文件逐字节大小一致（cp 返回码 + 大小抽查双保险）
  for _pds_db in "$DATADIR"/*.db "$DATADIR"/*.db-wal "$DATADIR"/*.db-shm; do
    [ -f "$_pds_db" ] || continue
    _pds_b="$BACKUPDIR/data-prev.new/${_pds_db##*/}"
    if [ ! -f "$_pds_b" ] \
       || [ "$(wc -c <"$_pds_db" 2>/dev/null)" != "$(wc -c <"$_pds_b" 2>/dev/null)" ]; then
      rm -rf "$BACKUPDIR/data-prev.new" 2>/dev/null
      echo "数据快照核验失败：$_pds_b"
      return 1
    fi
  done
  # 轮换：下一次成功更新时替换旧快照；提交成功后快照保留为 data-prev
  # 直到下次更新（作为那一次的回滚材料）。
  rm -rf "$BACKUPDIR/data-prev.old" 2>/dev/null
  if [ -d "$BACKUPDIR/data-prev" ] && ! mv "$BACKUPDIR/data-prev" "$BACKUPDIR/data-prev.old" 2>/dev/null; then
    rm -rf "$BACKUPDIR/data-prev.new" 2>/dev/null
    echo "旧数据快照无法轮换，保留现场"
    return 1
  fi
  if ! mv "$BACKUPDIR/data-prev.new" "$BACKUPDIR/data-prev" 2>/dev/null; then
    [ -d "$BACKUPDIR/data-prev.old" ] && mv "$BACKUPDIR/data-prev.old" "$BACKUPDIR/data-prev" 2>/dev/null
    rm -rf "$BACKUPDIR/data-prev.new" 2>/dev/null
    echo "数据快照无法就位"
    return 1
  fi
  rm -rf "$BACKUPDIR/data-prev.old" 2>/dev/null
  # 快照身份标记（与快照目录同级，不污染快照内容）：回滚时校验快照属于
  # 本笔事务，防止拿上一代的旧快照覆盖现在的数据
  # B3：身份标记写不进去时，这份快照无法通过 txid 校验被安全使用，按快照
  # 失败中止事务（与快照主体失败同路径）。快照本体已核验完整、且比上一代
  # 新，保留在 data-prev 供手工 --with-data 恢复（标记缺失时跳过身份比对）。
  if ! printf '%s %s\n' "${1:-unknown}" "$(now_epoch)" >"$BACKUPDIR/data-prev.txid" 2>/dev/null; then
    echo "数据快照身份标记写入失败"
    return 1
  fi
  chmod 700 "$BACKUPDIR/data-prev" 2>/dev/null
  PAYLOAD_DATA_SNAPSHOT_TAKEN=1
  log_to "$UPDLOG" "数据快照完成：${_pds_kb}KB -> $BACKUPDIR/data-prev（txid=${1:-unknown}）"
  return 0
}

payload_data_rollback() { # 把快照恢复回 $DATADIR；调用者持 update 锁
  if [ ! -d "$BACKUPDIR/data-prev" ]; then
    log_to "$UPDLOG" "数据快照缺失（$BACKUPDIR/data-prev），数据回滚失败，保留现场"
    return 1
  fi
  # 快照身份校验：只恢复「本笔事务」的快照。txid 对不上说明快照是上一代
  # 更新留下的 —— 用它覆盖现在的数据等于静默回退用户数据，必须拒绝。
  _pdr_want=${PAYLOAD_TXID:-}
  _pdr_have=$(awk 'NR==1{print $1; exit}' "$BACKUPDIR/data-prev.txid" 2>/dev/null)
  if [ -n "$_pdr_want" ] && [ "$_pdr_want" != "$_pdr_have" ]; then
    log_to "$UPDLOG" "数据快照属于其它事务（期望 $_pdr_want，实际 $_pdr_have），跳过数据回滚"
    return 1
  fi
  # 明确警告：这一步会用升级前的数据覆盖现在的数据目录
  log_to "$UPDLOG" "WARNING: 正在用升级前快照覆盖数据目录，升级期间对数据的写入会丢失"
  _pdr_kb=$(payload_size_kb "$BACKUPDIR/data-prev") || _pdr_kb=0
  space_require_kb "$APP_HOME" $((_pdr_kb + 16384)) || return 1
  _pdr_tmp="$DATADIR.restore.$$"
  rm -rf "$_pdr_tmp" 2>/dev/null
  mkdir -p "$_pdr_tmp" 2>/dev/null || return 1
  if ! cp -a "$BACKUPDIR/data-prev"/. "$_pdr_tmp"/ 2>/dev/null; then
    rm -rf "$_pdr_tmp" 2>/dev/null
    echo "数据快照复制失败，数据目录未动"
    return 1
  fi
  # 现场保全：升级后的数据先移开再换入快照（两次 rename 的窗口极小）；
  # 换入失败时原样放回，绝不把数据目录留在"不存在"的状态。
  _pdr_aside="$DATADIR.upgraded.$$"
  # F-003：两次 rename 前把中转/移开路径记入 journal——这一步一旦中断，
  # data 目录可能"不存在"，没有记录就无法安全补完或放回。只在 journal
  # 已存在（有事务上下文）时记录；写不进去就中止，不留无法恢复的窗口。
  if [ -s "$A2A_TXN_JOURNAL" ]; then
    payload_txn_reload
    TXN_DATA_TMP="$_pdr_tmp"
    TXN_DATA_ASIDE="$_pdr_aside"
    payload_txn_write rolling-back || {
      echo "无法记录数据回滚的 journal，中止（防中断后无法恢复）"
      return 1
    }
  fi
  if [ -d "$DATADIR" ] && ! mv "$DATADIR" "$_pdr_aside" 2>/dev/null; then
    # journal 已引用 tmp：保留它，下一次恢复才能继续首个 rename。
    echo "无法移开当前数据目录，保留快照副本等待重试"
    return 1
  fi
  if mv "$_pdr_tmp" "$DATADIR" 2>/dev/null; then
    chmod 700 "$DATADIR" 2>/dev/null
    # 完成状态先落盘，aside 后清；落盘失败保留 aside 与原 journal 可重复收尾。
    payload_data_mark_restored || return 1
    rm -rf "$_pdr_aside" 2>/dev/null
    log_to "$UPDLOG" "数据已回滚到升级前快照（${_pdr_kb}KB）"
    return 0
  fi
  _pdr_back=1
  if [ -d "$_pdr_aside" ]; then
    mv "$_pdr_aside" "$DATADIR" 2>/dev/null || {
      _pdr_back=0
      echo "严重：升级后数据在 $_pdr_aside，请手工恢复"
    }
  fi
  # 无论放回是否成功都保留 tmp 与 journal：恢复时按实际 rename 现场重试。
  # 先删除 tmp 再改记账会留下不可恢复的中断窗口。
  return 1
}

lib_verify() {
  payload_is_static && return 0  # 静态载荷不依赖 $PLIB
  [ -x "$LOADER" ] && "$LOADER" --version >/dev/null 2>&1
}
lib_snapshot_save() {
  [ -d "$PLIB" ] || return 1
  rm -rf "$BACKUPDIR/lib.new" 2>/dev/null
  mkdir -p "$BACKUPDIR/lib.new" 2>/dev/null || return 1
  cp -R "$PLIB"/. "$BACKUPDIR/lib.new"/ 2>/dev/null || { rm -rf "$BACKUPDIR/lib.new"; return 1; }
  rm -rf "$BACKUPDIR/lib.old" 2>/dev/null
  [ -d "$BACKUPDIR/lib" ] && mv "$BACKUPDIR/lib" "$BACKUPDIR/lib.old" 2>/dev/null
  mv "$BACKUPDIR/lib.new" "$BACKUPDIR/lib" 2>/dev/null || return 1
  rm -rf "$BACKUPDIR/lib.old" 2>/dev/null
  return 0
}
lib_restore() {
  [ -d "$BACKUPDIR/lib" ] || return 1
  rm -rf "$PLIB.restore" 2>/dev/null
  mkdir -p "$PLIB.restore" 2>/dev/null || return 1
  cp -R "$BACKUPDIR/lib"/. "$PLIB.restore"/ 2>/dev/null || { rm -rf "$PLIB.restore"; return 1; }
  rm -rf "$PLIB.bad" 2>/dev/null
  [ -d "$PLIB" ] && mv "$PLIB" "$PLIB.bad" 2>/dev/null
  if ! mv "$PLIB.restore" "$PLIB" 2>/dev/null; then
    [ -d "$PLIB.bad" ] && mv "$PLIB.bad" "$PLIB" 2>/dev/null
    return 1
  fi
  payload_fix_perms "$PAYLOAD"
  if ! lib_verify; then
    rm -rf "$PLIB" 2>/dev/null
    [ -d "$PLIB.bad" ] && mv "$PLIB.bad" "$PLIB" 2>/dev/null
    payload_fix_perms "$PAYLOAD"
    live_link_refresh
    echo "恢复的运行库校验失败，已退回原运行库"
    return 1
  fi
  rm -rf "$PLIB.bad" 2>/dev/null
  live_link_refresh
  return 0
}
