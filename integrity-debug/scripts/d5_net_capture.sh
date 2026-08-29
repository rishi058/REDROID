#!/usr/bin/env bash
# Phase D.5 - capture exp's integrity network egress on the VPS host. exp ONLY.
# Runs on the VPS HOST (not in container). Needs tcpdump + tshark (installed prior).
# READ-ONLY observation. Extracts TLS SNI of the endpoints hit during a request.
set -uo pipefail
C="$(sudo docker ps -q --filter 'label=coolify.serviceName=redroid-experimental' | head -n1)"
[ -z "$C" ] && { echo "exp not running"; exit 1; }
# find the veth/bridge for exp's eth0 (172.21.0.0/16 = coolify net)
BR="$(sudo docker network inspect bk6ojzx98y1dlabu4d63c6d3 -f '{{range .Options}}{{end}}br-{{.Id}}' 2>/dev/null | cut -c1-15)"
IFACE="${IFACE:-$(ip -o link | grep -oE 'br-[0-9a-f]{12}' | head -n1)}"
OUT="/tmp/exp_integrity_$(date +%s).pcap"
echo "== capturing 30s on $IFACE to $OUT (filter: exp 172.21.0.2 tcp 443) =="
sudo timeout 30 tcpdump -i "$IFACE" -w "$OUT" 'host 172.21.0.2 and tcp port 443' &
CAP=$!
sleep 2
echo "== triggering integrity check in exp =="
sudo docker exec "$C" sh -c 'am force-stop com.google.android.gms; am start -n gr.nikolasspyr.integritycheck/.MainActivity >/dev/null 2>&1'
wait $CAP
echo "== TLS SNI endpoints contacted =="
sudo tshark -r "$OUT" -Y 'tls.handshake.extensions_server_name' \
  -T fields -e ip.dst -e tls.handshake.extensions_server_name 2>/dev/null | sort -u
echo "== TLS alerts / resets (signs of blocking) =="
sudo tshark -r "$OUT" -Y 'tls.alert_message || tcp.flags.reset==1' -T fields -e ip.dst -e tls.alert_message.desc 2>/dev/null | sort -u
echo "pcap kept at $OUT"
