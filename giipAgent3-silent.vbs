' ============================================================================
' giipAgent3-silent.vbs
' Purpose: True windowless entry point for Task Scheduler.
'          "powershell.exe -WindowStyle Hidden" still briefly flashes a
'          console window on some Windows builds/logon types. WScript.Shell.Run
'          with window style 0 never allocates a visible console at all, so
'          this is the reliable fix. Task Scheduler action should target this
'          file via: wscript.exe "...\giipAgent3-silent.vbs"
' ============================================================================

Dim objFSO, objShell, scriptDir, targetScript, cmd

Set objFSO = CreateObject("Scripting.FileSystemObject")
Set objShell = CreateObject("WScript.Shell")

scriptDir = objFSO.GetParentFolderName(WScript.ScriptFullName)
targetScript = scriptDir & "\giipAgent3-launcher.ps1"

cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & targetScript & """"

' 0 = hidden window, True = wait for completion
objShell.Run cmd, 0, True
