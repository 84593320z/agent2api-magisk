#!/bin/sh

name=${1:-data-fail}
reset_case "$name-$$"
seed_payload "$PAYLOAD" old
printf old-schema >"$DATADIR/agent2api.db"
case "$name" in
 data-fail|payload-fail|missing-snapshot)
  make_pkg new; svc_run_set 1
  (
   case "$name" in
    data-fail) cp() { case "$*" in *"/backup/data-prev/."*) return 1;; esac; command cp "$@"; };;
    payload-fail) cp() { case "$*" in *"/backup/prev/."*) return 1;; esac; command cp "$@"; };;
    missing-snapshot) svc_wait_health() { [ -f "$RUNDIR/svc.restarted" ] && return 0; command rm -rf "$BACKUPDIR/data-prev"; return 1; };;
   esac
   LOCAL_TAG=v2.0.0 upd_do_update stable 1 "$APP_HOME/local.tar.gz"
  ); rc=$?
  printf 'RESULT %s rc=%s payload=%s data=%s journal=%s running=%s restart=%s\n' "$name" "$rc" "$(payload_version)" "$(cat "$DATADIR/agent2api.db")" "$(jphase)" "$(svc_run_get)" "$(test -f "$RUNDIR/svc.restarted" && echo yes || echo no)"
 ;;
 first-rename)
  PAYLOAD_TXID=tx-old; payload_data_snapshot "$PAYLOAD_TXID"
  printf new-schema >"$DATADIR/agent2api.db"
  TXN_DATA_SNAP=1; payload_txn_write started
  ( mv() { [ "$1" = "$DATADIR" ] && exit 91; command mv "$@"; }; payload_data_rollback ); injected=$?
  cp() { case "$*" in *"/backup/data-prev/."*) return 1;; esac; command cp "$@"; }
  payload_recover_interrupted boot; rc=$?
  printf 'RESULT first-rename injected=%s rc=%s data=%s journal=%s\n' "$injected" "$rc" "$(cat "$DATADIR/agent2api.db")" "$(jphase)"
 ;;
 signal-data-fail|signal-payload-fail)
  PAYLOAD_TXID=tx-sig; payload_data_snapshot "$PAYLOAD_TXID"
  seed_payload "$BACKUPDIR/prev" old
  seed_payload "$APP_HOME/payload.new.old.9" old
  seed_payload "$PAYLOAD" new
  printf new-schema >"$DATADIR/agent2api.db"
  TXN_OLD_PAYLOAD="$APP_HOME/payload.new.old.9"; TXN_DATA_SNAP=1; TXN_NEW_BUILT=new-built
  payload_txn_write started
  UPD_INSTALLED=1; UPD_SERVICE_STARTED=1; UPD_DATA_SNAP=1; UPD_WAS_RUNNING=1
  (
   if [ "$name" = signal-data-fail ]; then
    UPD_ACTIVATE_BEFORE="$TXN_OLD_PAYLOAD"; UPD_ACTIVATE_AFTER="$PAYLOAD"
    cp() { case "$*" in *"/backup/data-prev/."*) return 1;; esac; command cp "$@"; }
   else
    cp() { case "$*" in *"/backup/prev/."*) return 1;; esac; command cp "$@"; }
   fi
   svc_start() { printf 'SIGNAL_START payload=%s data=%s\n' "$(payload_version)" "$(cat "$DATADIR/agent2api.db")" >>"$EVENTS"; svc_run_set 1; }
   upd_on_signal
  ); rc=$?
  printf 'RESULT %s rc=%s payload=%s data=%s journal=%s running=%s\n' "$name" "$rc" "$(payload_version)" "$(cat "$DATADIR/agent2api.db")" "$(jphase)" "$(svc_run_get)"
 ;;
 customize-orphan|customize-recover-fail)
  PAYLOAD_TXID=tx-cz; payload_data_snapshot "$PAYLOAD_TXID"
  seed_payload "$APP_HOME/payload.new.old.9" old
  seed_payload "$PAYLOAD" new
  printf new-schema >"$DATADIR/agent2api.db"
  TXN_OLD_PAYLOAD="$APP_HOME/payload.new.old.9"; TXN_DATA_SNAP=1; TXN_NEW_BUILT=new-built
  payload_generation_write "$PAYLOAD_TXID" update
  payload_txn_write rollback-blocked
  sed 's/ rollback-blocked [0-9]* 12345 / rollback-blocked 999999 12345 /' "$A2A_TXN_JOURNAL" >"$A2A_TXN_JOURNAL.tmp"; mv "$A2A_TXN_JOURNAL.tmp" "$A2A_TXN_JOURNAL"
  update_lock_acquire "$UPD_LOCK" 2 || exit 4
  (
   ui_print() { echo "$*"; }; abort() { echo "ABORT $*"; exit 77; }
   _HOT_WAS_RUNNING=0; _HOT_SAFE_TO_RESTART=0; _INSTALL_SUCCESS=0; _ZONE_OLD_PRESENT=0
   _INSTALL_TRANSACTION="$APP_HOME/.install.test"; _ZONE_OLD="$APP_HOME/zoneinfo.old.test"
   . "$WORK/customize-cleanup.sh"
   trap 'install_cleanup' EXIT
   if [ "$name" = customize-orphan ]; then
    svc_is_running() { return 1; }
    svc_stray_pids() { echo 45678; }
    svc_kill_stray() { echo KILLED >>"$EVENTS"; }
    mv() { case "$*" in *"$DATADIR"*) printf 'DATA_RENAME_WITH_ORPHAN stray=%s\n' "$(svc_stray_pids)" >>"$EVENTS";; esac; command mv "$@"; }
   else
    svc_run_set 1
    cp() { case "$*" in *"/backup/data-prev/."*) return 1;; esac; command cp "$@"; }
   fi
   . "$WORK/customize-pre.sh"
   echo INSTALL_CONTINUED >>"$EVENTS"
  ); rc=$?
  printf 'RESULT %s rc=%s payload=%s data=%s journal=%s running=%s continued=%s killed=%s\n' "$name" "$rc" "$(payload_version)" "$(cat "$DATADIR/agent2api.db")" "$(jphase)" "$(svc_run_get)" "$(grep -c INSTALL_CONTINUED "$EVENTS")" "$(grep -c KILLED "$EVENTS")"
  update_lock_release "$UPD_LOCK"
 ;;
 customize-stop-fail)
  svc_run_set 1
  (
   _HOT_WAS_RUNNING=0; _HOT_SAFE_TO_RESTART=0; _INSTALL_SUCCESS=0; _ZONE_OLD_PRESENT=0
   _INSTALL_TRANSACTION="$APP_HOME/.install.test"; _ZONE_OLD="$APP_HOME/zoneinfo.old.test"
   ui_print() { :; }; abort() { echo "ABORT $*"; exit 77; }
   . "$WORK/customize-cleanup.sh"
   trap 'install_cleanup' EXIT
   svc_stray_pids() { echo 45678; }
   . "$WORK/customize-pre.sh"
  ); rc=$?
  printf 'RESULT customize-stop-fail rc=%s running=%s starts=%s\n' "$rc" "$(svc_run_get)" "$(grep -c SVC_START "$EVENTS")"
 ;;
 commit-unhealthy|commit-healthy)
  seed_payload "$APP_HOME/payload.new.old.9" older
  payload_generation_write tx-c update
  printf 'new 9 %s tx-c\n' "$APP_HOME/payload.new.old.9" >"$RUNDIR/update.pending"
  CHILD_GENERATION=tx-c
  . "$WORK/commit.sh"
  svc_http_health() { [ "$name" = commit-healthy ]; }
  supervise_commit_pending
  printf 'RESULT %s old=%s pending=%s\n' "$name" "$(test -d "$APP_HOME/payload.new.old.9" && echo yes || echo no)" "$(test -f "$RUNDIR/update.pending" && echo yes || echo no)"
 ;;
 snapshot-no-id|snapshot-wrong-id)
  PAYLOAD_TXID=expected; payload_data_snapshot "$PAYLOAD_TXID"
  printf new-schema >"$DATADIR/agent2api.db"
  if [ "$name" = snapshot-no-id ]; then rm -f "$BACKUPDIR/data-prev.txid"; else echo wrong >"$BACKUPDIR/data-prev.txid"; fi
  payload_data_rollback; rc=$?
  printf 'RESULT %s rc=%s data=%s\n' "$name" "$rc" "$(cat "$DATADIR/agent2api.db")"
 ;;
 second-rename|after-second-rename|restore-rename-fail)
  PAYLOAD_TXID=tx-resume; payload_data_snapshot "$PAYLOAD_TXID"
  printf new-schema >"$DATADIR/agent2api.db"
  TXN_DATA_SNAP=1; payload_txn_write started
  (
    mv() {
      if [ "$name" = after-second-rename ]; then
        command mv "$@" || return $?
        case "$1" in "$DATADIR".restore.*) exit 91;; esac
        return 0
      fi
      case "$1" in "$DATADIR".restore.*) exit 91;; esac
      command mv "$@"
    }
    payload_data_rollback
  ); injected=$?
  cp() { case "$*" in *"/backup/data-prev/."*) return 1;; esac; command cp "$@"; }
  if [ "$name" = restore-rename-fail ]; then
    mv() { case "$1" in "$DATADIR".restore.*) return 1;; esac; command mv "$@"; }
  fi
  payload_recover_interrupted boot; rc=$?
  printf 'RESULT %s rc=%s data=%s journal=%s restored=%s\n' "$name" "$rc" "$(cat "$DATADIR/agent2api.db")" "$(jphase)" "$(test -d "$DATADIR.restore.$$" && echo yes || echo no)"
 ;;
 recovered-data-retry)
  PAYLOAD_TXID=tx-retry; payload_data_snapshot "$PAYLOAD_TXID"
  printf new-schema >"$DATADIR/agent2api.db"
  TXN_DATA_SNAP=1; payload_txn_write started
  payload_data_rollback || exit 4
  # 完成状态已持久化：下次恢复不依赖原快照、不可重复复制。
  rm -rf "$BACKUPDIR/data-prev"
  PAYLOAD_DATA_RECOVERED=0
  payload_recover_interrupted boot; rc=$?
  printf 'RESULT %s rc=%s data=%s journal=%s\n' "$name" "$rc" "$(cat "$DATADIR/agent2api.db")" "$(jphase)"
 ;;
 contradictory-data)
  mkdir -p "$DATADIR.restore.9" "$DATADIR.upgraded.9"
  echo old-schema >"$DATADIR.restore.9/agent2api.db"
  echo upgraded >"$DATADIR.upgraded.9/agent2api.db"
  payload_txn_recover_data "$DATADIR.restore.9" "$DATADIR.upgraded.9"; rc=$?
  printf 'RESULT %s rc=%s tmp=%s aside=%s data=%s\n' "$name" "$rc" "$(test -d "$DATADIR.restore.9" && echo yes)" "$(test -d "$DATADIR.upgraded.9" && echo yes)" "$(cat "$DATADIR/agent2api.db")"
 ;;
 supervisor-recovery-fail)
  payload_recover_interrupted() { echo RECOVERY >>"$EVENTS"; return 1; }
  (
    cleanup() { echo CLEANUP >>"$EVENTS"; }
    . "$WORK/supervise-gate.sh"
    startup_gate
  ); rc=$?
  printf 'RESULT %s rc=%s starts=%s\n' "$name" "$rc" "$(grep -c SERVER_START "$EVENTS")"
 ;;
 boot-recovery-fail)
  payload_recover_interrupted() { return 1; }
  ( . "$WORK/boot-gate.sh"; echo ENSURE_LAYOUT >>"$EVENTS" ); rc=$?
  printf 'RESULT %s rc=%s layout=%s\n' "$name" "$rc" "$(grep -c ENSURE_LAYOUT "$EVENTS")"
 ;;
 customize-safe-fail)
  svc_run_set 1
  (
    _HOT_WAS_RUNNING=0; _HOT_SAFE_TO_RESTART=0; _INSTALL_SUCCESS=0; _ZONE_OLD_PRESENT=0
    _INSTALL_TRANSACTION="$APP_HOME/.install.test"; _ZONE_OLD="$APP_HOME/zoneinfo.old.test"
    ui_print() { :; }; abort() { exit 77; }
    . "$WORK/customize-cleanup.sh"
    trap 'install_cleanup' EXIT
    . "$WORK/customize-pre.sh"
    exit 77
  ); rc=$?
  printf 'RESULT %s rc=%s running=%s starts=%s\n' "$name" "$rc" "$(svc_run_get)" "$(grep -c SVC_START "$EVENTS")"
 ;;
 first-rename-return-fail)
  PAYLOAD_TXID=tx-first-fail; payload_data_snapshot "$PAYLOAD_TXID"
  printf new-schema >"$DATADIR/agent2api.db"
  TXN_DATA_SNAP=1; payload_txn_write started
  mv() { [ "$1" = "$DATADIR" ] && return 1; command mv "$@"; }
  payload_data_rollback; first=$?
  unset -f mv
  cp() { case "$*" in *"/backup/data-prev/."*) return 1;; esac; command cp "$@"; }
  payload_recover_interrupted boot; rc=$?
  printf 'RESULT %s first=%s rc=%s data=%s journal=%s\n' "$name" "$first" "$rc" "$(cat "$DATADIR/agent2api.db")" "$(jphase)"
 ;;
 payload-rename-retry|payload-complete-retry|payload-marker-fail)
  PAYLOAD_TXID=tx-payload-retry; payload_data_snapshot "$PAYLOAD_TXID"
  seed_payload "$APP_HOME/payload.old.9" old
  seed_payload "$PAYLOAD" new
  printf new-schema >"$DATADIR/agent2api.db"
  TXN_OLD_PAYLOAD="$APP_HOME/payload.old.9"; TXN_DATA_SNAP=1; TXN_NEW_BUILT=new-built
  payload_generation_write "$PAYLOAD_TXID" update
  payload_txn_write started
  (
    if [ "$name" = payload-complete-retry ]; then
      payload_txn_clear() { exit 91; }
    else
      mv() {
        case "$*" in *"/.a2a-rollback-txid") [ "$name" = payload-marker-fail ] && return 1;; esac
        command mv "$@" || return 1
        [ "$1" = "$APP_HOME/payload.old.9" ] && exit 91
        return 0
      }
    fi
    payload_recover_interrupted boot
  ); injected=$?
  if [ "$name" != payload-marker-fail ]; then
    # 目录标记应随 rename 换入，即便 generation 仍指新代次也能幂等收尾。
    marker=$(cat "$PAYLOAD/.a2a-rollback-txid" 2>/dev/null)
    payload_recover_interrupted boot; rc=$?
  else
    marker=none; rc=$injected
  fi
  printf 'RESULT %s injected=%s rc=%s payload=%s data=%s journal=%s marker=%s oldpath=%s\n' "$name" "$injected" "$rc" "$(payload_version)" "$(cat "$DATADIR/agent2api.db")" "$(jphase)" "$marker" "$(test -d "$APP_HOME/payload.old.9" && echo yes || echo no)"
 ;;
 *) exit 2;;
esac
