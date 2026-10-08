<#
.SYNOPSIS
  Add a "Home SOC Lab" shortcut to the Desktop and Start menu (no admin needed). Double-click it to open the dashboard.
.EXAMPLE
  .\install-shortcut.ps1                                         # local lab in WSL
  .\install-shortcut.ps1 -Remote -Url https://home-lab-cloud.your-tailnet.ts.net -Name 'Home SOC Lab (cloud)'
#>
param(
  [string]$Name = 'Home SOC Lab',
  [string]$Url = 'https://localhost',
  [string]$Distro = 'Ubuntu-24.04',
  [switch]$Remote,
  [string]$Ssh,
  [string]$SshKey
)
$script = Join-Path $PSScriptRoot 'open-homelab.ps1'
if (-not (Test-Path $script)) { throw "open-homelab.ps1 not found next to this script" }

$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$script`" -Url `"$Url`" -CopyPassword"
if ($Remote) { $arguments += ' -Remote' } else { $arguments += " -Distro `"$Distro`"" }
if ($Ssh) { $arguments += " -Ssh `"$Ssh`"" }
if ($SshKey) { $arguments += " -SshKey `"$SshKey`"" }

$shell = New-Object -ComObject WScript.Shell
$folders = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))
foreach ($dir in $folders) {
  $lnk = $shell.CreateShortcut((Join-Path $dir "$Name.lnk"))
  $lnk.TargetPath = (Get-Command powershell.exe).Source
  $lnk.Arguments = $arguments
  $lnk.WorkingDirectory = $PSScriptRoot
  $lnk.IconLocation = "$env:SystemRoot\System32\imageres.dll,77"
  $lnk.Description = "Open the Home SOC Lab dashboard ($Url)"
  $lnk.Save()
  Write-Host "Shortcut created: $(Join-Path $dir "$Name.lnk")"
}
