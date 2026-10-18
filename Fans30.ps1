# Uso: pwsh -File Fans30.ps1 [--time <segundos>] [--endless] [--forzar]   (60 s por defecto; --endless ignora --time)
$totalSegundos = 60
$endless = $false
$forzar = $false              # arranca aunque haya otro enfriamiento en marcha
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
    } elseif ($args[$k] -match '^--?forzar$') {
        $forzar = $true
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

# ¿Se puede redibujar el panel en el mismo sitio? Necesita una consola con manejador válido:
# con la salida redirigida, mover el cursor y leer el tamaño de ventana lanzan excepción.
$consolaInteractiva = -not [Console]::IsOutputRedirected
$anchoPanel = 60
if ($consolaInteractiva) {
    try {
        [void][Console]::GetCursorPosition()   # falla si no hay consola real
        $anchoPanel = [math]::Max(40, [Console]::WindowWidth - 1)
    } catch {
        $consolaInteractiva = $false
    }
}

# Espera hasta $milisegundos mirando si hay que cortar: Esc, o cualquier tecla con -Cualquiera
# (modo endless). Devuelve $true solo en ese caso; el resto de teclas se descartan en silencio.
function Espera-Tecla([int]$milisegundos, [switch]$Cualquiera) {
    if (-not $conTeclado) {
        Start-Sleep -Milliseconds $milisegundos
        return $false
    }
    $fin = [DateTime]::UtcNow.AddMilliseconds($milisegundos)
    $pulsada = $false
    while (-not $pulsada -and [DateTime]::UtcNow -lt $fin) {
        try {
            if ([Console]::KeyAvailable) { $pulsada = $Cualquiera -or ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Escape) }
        } catch {
            Start-Sleep -Milliseconds $milisegundos
            return $false
        }
        # Otras teclas se descartan en silencio, pero la cuenta atrás sigue a ritmo real.
        if (-not $pulsada) { Start-Sleep -Milliseconds 50 }
    }
    return $pulsada
}

# Suelta el cerrojo de instancia única. Importante liberarlo a mano y no confiar solo en la
# muerte del proceso: si el script se relanzó para pedir permisos, el proceso original sigue
# vivo un momento y, sin esto, bloquearía un arranque posterior con "ya hay un enfriamiento".
function Libera-Cerrojo {
    if ($yaHayInstancia) { return }   # lo tenía otro proceso: no es nuestro y no se suelta
    try {
        $mutex.ReleaseMutex()
    } catch {
        # No lo poseíamos: no hay nada que hacer.
    }
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

# Identifica al proceso que ya tiene el cerrojo, para poder nombrarlo en el aviso en vez de
# dejar al usuario adivinando. Busca otros PowerShell con este mismo script en su linea de
# comandos y descarta el nuestro. Devuelve $null si no encuentra ninguno.
function Get-ProcBloqueante {
    try {
        $nombres = @('pwsh', 'powershell')
        foreach ($proc in (Get-Process | Where-Object { $nombres -contains $_.ProcessName })) {
            if ($proc.Id -eq $PID) { continue }
            $linea = (Get-CimInstance Win32_Process -Filter "ProcessId=$($proc.Id)").CommandLine
            if ($linea -and $linea -like "*$([IO.Path]::GetFileName($PSCommandPath))*") {
                return [pscustomobject]@{
                    Id     = $proc.Id
                    Inicio = $proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
                }
            }
        }
    } catch { }
    return $null
}

# Solo una instancia a la vez: dos enfriamientos simultaneos pelearian por los mismos
# controles y el informe final mentiria. El mutex se suelta solo al morir el proceso, asi que
# hay que liberarlo a mano al salir: si no, el proceso original que relanza con UAC se
# quedaria con el cerrojo puesto aunque su script ya haya acabado.
$mutex = New-Object System.Threading.Mutex($false, 'Local\Fan100.Enfriamiento')
# Ojo con la semantica: WaitOne devuelve $true cuando NOSOTROS tomamos el mutex, no cuando
# hay otra instancia en marcha. Hay que invertirlo o el script no arranca nunca.
$yaHayInstancia = $false
try {
    $yaHayInstancia = -not $mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $yaHayInstancia = $false   # nos lo cede: la instancia anterior murio sin soltar
}
if ($yaHayInstancia -and -not $forzar) {
    Write-Host "Ya hay un enfriamiento en marcha. Espera a que termine antes de iniciar otro." -ForegroundColor Red
    $bloqueante = Get-ProcBloqueante
    if ($bloqueante) {
        Write-Host ("  Lo tiene el proceso {0}, iniciado el {1}." -f $bloqueante.Id, $bloqueante.Inicio) -ForegroundColor Red
        Write-Host "  Ciérrale la ventana para cortarlo, o termina ese proceso a mano." -ForegroundColor Red
    } else {
        Write-Host "  No se ha podido identificar qué proceso lo mantiene: puede ser otra copia del script." -ForegroundColor Red
        Write-Host "  Cierra la otra ventana de PowerShell que esté enfriando." -ForegroundColor Red
        Write-Host "  Si sabes que no hay ninguna en marcha, relánzalo con --forzar." -ForegroundColor Red
    }
    [void](Espera-Cierre $segundosCierreCorto)
    exit 1
}
if ($yaHayInstancia) {
    Write-Host "Aviso: se ignora el enfriamiento en marcha porque has pasado --forzar." -ForegroundColor Yellow
}

if (-not (Test-Path $libPath)) {
    Write-Host "No se encuentra LibreHardwareMonitorLib.dll en $PSScriptRoot" -ForegroundColor Red
    Libera-Cerrojo
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
                    Hardware = $hw.Name
                    Sensor   = $sensor.Name
                    Name     = "$($hw.Name) / $($sensor.Name)"
                    Value    = [double]$sensor.Value
                }
            }
        }
    }
    $result
}

# Colapsa espacios y recorta a $ancho caracteres con puntos suspensivos, para que los nombres
# largos del hardware no descuadren el panel.
function Acorta([string]$texto, [int]$ancho) {
    $texto = ($texto -replace '\s+', ' ').Trim()
    if ($texto.Length -le $ancho) { return $texto }
    return $texto.Substring(0, $ancho - 1) + '…'
}

# Fija qué sensores se muestran durante el enfriamiento y en qué orden: primero las
# temperaturas de cada hardware y luego sus ventiladores. Se calcula una sola vez porque el
# panel debe conservar el mismo alto para poder redibujarse encima.
function Get-PlantillaVivo($tempIni, $fanIni, $anchoNombre) {
    $grupos = [ordered]@{}
    foreach ($id in $tempIni.Keys) {
        $hw = $tempIni[$id].Hardware
        if (-not $grupos.Contains($hw)) { $grupos[$hw] = @{ Temps = @(); Fans = @() } }
        $grupos[$hw].Temps += $id
    }
    foreach ($id in $fanIni.Keys) {
        $hw = $fanIni[$id].Hardware
        if (-not $grupos.Contains($hw)) { $grupos[$hw] = @{ Temps = @(); Fans = @() } }
        $grupos[$hw].Fans += $id
    }

    $filas = @()
    foreach ($hw in $grupos.Keys) {
        $filas += [pscustomobject]@{ Titulo = $true; Texto = ('  ' + (Acorta $hw 60)); Color = 'Cyan' }
        foreach ($id in $grupos[$hw].Temps) {
            $filas += [pscustomobject]@{
                Titulo  = $false
                Nombre  = (Acorta $tempIni[$id].Sensor $anchoNombre)
                Unidad  = '°C'
                Id      = $id
                Inicial = $tempIni[$id].Value
            }
        }
        foreach ($id in $grupos[$hw].Fans) {
            $filas += [pscustomobject]@{
                Titulo  = $false
                Nombre  = (Acorta $fanIni[$id].Sensor $anchoNombre)
                Unidad  = 'RPM'
                Id      = $id
                Inicial = $fanIni[$id].Value
            }
        }
    }
    return , $filas
}

# Cuántas columnas caben en el ancho de la ventana. Con dos caben el doble de sensores, que
# es lo que hace falta en máquinas con muchos ventiladores. Cada columna reserva 38 caracteres
# para el sensor y 2 de separación.
function Get-ColumnasVivo([int]$anchoVentana) {
    $porColumna = 40
    $posibles = [math]::Floor($anchoVentana / $porColumna)
    if ($posibles -lt 1) { return 1 }
    if ($posibles -gt 3) { return 3 }
    return [int]$posibles
}

# Reparte las filas en varias columnas a la altura, para que quepan muchos más sensores en la
# misma ventana. Devuelve @{ Columnas; Alto } con las filas ya repartidas y la altura común.
function Reparte-Vivo($filas, [int]$columnas) {
    if ($columnas -lt 2 -or $filas.Count -le 12) { return @{ Columnas = @(,$filas); Alto = $filas.Count } }

    # Se agrupan las filas por hardware: un dispositivo no se parte entre dos columnas.
    $grupos = @()
    $actual = @()
    foreach ($fila in $filas) {
        if ($fila.Titulo -and $actual.Count -gt 0) { $grupos += , @($actual); $actual = @() }
        $actual += $fila
    }
    if ($actual.Count -gt 0) { $grupos += , @($actual) }

    # Se van colocando los grupos en la columna más corta: reparte mejor queround-robin.
    $cols = @()
    $altos = @()
    for ($c = 0; $c -lt $columnas; $c++) { $cols += , @(); $altos += 0 }
    foreach ($g in $grupos) {
        $corta = 0
        for ($c = 1; $c -lt $columnas; $c++) { if ($altos[$c] -lt $altos[$corta]) { $corta = $c } }
        $cols[$corta] = @($cols[$corta]) + @($g)
        $altos[$corta] += $g.Count
    }

    $alto = 0
    foreach ($h in $altos) { if ($h -gt $alto) { $alto = $h } }
    return @{ Columnas = $cols; Alto = $alto }
}

# Si el panel no cabe en la ventana se corta por abajo (lo menos importante) y se avisa.
# Se aplica DESPUÉS de repartir en columnas: si se recortara antes, al repartirse de nuevo
# volvería a crecer. $maxFilas = 0 deja el panel solo con cabecera y pie.
function Recorta-Vivo($reparto, $maxFilas) {
    if ($maxFilas -le 0) { return @{ Columnas = @(,@()); Alto = 0 } }
    if ($reparto.Alto -le $maxFilas) { return $reparto }

    $columnas = $reparto.Columnas
    $ocultos = 0
    $nuevas = @()
    foreach ($col in $columnas) {
        if ($col.Count -le $maxFilas) { $nuevas += , $col; continue }
        $visibles = @($col[0..($maxFilas - 1)])
        # Un título sin sensores debajo no aporta nada.
        if ($visibles.Count -gt 1 -and $visibles[-1].Titulo) { $visibles = @($visibles[0..($visibles.Count - 2)]) }
        $ocultos += @($col[$visibles.Count..($col.Count - 1)] | Where-Object { -not $_.Titulo }).Count
        $nuevas += , $visibles
    }

    if ($ocultos -gt 0) {
        # Esta fila es solo texto: lleva Titulo = $false pero no Id, para que Get-LineasVivo la
        # pinte tal cual en vez de intentar buscarle un sensor que no existe.
        $aviso = [pscustomobject]@{
            Titulo = $false
            Texto  = ('  ... y {0} sensores más que no caben' -f $ocultos)
            Color  = 'DarkGray'
            Fija   = $true
        }
        $primera = @($nuevas[0][0..($nuevas[0].Count - 1)]) + $aviso
        $nuevas[0] = $primera
    }

    $alto = 0
    foreach ($col in $nuevas) { if ($col.Count -gt $alto) { $alto = $col.Count } }
    return @{ Columnas = $nuevas; Alto = $alto }
}

# Un cuadro del panel: una línea por sensor con su valor actual y la variación desde el
# inicio (verde si va en la dirección buena: temperatura abajo o más RPM).
function Get-LineasVivo($reparto, [int]$anchoColumna, $tempFin, $fanFin, $cabecera, $pie) {
    $lineas = @(
        [pscustomobject]@{ Texto = $cabecera; Color = 'White' }
        [pscustomobject]@{ Texto = ''; Color = 'Gray' }
    )

    $columnas = $reparto.Columnas
    $alto = 0
    foreach ($col in $columnas) { if ($col.Count -gt $alto) { $alto = $col.Count } }

    for ($i = 0; $i -lt $alto; $i++) {
        $texto = ''
        foreach ($col in $columnas) {
            $celda = if ($i -lt $col.Count) { Formatea-CeldaVivo $col[$i] $tempFin $fanFin $anchoColumna } else { '' }
            $texto += $celda
        }
        $lineas += [pscustomobject]@{ Texto = $texto; Color = 'Gray' }
    }

    $lineas += [pscustomobject]@{ Texto = ''; Color = 'Gray' }
    $lineas += [pscustomobject]@{ Texto = $pie; Color = 'Cyan' }
    return , $lineas
}

# Un sensor del panel: valor actual y variación desde el inicio. Verde si va en la dirección
# buena (temperatura abajo, más RPM), rojo si va al revés, gris si no se mueve.
function Formatea-CeldaVivo($fila, $tempFin, $fanFin, [int]$ancho) {
    if ($fila.Titulo -or $fila.Fija) {
        # Título de hardware o aviso de "y N sensores más": se pinta tal cual.
        return $fila.Texto.PadRight($ancho)
    }
    $sensor = if ($fila.Unidad -eq '°C') { $tempFin[$fila.Id] } else { $fanFin[$fila.Id] }
    if ($null -eq $sensor) {
        # El sensor no está en la lectura actual: se marca en vez de fallar.
        return ('    {0}  --' -f $fila.Nombre.PadRight(20)).PadRight($ancho)
    }
    $cambio = if ($fila.Unidad -eq '°C') { [math]::Round($sensor.Value - $fila.Inicial, 1) } else { [math]::Round($sensor.Value - $fila.Inicial, 0) }
    if ($cambio -eq 0) {
        # Sin cambio respecto al inicio: no hace falta ensuciar la línea con un +0,0.
        $texto = if ($fila.Unidad -eq '°C') {
            '    {0}  {1,6:N1} °C' -f $fila.Nombre.PadRight(20), $sensor.Value
        } else {
            '    {0}  {1,6:N0} RPM' -f $fila.Nombre.PadRight(20), $sensor.Value
        }
        return $texto.PadRight($ancho)
    }
    if ($fila.Unidad -eq '°C') {
        return ('    {0}  {1,6:N1} °C  ({2:+0.0;-0.0})' -f $fila.Nombre.PadRight(20), $sensor.Value, $cambio).PadRight($ancho)
    }
    return ('    {0}  {1,6:N0} RPM  ({2:+0;-0})' -f $fila.Nombre.PadRight(20), $sensor.Value, $cambio).PadRight($ancho)
}

# Redibuja el panel en el mismo sitio: sube el cursor tantas líneas como ocupa y vuelve a
# escribirlas, rellenando con espacios para borrar el resto. Si la consola no deja mover el
# cursor se degrada a imprimir en bloque y no se vuelve a intentarlo.
function Write-Vivo($lineas) {
    if (-not $consolaInteractiva) {
        foreach ($linea in $lineas) { Write-Host $linea.Texto -ForegroundColor $linea.Color }
        return
    }
    try {
        # Ojo: GetCursorPosition devuelve una tupla y en PowerShell solo existen Item1/Item2.
        # El cursor queda una fila por debajo del panel, así que hay que subir exactamente
        # una fila por línea escrita; con count-1 el bloque bajaba una línea en cada refresco.
        $pos = [Console]::GetCursorPosition()
        [Console]::SetCursorPosition(0, $pos.Item2 - [Math]::Min($lineas.Count, $pos.Item2))
        $ancho = [Math]::Max(40, [Console]::WindowWidth - 1)
        foreach ($linea in $lineas) {
            $texto = $linea.Texto
            if ($texto.Length -gt $ancho) { $texto = $texto.Substring(0, $ancho) }
            Write-Host $texto.PadRight($ancho) -ForegroundColor $linea.Color
        }
    } catch {
        $script:consolaInteractiva = $false
    }
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
    $lineas += [pscustomobject]@{ Texto = 'Temperaturas (°C inicial -> final):'; Color = 'Yellow' }

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

        # El panel se dimensiona una sola vez: cabecera y pie cuentan, y encima van los sensores.
        $anchoNombre = [math]::Max(14, [math]::Min(26, $anchoPanel - 34))
        $maxFilas = 0
        if ($consolaInteractiva) {
            try {
                # Get-LineasVivo añade 4 líneas fijas (cabecera, hueco, hueco y pie): hay que
                # descontarlas aquí o el panel no cabe, la consola hace scroll y el redibujo
                # del bloque se descuadra. El margen final deja libres las dos últimas filas:
                # una porque la última línea justa provoca scroll en algunas consolas, y otra
                # porque al pintar el cuadro final la ventana puede haber cambiado de alto.
                $maxFilas = [Console]::WindowHeight - [Console]::GetCursorPosition().Item2 - 6
                # Con una ventana enana y mucho texto previo no cabe ni un sensor: en ese caso
                # no se pinta panel (haría scroll y descuadraría el bloque) y se deja solo la
                # cuenta atrás, que cabe en cualquier ventana.
                if ($maxFilas -lt 1) { $maxFilas = 0 }
            } catch {
                $consolaInteractiva = $false
            }
        }
        $plantilla = Get-PlantillaVivo $tempIni $fanIni $anchoNombre
        # Con ventana ancha se reparte en varias columnas para que quepan más sensores; si
        # aun así no cabe, Recorta-Vivo deja solo los que entran y avisa de los demás.
        $anchoVentana = if ($consolaInteractiva) { [Console]::WindowWidth - 1 } else { 80 }
        $columnas = Get-ColumnasVivo $anchoVentana
        $anchoColumna = [math]::Floor($anchoVentana / $columnas)
        $reparto = Reparte-Vivo $plantilla $columnas
        if ($reparto.Alto -gt $maxFilas) { $reparto = Recorta-Vivo $reparto $maxFilas }
        $cabecera = 'Enfriamiento a máxima velocidad' + $(if ($endless) { ' (modo endless)' })

        # Descarta lo que se haya pulsado mientras se activaban los ventiladores, para que una
        # tecla suelta no termine el ciclo nada más empezar.
        try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { }

        $t = 0
        $corteTecla = $false
        $primeraLinea = $true
        while ($true) {
            if (-not $endless -and $t -ge $totalSegundos) { break }
            $pie = if ($endless) {
                'En marcha: {0} s a máxima velocidad (pulsa para salir)...' -f $t
            } else {
                'Quedan {0} s a máxima velocidad (Esc para cancelar)...' -f ($totalSegundos - $t)
            }
            $lineas = Get-LineasVivo $reparto $anchoColumna (Read-Sensors 'Temperature') (Read-Sensors 'Fan') $cabecera $pie
            if ($consolaInteractiva) {
                Write-Vivo $lineas
            } else {
                if ($primeraLinea) {
                    Write-Informe $lineas     # sin consola real el panel se pinta una sola vez
                    $primeraLinea = $false
                }
                Write-Host ("`r" + $pie) -NoNewline -ForegroundColor Cyan
            }
            if (Espera-Tecla 1000 -Cualquiera:$endless) { $corteTecla = $true; break }
            $t++
        }

        $reloj.Stop()
        if ($corteTecla) {
            Write-Host ""
            Write-Host "Enfriamiento cancelado con Esc." -ForegroundColor Yellow
            $motivoCorte = 'Esc'
        } else {
            # Último cuadro en pantalla, con el estado final de cada sensor.
            if (-not $consolaInteractiva) { Write-Host "" }
            Write-Vivo (Get-LineasVivo $reparto $anchoColumna (Read-Sensors 'Temperature') (Read-Sensors 'Fan') $cabecera 'Enfriamiento terminado.')
        }
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

} catch {
    # Sin esto, un fallo a mitad del ciclo solo aparecía al final, tras la cuenta atrás de
    # cierre, y parecía que el enfriamiento se acababa antes de empezar.
    $errorCiclo = $_
    Write-Host ""
    Write-Host "ERROR inesperado durante el enfriamiento:" -ForegroundColor Red
    Write-Host ("  " + $errorCiclo.Exception.Message) -ForegroundColor Red
    if ($errorCiclo.InvocationInfo) {
        Write-Host ("  en la línea " + $errorCiclo.InvocationInfo.ScriptLineNumber + ": " + $errorCiclo.InvocationInfo.Line.Trim()) -ForegroundColor Red
    }
    $motivoCorte = 'error'
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
    Libera-Cerrojo   # ya no queda nada que proteger: que otro arranque no espere a este cierre
    $esperaCierre = if ($motivoCorte) { $segundosCierreCorto } else { $segundosCierre }
    if (Espera-Cierre $esperaCierre) {
        Write-Host "Cerrando ahora (tecla pulsada)." -ForegroundColor Cyan
    }
}
