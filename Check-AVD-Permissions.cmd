@echo off
echo.
echo  AVD Permissions Checker - Launch Options
echo  ==========================================
echo.
echo  [1] Device Authentication  (PowerShell 5)
echo  [2] Existing Context       (PowerShell 5)
echo  [3] PowerShell 7           (Default auth)
echo  [4] Service Principal      (Stored credentials)
echo.
choice /C 1234 /N /M "  Select option [1-4]: "
echo.
if errorlevel 4 goto sp
if errorlevel 3 goto ps7
if errorlevel 2 goto existing
if errorlevel 1 goto device
goto end

:device
start "" powershell.exe -WindowStyle Normal -ExecutionPolicy Bypass -File "%~dp0scripts\Check-Permissions.ps1" -UseDeviceAuthentication
goto end

:existing
set "SCRIPT=%~dp0scripts\Check-Permissions.ps1"
echo CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SCRIPT%"" -UseExistingContext", 0, False > "%TEMP%\~launch-avd.vbs"
wscript "%TEMP%\~launch-avd.vbs"
del "%TEMP%\~launch-avd.vbs" 2>nul
goto end

:ps7
start "" pwsh.exe -WindowStyle Normal -ExecutionPolicy Bypass -File "%~dp0scripts\Check-Permissions.ps1"
goto end

:sp
set "SCRIPT=%~dp0scripts\Check-Permissions.ps1"
echo CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SCRIPT%"" -UseServicePrincipal", 0, False > "%TEMP%\~launch-avd.vbs"
wscript "%TEMP%\~launch-avd.vbs"
del "%TEMP%\~launch-avd.vbs" 2>nul
goto end

:end
