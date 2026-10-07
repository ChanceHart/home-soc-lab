#!/usr/bin/env bash
# Replace the Wazuh API's well-known default password (user wazuh-wui) with a random one. Run as root.
# The new password is appended to /root/lab-credentials.txt (mode 600).
set -euo pipefail
cd /opt/lab/wazuh-docker/single-node
OLD='MyS3cr37P450r.*-'
NEW=$(python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print('Api'+''.join(secrets.choice(a) for _ in range(20))+'9.x')")
TOKEN=$(curl -sk -u "wazuh-wui:$OLD" -X POST 'https://localhost:55000/security/user/authenticate?raw=true')
[ ${#TOKEN} -gt 50 ] || { echo "Could not log in with the default API password (already changed?)"; exit 1; }
ID=$(curl -sk -H "Authorization: Bearer $TOKEN" 'https://localhost:55000/security/users?search=wazuh-wui' | python3 -c "import sys,json;print([u['id'] for u in json.load(sys.stdin)['data']['affected_items'] if u['username']=='wazuh-wui'][0])")
curl -sk -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -X PUT "https://localhost:55000/security/users/$ID" -d "{\"password\":\"$NEW\"}" | python3 -c "import sys,json;d=json.load(sys.stdin);print('API password changed' if d.get('error')==0 else d)"
cp docker-compose.yml docker-compose.yml.bak-api
sed -i "s/API_PASSWORD=MyS3cr37P450r\.\*-/API_PASSWORD=$NEW/g" docker-compose.yml
(umask 077; printf 'API user: wazuh-wui\nAPI password: %s\n' "$NEW" >> /root/lab-credentials.txt)
docker compose up -d >/dev/null 2>&1
sleep 20
echo "Default API password rejected? $(curl -sk -o /dev/null -w '%{http_code}' -u "wazuh-wui:$OLD" -X POST https://localhost:55000/security/user/authenticate) (expect 401)"
echo "New API password works?      $(curl -sk -o /dev/null -w '%{http_code}' -u "wazuh-wui:$NEW" -X POST https://localhost:55000/security/user/authenticate) (expect 200)"
