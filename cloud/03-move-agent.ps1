#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Point this PC's Wazuh agent at the cloud server (over Tailscale) and enroll it there.
.EXAMPLE
  .\03-move-agent.ps1 -Manager 100.x.y.z        # the cloud server's Tailscale IP; asks for the enrollment password
.NOTES
  Backs up ossec.conf first. To go back to the local lab: rerun with -Manager 127.0.0.1.
#>
param(
  [Parameter(Mandatory)][string]$Manager,
  [string]$EnrollmentPassword
)
$ErrorActionPreference = 'Stop'
$dir  = "${env:ProgramFiles(x86)}\ossec-agent"
$conf = Join-Path $dir 'ossec.conf'

# 1. Can we reach the server's agent ports over Tailscale?
foreach ($port in 1514, 1515) {
  if (-not (Test-NetConnection $Manager -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw "Cannot reach $Manager on port $port. Is Tailscale connected and is Wazuh running on the server?"
  }
}

# 2. Enrollment password -> authd.pass (readable by Administrators and SYSTEM only)
if (-not $EnrollmentPassword) {
  $sec = Read-Host 'Enrollment password (from /root/lab-credentials.txt on the server)' -AsSecureString
  $EnrollmentPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}
$pass = Join-Path $dir 'authd.pass'
[IO.File]::WriteAllText($pass, $EnrollmentPassword.Trim())
icacls $pass /inheritance:r /grant:r 'Administrators:F' 'SYSTEM:F' | Out-Null

# 3. New manager address (backup first; keep the file's UTF-8 without BOM)
Copy-Item $conf "$conf.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
$xml = [IO.File]::ReadAllText($conf)
$new = [regex]::Replace($xml, '(<server>\s*<address>)[^<]+(</address>)', "`${1}$Manager`${2}", 1)
if ($new -eq $xml -and $xml -notmatch "<address>$([regex]::Escape($Manager))</address>") { throw 'No <server><address> found in ossec.conf' }
[IO.File]::WriteAllText($conf, $new, (New-Object Text.UTF8Encoding $false))

# 4. Forget the old server's key so the agent enrolls with the new one, then restart
Stop-Service WazuhSvc
Set-Content (Join-Path $dir 'client.keys') -Value $null
Start-Service WazuhSvc

# 5. Confirm
$log = Join-Path $dir 'ossec.log'
$deadline = (Get-Date).AddSeconds(60)
do {
  Start-Sleep 5
  # Log line looks like: Connected to the server ([100.x.y.z]:1514/tcp).
  $hit = Select-String -Path $log -Pattern "Connected to the server .*$([regex]::Escape($Manager))" | Select-Object -Last 1
} until ($hit -or (Get-Date) -gt $deadline)
if ($hit) { "Agent connected to $Manager" } else { Write-Warning "No connection yet. Check: Get-Content '$log' -Tail 30" }
