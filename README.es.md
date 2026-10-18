# Fan100

[English](README.md) | **Español**

Script de PowerShell que pone todos los ventiladores del equipo al 100 % durante un tiempo fijo (o hasta que pulses una tecla) y después devuelve el control al firmware. Sirve para enfriar el equipo a fondo antes o después de una carga pesada, o para comprobar que los ventiladores responden.

Usa [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) para acceder a los controles de la placa base, la CPU y la GPU.

## Qué hace

1. Pide permisos de administrador si no los tiene (se relanza solo y aparece el aviso de UAC).
2. Lee las temperaturas y las RPM iniciales.
3. Fuerza al 100 % todos los controles de ventilador que expone el hardware y muestra cuáles ha podido controlar.
4. Espera el tiempo indicado, con cuenta atrás, o hasta que pulses una tecla en modo endless. Durante la cuenta atrás puedes pulsar `Esc` para cortar el enfriamiento antes de tiempo y restablecer los ventiladores de inmediato.
5. Muestra un resumen de RPM y temperaturas, de inicial a final. Las temperaturas que bajan salen en verde, las que suben en rojo y las que no cambian en azul.
6. Restablece el control automático por firmware.
7. Cierra la ventana solo, con una cuenta atrás de 10 segundos. Si pulsas cualquier tecla antes, cierra al instante.

Los ventiladores vuelven a control automático aunque cierres la ventana, cierres sesión o apagues el equipo con el script en marcha.

## Requisitos

- Windows
- [PowerShell 7](https://github.com/PowerShell/PowerShell) (`pwsh`). Windows PowerShell 5.1 (`powershell.exe`) no está soportado.
- `LibreHardwareMonitorLib.dll` en la misma carpeta que el script
- Un equipo cuyo hardware permita controlar los ventiladores por software. Los controles sin soporte se muestran como `[--] ... (sin control)`.

## Uso

Abre PowerShell 7 en la carpeta del proyecto y ejecuta:

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

Los accesos directos (`*.lnk`) no se incluyen en el repositorio, porque apuntan a rutas absolutas de cada equipo. Puedes crear los tuyos de dos formas.

### Opción A: crear los tres con un solo comando

1. Abre la carpeta del proyecto en el Explorador de archivos (la que contiene `Fans30.ps1`).
2. Haz clic en la barra de direcciones, escribe `pwsh` y pulsa Enter. Se abre una ventana de PowerShell 7 ya situada en esa carpeta. También puedes hacer clic derecho en una zona vacía de la carpeta y elegir **Abrir en Terminal**, y comprobar que el terminal sea PowerShell 7.
3. Pega este bloque y pulsa Enter. Crea los accesos directos en la carpeta actual:

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

Obtendrás:

- `Fans 1min.lnk`: 60 segundos
- `Fans 3min.lnk`: 180 segundos
- `Fans Endless.lnk`: hasta pulsar una tecla

Después puedes copiarlos al escritorio, al menú Inicio o a la barra de tareas. Si mueves o renombras la carpeta del proyecto, vuelve a ejecutar el bloque.

### Opción B: crear uno a mano

1. Haz clic derecho en el escritorio (o en cualquier carpeta) y elige **Nuevo > Acceso directo**.
2. En **Ubicación**, pega esta línea, sustituye la ruta por la ubicación real de `Fans30.ps1` y cambia el último argumento según necesites (`--time 60`, `--time 180` o `--endless`):

   ```text
   pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\ruta\a\Fans30.ps1" --time 60
   ```

3. Pulsa **Siguiente**, ponle un nombre y pulsa **Finalizar**.

Si Windows no encuentra `pwsh`, usa su ruta completa, por ejemplo `"C:\Program Files\PowerShell\7\pwsh.exe"`.

## Aviso

El script escribe en los controles de ventilador del hardware con permisos de administrador. Úsalo bajo tu responsabilidad. Si el proceso se mata de forma forzada (por ejemplo, terminando `pwsh` desde el Administrador de tareas), los ventiladores podrían quedarse al 100 % hasta reiniciar el equipo.

## Créditos

`LibreHardwareMonitorLib.dll` pertenece al proyecto [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) y se distribuye bajo su propia licencia (MPL 2.0).
