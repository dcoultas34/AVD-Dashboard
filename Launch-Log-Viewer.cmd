@echo off
set "SCRIPT=%~dp0tools\log-viewer.ps1"
echo CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SCRIPT%""", 0, False > "%TEMP%\~launch-logviewer.vbs"
wscript "%TEMP%\~launch-logviewer.vbs"
del "%TEMP%\~launch-logviewer.vbs" 2>nul
