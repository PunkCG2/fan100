# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Single PowerShell 7 script, `Fans30.ps1`, that forces all motherboard/GPU/CPU fan controls to 100% for a fixed time (or until a key is pressed), then restores firmware control. Hardware access comes from `LibreHardwareMonitorLib.dll` (must sit next to the script; loaded via `$PSScriptRoot`). No build, lint, or test setup.

## Running

```powershell
pwsh -File Fans30.ps1                # 60 s (default)
pwsh -File Fans30.ps1 --time 180     # N seconds
pwsh -File Fans30.ps1 --endless      # until keypress; ignores --time
```

Requires Windows and `pwsh` (not Windows PowerShell). Prebuilt `.lnk` shortcuts (`Fans 1min`, `Fans 3min`, `Fans Endless`) call the script with an absolute path; recreate them if the folder moves.

## Architecture notes

- **Self-elevation**: if not admin, the script relaunches itself with `Start-Process pwsh -Verb RunAs`, forwarding `$args` via `-join ' '`. Arguments containing spaces would break; current flags don't.
- **Fan restore safety**: `FanGuard` is a C# class compiled with `Add-Type`. It holds the list of `IControl` objects and registers a `SetConsoleCtrlHandler` that calls `SetDefault()` on window close, logoff, or shutdown. It must be C# because the handler runs on another thread, where PowerShell script blocks can't run. Any control set with `SetSoftware(100)` must be added to `FanGuard.Controls` first. The `finally` block also calls `FanGuard.Restore()` for normal exit and Ctrl+C.
- **Sensor reporting**: `Read-Sensors` snapshots Temperature/Fan sensors before and after, keyed by `Sensor.Identifier`, and prints a before/after diff.
- **Auto-close**: `Espera-Cierre` ends the run instead of blocking on `ReadKey`. It counts down from `$segundosCierre` (10 s, defined at the top of the script) and exits immediately on a keypress; polling `[Console]::KeyAvailable` every 100 ms. It falls back to a plain wait when console input is redirected, so it must not assume a keyboard exists. Both end-of-script paths call it: the missing-DLL error and the `finally` block.
- Script messages and comments are in Spanish; keep that convention.
