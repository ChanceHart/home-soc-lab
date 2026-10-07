#!/usr/bin/env bash
# Copy the custom detection rules into the Wazuh manager, validate them and restart. Run from the repo root as root.
set -euo pipefail
C=single-node-wazuh.manager-1
docker exec -i "$C" bash -c 'cat > /var/ossec/etc/rules/local_rules.xml && chown wazuh:wazuh /var/ossec/etc/rules/local_rules.xml' < rules/local_rules.xml
docker exec "$C" /var/ossec/bin/wazuh-analysisd -t && echo "Rules OK"
docker exec "$C" /var/ossec/bin/wazuh-control restart >/dev/null && echo "Manager restarted"
