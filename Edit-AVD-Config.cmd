@echo off
set "SCRIPT=%~dp0scripts\edit-config.ps1"
echo CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SCRIPT%""", 0, False > "%TEMP%\~launch-avd.vbs"
wscript "%TEMP%\~launch-avd.vbs"
del "%TEMP%\~launch-avd.vbs" 2>nul
