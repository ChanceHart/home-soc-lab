# Safe test for rule 100130 (T1053.005): creates a harmless scheduled task, then deletes it right away.
schtasks.exe /create /tn "HomeLabDetectionTest" /tr "cmd.exe /c echo test" /sc once /st 23:59 /f | Out-Null
schtasks.exe /delete /tn "HomeLabDetectionTest" /f | Out-Null
"Scheduled task test done: expect 'Lab: scheduled task created' alert. The task was removed."
