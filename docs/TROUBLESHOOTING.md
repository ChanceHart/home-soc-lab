# Troubleshooting

Every problem below actually happened while building this lab. Most are now handled by the scripts; this page explains what you'll see and what to do.

**First, run the health check** (Windows, no admin): `.\cloud\verify.ps1 -Server <server Tailscale IP> -PublicIp <server public IP>`. Every line is PASS / WARN / FAIL with its fix.

## Oracle Cloud

| What you see | Why | What to do |
|---|---|---|
| "Out of capacity for shape VM.Standard.A1.Flex" (console or script) | Free Arm VMs are in high demand | Don't click Create over and over. Run `python cloud/launch_vm.py --fallback-after 1`: it retries every availability domain, full size then half size, until a slot opens. Upgrading the account to **Pay As You Go** gets capacity much faster and still costs $0 inside the Always Free limits (set a $1 budget alert). |
| Confused by the API key / "Configuration file preview" | The console offers three key options | Run `python cloud/setup_oci_key.py`. It creates the key, shows the exact clicks, checks that what you paste matches, and writes `~/.oci/config`. Pick **Paste a public key**, not "Generate API key pair". |
| `401 NotAuthenticated` right after adding the key, then it works, then 401 again | A new key takes a few minutes to reach every Oracle server | Wait. Both scripts retry 401s automatically. |
| `429 TooManyRequests` | Oracle limits how fast you can ask for VMs | The launcher backs off 5 minutes and spaces requests 30 s apart. Leave it running. |
| Launcher stopped printing for hours | The PC went to sleep | The launcher now blocks idle sleep while it runs (closing the lid still sleeps). Rerun it any time; it never creates a second VM. |
| Launcher crashed with `Read timed out` | Network blip | Fixed: network errors are retried. If you see this on an old copy, pull the latest repo. |
| Can't find the Upgrade / Pay As You Go page | It's under billing | Use the "Upgrade" link in the beige Free Trial banner, or Menu > Billing & Cost Management > Upgrade and Manage Payment. |
| Worried the free VM gets deleted | Oracle reclaims Always Free VMs idle for 7 days (CPU, network **and** memory under 20%) | Handled: the indexer uses enough memory to stay above 20%. Pay As You Go accounts are never reclaimed. |

## Setting up the server

| What you see | Why | What to do |
|---|---|---|
| Dashboard says "Wazuh dashboard server is not ready yet" forever | The password change restarts the dashboard during its first start, leaving an empty half-made `.kibana_1` index | `02-wazuh.sh` now detects and clears it. By hand: delete the **empty** `.kibana_1` index (`curl -sk -u admin:<password> -X DELETE https://localhost:9200/.kibana_1`) and `docker restart single-node-wazuh.dashboard-1`. |
| `find: command not found` while certificates are generated | Harmless message from Wazuh's certificate tool on Arm | Ignore it; the certificates are created. |
| Tailscale warns "UDP GRO forwarding is suboptimally configured" | Performance tip for exit nodes | Handled by `01-base.sh` (`tailscale-gro` service). |
| Locked out of SSH | Port 22 was closed before Tailscale SSH was confirmed | `04-lockdown.sh` refuses to run unless you're connected over Tailscale. If it still happens: Oracle console > instance > Console connection. |
| Where is the dashboard password? | It's generated, never printed | On the server: `sudo cat /root/lab-credentials.txt`, or let the shortcut copy it (`install-shortcut.ps1 -Ssh ...`). |

## Tailscale

| What you see | Why | What to do |
|---|---|---|
| Saved the access policy but the server can still reach your PC | The editor reloaded the old default policy and that was what got saved | Before clicking Save, check **line 1** reads `// Tailscale access policy for the Home SOC Lab` and the file is about 26 lines (the default is ~78). Then run `verify.ps1`: "server -> your PC (isolation)" must say **blocked**. |
| Policy save fails with a test error | The IPs in `hosts` don't match your devices | Fix the three IPs (`tailscale status` lists them). The tests exist so a wrong policy can't be saved. |
| Server disappears from the tailnet months later | Device keys expire after 180 days by default | Tailscale admin > Machines > server > **...** > **Disable key expiry**. `verify.ps1` warns if it's still on. |
| Phone can't select the server as an exit node | Exit nodes need approval | Machines > server > **...** > **Edit route settings** > **Use as exit node**. |
| Phone loses all internet (Wi-Fi and cellular) when the VPN is on | The phone's Tailscale app isn't actually connected, so the exit-node tunnel never forms and traffic goes nowhere | Set Exit node to None (service returns), open the Tailscale app, sign in / switch it on until it says **Connected**, then pick the exit node again. On the server, `tailscale status` should show the phone as active, not offline. |
| Saw two "home lab" machines | One is your PC, one is the cloud server | Expected. The PC is the monitored endpoint; the server is the SIEM. |

## Windows endpoint

| What you see | Why | What to do |
|---|---|---|
| `03-move-agent.ps1` says "No connection yet" but the agent is fine | Older copy looked for the wrong log wording | Fixed. Confirm on the server: `sudo docker exec single-node-wazuh.manager-1 /var/ossec/bin/agent_control -l` shows the PC as Active. |
| Agent won't enroll | Enrollment needs the password from `/root/lab-credentials.txt` | Rerun `03-move-agent.ps1` and paste the "Enrollment password" line's value. |
| Encoded-PowerShell test shows Wazuh rule 92057 instead of the lab rule | When PowerShell launches PowerShell, the built-in rule matches first | Fixed with rule 100121 (lab alert either way). |
| No pop-up when the lab quarantines a file or blocks an IP | The notifier wasn't installed, or an older copy stopped after a busy-file error | Run `malware-defense\install-notifier.ps1` (no admin). It now ignores busy-file errors and a watchdog restarts it every 15 minutes. Test: run `malware-defense\make-test-file.ps1`; the file vanishes from Downloads and a pop-up appears. |
| Admin prompts | Agent install, Sysmon, firewall blocks and the admin-account test change Windows | Expected; click Yes. Nothing else needs admin. |
| WSL keeps using memory after moving to the cloud | `.wslconfig` from setup A keeps WSL running | Remove `vmIdleTimeout=-1` / `instanceIdleTimeout=-1` from `%UserProfile%\.wslconfig` once the local lab is retired. |
