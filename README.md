# Fan100

Script de PowerShell que pone todos los ventiladores del equipo al 100 % durante un tiempo fijo (o hasta que pulses una tecla) y después devuelve el control al firmware. Sirve para enfriar el equipo a fondo antes o después de una carga pesada, o para comprobar que los ventiladores responden.

Usa [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) para acceder a los controles de la placa base, la CPU y la GPU.

## Qué hace

1. Pide permisos de administrador si no los tiene (se relanza solo con UAC).
2. Lee las temperaturas y las RPM iniciales.
3. Fuerza al 100 % todos los controles de ventilador que expone el hardware y muestra cuáles ha podido controlar.
4. Espera el tiempo indicado, con cuenta atrás, o hasta que pulses una tecla en modo endless.
5. Muestra un resumen de RPM y temperaturas, de inicial a final. Las temperaturas que bajan salen en verde, las que suben en rojo y las que no cambian en azul.
6. Restablece el control automático por firmware.

Los ventiladores vuelven a control automático aunque cierres la ventana, cierres sesión o apagues el equipo con el script en marcha.

## Requisitos

- Windows
- [PowerShell 7](https://github.com/PowerShell/PowerShell) (`pwsh`)
- `LibreHardwareMonitorLib.dll` en la misma carpeta que el script
- Un equipo cuyo hardware permita controlar los ventiladores por software. Los controles sin soporte se muestran como `[--] ... (sin control)`.

## Uso

```powershell
pwsh -File Fans30.ps1                # 60 segundos (por defecto)
pwsh -File Fans30.ps1 --time 180     # N segundos
pwsh -File Fans30.ps1 --endless      # hasta pulsar una tecla (ignora --time)
```

| Opción | Descripción |
| --- | --- |
| `--time <segundos>` | Duración en segundos. Debe ser un entero positivo. Por defecto, 60. |
| `--endless` | Sin límite de tiempo: termina al pulsar cualquier tecla. Tiene prioridad sobre `--time`. |

## Accesos directos

Los accesos directos (`*.lnk`) no se incluyen en el repositorio, porque apuntan a rutas absolutas de cada equipo. Para lanzar el script con un clic, crea tres desde la carpeta del proyecto con esta orden:

- `Fans 1min.lnk`: 60 segundos
- `Fans 3min.lnk`: 180 segundos
- `Fans Endless.lnk`: hasta pulsar una tecla

```powershell
$dir  = $PWD.Path
$pwsh = (Get-Command pwsh).Source
$ws   = New-Object -ComObject WScript.Shell
@(
  @{n='Fans 1min';    a='--time 60'},
  @{n='Fans 3min';    a='--time 180'},
  @{n='Fans Endless'; a='--endless'}
) | ForEach-Object {
  $l = $ws.CreateShortcut("$dir\$($_.n).lnk")
  $l.TargetPath       = $pwsh
  $l.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$dir\Fans30.ps1`" $($_.a)"
  $l.WorkingDirectory = $dir
  $l.IconLocation     = "$pwsh,0"
  $l.Save()
}
```

Después puedes copiarlos al escritorio, al menú Inicio o a la barra de tareas.

## Aviso

El script escribe en los controles de ventilador del hardware con permisos de administrador. Úsalo bajo tu responsabilidad. Si el proceso se mata de forma forzada (por ejemplo, terminando `pwsh` desde el Administrador de tareas) los ventiladores podrían quedarse al 100 % hasta reiniciar el equipo.

## Créditos

`LibreHardwareMonitorLib.dll` pertenece al proyecto [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) y se distribuye bajo su propia licencia (MPL 2.0).
