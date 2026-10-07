#!/usr/bin/env bash
# Pull free threat-intel feeds and load them into Wazuh as CDB lists. Run as root; safe to run daily (cron).
#   bad-ips      Feodo Tracker botnet C2 IPs (abuse.ch) + IPsum level 3+ (IPs on 3+ public blocklists)
#   bad-domains  URLhaus malware-distribution hosts (abuse.ch)
#   bad-hashes   MalwareBazaar SHA-256 hashes of malware seen in the last 48 hours (abuse.ch)
# Extra entries (for example a test IP) can go in /root/homelab-extra-ips.txt, one per line.
set -euo pipefail
C=single-node-wazuh.manager-1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fetch() { curl -fsSL --max-time 60 "$1" -o "$2" || { echo "feed failed: $1"; : > "$2"; }; }

fetch https://feodotracker.abuse.ch/downloads/ipblocklist.txt "$T/feodo.txt"
fetch https://raw.githubusercontent.com/stamparm/ipsum/master/levels/3.txt "$T/ipsum.txt"
fetch https://urlhaus.abuse.ch/downloads/hostfile/ "$T/urlhaus.txt"
fetch https://bazaar.abuse.ch/export/txt/sha256/recent/ "$T/bazaar.txt"

sed -i 's/$//' "$T"/*.txt
ipre='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
{ grep -hEo '^[0-9.]+' "$T/feodo.txt" "$T/ipsum.txt" 2>/dev/null; cat /root/homelab-extra-ips.txt 2>/dev/null || true; } \
  | { grep -E "$ipre" || true; } | sort -u | sed 's/$/:/' > "$T/bad-ips"
awk '$1=="127.0.0.1" && $2!="localhost" {print tolower($2)":"}' "$T/urlhaus.txt" | sort -u > "$T/bad-domains"
{ grep -Eio '^[0-9a-f]{64}$' "$T/bazaar.txt" || true; } | tr 'A-F' 'a-f' | sort -u | sed 's/$/:/' > "$T/bad-hashes"

docker exec "$C" mkdir -p /var/ossec/etc/lists/homelab
for f in bad-ips bad-domains bad-hashes; do
  docker exec -i "$C" bash -c "cat > /var/ossec/etc/lists/homelab/$f && chown wazuh:wazuh /var/ossec/etc/lists/homelab/$f" < "$T/$f"
  echo "$f: $(wc -l < "$T/$f") entries"
done
# Lists are compiled to .cdb when the manager (re)starts
docker exec "$C" /var/ossec/bin/wazuh-control restart >/dev/null && echo "Manager restarted, lists compiled"
