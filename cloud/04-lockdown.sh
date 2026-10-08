#!/usr/bin/env bash
# Final lockdown: SSH only over Tailscale, keys only, no forwarding. Run as root over a TAILSCALE SSH session
# (ssh ubuntu@<tailscale-ip>), after 02-wazuh.sh. Afterwards also delete the port 22 rule in your cloud
# provider's firewall (Oracle: VCN security list), so the server has no ports open to the internet.
set -euo pipefail

# Refuse unless someone is logged in over Tailscale right now: otherwise you could lock yourself out.
# (sudo drops $SSH_CONNECTION, so look at the live SSH connections instead.)
if ! ss -Htn state established '( sport = :22 )' | awk '{print $4}' | grep -qE '^(100\.|\[fd7a:115c:a1e0:)'; then
  echo "No SSH session over Tailscale found. Log in with ssh ubuntu@<tailscale-ip> and run this again."
  exit 1
fi

cat > /etc/ssh/sshd_config.d/01-homelab.conf <<'EOF'
# Home SOC Lab: SSH only over Tailscale, keys only, no forwarding
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
sshd -t && systemctl reload ssh

# Host firewall: drop the public SSH allow rule (tailscale0 stays trusted), live and on every boot
iptables -D INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT 2>/dev/null || true
sed -i '/--dport 22 -j ACCEPT/d' /etc/iptables/rules.v4
echo "Locked down. Test a NEW Tailscale SSH login before closing this session."
