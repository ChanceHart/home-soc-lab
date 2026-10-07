# Saves your free VirusTotal API key inside the lab's Linux side (/root/virustotal.key, readable by root only).
# The key never touches a Windows file, OneDrive or this repo. Run: powershell -ExecutionPolicy Bypass -File save-virustotal-key.ps1
$secure = Read-Host 'Paste your VirusTotal API key (it will not show)' -AsSecureString
$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
if ($key.Length -lt 32) { Write-Host 'That does not look like a VirusTotal key (expected 64 characters). Nothing saved.'; exit 1 }
$key | wsl.exe -d Ubuntu-24.04 -u root -- sh -c "umask 077; tr -d '\r\n ' > /root/virustotal.key"
$len = wsl.exe -d Ubuntu-24.04 -u root -- sh -c "wc -c < /root/virustotal.key"
Write-Host "Saved ($($len.Trim()) characters). Tell Claude: saved"
