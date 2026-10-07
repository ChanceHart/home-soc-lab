#!/usr/bin/env bash
# Open the Home SOC Lab dashboard any time (Linux / macOS). Starts the local Wazuh stack if needed, waits, opens the browser.
#   ./open-homelab.sh                                              # local lab (default https://localhost)
#   URL=https://home-lab-cloud.your-tailnet.ts.net ./open-homelab.sh   # remote/cloud lab over Tailscale
set -euo pipefail
URL="${URL:-https://localhost}"
DIR="${WAZUH_DIR:-/opt/lab/wazuh-docker/single-node}"

if [ "$URL" = "https://localhost" ] && [ -d "$DIR" ]; then
  echo "Starting the lab..."
  (cd "$DIR" && sudo docker compose up -d >/dev/null)
fi

printf 'Waiting for %s ' "$URL"
for _ in $(seq 1 60); do
  # Any HTTP answer means it is up. -k: the lab uses its own self-signed certificate. No credentials are sent.
  curl -ks -o /dev/null --max-time 5 "$URL" && { echo " up."; break; }
  printf .; sleep 5
done

if command -v xdg-open >/dev/null; then xdg-open "$URL" >/dev/null 2>&1 &
elif command -v open >/dev/null; then open "$URL"
else echo "Open $URL in your browser"; fi
echo "A certificate warning is normal (the lab uses its own certificate)."
