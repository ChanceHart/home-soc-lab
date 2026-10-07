#!/usr/bin/env bash
# Replace Wazuh's well-known default indexer/dashboard admin password with a random one. Run as root after setup-wazuh.sh.
# The new password is written only to /root/lab-credentials.txt (mode 600).
set -euo pipefail
cd /opt/lab/wazuh-docker/single-node
VER=$(grep -o 'wazuh/wazuh-indexer:[0-9.]*' docker-compose.yml | head -1)
PW=$(python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print('Wz'+''.join(secrets.choice(a) for _ in range(18))+'7.x')")
HASH=$(docker run --rm "$VER" bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$PW" 2>/dev/null | tail -1)
cp config/wazuh_indexer/internal_users.yml{,.bak}
python3 - "$HASH" <<'PY'
import re, sys
p = 'config/wazuh_indexer/internal_users.yml'
s = open(p).read()
s = re.sub(r'(\nadmin:\n  hash: )"[^"]*"', lambda m: m.group(1) + '"' + sys.argv[1] + '"', s, count=1)
open(p, 'w').write(s)
PY
cp docker-compose.yml{,.bak}
sed -i "s/INDEXER_PASSWORD=SecretPassword/INDEXER_PASSWORD=$PW/g" docker-compose.yml
(umask 077; printf 'Wazuh dashboard: https://localhost\nuser: admin\npassword: %s\n' "$PW" > /root/lab-credentials.txt)
docker compose down && docker compose up -d && sleep 60
docker exec single-node-wazuh.indexer-1 bash -c 'export JAVA_HOME=/usr/share/wazuh-indexer/jdk; C=/usr/share/wazuh-indexer/config/certs; bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh -cd /usr/share/wazuh-indexer/config/opensearch-security/ -nhnv -cacert $C/root-ca.pem -cert $C/admin.pem -key $C/admin-key.pem -p 9200 -icl'
echo "Default password rejected? $(curl -sk -o /dev/null -w '%{http_code}' -u admin:SecretPassword https://localhost:9200) (expect 401)"
