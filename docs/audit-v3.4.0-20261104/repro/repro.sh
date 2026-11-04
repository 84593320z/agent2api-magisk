#!/usr/bin/env bash
# Offline MSYS Bash fault-injection; never executes /data Android paths.
set -u
SRC=/e/AI/tmp/agent2api-audit-20261104/repo/module
OUT=/e/AI/tmp/agent2api-audit-20261104/agent-update
mkdir -p "$OUT/cases"
. "$SRC/libexec/common.sh"
. "$SRC/libexec/payload.sh"
reset_case() {
  APP_HOME="$OUT/cases/$1"; PAYLOAD="$APP_HOME/payload"; PLIB="$PAYLOAD/lib"
  DATADIR="$APP_HOME/data"; BACKUPDIR="$APP_HOME/backup"; RUNDIR="$APP_HOME/run"
  TMPD="$APP_HOME/tmp"; BINDIR="$APP_HOME/bin"; LOGDIR="$APP_HOME/logs"; CFGDIR="$APP_HOME/etc"
  SETTINGS="$CFGDIR/settings.conf"; UPDLOG="$LOGDIR/update.log"; SUPLOG="$LOGDIR/supervisor.log"
  SERVER_BIN="$PAYLOAD/agent2api-server"; LOADER="$PLIB/ld-linux-aarch64.so.1"
  CURL="$BINDIR/curl"; CACERT="$BINDIR/cacert.pem"
  case "$APP_HOME" in "$OUT"/cases/*) rm -rf "$APP_HOME";; *) exit 99;; esac
  mkdir -p "$DATADIR" "$BACKUPDIR" "$RUNDIR" "$TMPD" "$LOGDIR" "$CFGDIR"
  UPDATE_LOCK_TOKEN=; UPDATE_LOCK_PATH=; PAYLOAD_TXID=; PAYLOAD_DATA_SNAPSHOT_TAKEN=0
}
# Native identity/space plumbing is stubbed, not transaction filesystem behavior.
proc_start_ticks() { printf 12345; }
pid_alive() { [ "$1" = "$$" ]; }
space_require_kb() { return 0; }
live_link_refresh() { return 0; }
svc_is_running() { return 1; }
seed() {
  mkdir -p "$1/ui"
  printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\002\000\267\000' >"$1/agent2api-server"
  head -c 1100000 /dev/urandom >>"$1/agent2api-server"
  printf test >"$1/ui/index.html"
  printf 'ver=%s\nbuilt=2026-11-01T00:00:00Z\n' "$2" >"$1/VERSION"
}
echo '=== CASE1 health-failure rollback while new service remains alive ==='
(
reset_case live-rollback
seed "$PAYLOAD" 1.0.0; seed "$APP_HOME/source" 2.0.0
printf old-schema >"$DATADIR/agent2api.db"
tar -czf "$APP_HOME/local.tar.gz" -C "$APP_HOME/source" agent2api-server ui VERSION
sha256sum "$APP_HOME/local.tar.gz" >"$APP_HOME/local.tar.gz.sha256"
. "$SRC/libexec/updater.sh"
RUN=1; HEALTH_CALLS=0
svc_is_running() { [ "$RUN" = 1 ]; }
svc_stop() { echo SVC_STOP; RUN=0; }
svc_kill_stray() { :; }; svc_stray_pids() { :; }
svc_start() { echo SVC_START_NEW; RUN=1; printf new-schema >"$DATADIR/agent2api.db"; }
svc_restart() { echo "SVC_RESTART after_restore db=$(cat "$DATADIR/agent2api.db")"; RUN=1; }
svc_wait_health() { HEALTH_CALLS=$((HEALTH_CALLS+1)); [ "$HEALTH_CALLS" -gt 1 ]; }
eval "$(declare -f payload_data_rollback | sed '1s/payload_data_rollback/payload_data_rollback_real/')"
payload_data_rollback() { echo "DATA_ROLLBACK service_alive=$RUN"; payload_data_rollback_real; }
# Model one application write-by-path at the exact publication point. The real
# transaction filesystem operation remains unchanged; only service work is modeled.
mv() {
  command mv "$@"; rc=$?
  if [ "${2:-}" = "$DATADIR" ] && [ "$RUN" = 1 ]; then
    printf new-service-write-after-restore >"$DATADIR/agent2api.db"
    echo "LIVE_WRITER changed_restored_db=$(cat "$DATADIR/agent2api.db")"
  fi
  return "$rc"
}
LOCAL_TAG=v2.0.0
upd_do_update stable 1 "$APP_HOME/local.tar.gz"
echo "update_rc=$? payload=$(payload_version) db=$(cat "$DATADIR/agent2api.db")"
)
echo '=== CASE2 quick reboot after first payload rename ==='
(
reset_case quick-reboot
seed "$PAYLOAD" 1.0.0; seed "$APP_HOME/staging" 2.0.0
# Switching marker written by production activation. Crash immediately after first rename.
(
  mv() { command mv "$@"; rc=$?; if [ "${1:-}" = "$PAYLOAD" ]; then exit 77; fi; return "$rc"; }
  payload_activate_staged "$APP_HOME/staging" new
)
echo "crash_exit=$? old_before=$(find "$APP_HOME" -maxdepth 1 -name 'payload.new.old.*' | wc -l)"
# Execute production post-fs-data recovery/sweep pair, with same-boot clock <120s.
payload_recover_interrupted
sweep_stale_dirs
echo "payload_exists=$([ -d "$PAYLOAD" ] && echo yes || echo no) old_after=$(find "$APP_HOME" -maxdepth 1 -name 'payload.new.old.*' | wc -l) switching=$([ -f "$RUNDIR/payload.switching" ] && echo yes || echo no)"
cat "$SUPLOG"
)
echo '=== CASE3 power loss during data rollback rename window ==='
(
reset_case data-powerloss
printf upgraded >"$DATADIR/agent2api.db"
mkdir -p "$BACKUPDIR/data-prev"; printf original >"$BACKUPDIR/data-prev/agent2api.db"
(
  mv() { command mv "$@"; rc=$?; if [ "${1:-}" = "$DATADIR" ]; then exit 78; fi; return "$rc"; }
  payload_data_rollback
)
echo "crash_exit=$? data_exists=$([ -d "$DATADIR" ] && echo yes || echo no)"
# Production ensure_layout (pre-recovery) creates a fresh empty data directory.
mkdir -p "$DATADIR"
sweep_stale_dirs
echo "data_files=$(find "$DATADIR" -type f | wc -l) restore_dirs=$(find "$APP_HOME" -maxdepth 1 -name 'data.restore.*' | wc -l) upgraded_dirs=$(find "$APP_HOME" -maxdepth 1 -name 'data.upgraded.*' | wc -l) snapshot_db=$(cat "$BACKUPDIR/data-prev/agent2api.db")"
)
echo '=== CASE4 subsequent customize cleanup destroys pending rollback payload ==='
(
reset_case pending-delete
seed "$PAYLOAD" 1.0.0; seed "$APP_HOME/staging" 2.0.0
payload_activate_staged "$APP_HOME/staging" new
PENDING_PATH=$(awk '{print $3}' "$RUNDIR/update.pending")
echo "pending_before=$([ -d "$PENDING_PATH" ] && echo present || echo absent)"
# Exact customize.sh:134 glob, reached under update lock before version comparison.
rm -rf "$APP_HOME"/payload.new.* "$APP_HOME"/payload.broken.* 2>/dev/null
echo "pending_after=$([ -d "$PENDING_PATH" ] && echo present || echo absent) marker_preserved=$([ -s "$RUNDIR/update.pending" ] && echo yes || echo no)"
)
echo '=== NEGATIVE CONTROL (not a finding): direct API with stale snapshot and missing txid ==='
(
reset_case stale-data
mkdir -p "$BACKUPDIR/data-prev"; printf stale-secret >"$BACKUPDIR/data-prev/agent2api.db"
PAYLOAD_TXID=tx-current
payload_data_snapshot "$PAYLOAD_TXID"
echo "snapshot_rc=$? snapshot_taken=$PAYLOAD_DATA_SNAPSHOT_TAKEN"
printf newly-created >"$DATADIR/agent2api.db"
payload_data_rollback
echo "rollback_rc=$? restored=$(cat "$DATADIR/agent2api.db")"
)
