#!/system/bin/sh
# Split DNS: local dnsproxy with per-domain upstreams + iptables redirect of port 53.
# Usage: splitdns.sh start|stop|restart|enable|disable|status|webstatus|watch|apply <cmd>

set -f   # no globbing: "*" in domains.txt must stay literal

MODDIR=${0%/*}
DATA=/data/adb/splitdns
CONF=$DATA/domains.txt
DISABLED=$DATA/disabled    # set by "disable" / the WebUI master switch, survives reboots
RUN=$DATA/run
LOG=$DATA/splitdns.log
BIN=$MODDIR/bin/dnsproxy
NOREDIRECT=$DATA/no-redirect   # "Replace system DNS" off: redirect only DNS sent to VPN_DNS_IP
# Address to put into the VPN client as its DNS (clients reject 127.0.0.1).
# 192.0.2.0/24 (TEST-NET-1, RFC 5737) is for documentation only: nothing real lives
# there, and unlike 198.18.0.0/15 it is not a Clash/sing-box fake-IP range.
# Override: echo 10.x.x.x > /data/adb/splitdns/vpn-dns-ip
VPN_DNS_IP=192.0.2.53
[ -s "$DATA/vpn-dns-ip" ] && VPN_DNS_IP=$(head -n 1 "$DATA/vpn-dns-ip" | tr -d ' \r\n')
PORT=5354
GID=23333          # dnsproxy runs with this gid; its own queries are not redirected
CHAIN=SPLITDNS
WATCH_INTERVAL=15

for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox; do
  [ -x "$b" ] && BB=$b && break
done

mkdir -p "$RUN"

log() {
  echo "$*"
  echo "[$(date '+%F %T')] $*" >> "$LOG"
}

# Keep the log small
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ] && tail -n 500 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"

# Daemons started from the WebUI would otherwise live in the KernelSU manager's
# cgroup and get frozen with it when the app goes to the background.
echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null
for c in /dev/cpuset /dev/cpuctl /dev/blkio /dev/memcg; do
  [ -w "$c/cgroup.procs" ] && echo $$ > "$c/cgroup.procs" 2>/dev/null
done

# IP -> ip:53 / [ip6]:53; dnsproxy URLs (https:// tls:// quic:// ...) as is
fmt_server() {
  case "$1" in
    *://*) echo "$1" ;;
    *:*) echo "[$1]:53" ;;
    *) echo "$1:53" ;;
  esac
}

# domains.txt -> $RUN/rules ("server name" per line); returns 1 if nothing usable.
# Line format: <server>[,<server>...] <name> [<name> ...]
# A name listed on several lines belongs to the first line only (upper group wins).
# One awk pass: forking grep per name took minutes on thousands of rules.
parse_conf() {
  [ -f "$CONF" ] || { log "config not found: $CONF"; return 1; }
  awk '
    function ok_srv(s) {
      return s ~ /^(https|tls|quic|h3|sdns|tcp|udp):\/\/./ ||
             s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || s ~ /^[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*$/
    }
    function ok_name(n) { return n == "*" || n ~ /^\.?[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$/ }
    {
      sub(/\r$/, ""); sub(/#.*/, "")
      if (NF < 2) next
      line++
      ns = split($1, S, ",")
      for (i = 1; i <= ns; i++) {
        s = S[i]
        if (s == "") continue
        if (!ok_srv(s)) { print "skip: \047" s "\047 is not a DNS server" > "/dev/stderr"; continue }
        for (j = 2; j <= NF; j++) {
          n = $j
          if (!ok_name(n)) { bad[n] = 1; continue }
          if (!(n in owner)) owner[n] = line
          if (owner[n] == line) print s, n
        }
      }
    }
    END { for (n in bad) print "skip: bad name \047" n "\047" > "/dev/stderr" }
  ' "$CONF" > "$RUN/rules" 2> "$RUN/skips"
  while read -r l; do log "$l"; done < "$RUN/skips"
  [ -s "$RUN/rules" ] || { log "no rules in $CONF"; return 1; }
}

# DNS servers of the active VPN, else of the default network
detect_default() {
  dc=$(dumpsys connectivity 2>/dev/null)
  nai=$(echo "$dc" | grep 'NetworkAgentInfo{' | grep 'Transports: VPN' | head -n 1)
  if [ -z "$nai" ]; then
    id=$(echo "$dc" | sed -n 's/^ *Active default network: \([0-9]*\).*/\1/p' | head -n 1)
    [ -n "$id" ] && nai=$(echo "$dc" | grep "NetworkAgentInfo{network{$id}" | head -n 1)
  fi
  echo "$nai" | sed -n 's/.* DnsAddresses: \[\([^]]*\)\].*/\1/p' | tr ',' '\n' |
    sed 's/^[ /]*//; s/[ ]*$//; s/%.*//' | grep -iv -e '^$' -e '^127\.' -e '^::1$' -e '^fe80:' -e "^$VPN_DNS_IP\$"
}

# Default upstreams: "*" lines, else autodetected
defaults() {
  d=$(awk '$2 == "*" { print $1 }' "$RUN/rules")
  [ -z "$d" ] && d=$(detect_default)
  [ -z "$d" ] && d=$(awk 'NR == 1 { print $1 }' "$RUN/rules")
  echo $d
}

proxy_alive() {
  [ -f "$RUN/proxy.pid" ] && kill -0 "$(cat "$RUN/proxy.pid")" 2>/dev/null
}

stop_proxy() {
  if [ -f "$RUN/proxy.pid" ]; then
    kill "$(cat "$RUN/proxy.pid")" 2>/dev/null
    rm -f "$RUN/proxy.pid"
  fi
}

start_proxy() {
  stop_proxy
  dflt=$(defaults)
  # Bootstrap resolves hostnames in DoH/DoT upstream URLs
  set -- --listen=127.0.0.1 --listen=::1 --port=$PORT --cache --cache-size=1048576 \
    --bootstrap=9.9.9.10:53 --bootstrap=1.1.1.1:53
  # One --upstream per server with up to 100 domains: [/a.com/*.b.com/]server
  awk '
    $2 == "*" { next }
    {
      s = $1
      if (s !~ /:\/\//) s = (s ~ /:/) ? "[" s "]:53" : s ":53"
      d = ($2 ~ /^\./) ? "*" $2 : $2
      if (!(s in cnt)) order[++k] = s
      list[s] = list[s] d "/"
      if (++cnt[s] % 100 == 0) { print "--upstream=[/" list[s] "]" s; list[s] = "" }
    }
    END { for (i = 1; i <= k; i++) if (list[order[i]] != "") print "--upstream=[/" list[order[i]] "]" order[i] }
  ' "$RUN/rules" > "$RUN/args"
  while IFS= read -r a; do set -- "$@" "$a"; done < "$RUN/args"
  for d in $dflt; do set -- "$@" "--upstream=$(fmt_server "$d")"; done

  echo "$dflt" > "$RUN/default"
  # All three std fds redirected: a daemon must not hold the caller's pipes open
  "$BB" setsid "$BB" setuidgid 0:$GID "$BIN" "$@" < /dev/null >> "$LOG" 2>&1 &
  echo $! > "$RUN/proxy.pid"
  sleep 1
  if ! proxy_alive; then
    log "dnsproxy failed to start, see $LOG"
    return 1
  fi
  log "dnsproxy pid $(cat "$RUN/proxy.pid"), default DNS: $dflt"
}

# Only DNS sent to VPN_DNS_IP goes to dnsproxy; everything else is untouched
ipt_on_vpn_ip() {
  iptables -w -t nat -N $CHAIN 2>/dev/null
  iptables -w -t nat -F $CHAIN
  iptables -w -t nat -A $CHAIN -m owner --gid-owner $GID -j RETURN
  iptables -w -t nat -A $CHAIN -d "$VPN_DNS_IP" -p udp --dport 53 -j REDIRECT --to-ports $PORT
  iptables -w -t nat -A $CHAIN -d "$VPN_DNS_IP" -p tcp --dport 53 -j REDIRECT --to-ports $PORT
  iptables -w -t nat -C OUTPUT -j $CHAIN 2>/dev/null || iptables -w -t nat -I OUTPUT -j $CHAIN
}

ipt_on() {
  for t in iptables ip6tables; do
    # stderr silenced: missing ip6 nat is expected on many kernels and handled below
    $t -w -t nat -N $CHAIN 2>/dev/null
    $t -w -t nat -F $CHAIN 2>/dev/null
    $t -w -t nat -A $CHAIN -m owner --gid-owner $GID -j RETURN 2>/dev/null
    $t -w -t nat -A $CHAIN -p udp --dport 53 -j REDIRECT --to-ports $PORT 2>/dev/null &&
    $t -w -t nat -A $CHAIN -p tcp --dport 53 -j REDIRECT --to-ports $PORT 2>/dev/null &&
    { $t -w -t nat -C OUTPUT -j $CHAIN 2>/dev/null || $t -w -t nat -I OUTPUT -j $CHAIN; } &&
      continue
    # No NAT for this family: block its DNS so the resolver falls back to the other one
    log "$t: nat redirect unavailable, blocking its port 53 instead"
    $t -w -t nat -D OUTPUT -j $CHAIN 2>/dev/null
    $t -w -t nat -X $CHAIN 2>/dev/null
    $t -w -N $CHAIN 2>/dev/null
    $t -w -F $CHAIN
    $t -w -A $CHAIN -m owner --gid-owner $GID -j RETURN
    $t -w -A $CHAIN -p udp --dport 53 -j REJECT
    $t -w -A $CHAIN -p tcp --dport 53 -j REJECT
    $t -w -C OUTPUT -j $CHAIN 2>/dev/null || $t -w -I OUTPUT -j $CHAIN
  done
}

ipt_off() {
  for t in iptables ip6tables; do
    for tbl in nat filter; do
      while $t -w -t $tbl -D OUTPUT -j $CHAIN 2>/dev/null; do :; done
      $t -w -t $tbl -F $CHAIN 2>/dev/null
      $t -w -t $tbl -X $CHAIN 2>/dev/null
    done
  done
}

stop_watch() {
  if [ -f "$RUN/watch.pid" ]; then
    kill "$(cat "$RUN/watch.pid")" 2>/dev/null
    rm -f "$RUN/watch.pid"
  fi
}

set_status() {
  sed -i "s|^description=.*|description=$1|" "$MODDIR/module.prop" 2>/dev/null
}

do_stop() {
  stop_watch
  ipt_off
  stop_proxy
  set_status "Stopped. Config: $CONF"
}

do_start() {
  do_stop
  if [ -f "$DISABLED" ]; then
    set_status "Disabled. Config: $CONF"
    log "disabled (turn on in WebUI or: $0 enable)"
    return 0
  fi
  [ -n "$BB" ] || { log "busybox not found"; return 1; }
  [ -x "$BIN" ] || { log "dnsproxy binary missing: $BIN"; return 1; }
  parse_conf || { set_status "Error: no rules in $CONF"; return 1; }
  start_proxy || { set_status "Error: dnsproxy failed, see $LOG"; return 1; }
  if [ -f "$NOREDIRECT" ]; then
    ipt_on_vpn_ip
    mode="only DNS to $VPN_DNS_IP (set it as DNS in the VPN client)"
  else
    ipt_on
    mode="system DNS redirected"
  fi
  "$BB" setsid sh "$0" watch < /dev/null > /dev/null 2>&1 &
  echo $! > "$RUN/watch.pid"
  rules=$(grep -vc ' \*$' "$RUN/rules")
  set_status "Running, $mode: $rules rules, default DNS $(cat "$RUN/default"). Config: $CONF"
  log "applied $rules rules from $CONF"
}

# Restarts dnsproxy when it dies or when the VPN/network DNS changes
do_watch() {
  while sleep $WATCH_INTERVAL; do
    [ -f "$RUN/rules" ] || exit 0
    if ! proxy_alive; then
      log "dnsproxy is not running, restarting"
      start_proxy
    elif [ "$(defaults)" != "$(cat "$RUN/default" 2>/dev/null)" ]; then
      log "default DNS changed: $(cat "$RUN/default") -> $(defaults)"
      start_proxy
    fi
  done
}

case "$1" in
  start|restart) do_start ;;
  stop) do_stop; log "stopped" ;;
  enable) rm -f "$DISABLED"; do_start ;;
  disable) touch "$DISABLED"; do_stop; log "disabled" ;;
  watch) do_watch ;;
  status)
    if proxy_alive; then echo "running, default DNS: $(cat "$RUN/default")"; else echo "stopped"; fi
    cat "$RUN/rules" 2>/dev/null
    ;;
  apply)
    # For the WebUI: run restart|enable|disable fully detached and return at once,
    # so ksu.exec never waits on it. Progress: "applying" / "result" in webstatus.
    case "$2" in
      restart|enable|disable|redirect-on|redirect-off) ;;
      *) echo "usage: $0 apply restart|enable|disable|redirect-on|redirect-off"; exit 1 ;;
    esac
    rm -f "$RUN/apply.result"
    echo $$ > "$RUN/applying"
    if [ -n "$BB" ]; then
      "$BB" setsid sh "$0" apply-run "$2" < /dev/null > /dev/null 2>&1 &
    else
      nohup sh "$0" apply-run "$2" < /dev/null > /dev/null 2>&1 &
    fi
    ;;
  apply-run)
    sh "$0" "$2" > /dev/null 2>> "$LOG"   # log() already writes to $LOG
    echo $? > "$RUN/apply.result"
    rm -f "$RUN/applying"
    ;;
  webstatus)
    # key=value for the WebUI
    if [ -f "$DISABLED" ]; then echo enabled=0; else echo enabled=1; fi
    if [ -f "$NOREDIRECT" ]; then echo redirect=0; else echo redirect=1; fi
    echo "vpndns=$VPN_DNS_IP"
    if proxy_alive; then echo running=1; else echo running=0; fi
    if [ -f "$RUN/applying" ]; then echo applying=1; else echo applying=0; fi
    echo "result=$(cat "$RUN/apply.result" 2>/dev/null)"
    echo "default=$(cat "$RUN/default" 2>/dev/null)"
    # "webstatus fast" skips dumpsys (used while polling)
    [ "$2" = fast ] || echo "detected=$(detect_default | tr '\n' ' ')"
    echo "lastlog=$(tail -n 1 "$LOG" 2>/dev/null)"
    ;;
  redirect-on) rm -f "$NOREDIRECT"; do_start ;;
  redirect-off) touch "$NOREDIRECT"; do_start ;;
  *) echo "usage: $0 start|stop|restart|enable|disable|redirect-on|redirect-off|status|apply"; exit 1 ;;
esac
