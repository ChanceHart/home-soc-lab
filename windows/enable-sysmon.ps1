# Enable Windows 11's built-in Sysmon (25H2+) with the SwiftOnSecurity community config. Run as Administrator.
# Note: on builds with native Sysmon, the standalone Sysinternals installer fails ("wevtutil.exe returned failure").
# Restart Windows after this so the Sysmon event channel finishes registering, then restart the Wazuh agent.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfg = Join-Path $here 'sysmonconfig.xml'
if (-not (Test-Path $cfg)) {
  Invoke-WebRequest -UseBasicParsing -OutFile $cfg 'https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml'
}
Dism /Online /Enable-Feature /FeatureName:Sysmon /NoRestart
& "$env:SystemRoot\System32\Sysmon.exe" -accepteula -i $cfg
Get-Service Sysmon | Format-Table Name, Status
"Restart Windows now, then run: Restart-Service WazuhSvc"
