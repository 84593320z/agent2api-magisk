#!/bin/sh
# Production-entry DNS identity/publication regression. Android sampling and
# liveness are controlled; dns_write/apply/ensure/refresh remain real source.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC="${DNS_TEST_SRC:-$HERE/../module}"
MODDIR=$SRC
. "$SRC/libexec/common.sh"
. "$SRC/libexec/dns.sh"
WORK=${DNS_TEST_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/a2a-dns-identity.XXXXXX")}
mkdir -p "$WORK"
PASS=0; FAIL=0
ck() {
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s expected=<%s> actual=<%s>\n' "$1" "$2" "$3"; fi
}
reset_case() {
  APP_HOME="$WORK/$1"; RUNDIR="$APP_HOME/run"; TMPD="$APP_HOME/tmp"
  A2A_LIVE="$APP_HOME/live"; LOGDIR="$APP_HOME/log"; SUPLOG="$LOGDIR/sup.log"
  SETTINGS="$APP_HOME/settings"; DNSFILE="$A2A_LIVE/resolv"; DNS_CACHE="$RUNDIR/resolv.last"
  DNS_ACTIVE_CACHE="$RUNDIR/dns-active"; DNS_VPN_CACHE="$RUNDIR/dns-vpn"; DNS_NETID_CACHE="$RUNDIR/dns-netid"
  NSSFILE="$A2A_LIVE/nsswitch"; GAIFILE="$A2A_LIVE/gai"
  mkdir -p "$RUNDIR" "$TMPD" "$A2A_LIVE" "$LOGDIR"; : >"$SETTINGS"
  IFACE=wlan0; VPN=0; NETID=100; SAMPLE=''; STATIC=''; LIVE_OK=1
  FAIL_CP=''; FAIL_MV=''; FAIL_CHMOD=''; FAULTS=0; FLIP_ID=0
}
dns_default_iface() { printf '%s\n' "$IFACE"; }
dns_vpn_active() { [ "$VPN" = 1 ]; }
dns_active_netid() { printf '%s\n' "$NETID"; }
dns_collect_system() { printf '%s\n' "$SAMPLE"; }
dns_static_list() { printf '%s\n' "$STATIC"; }
dns_liveness_ok() { [ "$FLIP_ID" = 0 ] || NETID=999; [ "$LIVE_OK" = 1 ]; }
dns_opts_line() { printf 'options timeout:2\n'; }
now_human() { printf 'test-time'; }
cp() { for arg in "$@"; do [ -z "$FAIL_CP" ] || [ "$arg" != "$FAIL_CP" ] || { FAULTS=$((FAULTS + 1)); return 1; }; done; command cp "$@"; }
mv() { for arg in "$@"; do [ -z "$FAIL_MV" ] || [ "$arg" != "$FAIL_MV" ] || { FAULTS=$((FAULTS + 1)); return 1; }; done; command mv "$@"; }
chmod() { for arg in "$@"; do [ -z "$FAIL_CHMOD" ] || [ "$arg" != "$FAIL_CHMOD" ] || { FAULTS=$((FAULTS + 1)); return 1; }; done; command chmod "$@"; }
ns() { awk '$1=="nameserver" {print $2; exit}' "$1" 2>/dev/null || :; }
metadata() { printf '%s %s %s' "$(cat "$DNS_ACTIVE_CACHE" 2>/dev/null)" "$(cat "$DNS_VPN_CACHE" 2>/dev/null)" "$(cat "$DNS_NETID_CACHE" 2>/dev/null)"; }
seed() {
  printf 'nameserver 192.168.1.1\n' >"$DNS_CACHE"
  printf wlan0 >"$DNS_ACTIVE_CACHE"; printf 0 >"$DNS_VPN_CACHE"; printf 100 >"$DNS_NETID_CACHE"
}

reset_case refresh_cross_netid; seed
command cp "$DNS_CACHE" "$DNSFILE"
printf '192.168.1.1\n' >"$A2A_LIVE/dns.lastgood"; printf 'wlan0 0 100\n' >"$A2A_LIVE/dns.lastgood.id"
IFACE=tun0; VPN=1; NETID=101
dns_refresh_if_changed; rc=$?
ck 'refresh cross-netid cache-only rejected' 1 "$rc"
ck 'refresh failure preserves old identity' 'wlan0 0 100' "$(metadata)"
ck 'refresh failure has no new lastgood' '' "$(cat "$A2A_LIVE/dns.lastgood.id" 2>/dev/null)"
ck 'refresh failure preserves exact old cache' 192.168.1.1 "$(ns "$DNS_CACHE")"
ck 'refresh failure has no success timestamp' 0 "$([ -e "$A2A_LIVE/.dnsverify" ] && echo 1 || echo 0)"

for change in iface vpn both; do
  reset_case "same_netid_$change"; seed
  case "$change" in iface) IFACE=rmnet0 ;; vpn) VPN=1 ;; both) IFACE=tun0; VPN=1 ;; esac
  dns_ensure; rc=$?
  ck "same-netid $change rejected" 1 "$rc"
  ck "same-netid $change no live publication" 0 "$([ -e "$DNSFILE" ] && echo 1 || echo 0)"
  ck "same-netid $change metadata unchanged" 'wlan0 0 100' "$(metadata)"
done

reset_case same_identity_legacy; seed
dns_ensure; rc=$?
ck 'legacy full-identity cache restores absent live' 0 "$rc"
ck 'legacy recovery content' 192.168.1.1 "$(ns "$DNSFILE")"
ck 'legacy cache upgraded to atomic full identity' 'wlan0 0 100' "$(sed -n 's/^# agent2api-dns-identity //p' "$DNS_CACHE")"
rm -f "$DNSFILE" "$A2A_LIVE/dns.lastgood" "$A2A_LIVE/dns.lastgood.id"
dns_ensure; rc=$?
ck 'new format same identity cache recovery' 0 "$rc"
ck 'new format recovered nameserver' 192.168.1.1 "$(ns "$DNSFILE")"
# Changing only mirrors must not relabel the embedded content identity.
NETID=101; printf 101 >"$DNS_NETID_CACHE"
rm -f "$DNSFILE" "$A2A_LIVE/dns.lastgood" "$A2A_LIVE/dns.lastgood.id"
dns_ensure; rc=$?
ck 'embedded identity rejects prewritten new metadata' 1 "$rc"

reset_case direct_metadata; seed; NETID=600; SAMPLE='nameserver 1.1.1.1'
dns_ensure; rc=$?
ck 'direct ensure succeeds' 0 "$rc"
ck 'direct ensure synchronizes all metadata' 'wlan0 0 600' "$(metadata)"
ck 'direct ensure content-bound identity' 'wlan0 0 600' "$(sed -n 's/^# agent2api-dns-identity //p' "$DNS_CACHE")"
ck 'direct ensure lastgood identity' 'wlan0 0 600' "$(cat "$A2A_LIVE/dns.lastgood.id")"

for mode in default 0 1 2; do
  reset_case "follow_$mode"; SAMPLE='nameserver 10.8.0.1'; STATIC=9.9.9.9
  [ "$mode" = default ] || printf 'dns_follow_system=%s\n' "$mode" >"$SETTINGS"
  dns_ensure; rc=$?; want=9.9.9.9; [ "$mode" != 1 ] || want=10.8.0.1
  ck "follow_system=$mode status" 0 "$rc"
  ck "follow_system=$mode priority" "$want" "$(ns "$DNSFILE")"
done

for failure in liveness live_copy live_rename live_chmod cache_copy cache_rename cache_chmod metadata_copy metadata_rename metadata_chmod identity_drift; do
  reset_case "failure_$failure"; seed; command cp "$DNS_CACHE" "$DNSFILE"
  command cp "$DNSFILE" "$APP_HOME/original"; command cp "$DNS_CACHE" "$APP_HOME/cache.original"
  NETID=101; SAMPLE='nameserver 1.1.1.1'
  case "$failure" in
    liveness) LIVE_OK=0 ;;
    live_copy) FAIL_CP="$DNSFILE.new.$$" ;;
    live_rename) FAIL_MV="$DNSFILE" ;;
    live_chmod) FAIL_CHMOD="$DNSFILE.new.$$" ;;
    cache_copy) FAIL_CP="$DNS_CACHE.new.$$" ;;
    cache_rename) FAIL_MV="$DNS_CACHE" ;;
    cache_chmod) FAIL_CHMOD="$DNS_CACHE.new.$$" ;;
    metadata_copy) FAIL_CP="$DNS_NETID_CACHE.new.$$" ;;
    metadata_rename) FAIL_MV="$DNS_NETID_CACHE" ;;
    metadata_chmod) FAIL_CHMOD="$DNS_NETID_CACHE.new.$$" ;;
    identity_drift) FLIP_ID=1 ;;
  esac
  dns_ensure; rc=$?
  ck "$failure reports failure" 1 "$rc"
  ck "$failure preserves original metadata" 'wlan0 0 100' "$(metadata)"
  ck "$failure preserves original cache bytes" 0 "$(cmp -s "$DNS_CACHE" "$APP_HOME/cache.original"; echo $?)"
  ck "$failure no new lastgood identity" '' "$(cat "$A2A_LIVE/dns.lastgood.id" 2>/dev/null)"
  ck "$failure clears publish lock" 0 "$([ -e "$DNS_CACHE.publish.lock" ] && echo 1 || echo 0)"
  # A permanently failing live rename also blocks rollback; do not mis-assert restoration.
  if [ "$failure" != live_rename ]; then ck "$failure restores live bytes" 0 "$(cmp -s "$DNSFILE" "$APP_HOME/original"; echo $?)"; fi
done

reset_case missing_identity; seed; rm -f "$DNS_VPN_CACHE"
dns_ensure; ck 'cache with incomplete identity rejected' 1 "$?"
reset_case invalid_cache; seed; printf 'nameserver 127.0.0.1\n' >"$DNS_CACHE"
dns_ensure; ck 'unusable cache rejected' 1 "$?"

reset_case write_cross; seed; IFACE=tun0; VPN=1; NETID=101
printf 'dns_static=\ndns_static_v6=\n' >"$SETTINGS"
dns_write auto; ck 'dns_write auto cross-identity cache rejected' 1 "$?"
ck 'dns_write failure preserves metadata' 'wlan0 0 100' "$(metadata)"
reset_case write_same; seed
dns_write auto; ck 'dns_write auto same-identity recovery' 0 "$?"
ck 'dns_write recovery metadata' 'wlan0 0 100' "$(metadata)"
reset_case bootstrap; seed; NETID=600
printf 'dns_mode=static\ndns_static=4.4.4.4\n' >"$SETTINGS"
dns_bootstrap; ck 'real bootstrap static publication succeeds' 0 "$?"
ck 'bootstrap shares identity publication' 'wlan0 0 600' "$(metadata)"
ck 'bootstrap bound cache content' 4.4.4.4 "$(ns "$DNS_CACHE")"
reset_case write_cache_failure; seed; NETID=600; SAMPLE='nameserver 4.4.4.4'; FAIL_MV="$DNS_CACHE"
dns_write auto; ck 'dns_write cache failure is nonzero' 1 "$?"
ck 'dns_write cache failure preserves identity' 'wlan0 0 100' "$(metadata)"

# Lastgood content/identity are a single atom; compatibility mirror failures
# neither corrupt that record nor prevent reading the new authoritative header.
reset_case lastgood_mirror_failure; NETID=600; SAMPLE='nameserver 4.4.4.4'
FAIL_MV="$A2A_LIVE/dns.lastgood.id"
dns_ensure; ck 'lastgood mirror failure does not undo successful publication' 0 "$?"
ck 'lastgood embeds successful identity' 'wlan0 0 600' "$(sed -n 's/^# agent2api-dns-identity //p' "$A2A_LIVE/dns.lastgood")"
ck 'lastgood contains only filtered published addresses' 4.4.4.4 "$(awk '$1 !~ /^#/ {print $1; exit}' "$A2A_LIVE/dns.lastgood")"
printf 'wlan0 0 599\n' >"$A2A_LIVE/dns.lastgood.id"
SAMPLE=''; rm -f "$DNSFILE" "$DNS_CACHE"; FAIL_MV=''
dns_ensure; ck 'new lastgood identity overrides stale mirror on recovery' 0 "$?"
ck 'lastgood restores validated address' 4.4.4.4 "$(ns "$DNSFILE")"
# Mirror-only relabeling must not authorize old content on a different network.
NETID=601; printf 'wlan0 0 601\n' >"$A2A_LIVE/dns.lastgood.id"; rm -f "$DNSFILE" "$DNS_CACHE"
dns_ensure; ck 'lastgood header rejects relabeled split mirror' 1 "$?"

for lastgood_fault in rename chmod; do
  reset_case "lastgood_$lastgood_fault"; SAMPLE='nameserver 4.4.4.4'
  printf '127.0.0.1\n' >"$A2A_LIVE/dns.lastgood"; printf 'wlan0 0 100\n' >"$A2A_LIVE/dns.lastgood.id"
  command cp "$A2A_LIVE/dns.lastgood" "$APP_HOME/lastgood.original"
  case "$lastgood_fault" in rename) FAIL_MV="$A2A_LIVE/dns.lastgood" ;; chmod) FAIL_CHMOD="$A2A_LIVE/dns.lastgood.new.$$" ;; esac
  dns_ensure; ck "lastgood $lastgood_fault failure preserves DNS success" 0 "$?"
  ck "lastgood $lastgood_fault leaves exact old content" 0 "$(cmp -s "$A2A_LIVE/dns.lastgood" "$APP_HOME/lastgood.original"; echo $?)"
  ck "lastgood $lastgood_fault leaves exact old mirror" 'wlan0 0 100' "$(cat "$A2A_LIVE/dns.lastgood.id")"
  ck "lastgood $lastgood_fault successful cache remains bound" 'wlan0 0 100' "$(sed -n 's/^# agent2api-dns-identity //p' "$DNS_CACHE")"
done

# Interrupt the compatibility metadata rename: authoritative old cache must
# remain bound and its mirrors must roll back despite one committed field.
reset_case metadata_second_field_failure; seed; NETID=101; SAMPLE='nameserver 4.4.4.4'; VPN=1
FAIL_MV="$DNS_VPN_CACHE"
dns_ensure; ck 'second metadata rename failure returns nonzero' 1 "$?"
ck 'partially advanced metadata rolled back' 'wlan0 0 100' "$(metadata)"
ck 'partially advanced metadata leaves old cache' 192.168.1.1 "$(ns "$DNS_CACHE")"

reset_case stale_publish_lock; seed; NETID=600; SAMPLE='nameserver 4.4.4.4'
mkdir "$DNS_CACHE.publish.lock"; printf 2147483647 >"$DNS_CACHE.publish.lock/pid"
dns_ensure; ck 'dead publisher lock recovered' 0 "$?"
ck 'dead publisher recovery binds new identity' 'wlan0 0 600' "$(metadata)"
reset_case active_publish_lock; seed; NETID=600; SAMPLE='nameserver 4.4.4.4'
mkdir "$DNS_CACHE.publish.lock"; printf '%s' "$$" >"$DNS_CACHE.publish.lock/pid"
dns_ensure; ck 'active publisher lock rejects concurrent publication' 1 "$?"
ck 'active publisher lock leaves metadata unchanged' 'wlan0 0 100' "$(metadata)"
ck 'active publisher lock leaves cache unchanged' 192.168.1.1 "$(ns "$DNS_CACHE")"

printf '\n%d checked / %d passed / %d failed\nEvidence directory: %s\n' "$((PASS + FAIL))" "$PASS" "$FAIL" "$WORK"
[ "$FAIL" -eq 0 ]
