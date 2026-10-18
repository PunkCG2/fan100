@echo off
rem Lanzador de Fans30.ps1. Uso: Fans.cmd [--time <segundos>] [--endless] [--forzar]
rem El script necesita PowerShell 7 sobre .NET 10 (7.6 o posterior), que no viene con Windows:
rem si no esta, o es una version anterior, se instala con winget y despues se lanza el script.
setlocal

set "PWSH="
for %%P in (pwsh.exe) do set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"

rem La DLL de LibreHardwareMonitor es para .NET 10: un pwsh 7.4 o 7.5, sobre .NET 8 o 9, no la carga.
rem Ojo: dentro de los bloques entre parentesis no puede haber comentarios con parentesis.
if defined PWSH (
    "%PWSH%" -NoProfile -Command "exit [int]([Environment]::Version.Major -lt 10)"
    if not errorlevel 1 goto :lanzar
    echo PowerShell 7 es demasiado antiguo: hace falta la version 7.6 o posterior.
) else (
    echo No se encuentra PowerShell 7 ^(pwsh^), necesario para este script.
)

where winget >nul 2>nul
if errorlevel 1 (
    echo winget no esta disponible: instala PowerShell 7.6 a mano desde https://aka.ms/powershell
    goto :error
)
echo Instalandolo con winget ^(solo hace falta la primera vez^)...
winget install --id Microsoft.PowerShell --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity

rem Esta consola no ve el PATH nuevo hasta reabrirse: se usa la ruta de instalacion directamente.
set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PWSH%" (
    echo No se ha podido instalar PowerShell 7. Instalalo a mano: winget install Microsoft.PowerShell
    goto :error
)
"%PWSH%" -NoProfile -Command "exit [int]([Environment]::Version.Major -lt 10)"
if errorlevel 1 (
    echo PowerShell 7 se ha instalado, pero sigue siendo anterior a la 7.6.
    goto :error
)
echo PowerShell 7 instalado.

:lanzar
"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fans30.ps1" %*
exit /b %errorlevel%

:error
timeout /t 10
exit /b 1
