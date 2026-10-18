# Fan100

**English** | [Español](README.es.md)

A PowerShell script that sets every fan in your computer to 100% for a fixed time (or until you press a key), then hands control back to the firmware. Use it to cool the machine down before or after a heavy workload, or to check that your fans respond. Temperatures and RPM are shown live while it cools.

It uses [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) to reach the motherboard, CPU and GPU fan controls.

## What it does

1. Asks for administrator rights if it does not have them (it relaunches itself and shows the UAC prompt).
2. Refuses to start if a cooling run is already in progress: two sessions at once would fight over the same controls and the report would lie.
3. Reads the initial temperatures and fan RPM.
4. Forces every fan control the hardware exposes to 100% and lists which ones it could control. If it could control none, it says so and stops, because there is no point in waiting when nothing can be cooled.
5. Shows a live panel that refreshes every second: the temperatures and RPM of every device, with the change since the start (green when it moves the right way, temperature down or more RPM; red when it moves the wrong way; unchanged in blue). The panel spreads over several columns when the window is wide enough to fit every sensor, and only mentions the ones it had to leave out when they really do not fit. The countdown sits at the bottom of the panel. It waits for the chosen time, or until you press a key in endless mode. During the countdown you can press `Esc` to cut cooling short and restore the fans right away.
6. Leaves a last frame on screen with the final state of every sensor, then prints a summary of the duration, RPM and temperatures, from start to end. Temperatures that dropped are green, those that rose are red, and those that did not change are blue.
7. Restores automatic firmware control and **checks that it worked**: if a fan is left under software control it warns in red, naming the control, so you can set it by hand.
8. Saves the report to `logs\coolingLog_AAMMDD.txt` (one file per day, one block per run) and closes the window on its own after a 10 second countdown so you can read the report. Press any key before that and it closes right away. If you aborted with `Esc`, or there were no controllable fans, there is no report to read, so the wait drops to 3 seconds.

Fans go back to automatic control even if you close the window, log off or shut down while the script is running.

## Logs

Every completed run appends a block to `logs\coolingLog_AAMMDD.txt` (one file per day, created automatically). Each block holds the date and time, the mode, how long the cooling lasted and the same values shown on screen:

```text
=== 2026-10-17 21:34:05 | --time 60 ===
Duración del enfriamiento: 60,0 s (--time 60)

Ventiladores (RPM inicial -> final):
  CPU / Fan1: 1.200 -> 2.400 RPM

Temperaturas (°C inicial -> final; azul = sin cambio):
  CPU / Package: 60,0 -> 52,3 (-7,7)
```

Runs cancelled with `Esc` are not logged: there is no final report to store. The `logs` folder is in `.gitignore`.

## Requirements

- Windows
- [PowerShell 7](https://github.com/PowerShell/PowerShell) (`pwsh`). Windows PowerShell 5.1 (`powershell.exe`) is not supported.
- `LibreHardwareMonitorLib.dll` in the same folder as the script
- The [PawnIO](https://pawnio.eu) driver. If it is missing, the script installs it with `winget` on first run (`winget install namazso.PawnIO`). Without it the library cannot reach the hardware: temperatures read 0 and no fans show up.
- Hardware whose fans can be controlled by software. Controls that are not supported are shown as `[--] ... (sin control)`. On most laptops the fan is driven by the embedded controller (EC), which LibreHardwareMonitor cannot control.

## Usage

Open PowerShell 7 in the project folder and run:

```powershell
pwsh -File Fans30.ps1                # 60 seconds (default)
pwsh -File Fans30.ps1 --time 180     # N seconds
pwsh -File Fans30.ps1 --endless      # until a key is pressed (ignores --time)
```

| Option | Description |
| --- | --- |
| `--time <seconds>` | Duration in seconds. Must be a positive integer. Default: 60. |
| `--endless` | No time limit: it stops when you press any key. Takes precedence over `--time`. |
| `--forzar` | Starts even if another cooling run is detected. Use it only when you know that warning is wrong. |

The script's on-screen messages are in Spanish.

## Shortcuts

Shortcuts (`*.lnk`) are not part of the repository, because they point to absolute paths on each computer. You can create your own in either of these ways.

### Option A: create all three with one command

1. Open the project folder in File Explorer (the one that contains `Fans30.ps1`).
2. Click the address bar, type `pwsh` and press Enter. A PowerShell 7 window opens already in that folder. Alternatively, right-click an empty area of the folder and choose **Open in Terminal**, then make sure the terminal is PowerShell 7.
3. Paste the following block and press Enter. It creates the shortcuts in the current folder:

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

This gives you:

- `Fans 1min.lnk`: 60 seconds
- `Fans 3min.lnk`: 180 seconds
- `Fans Endless.lnk`: until you press a key

You can then copy them to the desktop, the Start menu or the taskbar. If you move or rename the project folder, run the block again.

### Option B: create one by hand

1. Right-click the desktop (or any folder) and choose **New > Shortcut**.
2. In **Location**, paste the following line, replacing the path with the real location of `Fans30.ps1`, and change the last argument as needed (`--time 60`, `--time 180` or `--endless`):

   ```text
   pwsh -NoProfile -ExecutionPolicy Bypass -File "C:\path\to\Fans30.ps1" --time 60
   ```

3. Click **Next**, name the shortcut and click **Finish**.

If Windows cannot find `pwsh`, use its full path instead, for example `"C:\Program Files\PowerShell\7\pwsh.exe"`.

## Warning

The script writes to your hardware's fan controls with administrator rights. Use it at your own risk. If the process is killed forcibly (for example, ending `pwsh` from Task Manager), the fans may stay at 100% until you restart the computer.

## Credits

`LibreHardwareMonitorLib.dll` belongs to the [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) project and is distributed under its own license (MPL 2.0).
