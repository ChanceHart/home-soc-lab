# Safe test for rule 100100 (T1110): 6 failed logons with an account that does not exist.
# Nothing real is guessed: the username and password are made up.
# Needs failed-logon auditing: auditpol /set /subcategory:"Logon" /failure:enable
# (A loopback "net use \\127.0.0.1\IPC$" attempt does NOT produce Event 4625, so this uses a local logon instead.)
$pw = ConvertTo-SecureString "not-a-real-password" -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("homelab-nonexistent", $pw)
1..6 | ForEach-Object {
  try { Start-Process cmd.exe -Credential $cred -ArgumentList "/c exit" -WindowStyle Hidden -ErrorAction Stop } catch { }
}
"Failed logon test done: expect 'Lab: possible brute force' alert."
