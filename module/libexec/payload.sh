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
  payload_activate_staged "$_tmp" new || { rm -rf "$_tmp" 2>/dev/null; return 1; }
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
  payload_activate_staged "$_tmp" rollback || { rm -rf "$_tmp" 2>/dev/null; return 1; }
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
    # 无快照时跳过并记日志，不算失败（数据目录本来就可能是空的）
    log_to "$UPDLOG" "没有数据快照（$BACKUPDIR/data-prev），跳过数据回滚"
    return 0
  fi
  # 快照身份校验：只恢复「本笔事务」的快照。txid 对不上说明快照是上一代
  # 更新留下的 —— 用它覆盖现在的数据等于静默回退用户数据，必须拒绝。
  _pdr_want=${PAYLOAD_TXID:-}
  _pdr_have=$(awk 'NR==1{print $1; exit}' "$BACKUPDIR/data-prev.txid" 2>/dev/null)
  if [ -n "$_pdr_want" ] && [ -n "$_pdr_have" ] && [ "$_pdr_want" != "$_pdr_have" ]; then
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
  if [ -d "$DATADIR" ] && ! mv "$DATADIR" "$_pdr_aside" 2>/dev/null; then
    rm -rf "$_pdr_tmp" 2>/dev/null
    echo "无法移开当前数据目录，数据回滚中止"
    return 1
  fi
  if mv "$_pdr_tmp" "$DATADIR" 2>/dev/null; then
    rm -rf "$_pdr_aside" 2>/dev/null
    chmod 700 "$DATADIR" 2>/dev/null
    log_to "$UPDLOG" "数据已回滚到升级前快照（${_pdr_kb}KB）"
    return 0
  fi
  if [ -d "$_pdr_aside" ]; then
    mv "$_pdr_aside" "$DATADIR" 2>/dev/null || echo "严重：升级后数据在 $_pdr_aside，请手工恢复"
  fi
  rm -rf "$_pdr_tmp" 2>/dev/null
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
