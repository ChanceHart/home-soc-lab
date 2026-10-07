# Install the Wazuh agent on Windows and point it at the lab manager. Run as Administrator.
# Then run enable-sysmon.ps1. Set $Manager to your server's IP if it isn't on this PC (WSL forwards localhost).
param([string]$Manager = '127.0.0.1', [string]$Version = '4.14.8-1', [string]$AgentName = 'lab-windows')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$msi = Join-Path $here "wazuh-agent-$Version.msi"
if (-not (Test-Path $msi)) {
  Invoke-WebRequest -UseBasicParsing -OutFile $msi "https://packages.wazuh.com/4.x/windows/wazuh-agent-$Version.msi"
}
if ((Get-AuthenticodeSignature $msi).Status -ne 'Valid') { throw "Installer signature is not valid: $msi" }

Start-Process msiexec.exe -Wait -ArgumentList "/i `"$msi`" /q WAZUH_MANAGER=$Manager WAZUH_AGENT_NAME=$AgentName WAZUH_AGENT_GROUP=default"

# Collect Sysmon, PowerShell and Task Scheduler logs in addition to the default Application/Security/System
$conf = 'C:\Program Files (x86)\ossec-agent\ossec.conf'
$x = Get-Content $conf -Raw
if ($x -notmatch 'Sysmon/Operational') {
  $add = @"
  <!-- Home SOC Lab: extra Windows event channels -->
  <localfile>
    <location>Microsoft-Windows-Sysmon/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
  <localfile>
    <location>Microsoft-Windows-PowerShell/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
  <localfile>
    <location>Microsoft-Windows-TaskScheduler/Operational</location>
    <log_format>eventchannel</log_format>
  </localfile>
</ossec_config>
"@
  $i = $x.LastIndexOf('</ossec_config>')
  Set-Content -Path $conf -Value ($x.Substring(0, $i) + $add) -Encoding ascii
}
Restart-Service WazuhSvc
Get-Service WazuhSvc | Format-Table Name, Status
