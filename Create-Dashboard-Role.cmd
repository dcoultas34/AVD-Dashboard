@echo off
echo.
echo  AVD Dashboard Role Creator
echo  ===========================
echo.
echo  Creates the "AVD Dashboard Operator" custom RBAC role in the current subscription.
echo.
echo  [1] Current context  (use existing Az PowerShell sign-in)
echo  [2] Interactive      (browser sign-in)
echo  [3] Update existing  (update role if it already exists)
echo.
choice /C 123 /N /M "  Select option [1-3]: "
echo.
if errorlevel 3 goto update
if errorlevel 2 goto interactive
if errorlevel 1 goto existing
goto end

:existing
start "" powershell.exe -WindowStyle Normal -ExecutionPolicy Bypass -NoExit -Command "& '%~dp0scripts\Create-DashboardRole.ps1'"
goto end

:interactive
start "" powershell.exe -WindowStyle Normal -ExecutionPolicy Bypass -NoExit -Command "Connect-AzAccount; & '%~dp0scripts\Create-DashboardRole.ps1'"
goto end

:update
start "" powershell.exe -WindowStyle Normal -ExecutionPolicy Bypass -NoExit -Command "& '%~dp0scripts\Create-DashboardRole.ps1' -Update"
goto end

:end
