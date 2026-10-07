<p align="center">
  <img src="assets/banner.png" alt="Home SOC lab: a security operations center built at home" width="100%">
</p>

<p align="center">
  <img alt="Wazuh 4.14" src="https://img.shields.io/badge/wazuh-4.14-b6abff?style=flat-square&labelColor=0e0f11">
  <img alt="Windows 11 + WSL2" src="https://img.shields.io/badge/endpoint-windows%2011%20%2B%20wsl2-00cbaa?style=flat-square&labelColor=0e0f11">
  <img alt="MITRE ATT&CK mapped" src="https://img.shields.io/badge/MITRE%20ATT%26CK-9%20techniques-eef35f?style=flat-square&labelColor=0e0f11">
  <img alt="YARA + VirusTotal" src="https://img.shields.io/badge/malware-YARA%20%2B%20VirusTotal-eef35f?style=flat-square&labelColor=0e0f11">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-cfcfd3?style=flat-square&labelColor=0e0f11"></a>
</p>

# Home SOC Lab

**A small security operations center I built on my own laptop to do what a SOC analyst does:** collect endpoint telemetry, write detections, prove them with safe tests, tune out false positives, and respond automatically when something bad shows up.

Everything here is real and was tested on my machine: every alert in the banner above fired from my own test scripts. The whole stack runs in Docker, so it can move to a cloud server unchanged.

<p align="center">
  <img src="assets/architecture.png" alt="Architecture: Windows 11 endpoint with Sysmon and the Wazuh agent sends events to a Wazuh manager in Docker on WSL2; YARA and VirusTotal verdicts trigger an active response that quarantines the file" width="100%">
</p>

## What it detects

| Rule | Detection | MITRE ATT&CK | Proven by |
|---|---|---|---|
| 100100 | 5+ failed Windows logons in 2 minutes | T1110 Brute Force | `tests/test-failed-logons.ps1` ✅ |
| 100110 | Account added to the local Administrators group | T1098, T1136.001 | `tests/test-new-admin.ps1` ✅ |
| 100120 | PowerShell download-and-run or encoded command | T1059.001, T1027 | `tests/test-encoded-powershell.ps1` ✅ |
| 100130 | Scheduled task created with `schtasks /create` | T1053.005 | `tests/test-scheduled-task.ps1` ✅ |
| 100131 | New Windows service installed (Event 7045) | T1543.003 | fired on real installs ✅ |
| 100140 | Discovery commands (`whoami`, `net user`, `systeminfo`) | T1033, T1087.001, T1082 | `tests/test-recon.ps1` ✅ |
| 100141 | Burst of 3+ discovery commands in a minute | T1033, T1087.001, T1082 | `tests/test-recon.ps1` ✅ |
| 100150 | Malicious file quarantined by the lab scanner | T1204.002 | `malware-defense/test-quarantine-loop.ps1` ✅ |

Every test is harmless: it prints text, creates and deletes a dummy task or account, fails a logon with a made-up user, or drops a lab-only marker file (like EICAR, but only this lab's rule matches it).

## Malware defense: my own small antivirus

Microsoft Defender stays on. This is a second, transparent layer that I can read, test and explain line by line.

1. **Watch.** Wazuh file integrity monitoring watches Downloads and Desktop (every file) and Documents and Temp (risky types only: `.exe .dll .ps1 .js .msi .lnk .iso .docm` and more) in real time.
2. **Decide.** Each new or changed file is scanned offline with ~3,000 [YARA Forge](https://github.com/YARAHQ/yara-forge) rules and, once a free API key is saved (step 8 below), its hash is checked against ~70 antivirus engines through Wazuh's VirusTotal integration.
3. **Act.** A hit moves the file into a locked quarantine folder (SYSTEM and Administrators only), records its original path, SHA-256 and the reason, and raises a level-12 alert. `restore-quarantine.ps1` lists and restores false positives.

```text
$ make-test-file.ps1
Created c:\users\<you>\downloads\homelab-yara-test.txt
homelab-av: QUARANTINED id=076eebb52a50 reason="YARA: HomeLab_Test_Marker"   # about 4 seconds later
Lab: malicious file quarantined by the lab scanner   (level 12, T1204.002)
$ restore-quarantine.ps1 -Id 076eebb52a50
Restored c:\users\<you>\downloads\homelab-yara-test.txt
```

## What I learned

- **Real findings on day one.** The new-service rule flagged two real installs on my PC (an app update and an antivirus task). Both were legitimate, which is the everyday SOC job: check, confirm, document.
- **Day-one triage: 300+ alerts, zero attacks.** I went through every alert of level 7 or higher. 223 came from one file: PowerShell writes a `__PSScriptPolicyTest_*` script to Temp on every start (an app-control check), and Wazuh's malware-folder rules scored it as high as level 15. Others were Opera's signed updater, Windows services whose parent Sysmon didn't record, and Wazuh's own CIS scan running `net accounts`. Each got a narrow tuning rule (`100142`, `100160`-`100164`) that matches only the verified benign pattern, so the original rule still fires for anything else. Encoded PowerShell stays alerting on purpose: my AI agent uses it, and so do attackers.
- **Tuning false positives.** My first PowerShell rule also matched `-ExecutionPolicy Bypass`, which normal tools use constantly: 10 alerts in a few minutes, none malicious. My first recon rule counted every `net start`. I narrowed both.
- **Know the built-in rules.** Wazuh's own rule 92057 catches encoded PowerShell first, so my rule became a backstop for download cradles instead of a duplicate.
- **Test the test.** My first brute-force test used a loopback `net use` login. It failed every time, but Windows never logged it as Event 4625, so the rule looked broken. A local logon attempt produced the events.
- **The scanner caught itself.** It quarantined its own YARA rules file (it contains every signature, so of course it matches) and one of my test scripts. Rule files are now skipped, and the test marker is assembled at run time.
- **Config that survives restarts.** The Wazuh Docker image copies a template over `ossec.conf` whenever the container is recreated, which silently wiped my active response. Changes now go into the template (`config/wazuh_cluster/wazuh_manager.conf`).
- **Default credentials are a finding.** Both the dashboard admin and the API user ship with publicly known passwords. `server/change-admin-password.sh` and `server/change-api-password.sh` replace them and confirm the old ones are rejected (HTTP 401).
- **Windows 11 25H2 ships Sysmon built in.** The standalone installer fails there (`wevtutil.exe returned failure`); the fix is the optional feature plus a restart.
- **WSL2 stops when idle**, which silently killed the SIEM. `vmIdleTimeout=-1` keeps it up.

## Run it yourself

| Step | Where | Command |
|---|---|---|
| 1. WSL2 + Ubuntu | PowerShell (admin) | `wsl --install -d Ubuntu-24.04`, restart, copy `wslconfig.example` to `%UserProfile%\.wslconfig`, `wsl --shutdown` |
| 2. Wazuh server | Ubuntu (root) | `bash server/setup-wazuh.sh` |
| 3. Kill default passwords | Ubuntu (root) | `bash server/change-admin-password.sh && bash server/change-api-password.sh` |
| 4. Detections | Ubuntu (root, repo root) | `bash server/load-rules.sh` |
| 5. Windows agent + Sysmon | PowerShell (admin) | `windows\install-agent.ps1`, then `windows\enable-sysmon.ps1`, restart Windows |
| 6. Failed-logon auditing | PowerShell (admin) | `auditpol /set /subcategory:"Logon" /failure:enable` |
| 7. Malware defense | PowerShell (admin) | `malware-defense\install-malware-defense.ps1`, then `bash server/enable-malware-defense.sh` |
| 8. VirusTotal (optional) | PowerShell | `windows\save-virustotal-key.ps1`, then rerun `server/enable-malware-defense.sh` |
| 9. Prove it | PowerShell | scripts in `tests\` and `malware-defense\test-quarantine-loop.ps1`; watch https://localhost |

```text
rules/             custom Wazuh rules (local_rules.xml)
server/            Docker + Wazuh setup, password hardening, rule loading, malware-defense config
windows/           agent install, built-in Sysmon, VirusTotal key helper
malware-defense/   homelab-av scanner, installer, quarantine restore, end-to-end test
tests/             safe attack simulations, one per detection
assets/            banner and diagram (HTML sources in assets/source)
```

## Next

- Move the server to a small cloud VM and enroll a Linux endpoint (SSH brute force, auditd)
- Active response that blocks an IP after a brute-force alert
- Map coverage in the MITRE ATT&CK Navigator

---

Built by **[Chance Hart](https://chancehart.github.io)** while studying for CompTIA Security+. Also see **[claude-session-saver](https://github.com/ChanceHart/claude-session-saver)**.
