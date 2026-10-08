#!/usr/bin/env bash
# Wazuh on the cloud server, hardened. Run from the repo root as root, after 01-base.sh and `tailscale up`.
# Put the VirusTotal key in /root/virustotal.key (mode 600) first if you want that integration.
# All new secrets go only to /root/lab-credentials.txt (mode 600).
set -euo pipefail
REPO=$(pwd)
D=/opt/lab/wazuh-docker/single-node
M=single-node-wazuh.manager-1
tailscale ip -4 >/dev/null || { echo "Run tailscale up first"; exit 1; }

# 1. Docker + Wazuh 4.14.8 (shared with the laptop version)
bash server/setup-wazuh.sh
cd "$D"

# 2. Only the agent ports (1514/1515) are published; admin ports listen on localhost only
#    (dashboard reaches the tailnet through `tailscale serve`). Indexer heap sized to the VM.
python3 - <<'PY'
p = 'docker-compose.yml'; s = open(p).read()
for old, new in [('"514:514/udp"', '"127.0.0.1:514:514/udp"'), ('"55000:55000"', '"127.0.0.1:55000:55000"'),
                 ('"9200:9200"', '"127.0.0.1:9200:9200"'), ('- 443:5601', '- "127.0.0.1:443:5601"')]:
    s = s.replace(old, new)
assert s.count('127.0.0.1:') == 4, 'compose port layout changed; review docker-compose.yml by hand'
gb = int(open('/proc/meminfo').read().split()[1]) // 1024 // 1024
heap = '6g' if gb >= 20 else '3g'   # also keeps memory use above Oracle's 20% idle-reclaim line
s = s.replace('-Xms1g -Xmx1g', f'-Xms{heap} -Xmx{heap}')
open(p, 'w').write(s)
PY

# 3. Docker publishes ports around the host firewall, so drop NEW connections that arrive on the public NIC
#    (agents and the phone only come in over tailscale0). Re-applied by a systemd unit after Docker starts.
cat > /usr/local/sbin/homelab-docker-guard.sh <<'EOF'
#!/bin/sh
IF=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
iptables -C DOCKER-USER -i "$IF" -m conntrack --ctstate NEW -j DROP 2>/dev/null \
  || iptables -I DOCKER-USER 1 -i "$IF" -m conntrack --ctstate NEW -j DROP
# Containers never need the cloud instance-metadata service (a classic credential-theft path)
iptables -C DOCKER-USER -d 169.254.169.254 -p tcp -m multiport --dports 80,443 -j DROP 2>/dev/null \
  || iptables -I DOCKER-USER 1 -d 169.254.169.254 -p tcp -m multiport --dports 80,443 -j DROP
EOF
chmod 755 /usr/local/sbin/homelab-docker-guard.sh
cat > /etc/systemd/system/homelab-docker-guard.service <<'EOF'
[Unit]
Description=Block public access to Docker-published ports (Home SOC Lab)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/homelab-docker-guard.sh

[Install]
WantedBy=multi-user.target docker.service
EOF
systemctl daemon-reload && systemctl enable --now homelab-docker-guard.service

# 4. Replace both vendor default passwords (scripts restart the stack with the new compose settings)
bash "$REPO/server/change-admin-password.sh"
bash "$REPO/server/change-api-password.sh"
# Files holding secrets: root only, and no stale copies lying around
rm -f docker-compose.yml.bak docker-compose.yml.bak-api config/wazuh_indexer/internal_users.yml.bak
chmod 600 docker-compose.yml config/wazuh_cluster/wazuh_manager.conf

# 5. Agent enrollment needs a password (only devices we enroll can join, even inside the tailnet)
if ! grep -q 'Enrollment password' /root/lab-credentials.txt; then
  EP=$(python3 -c "import secrets;print(secrets.token_urlsafe(24))")
  docker exec -i "$M" bash -c 'cat > /var/ossec/etc/authd.pass && chown root:wazuh /var/ossec/etc/authd.pass && chmod 640 /var/ossec/etc/authd.pass' <<<"$EP"
  (umask 077; printf 'Enrollment password: %s\n' "$EP" >> /root/lab-credentials.txt)
fi
sed -i 's#<use_password>no</use_password>#<use_password>yes</use_password>#' config/wazuh_cluster/wazuh_manager.conf

# 6. Detections, malware defense, VirusTotal, threat-intel lists (recreates the manager, loads the rules)
cd "$REPO" && bash server/enable-malware-defense.sh
install -D -m 755 server/update-threat-intel.sh /opt/lab/bin/update-threat-intel.sh
echo '15 6 * * * root /opt/lab/bin/update-threat-intel.sh >> /var/log/homelab-threat-intel.log 2>&1' > /etc/cron.d/homelab-threat-intel
bash /opt/lab/bin/update-threat-intel.sh

# 7. Watch the cloud server itself with a local agent (SSH logins, sudo, package changes)
if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
  curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
  echo 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' > /etc/apt/sources.list.d/wazuh.list
  apt-get update -qq
  EP=$(sed -n 's/^Enrollment password: //p' /root/lab-credentials.txt)
  WAZUH_MANAGER=127.0.0.1 WAZUH_AGENT_NAME=home-lab-cloud WAZUH_REGISTRATION_PASSWORD="$EP" \
    apt-get install -y -qq wazuh-agent=4.14.8-1
  apt-mark hold wazuh-agent >/dev/null
  sed -i 's/^deb /#deb /' /etc/apt/sources.list.d/wazuh.list   # no surprise agent upgrades
  systemctl daemon-reload && systemctl enable --now wazuh-agent
fi

# 8. The password change restarts the dashboard during its first start, which can leave an empty, half-made
#    .kibana_1 index; the dashboard then waits forever ("not ready yet"). Remove it only if it is empty.
PW=$(sed -n 's/^password: //p' /root/lab-credentials.txt)
for _ in $(seq 1 36); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/)" = 302 ] && break; sleep 5; done
if [ "$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/)" != 302 ] && \
   docker logs --tail 50 single-node-wazuh.dashboard-1 2>&1 | grep -q 'appears to be migrating' && \
   [ "$(curl -sk -u "admin:$PW" 'https://localhost:9200/_cat/indices/.kibana_1?h=docs.count' | tr -d ' \n')" = 0 ]; then
  curl -sk -u "admin:$PW" -X DELETE https://localhost:9200/.kibana_1 >/dev/null
  docker restart single-node-wazuh.dashboard-1 >/dev/null
  echo "Cleared a stuck dashboard migration"
fi

# 9. Dashboard on the tailnet only: https://<this machine>.<tailnet>.ts.net
tailscale serve --bg https+insecure://localhost:443 || echo "Enable Serve in the Tailscale admin console, then rerun: tailscale serve --bg https+insecure://localhost:443"

echo "Done. Check: docker compose -f $D/docker-compose.yml ps ; ss -tlnp ; tailscale serve status"
