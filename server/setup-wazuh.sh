#!/usr/bin/env bash
# Home SOC Lab server: Docker Engine + Wazuh single-node on Ubuntu (WSL2 or any Linux/cloud VM). Run as root.
set -euo pipefail
WAZUH_VERSION="${WAZUH_VERSION:-v4.14.8}"

# 1. Docker Engine from Docker's official repository
apt-get update -qq && apt-get install -y -qq ca-certificates curl git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update -qq && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable --now docker

# 2. The indexer (OpenSearch) needs a higher mmap limit (on WSL2 set it in .wslconfig instead)
sysctl -w vm.max_map_count=262144 || true

# 3. Wazuh single-node stack
mkdir -p /opt/lab && cd /opt/lab
[ -d wazuh-docker ] || git clone -q --depth=1 -b "$WAZUH_VERSION" https://github.com/wazuh/wazuh-docker.git
cd wazuh-docker/single-node
docker compose -f generate-indexer-certs.yml run --rm generator
docker compose up -d
echo "Wazuh is starting. Next: run change-admin-password.sh (never keep the default password)."
