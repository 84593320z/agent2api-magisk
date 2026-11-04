. /e/AI/tmp/agent2api-audit-20261104/repo/module/libexec/common.sh
APP_HOME=/e/AI/tmp/agent2api-audit-20261104/agent-runtime/fixture
PAYLOAD="$APP_HOME/payload"; PLIB="$PAYLOAD/lib"; BINDIR="$APP_HOME/bin"; CFGDIR="$APP_HOME/etc"; DATADIR="$APP_HOME/data"; LOGDIR="$APP_HOME/logs"; RUNDIR="$APP_HOME/run"; TMPD="$APP_HOME/tmp"; HOMEDIR="$APP_HOME/home"; BACKUPDIR="$APP_HOME/backup"; DLDIR="$APP_HOME/download"
SETTINGS="$CFGDIR/settings.conf"; SUPLOG="$LOGDIR/supervisor.log"; SRVLOG="$LOGDIR/server.log"; APPLOG="$LOGDIR/app.log"; SERVER_BIN="$PAYLOAD/agent2api-server"; LOADER="$PLIB/ld-linux-aarch64.so.1"
A2A_LIVE="$APP_HOME/live"; DNSFILE="$A2A_LIVE/resolv"; DNS_CACHE="$RUNDIR/resolv.last"
ensure_layout; mkdir -p "$A2A_LIVE"
. /e/AI/tmp/agent2api-audit-20261104/repo/module/libexec/dns.sh

printf 'nameserver 192.168.1.1
' >"$DNSFILE"; cp "$DNSFILE" "$DNS_CACHE"
printf wlan0 >"$DNS_ACTIVE_CACHE"; printf 0 >"$DNS_VPN_CACHE"
dns_default_iface() { echo tun0; }; dns_vpn_active() { return 0; }; dns_liveness_ok() { return 0; }; dns_ensure() { echo DNS_ENSURE_CALLED; }
printf 'before='; cat "$DNSFILE"
dns_refresh_if_changed; echo "refresh_rc=$?"
printf 'after='; cat "$DNSFILE"; printf 'recorded_iface='; cat "$DNS_ACTIVE_CACHE"; echo
