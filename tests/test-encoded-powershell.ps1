# Safe test for rule 100120 (T1059.001, T1027): runs an encoded PowerShell command that only prints text.
$cmd = "Write-Output 'home lab detection test'"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
powershell.exe -NoProfile -EncodedCommand $enc
"Encoded PowerShell test done: expect 'Lab: suspicious PowerShell' alert."
