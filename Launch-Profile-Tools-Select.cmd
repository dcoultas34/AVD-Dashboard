@echo off
echo.
echo  Profile Tools - Launch Options
echo  ==============================
echo.
echo  [1] Interactive Browser    (default)
echo  [2] Device Authentication  (device code flow)
echo  [3] Existing Context       (reuse current Az session)
echo  [4] Service Principal      (stored credentials)
echo.
choice /C 1234 /N /M "  Select option [1-4]: "
echo.
if errorlevel 4 goto sp
if errorlevel 3 goto existing
if errorlevel 2 goto device
if errorlevel 1 goto interactive
goto end

:interactive
set "SCRIPT=%~dp0profile-tools.ps1"
echo CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SCRIPT%""", 0, False > "%TEMP%\~launch-avd.vbs"
wscript "%TEMP%\~launch-avd.vbs"
del "%TEMP%\~launch-avd.vbs" 2>nul
goto end

:device
start "" powershell.exe -WindowStyle Normal -ExecutionPolicy Bypass -File "%~dp0profile-tools.ps1" -UseDeviceAuthentication
goto end

:existing
set "SCRIPT=%~dp0profile-tools.ps1"
echo CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SCRIPT%"" -UseExistingContext", 0, False > "%TEMP%\~launch-avd.vbs"
wscript "%TEMP%\~launch-avd.vbs"
del "%TEMP%\~launch-avd.vbs" 2>nul
goto end

:sp
set "SCRIPT=%~dp0profile-tools.ps1"
echo CreateObject("WScript.Shell").Run "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File ""%SCRIPT%"" -UseServicePrincipal", 0, False > "%TEMP%\~launch-avd.vbs"
wscript "%TEMP%\~launch-avd.vbs"
del "%TEMP%\~launch-avd.vbs" 2>nul
goto end

:end
