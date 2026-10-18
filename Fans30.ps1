# Uso: pwsh -File Fans30.ps1 [--time <segundos>] [--endless]   (por defecto 60 s; --endless ignora --time)
$totalSegundos = 60
$endless = $false
$segundosCierre = 10            # espera antes de cerrar al terminar, para poder leer el informe (0 = cierra al instante)
$segundosCierreCorto = 3        # cuando no hay informe que leer: cancelado con Esc o sin ventiladores que controlar
$carpetaLogs = 'logs'           # informes guardados junto al script, uno por dia (coolingLog_AAMMDD.txt)
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

# ¿Hay teclado disponible? False si la entrada de la consola está redirigida (no hay consola).
$conTeclado = $true
try { [void][Console]::KeyAvailable } catch { $conTeclado = $false }

# Espera hasta $milisegundos mirando si se pulsa Esc; devuelve $true solo en ese caso.
function Espera-Escape([int]$milisegundos) {
    if (-not $conTeclado) {
        Start-Sleep -Milliseconds $milisegundos
        return $false
    }
    $fin = [DateTime]::UtcNow.AddMilliseconds($milisegundos)
    $escape = $false
    while (-not $escape -and [DateTime]::UtcNow -lt $fin) {
        try {
            if ([Console]::KeyAvailable) { $escape = ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Escape) }
        } catch {
            Start-Sleep -Milliseconds $milisegundos
            return $false
        }
        # Otras teclas se descartan en silencio, pero la cuenta atrás sigue a ritmo real.
        if (-not $escape) { Start-Sleep -Milliseconds 50 }
    }
    return $escape
}

# Espera $segundos antes de cerrar, o hasta que se pulse una tecla (cierre inmediato).
# Devuelve $true si el usuario pulsó una tecla. Si la entrada de la consola está
# redirigida (sin teclado disponible), espera igualmente el tiempo completo.
function Espera-Cierre([int]$segundos) {
    $teclado = $conTeclado

    if ($segundos -le 0) {
        if ($teclado -and [Console]::KeyAvailable) {
            [void][Console]::ReadKey($true)
            return $true
        }
        return $false
    }

    for ($i = $segundos; $i -gt 0; $i--) {
        Write-Host ("`rCerrando en {0} segundos (pulsa una tecla para cerrar ahora)... " -f $i) -NoNewline -ForegroundColor Cyan
        # Sondea en fracciones de 100 ms para notar la tecla casi al instante.
        for ($t = 0; $t -lt 10; $t++) {
            if ($teclado) {
                try {
                    if ([Console]::KeyAvailable) {
                        [void][Console]::ReadKey($true)
                        return $true
                    }
                } catch {
                    $teclado = $false
                    break
                }
            }
            Start-Sleep -Milliseconds 100
        }
    }
    Write-Host ""
    return $false
}

# Solo una instancia a la vez: dos enfriamientos simultaneos pelearian por los mismos
# controles y el informe final mentiria. El mutex se libera solo al terminar el proceso.
$mutex = New-Object System.Threading.Mutex($false, 'Local\Fan100.Enfriamiento')
$yaHayInstancia = $false
try {
    $yaHayInstancia = $mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $yaHayInstancia = $false   # la instancia anterior murio sin soltar: el mutex es nuestro
}
if ($yaHayInstancia) {
    Write-Host "Ya hay un enfriamiento en marcha. Espera a que termine antes de iniciar otro." -ForegroundColor Red
    [void](Espera-Cierre $segundosCierreCorto)
    exit 1
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

    // Devuelve un texto por cada control que no ha vuelto al firmware. El handler de Ctrl
    // la llama con $verificar = false: al cerrar la ventana no hay tiempo de comprobar.
    public static string[] Restore(bool verificar) {
        List<string> fallos = new List<string>();
        lock (Controls) {
            foreach (IControl c in Controls) {
                try {
                    c.SetDefault();
                } catch (Exception e) {
                    fallos.Add(Describe(c) + " -> SetDefault ha fallado: " + e.Message);
                }
            }
            if (verificar) {
                foreach (IControl c in Controls) {
                    // Solo se avisa si sigue en modo Software: es el que ha puesto el script.
                    try {
                        if (c.ControlMode == ControlMode.Software)
                            fallos.Add(Describe(c) + " -> sigue bajo control software: reinicia o ajüstalo a mano");
                    } catch (Exception e) {
                        fallos.Add(Describe(c) + " -> no se ha podido verificar el modo: " + e.Message);
                    }
                }
            }
        }
        return fallos.ToArray();
    }

    static string Describe(IControl c) {
        try { return c.Sensor.Hardware.Name + " / " + c.Sensor.Name; } catch { }
        try { return c.Identifier.ToString(); } catch { }
        return "control desconocido";
    }

    // 2 = cerrar ventana, 5 = cerrar sesión, 6 = apagado
    static bool OnCtrl(uint ctrlType) {
        if (ctrlType == 2 || ctrlType == 5 || ctrlType == 6) Restore(false);
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

# Devuelve las líneas del informe final como objetos {Texto, Color}: el texto plano va al
# log y el color solo se usa al imprimirlo por consola.
function Get-LineasInforme($tempIni, $fanIni, $duracionSeg, $detalle) {
    $lineas = @(
        [pscustomobject]@{ Texto = ('Duración del enfriamiento: {0:F1} s ({1})' -f $duracionSeg, $detalle); Color = 'White' }
        [pscustomobject]@{ Texto = ''; Color = 'Gray' }
        [pscustomobject]@{ Texto = 'Ventiladores (RPM inicial -> final):'; Color = 'Yellow' }
    )

    $fanFin = Read-Sensors 'Fan'
    foreach ($id in $fanFin.Keys) {
        $ini = if ($fanIni.Contains($id)) { '{0:N0}' -f $fanIni[$id].Value } else { '?' }
        $lineas += [pscustomobject]@{
            Texto = ('  {0}: {1} -> {2:N0} RPM' -f $fanFin[$id].Name, $ini, $fanFin[$id].Value)
            Color = 'Gray'
        }
    }

    $lineas += [pscustomobject]@{ Texto = ''; Color = 'Gray' }
    $lineas += [pscustomobject]@{ Texto = 'Temperaturas (°C inicial -> final; azul = sin cambio):'; Color = 'Yellow' }

    $tempFin = Read-Sensors 'Temperature'
    foreach ($id in $tempFin.Keys) {
        $b = [math]::Round($tempFin[$id].Value, 1)
        if (-not $tempIni.Contains($id)) {
            $lineas += [pscustomobject]@{ Texto = ('  {0}: ? -> {1:N1}' -f $tempFin[$id].Name, $b); Color = 'Cyan' }
            continue
        }
        $a = [math]::Round($tempIni[$id].Value, 1)
        if ($a -eq $b) {
            $lineas += [pscustomobject]@{ Texto = ('  {0}: {1:N1} -> {2:N1}' -f $tempFin[$id].Name, $a, $b); Color = 'Cyan' }
        } else {
            $color = if ($b -lt $a) { 'Green' } else { 'Red' }
            $lineas += [pscustomobject]@{
                Texto = ('  {0}: {1:N1} -> {2:N1} ({3:+0.0;-0.0})' -f $tempFin[$id].Name, $a, $b, ($b - $a))
                Color = $color
            }
        }
    }
    return , $lineas
}

function Write-Informe($lineas) {
    foreach ($linea in $lineas) { Write-Host $linea.Texto -ForegroundColor $linea.Color }
}

# Añade el informe a logs\coolingLog_AAMMDD.txt, un bloque por ejecución.
function Add-InformeLog($lineas, $detalle) {
    try {
        $dir = Join-Path $PSScriptRoot $carpetaLogs
        if (-not (Test-Path $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $archivo = Join-Path $dir ('coolingLog_{0}.txt' -f (Get-Date).ToString('yyMMdd'))
        $cabecera = '=== {0} | {1} ===' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $detalle
        $texto = (@($cabecera) + @($lineas | ForEach-Object { $_.Texto }) + '') -join "`r`n"
        Add-Content -Path $archivo -Encoding utf8BOM -Value ($texto + "`r`n")
        return [IO.Path]::GetFileName($archivo)
    } catch {
        return $null
    }
}

$motivoCorte = ''   # '' = ciclo completo; 'Esc' o 'sin ventiladores' = corte antes de tiempo (no hay informe)
try {
    $tempIni = Read-Sensors 'Temperature'
    $fanIni  = Read-Sensors 'Fan'

    Write-Host "Activando ventiladores al 100%..." -ForegroundColor Yellow

    $controles = 0
    [FanGuard]::Install()
    foreach ($hw in $all) {
        foreach ($sensor in $hw.Sensors) {
            if ($sensor.SensorType -eq 'Control') {
                if ($sensor.Control) {
                    [FanGuard]::Controls.Add($sensor.Control)
                    $sensor.Control.SetSoftware(100)
                    $controles++
                    Write-Host ("  [OK] {0} / {1}" -f $hw.Name, $sensor.Name) -ForegroundColor Green
                } else {
                    Write-Host ("  [--] {0} / {1} (sin control)" -f $hw.Name, $sensor.Name) -ForegroundColor DarkYellow
                }
            }
        }
    }

    if ($controles -eq 0) {
        Write-Host "No se ha podido controlar ningún ventilador: no hay nada que enfriar." -ForegroundColor Red
        Write-Host "El hardware no expone controles compatibles con LibreHardwareMonitor." -ForegroundColor Red
        $motivoCorte = 'sin ventiladores'
    } else {
        $reloj = [System.Diagnostics.Stopwatch]::StartNew()
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
                Write-Host ("`rTiempo restante a máxima velocidad: {0} segundos (pulsa Esc para cancelar)... " -f $i) -NoNewline -ForegroundColor Cyan
                if (Espera-Escape 1000) {
                    Write-Host ""
                    Write-Host "Enfriamiento cancelado con Esc." -ForegroundColor Yellow
                    $motivoCorte = 'Esc'
                    break
                }
            }
        }
        $reloj.Stop()
    }
    Write-Host ""

    if (-not $motivoCorte) {
        $detalle = if ($endless) { 'modo endless' } else { "--time $totalSegundos" }
        $lineas = Get-LineasInforme $tempIni $fanIni ([math]::Round($reloj.Elapsed.TotalSeconds, 1)) $detalle

        Write-Host ""
        Write-Informe $lineas

        $guardado = Add-InformeLog $lineas $detalle
        if ($guardado) {
            Write-Host ""
            Write-Host ("Informe guardado en {0}\{1}" -f $carpetaLogs, $guardado) -ForegroundColor DarkGray
        } else {
            Write-Host "No se ha podido guardar el informe en la carpeta $carpetaLogs." -ForegroundColor DarkYellow
        }
    }

} finally {
    Write-Host ""
    Write-Host "Restableciendo ventiladores al control automático por firmware..." -ForegroundColor Green

    $fallos = @([FanGuard]::Restore($true))
    $computer.Close()

    if ($fallos.Count -gt 0) {
        Write-Host ""
        Write-Host "ATENCIÓN: no todos los ventiladores han vuelto al control del firmware:" -ForegroundColor Red
        foreach ($fallo in $fallos) { Write-Host "  $fallo" -ForegroundColor Red }
        Write-Host "Reinicia el equipo o ajusta esos ventiladores a mano." -ForegroundColor Red
    }

    Write-Host ""
    $esperaCierre = if ($motivoCorte) { $segundosCierreCorto } else { $segundosCierre }
    if (Espera-Cierre $esperaCierre) {
        Write-Host "Cerrando ahora (tecla pulsada)." -ForegroundColor Cyan
    }
}
