# Uso: pwsh -File Fans30.ps1 [--time <segundos>] [--endless]   (por defecto 60 s; --endless ignora --time)
$totalSegundos = 60
$endless = $false
$segundosCierre = 10   # espera antes de cerrar la ventana al terminar (0 = cierra al instante)
for ($k = 0; $k -lt $args.Count; $k++) {
    if ($args[$k] -match '^--?time$') {
        $k++
        if ($k -ge $args.Count -or -not ($args[$k] -as [int]) -or [int]$args[$k] -lt 1) {
            Write-Host "--time requiere un entero positivo (segundos)." -ForegroundColor Red
            exit 1
        }
        $totalSegundos = [int]$args[$k]
    } elseif ($args[$k] -match '^--?endless$') {
        $endless = $true
    } else {
        Write-Host "Argumento desconocido: $($args[$k])" -ForegroundColor Red
        exit 1
    }
}

$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "Solicitando permisos de Administrador..." -ForegroundColor Yellow
    Start-Process pwsh -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $($args -join ' ')" -Verb RunAs
    exit
}

$libPath = Join-Path $PSScriptRoot "LibreHardwareMonitorLib.dll"

# Espera $segundos antes de cerrar, o hasta que se pulse una tecla (cierre inmediato).
# Devuelve $true si el usuario pulsó una tecla. Si la entrada de la consola está
# redirigida (sin teclado disponible), espera igualmente el tiempo completo.
function Espera-Cierre([int]$segundos) {
    $conTeclado = $true
    try { [void][Console]::KeyAvailable } catch { $conTeclado = $false }

    if ($segundos -le 0) {
        if ($conTeclado -and [Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
            return $true
        }
        return $false
    }

    for ($i = $segundos; $i -gt 0; $i--) {
        Write-Host ("`rCerrando en {0} segundos (pulsa una tecla para cerrar ahora)... " -f $i) -NoNewline -ForegroundColor Cyan
        # Sondea en fracciones de 100 ms para notar la tecla casi al instante.
        for ($t = 0; $t -lt 10; $t++) {
            if ($conTeclado) {
                try {
                    if ([Console]::KeyAvailable) {
                        [void][Console]::ReadKey($true)
                        return $true
                    }
                } catch {
                    $conTeclado = $false
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ""
    return $false
}

if (-not (Test-Path $libPath)) {
    Write-Host "No se encuentra LibreHardwareMonitorLib.dll en $PSScriptRoot" -ForegroundColor Red
    [void](Espera-Cierre $segundosCierre)
    exit 1
}
Add-Type -Path $libPath

# Restaura los controles si se cierra la ventana, cierra sesión o apaga (el handler corre en otro hilo, por eso va en C#).
Add-Type -ReferencedAssemblies $libPath,"System.Collections", "System.Runtime", "System.Runtime.InteropServices", "System.Threading" -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using LibreHardwareMonitor.Hardware;

public static class FanGuard {
    public static readonly List<IControl> Controls = new List<IControl>();
    delegate bool Handler(uint ctrlType);
    static Handler handler;

    [DllImport("kernel32.dll")]
    static extern bool SetConsoleCtrlHandler(Handler h, bool add);

    public static void Install() {
        handler = OnCtrl;
        SetConsoleCtrlHandler(handler, true);
    }

    public static void Restore() {
        lock (Controls) {
            foreach (IControl c in Controls) {
                try { c.SetDefault(); } catch { }
            }
        }
    }

    // 2 = cerrar ventana, 5 = cerrar sesión, 6 = apagado
    static bool OnCtrl(uint ctrlType) {
        if (ctrlType == 2 || ctrlType == 5 || ctrlType == 6) Restore();
        return false;
    }
}
'@

$computer = New-Object LibreHardwareMonitor.Hardware.Computer
$computer.IsCpuEnabled = $true
$computer.IsMotherboardEnabled = $true
$computer.IsGpuEnabled = $true
$computer.Open()

function Get-AllHardware($hw) {
    $hw
    foreach ($sub in $hw.SubHardware) { Get-AllHardware $sub }
}
$all = foreach ($h in $computer.Hardware) { Get-AllHardware $h }

function Read-Sensors($type) {
    $result = [ordered]@{}
    foreach ($hw in $all) {
        $hw.Update()
        foreach ($sensor in $hw.Sensors) {
            if ($sensor.SensorType -eq $type -and $null -ne $sensor.Value) {
                $result[[string]$sensor.Identifier] = [pscustomobject]@{
                    Name  = "$($hw.Name) / $($sensor.Name)"
                    Value = [double]$sensor.Value
                }
            }
        }
    }
    $result
}

try {
    $tempIni = Read-Sensors 'Temperature'
    $fanIni  = Read-Sensors 'Fan'

    Write-Host "Activando ventiladores al 100%..." -ForegroundColor Yellow

    [FanGuard]::Install()
    foreach ($hw in $all) {
        foreach ($sensor in $hw.Sensors) {
            if ($sensor.SensorType -eq 'Control') {
                if ($sensor.Control) {
                    [FanGuard]::Controls.Add($sensor.Control)
                    $sensor.Control.SetSoftware(100)
                    Write-Host ("  [OK] {0} / {1}" -f $hw.Name, $sensor.Name) -ForegroundColor Green
                } else {
                    Write-Host ("  [--] {0} / {1} (sin control)" -f $hw.Name, $sensor.Name) -ForegroundColor DarkYellow
                }
            }
        }
    }

    if ($endless) {
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
        $t = 0
        while (-not [Console]::KeyAvailable) {
            Write-Host ("`rTiempo a máxima velocidad: {0} segundos (presiona una tecla para terminar)... " -f $t) -NoNewline -ForegroundColor Cyan
            Start-Sleep -Seconds 1
            $t++
        }
        [void][Console]::ReadKey($true)
    } else {
        for ($i = $totalSegundos; $i -gt 0; $i--) {
            Write-Host ("`rTiempo restante a máxima velocidad: {0} segundos... " -f $i) -NoNewline -ForegroundColor Cyan
            Start-Sleep -Seconds 1
        }
    }
    Write-Host ""

    $tempFin = Read-Sensors 'Temperature'
    $fanFin  = Read-Sensors 'Fan'

    Write-Host ""
    Write-Host "Ventiladores (RPM inicial -> final):" -ForegroundColor Yellow
    foreach ($id in $fanFin.Keys) {
        $ini = if ($fanIni.Contains($id)) { '{0:N0}' -f $fanIni[$id].Value } else { '?' }
        Write-Host ("  {0}: {1} -> {2:N0} RPM" -f $fanFin[$id].Name, $ini, $fanFin[$id].Value)
    }

    Write-Host ""
    Write-Host "Temperaturas (°C inicial -> final; azul = sin cambio):" -ForegroundColor Yellow
    foreach ($id in $tempFin.Keys) {
        $b = [math]::Round($tempFin[$id].Value, 1)
        if (-not $tempIni.Contains($id)) {
            Write-Host ("  {0}: ? -> {1:N1}" -f $tempFin[$id].Name, $b) -ForegroundColor Cyan
            continue
        }
        $a = [math]::Round($tempIni[$id].Value, 1)
        if ($a -eq $b) {
            Write-Host ("  {0}: {1:N1} -> {2:N1}" -f $tempFin[$id].Name, $a, $b) -ForegroundColor Cyan
        } else {
            $color = if ($b -lt $a) { 'Green' } else { 'Red' }
            Write-Host ("  {0}: {1:N1} -> {2:N1} ({3:+0.0;-0.0})" -f $tempFin[$id].Name, $a, $b, ($b - $a)) -ForegroundColor $color
        }
    }

} finally {
    Write-Host ""
    Write-Host "Restableciendo ventiladores al control automático por firmware..." -ForegroundColor Green

    [FanGuard]::Restore()
    $computer.Close()

    Write-Host ""
    if (Espera-Cierre $segundosCierre) {
        Write-Host "Cerrando ahora (tecla pulsada)." -ForegroundColor Cyan
    }
}
