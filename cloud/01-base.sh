#!/usr/bin/env bash
# Cloud server base setup (Ubuntu 24.04 on Oracle Cloud Always Free). Run as root once; safe to re-run.
# Next step after this: tailscale up --advertise-exit-node --hostname=home-lab-cloud
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# 1. Patches now, security patches automatically from here on
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections
apt-get update -qq && apt-get -y -qq upgrade
apt-get install -y -qq unattended-upgrades iptables-persistent git curl jq python3
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades

# 2. Kernel settings: indexer mmap limit + packet forwarding for the Tailscale exit node
cat > /etc/sysctl.d/90-homelab.conf <<'EOF'
vm.max_map_count=262144
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
EOF
sysctl --system >/dev/null

# 3. Services the lab doesn't need (Oracle's image ships rpcbind)
systemctl disable --now rpcbind.socket rpcbind.service >/dev/null 2>&1 || true

# 4. Tailscale (official package repository) + the exit-node throughput setting Tailscale recommends
command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh
apt-get install -y -qq ethtool
IF=$(ip -o route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
cat > /etc/systemd/system/tailscale-gro.service <<UNIT
[Unit]
Description=UDP GRO forwarding for the Tailscale exit node
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -K $IF rx-udp-gro-forwarding on rx-gro-list off
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload && systemctl enable --now tailscale-gro.service >/dev/null

# 5. Host firewall. Oracle's Ubuntu image ships iptables rules that reject all inbound traffic except SSH.
#    Keep them (ufw conflicts with them) and trust only the Tailscale interface.
iptables -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i tailscale0 -j ACCEPT
netfilter-persistent save >/dev/null   # saved before Docker exists, so Docker's own rules are never frozen in
echo "Base setup done. Next: tailscale up --advertise-exit-node --hostname=home-lab-cloud"
