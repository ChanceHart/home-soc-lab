<#
.SYNOPSIS
  One-command health and security check for the cloud Home SOC Lab. Run it from the Windows PC (no admin needed).
  Every line is PASS, WARN or FAIL, and each problem says how to fix it.
.EXAMPLE
  .\cloud\verify.ps1 -Server 100.x.y.z -PublicIp 203.0.113.10 -SshKey ~\.ssh\oracle_home_lab
#>
param(
  [Parameter(Mandatory)][string]$Server,      # the server's Tailscale IP
  [string]$PublicIp,                          # the server's public IP (checks nothing is exposed to the internet)
  [string]$SshKey = "$env:USERPROFILE\.ssh\oracle_home_lab",
  [string]$User = 'ubuntu'
)
$ErrorActionPreference = 'Stop'
$script:fails = 0; $script:warns = 0

function Report($status, $name, $detail, $fix) {
  $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$status]
  Write-Host ("{0,-5} {1,-38} {2}" -f $status, $name, $detail) -ForegroundColor $color
  if ($status -ne 'PASS' -and $fix) { Write-Host "      fix: $fix" -ForegroundColor DarkGray }
  if ($status -eq 'FAIL') { $script:fails++ } elseif ($status -eq 'WARN') { $script:warns++ }
}
function Test-Port($ip, $port, $ms = 3000) {
  $c = New-Object Net.Sockets.TcpClient
  try { return $c.ConnectAsync($ip, $port).Wait($ms) -and $c.Connected } catch { return $false } finally { $c.Close() }
}

Write-Host "`nHome SOC Lab check: $Server`n"

# 1. Tailscale on this PC and the server
$ts = Get-Command tailscale.exe -ErrorAction SilentlyContinue
if (-not $ts) { $ts = Get-Item "$env:ProgramFiles\Tailscale\tailscale.exe" -ErrorAction SilentlyContinue }
if (-not $ts) { Report FAIL 'Tailscale on this PC' 'not installed' 'install Tailscale and sign in'; exit 1 }
$st = & $ts.Source status --json | ConvertFrom-Json
$me = $st.Self.TailscaleIPs | Where-Object { $_ -like '100.*' } | Select-Object -First 1
$peer = $st.Peer.PSObject.Properties.Value | Where-Object { $_.TailscaleIPs -contains $Server }
if (-not $peer) { Report FAIL 'server on your tailnet' "no device with $Server" 'on the server: sudo tailscale up, then approve the login link'; exit 1 }
if ($peer.Online) { Report PASS 'server online in Tailscale' $peer.HostName } else { Report FAIL 'server online in Tailscale' 'offline' 'check the VM is running in the Oracle console' }
if (-not $peer.KeyExpiry) { Report PASS 'server key expiry' 'disabled' }
else { Report WARN 'server key expiry' "expires $($peer.KeyExpiry)" "Tailscale admin > Machines > $($peer.HostName) > ... > Disable key expiry" }
if ($peer.ExitNodeOption) { Report PASS 'server approved as exit node (VPN)' 'yes' }
else { Report WARN 'server approved as exit node (VPN)' 'no' "Tailscale admin > Machines > $($peer.HostName) > ... > Edit route settings > Use as exit node" }

# 2. Nothing reachable from the internet
if ($PublicIp) {
  $open = @(22, 80, 443, 1514, 1515, 5601, 9200, 55000 | Where-Object { Test-Port $PublicIp $_ })
  if ($open.Count -eq 0) { Report PASS 'internet exposure (public IP)' 'no ports open' }
  else { Report FAIL 'internet exposure (public IP)' "open: $($open -join ', ')" 'remove those ingress rules from the Oracle VCN security list' }
} else { Report WARN 'internet exposure (public IP)' 'skipped' 'pass -PublicIp to check it' }

# 3. What your PC should reach over Tailscale
$need = @{ 22 = 'SSH'; 443 = 'dashboard'; 1514 = 'agent events'; 1515 = 'agent enrollment' }
$missing = @($need.Keys | Where-Object { -not (Test-Port $Server $_) } | ForEach-Object { "$_ ($($need[$_]))" })
if ($missing.Count -eq 0) { Report PASS 'PC -> server over Tailscale' '22, 443, 1514, 1515 reachable' }
else { Report FAIL 'PC -> server over Tailscale' "unreachable: $($missing -join ', ')" 'check the Tailscale policy lets your PC reach the server, and that Wazuh is running' }
if ($peer.DNSName) {
  $url = 'https://' + $peer.DNSName.TrimEnd('.') + '/'
  try {
    $r = [Net.HttpWebRequest]::Create($url); $r.AllowAutoRedirect = $false; $r.Timeout = 30000
    $code = [int]$r.GetResponse().StatusCode
  } catch [Net.WebException] { $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } }
  if ($code -in 200, 302) { Report PASS 'dashboard (trusted certificate)' $url }
  else { Report FAIL 'dashboard (trusted certificate)' "HTTP $code at $url" 'on the server: sudo tailscale serve --bg https+insecure://localhost:443 (enable Serve in the Tailscale admin if asked)' }
}

# 4. Checks on the server itself (over SSH), including the server -> PC isolation test
$remote = @'
P(){ echo "PASS|$1|$2|"; }; W(){ echo "WARN|$1|$2|$3"; }; F(){ echo "FAIL|$1|$2|$3"; }
n=$(docker ps --format '{{.Names}}' | grep -c 'single-node-wazuh')
[ "$n" = 3 ] && P "Wazuh containers" "3 running" || F "Wazuh containers" "$n of 3 running" "cd /opt/lab/wazuh-docker/single-node && sudo docker compose up -d"
c=$(curl -sk -o /dev/null -w '%{http_code}' https://localhost/)
[ "$c" = 302 ] || [ "$c" = 200 ] && P "dashboard on the server" "HTTP $c" || F "dashboard on the server" "HTTP $c" "see docs/TROUBLESHOOTING.md: dashboard not ready"
a=$(docker exec single-node-wazuh.manager-1 /var/ossec/bin/agent_control -l 2>/dev/null | grep -v 'ID: 000' | grep -c 'Active')
t=$(docker exec single-node-wazuh.manager-1 /var/ossec/bin/agent_control -l 2>/dev/null | grep -vc 'ID: 000\|^$\|List of\|^ *$')
[ "$a" -ge 1 ] && [ "$a" = "$t" ] && P "agents connected" "$a of $t active" || W "agents connected" "$a of $t active" "on the PC (admin): Restart-Service WazuhSvc"
[ "$(iptables -S DOCKER-USER | grep -c DROP)" -ge 2 ] && P "Docker guard rules" "public NIC + metadata blocked" || F "Docker guard rules" "missing" "sudo systemctl restart homelab-docker-guard"
[ "$(iptables -S INPUT | grep -c 'dport 22')" = 0 ] && P "host firewall" "no public SSH rule" || W "host firewall" "public SSH still allowed" "run cloud/04-lockdown.sh over Tailscale SSH"
[ "$(sshd -T | awk '/^permitrootlogin /{print $2}')" = no ] && P "SSH hardening" "no root, keys only" || W "SSH hardening" "not locked down" "run cloud/04-lockdown.sh over Tailscale SSH"
[ "$(stat -c %a /root/lab-credentials.txt 2>/dev/null)" = 600 ] && P "secrets file" "root-only (600)" || F "secrets file" "missing or readable by others" "sudo chmod 600 /root/lab-credentials.txt"
up=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst'); [ -f /var/run/reboot-required ] && W "updates" "$up pending, reboot required" "sudo apt full-upgrade -y && sudo reboot" || P "updates" "$up pending, no reboot needed"
d=$(df --output=pcent / | tail -1 | tr -dc 0-9); [ "$d" -lt 80 ] && P "disk" "$d% used" || W "disk" "$d% used" "old alerts are deleted after 90 days; check /var/lib/docker"
L=/var/ossec/etc/lists/homelab/bad-ips
n=$(docker exec single-node-wazuh.manager-1 sh -c "wc -l < $L" 2>/dev/null || echo 0)
age=$(( ( $(date +%s) - $(docker exec single-node-wazuh.manager-1 stat -c %Y $L 2>/dev/null || echo 0) ) / 3600 ))
[ "$n" -gt 1000 ] && [ "$age" -lt 48 ] && P "threat-intel lists" "$n bad IPs, updated ${age}h ago" || W "threat-intel lists" "$n bad IPs, updated ${age}h ago" "sudo /opt/lab/bin/update-threat-intel.sh (runs daily at 06:15 by cron)"
if [ -n "${PC_IP:-}" ]; then
  o=$(python3 -c "
import socket,sys
op=[]
for p in (445,135,139,3389,5985):
    s=socket.socket(); s.settimeout(3)
    try: s.connect((sys.argv[1],p)); op.append(str(p))
    except Exception: pass
    finally: s.close()
print(','.join(op))" "$PC_IP")
  [ -z "$o" ] && P "server -> your PC (isolation)" "blocked" || F "server -> your PC (isolation)" "server can reach PC ports $o" "save cloud/tailscale-policy.example.hujson in Tailscale > Access controls; line 1 must be the Home SOC Lab comment"
fi
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($remote -replace "`r", '')))
$out = & ssh.exe -i $SshKey -o BatchMode=yes -o ConnectTimeout=15 "$User@$Server" "echo $b64 | base64 -d | sudo PC_IP=$me bash" 2>&1
if ($LASTEXITCODE -ne 0 -and -not ($out -match '^(PASS|WARN|FAIL)\|')) {
  Report FAIL 'SSH to the server' ($out | Select-Object -Last 1) "ssh -i $SshKey $User@$Server  (Tailscale connected? right key?)"
} else {
  foreach ($line in $out) { if ($line -match '^(PASS|WARN|FAIL)\|([^|]*)\|([^|]*)\|(.*)$') { Report $Matches[1] $Matches[2] $Matches[3] $Matches[4] } }
}

Write-Host ''
if ($fails -eq 0 -and $warns -eq 0) { Write-Host 'All checks passed.' -ForegroundColor Green }
else { Write-Host "$fails failed, $warns warnings. Each one shows its fix above; see docs/TROUBLESHOOTING.md for more." -ForegroundColor Yellow }
exit [int]($fails -gt 0)
