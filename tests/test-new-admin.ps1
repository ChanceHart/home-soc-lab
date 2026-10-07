# Safe test for rule 100110 (T1098, T1136.001). RUN AS ADMINISTRATOR.
# Creates a temporary disabled local user, adds it to Administrators, then deletes it.
$name = "homelab-test"
$pw = ConvertTo-SecureString ([guid]::NewGuid().ToString() + "aA1!") -AsPlainText -Force
New-LocalUser -Name $name -Password $pw -Description "Home lab detection test (temporary)" | Out-Null
Disable-LocalUser -Name $name
Add-LocalGroupMember -Group "Administrators" -Member $name
Start-Sleep 2
Remove-LocalUser -Name $name
"New admin test done: expect 'Lab: account added to the local Administrators group' alert. The test user was deleted."
