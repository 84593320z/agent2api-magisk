. /e/AI/tmp/agent2api-audit-20261104/repo/module/libexec/common.sh
APP_HOME=/e/AI/tmp/agent2api-audit-20261104/agent-runtime/fixture
PAYLOAD="$APP_HOME/payload"; PLIB="$PAYLOAD/lib"; BINDIR="$APP_HOME/bin"; CFGDIR="$APP_HOME/etc"; DATADIR="$APP_HOME/data"; LOGDIR="$APP_HOME/logs"; RUNDIR="$APP_HOME/run"; TMPD="$APP_HOME/tmp"; HOMEDIR="$APP_HOME/home"; BACKUPDIR="$APP_HOME/backup"; DLDIR="$APP_HOME/download"
SETTINGS="$CFGDIR/settings.conf"; SUPLOG="$LOGDIR/supervisor.log"; SRVLOG="$LOGDIR/server.log"; APPLOG="$LOGDIR/app.log"; SERVER_BIN="$PAYLOAD/agent2api-server"; LOADER="$PLIB/ld-linux-aarch64.so.1"
A2A_LIVE="$APP_HOME/live"; DNSFILE="$A2A_LIVE/resolv"; DNS_CACHE="$RUNDIR/resolv.last"
ensure_layout; mkdir -p "$A2A_LIVE"
cmd_ensure_payload() {
  if [ ! -f "$SERVER_BIN" ] || [ ! -x "$LOADER" ]; then
    say "载荷缺失（$PAYLOAD），请重新刷入模块 zip 恢复"
    return 1
  fi
  return 0
}
cmd_start() { cmd_ensure_payload && svc_start; }

printf 'static-musl-fixture
' >"$SERVER_BIN"; chmod 755 "$SERVER_BIN"
A2A_STATIC=1
svc_start() { echo SVC_START_CALLED; }
printf 'payload_is_static='; payload_is_static; echo $?
cmd_start; echo "cmd_start_rc=$? loader_exists=$([ -x "$LOADER" ] && echo yes || echo no)"
