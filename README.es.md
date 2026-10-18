# Fan100

[English](README.md) | **Español**

Script de PowerShell que pone todos los ventiladores del equipo al 100 % durante un tiempo fijo (o hasta que pulses una tecla) y después devuelve el control al firmware. Sirve para enfriar el equipo a fondo antes o después de una carga pesada, o para comprobar que los ventiladores responden. Durante el enfriamiento muestra las temperaturas y las RPM en vivo.

Usa [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) para acceder a los controles de la placa base, la CPU y la GPU.

## Qué hace

1. Pide permisos de administrador si no los tiene (se relanza solo y aparece el aviso de UAC).
2. Se niega a arrancar si ya hay un enfriamiento en marcha: dos sesiones a la vez pelearían por los mismos controles y el informe mentdría. El aviso te dice qué proceso lo tiene, para que puedas identificarlo y cerrarlo. Si sabes que no hay ninguno en marcha, relánzalo con `--forzar`.
3. Lee las temperaturas y las RPM iniciales.
4. Fuerza al 100 % todos los controles de ventilador que expone el hardware y muestra cuáles ha podido controlar. Si no controla ninguno, avisa y termina, porque no sirve de nada esperar el tiempo indicado para no poder enfriar nada.
5. Muestra un panel en vivo que se refresca cada segundo: las temperaturas y las RPM de cada dispositivo, con la variación respecto al inicio (verde cuando va en la buena dirección, temperatura abajo o más RPM; rojo cuando va al revés; sin cambios en azul). El panel se reparte en varias columnas si la ventana es ancha, para que quepan todos los sensores, y solo avisa de los que se quedan fuera si de verdad no caben. Abajo del panel va la cuenta atrás. Espera el tiempo indicado, o hasta que pulses una tecla en modo endless. Durante la cuenta atrás puedes pulsar `Esc` para cortar el enfriamiento antes de tiempo y restablecer los ventiladores de inmediato.
6. Al terminar deja un último cuadro en pantalla con el estado final de cada sensor y muestra un resumen de la duración y de las RPM y temperaturas, de inicial a final. Las temperaturas que bajan salen en verde, las que suben en rojo y las que no cambian en azul.
7. Restablece el control automático por firmware y **comprueba que ha funcionado**: si algún ventilador se queda bajo control software, avisa en rojo con qué control es para que lo ajustes a mano.
8. Guarda el informe en `logs\coolingLog_AAMMDD.txt` (un fichero por día, un bloque por ejecución) y cierra la ventana solo, con una cuenta atrás de 10 segundos para que puedas leer el informe. Si pulsas cualquier tecla antes, cierra al instante. Si has cancelado con `Esc` o no había ventiladores que controlar, la espera es de solo 3 segundos porque no hay informe que mostrar.

Los ventiladores vuelven a control automático aunque cierres la ventana, cierres sesión o apagues el equipo con el script en marcha.

## Registros (logs)

Cada ejecución completada añade un bloque a `logs\coolingLog_AAMMDD.txt` (un fichero por día, se crea solo). Cada bloque guarda la fecha y hora, el modo, cuánto duró el enfriamiento y los mismos valores que se ven en pantalla:

```text
=== 2026-10-17 21:34:05 | --time 60 ===
Duración del enfriamiento: 60,0 s (--time 60)

Ventiladores (RPM inicial -> final):
  CPU / Fan1: 1.200 -> 2.400 RPM

Temperaturas (°C inicial -> final; azul = sin cambio):
  CPU / Package: 60,0 -> 52,3 (-7,7)
```

Las ejecuciones canceladas con `Esc` no se registran: no hay informe final que guardar. La carpeta `logs` está en `.gitignore`.

## Requisitos

- Windows
- [PowerShell 7](https://github.com/PowerShell/PowerShell) (`pwsh`), versión 7.6 o posterior (la DLL es para .NET 10). Windows PowerShell 5.1 (`powershell.exe`) no está soportado. Si no lo tienes, `Fans.cmd` lo instala con `winget` (`winget install Microsoft.PowerShell`).
- `LibreHardwareMonitorLib.dll` en la misma carpeta que el script. Si falta, el script descarga la versión 0.9.6 del [paquete NuGet oficial](https://www.nuget.org/packages/LibreHardwareMonitorLib) y comprueba su hash SHA-256 antes de usarla.
- El driver [PawnIO](https://pawnio.eu). Si falta, el script lo instala solo con `winget` la primera vez (`winget install namazso.PawnIO`). Sin él, la librería no llega al hardware: las temperaturas salen a 0 y no aparece ningún ventilador.
- Un equipo cuyo hardware permita controlar los ventiladores por software. Los controles sin soporte se muestran como `[--] ... (sin control)`. En la mayoría de portátiles el ventilador lo gobierna el controlador embebido (EC) y LibreHardwareMonitor no puede controlarlo.

## Uso

La primera vez en un equipo nuevo, lo más sencillo es hacer doble clic en `Fans.cmd` (o ejecutarlo con las mismas opciones, por ejemplo `Fans.cmd --time 180`). Instala PowerShell 7.6 si falta y lanza el script, que a su vez descarga la DLL e instala PawnIO si hace falta.

Si ya tienes PowerShell 7, abre una ventana en la carpeta del proyecto y ejecuta:

```powershell
pwsh -File Fans30.ps1                # 60 segundos (por defecto)
pwsh -File Fans30.ps1 --time 180     # N segundos
pwsh -File Fans30.ps1 --endless      # hasta pulsar una tecla (ignora --time)
```

| Opción | Descripción |
| --- | --- |
| `--time <segundos>` | Duración en segundos. Debe ser un entero positivo. Por defecto, 60. |
| `--endless` | Sin límite de tiempo: termina al pulsar cualquier tecla. Tiene prioridad sobre `--time`. |
| `--forzar` | Arranca aunque detecte otro enfriamiento en marcha. Úsalo solo si sabes que ese aviso es un error. |

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
