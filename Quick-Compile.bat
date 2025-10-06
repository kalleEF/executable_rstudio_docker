@echo off
REM Quick IMPACT.exe Compilation (Silent Mode)
REM ==========================================

cd /d "%~dp0"

echo Compiling IMPACT.exe...

REM Try PowerShell 7 first, then fallback to Windows PowerShell  
pwsh.exe -ExecutionPolicy Bypass -Command "& '.\Compile-IMPACT.ps1' -Force" >nul 2>&1
if %errorlevel% neq 0 (
    powershell.exe -ExecutionPolicy Bypass -Command "& '.\Compile-IMPACT.ps1' -Force" >nul 2>&1
)

if %errorlevel% equ 0 (
    echo SUCCESS: IMPACT.exe compiled successfully!
) else (
    echo ERROR: Compilation failed
    pause
    exit /b 1
)

echo.
timeout /t 2 >nul