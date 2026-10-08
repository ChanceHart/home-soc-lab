<#
.SYNOPSIS
  Open the Home SOC Lab dashboard any time: starts the local lab if needed, waits until it answers, opens your browser.
.EXAMPLE
  .\open-homelab.ps1                                    # local lab in WSL (default)
  .\open-homelab.ps1 -CopyPassword                      # also put the dashboard admin password on the clipboard for 45 s
  .\open-homelab.ps1 -Remote -Url https://home-lab-cloud.your-tailnet.ts.net   # cloud/remote lab over Tailscale
  .\open-homelab.ps1 -Remote -Url https://... -CopyPassword -Ssh ubuntu@100.x.y.z -SshKey ~\.ssh\my_key   # fetch the password over SSH
.NOTES
  install-shortcut.ps1 creates a Desktop + Start menu shortcut with the same options.
#>
param(
  [string]$Url = 'https://localhost',
  [string]$Distro = 'Ubuntu-24.04',
  [switch]$Remote,
  [switch]$CopyPassword,
  [string]$Ssh,       # remote lab: user@host to read the password from (over Tailscale)
  [string]$SshKey,    # remote lab: private key for that SSH login
  [int]$TimeoutSec = 300
)
$ErrorActionPreference = 'Stop'
$Host.UI.RawUI.WindowTitle = 'Home SOC Lab'

function Test-Dashboard {
  # "Is it up?" check only: no credentials are sent. The lab uses a self-signed certificate, so it is not validated here.
  try {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.ServerCertificateValidationCallback = { $true }
    $req.Timeout = 5000
    $req.GetResponse().Close()
    return $true
  } catch [Net.WebException] {
    return [bool]$_.Exception.Response   # any HTTP answer (401, 302...) means the dashboard is running
  } catch { return $false }
}

if (-not $Remote) {
  Write-Host "Starting the lab ($Distro)..."
  wsl.exe -d $Distro -u root -- systemctl start docker | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not start WSL distro '$Distro'. Check the name with: wsl -l -v" }
  # The Wazuh containers use 'restart: always', so Docker brings them back on its own.
}

$agent = Get-Service WazuhSvc -ErrorAction SilentlyContinue
if ($agent -and $agent.Status -ne 'Running') {
  Write-Warning 'The Wazuh agent on this PC is stopped. To start it, run as administrator: Start-Service WazuhSvc'
}

Write-Host -NoNewline "Waiting for $Url "
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Dashboard)) {
  if ((Get-Date) -gt $deadline) {
    Write-Host ''
    if ($Remote) { throw "No answer from $Url. Is Tailscale connected on this device, and is the server on?" }
    throw "The dashboard did not come up within $TimeoutSec s. Check: wsl -d $Distro -u root -- docker ps"
  }
  Write-Host -NoNewline '.'
  Start-Sleep -Seconds 5
}
Write-Host ' up.'
Start-Process $Url
Write-Host 'Opened in your browser. A certificate warning is normal (the lab uses its own certificate): choose Advanced > Continue.'

if ($CopyPassword) {
  $read = "sed -n 's/^password: //p' /root/lab-credentials.txt"
  if ($Remote -and -not $Ssh) {
    Write-Host 'The password for a remote lab lives on that server (/root/lab-credentials.txt). Add -Ssh user@host to fetch it.'
  } else {
    if ($Remote) {
      $sshArgs = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
      if ($SshKey) { $sshArgs += @('-i', $SshKey) }
      $pw = (& ssh.exe @sshArgs $Ssh "sudo $read" | Select-Object -First 1)
    } else {
      $pw = (wsl.exe -d $Distro -u root -- sed -n 's/^password: //p' /root/lab-credentials.txt | Select-Object -First 1)
    }
    if ($pw) {
      Set-Clipboard -Value $pw.Trim()
      Write-Host 'Admin password copied (user: admin). Clipboard is cleared in 45 seconds...'
      Start-Sleep -Seconds 45
      Set-Clipboard -Value ' '
    } else { Write-Warning 'No password found in /root/lab-credentials.txt' }
  }
}
Start-Sleep -Seconds 3
