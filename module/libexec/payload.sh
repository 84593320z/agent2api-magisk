#!/system/bin/sh
# Agent2API 模块 · 载荷事务、完整备份与恢复
# 任意复制/校验/切换失败都返回非零；不在原载荷上做不完整覆盖。

payload_file() { sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1 | tr -d '\r'; }
payload_version() { payload_file ver "$PAYLOAD/VERSION"; }
payload_built() { payload_file built "${1:-$PAYLOAD}/VERSION"; }

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
  chmod 755 "$_d" "$_d/agent2api-server" "$_d/lib" 2>/dev/null || return 1
  for _f in "$_d/lib/"*.so*; do
    [ -e "$_f" ] || continue
    chmod 755 "$_f" 2>/dev/null || return 1
  done
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
update_lock_release() {
  _ur_lock="${1:-$RUNDIR/update.lock.d}"
  [ -n "$UPDATE_LOCK_TOKEN" ] || return 0
  _ur_owner=$(cat "$_ur_lock/owner" 2>/dev/null) || _ur_owner=""
  _ur_token=$(printf '%s\n' "$_ur_owner" | awk '{print $3}')
  if [ "$_ur_token" = "$UPDATE_LOCK_TOKEN" ]; then
    rm -f "$_ur_lock/owner" 2>/dev/null || return 1
  fi
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
  printf '%s\n' "$_pa_tag $$ $_pa_old" >"$RUNDIR/update.active" 2>/dev/null || return 1
  if command -v upd_payload_before_move >/dev/null 2>&1; then
    upd_payload_before_move "$_pa_old" "$_pa_tmp" || return 1
  fi
  if [ -d "$PAYLOAD" ] && ! mv "$PAYLOAD" "$_pa_old" 2>/dev/null; then
    rm -f "$RUNDIR/update.active" 2>/dev/null
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
    rm -f "$RUNDIR/update.active" 2>/dev/null
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
    rm -f "$RUNDIR/update.active" 2>/dev/null
    return 1
  fi
  if command -v upd_payload_commit >/dev/null 2>&1; then
    upd_payload_commit "$_pa_old" "$_pa_tmp"
  fi
  # 旧载荷绝不能在这里删：此刻服务端还没做健康检查，健康失败要回滚时
  # 这份同一事务的旧版本是唯一能立刻顶回去的副本（备份目录 prev 是上一代，
  # 不是这一次被换下来的那一份）。改成写 pending 标记，由
  # payload_commit_old 在健康通过/安装收尾后删除。
  printf '%s\n' "$_pa_tag $$ $_pa_old" >"$RUNDIR/update.pending" 2>/dev/null
  rm -f "$RUNDIR/update.active" 2>/dev/null
  # /data/a2a/ld.so 只是"插件解释器"这条旁路，真正的服务端是用绝对路径
  # $LOADER 起的，跟这个软链无关。切换已经成功却因为软链失败报整体失败，
  # 会让调用方回滚一份正确落地的新载荷，反而更糟 —— 降级为告警。
  live_link_refresh || echo "警告：动态链接器软链刷新失败（插件可能暂时不可用，重启后自动重试）"
  return 0
}

# 提交事务旧载荷：只有当前载荷被证明完整时才删，删的是 pending 里记录的
# 那一个路径，绝不按通配符批量删（避免误删别人的回滚副本）。
payload_commit_old() {
  _pco_marker="$RUNDIR/update.pending"
  [ -s "$_pco_marker" ] || return 0
  _pco_path=$(awk '{print $3}' "$_pco_marker" 2>/dev/null | head -n 1)
  [ -n "$_pco_path" ] || { rm -f "$_pco_marker" 2>/dev/null; return 0; }
  # 只接受本模块自己的临时目录名，挡住 marker 被写坏导致的任意删除。
  case "$_pco_path" in
    "$APP_HOME"/payload.*.old.*|"$APP_HOME"/payload.old) ;;
    *) rm -f "$_pco_marker" 2>/dev/null; return 0 ;;
  esac
  if ! payload_validate "$PAYLOAD" >/dev/null 2>&1; then
    log_to "$SUPLOG" "当前载荷不完整，保留事务旧载荷：$_pco_path"
    return 1
  fi
  rm -rf "$_pco_path" 2>/dev/null
  rm -f "$_pco_marker" 2>/dev/null
  return 0
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
