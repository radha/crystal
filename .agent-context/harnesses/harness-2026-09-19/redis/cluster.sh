#!/bin/bash
set -eu
D="$(cd "$(dirname "$0")" && pwd)/cluster-data"
PORTS="7100 7101 7102"
case "${1:-start}" in
start)
  mkdir -p "$D"
  for p in $PORTS; do
    mkdir -p "$D/n$p"
    valkey-server --port $p --cluster-enabled yes --cluster-config-file nodes.conf --dir "$D/n$p" \
      --save "" --appendonly no --daemonize no --logfile log.txt --bind 127.0.0.1 >/dev/null 2>&1 &
    echo $! >> "$D/pids"
  done
  for p in $PORTS; do
    for _ in $(seq 1 50); do valkey-cli -p $p ping 2>/dev/null | grep -q PONG && break; sleep 0.1; done
  done
  valkey-cli -p 7100 cluster addslotsrange 0 5460 >/dev/null
  valkey-cli -p 7101 cluster addslotsrange 5461 10922 >/dev/null
  valkey-cli -p 7102 cluster addslotsrange 10923 16383 >/dev/null
  valkey-cli -p 7100 cluster meet 127.0.0.1 7101 >/dev/null
  valkey-cli -p 7100 cluster meet 127.0.0.1 7102 >/dev/null
  for _ in $(seq 1 100); do
    ok=0; for p in $PORTS; do valkey-cli -p $p cluster info 2>/dev/null | grep -q 'cluster_state:ok' && ok=$((ok+1)); done
    [ $ok = 3 ] && break; sleep 0.1
  done
  echo "cluster up on $PORTS (ok=$ok)"
  ;;
stop)
  [ -f "$D/pids" ] && kill $(cat "$D/pids") 2>/dev/null || true
  rm -rf "$D"
  echo "cluster stopped"
  ;;
esac
