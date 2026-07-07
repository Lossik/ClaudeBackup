' claude-backup-hidden.vbs
' Spousti claude-backup.ps1 bez blikajiciho okna konzole (Plánovac -> wscript -> powershell skryte).
' Ceka na dokonceni a propaguje navratovy kod, aby LastTaskResult v Planovaci dal ukazoval chyby.
Dim sh, rc
Set sh = CreateObject("WScript.Shell")
rc = sh.Run("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ""C:\Users\petrl\.local\bin\claude-backup.ps1""", 0, True)
WScript.Quit rc
