# Safe test for rules 100140/100141 (T1033, T1087.001, T1082): runs harmless discovery commands.
whoami | Out-Null
whoami /groups | Out-Null
net user | Out-Null
systeminfo | Out-Null
"Recon test done: expect 'Lab: discovery command run' alerts and one 'burst of discovery commands' alert."
