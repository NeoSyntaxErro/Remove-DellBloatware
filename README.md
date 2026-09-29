# Remove-DellBloatware.ps1

**Scripted by:** Steffen Teall

## Overview

`Remove-DellBloatware.ps1` finds Dell-branded software installed on a Windows machine and silently uninstalls it, whether the product uses a Windows Installer (MSI) package or a standard EXE uninstaller. Every uninstall is monitored live in the same console window, and a results summary is printed and saved at the end.

It replaces two earlier scripts: `Remove-DellBloatware.ps1`, which handled detection and MSI-only uninstalls, and `Remove-DellBloatware-Monitor.ps1`, which had to be run in a second window to tail the MSI log.

## Use Case

New Dell machines ship with a range of preinstalled utilities (SupportAssist components, Dell Optimizer, Digital Delivery, Display Manager, Peripheral Manager and similar). For an MSP onboarding or re-imaging devices, removing these by hand is slow and inconsistent. This script is intended to be run:

- As part of a new-device onboarding or provisioning checklist.
- Through an RMM tool as a scripted job across a fleet of Dell endpoints.
- Interactively by a technician who wants to watch exactly what is being removed.

The exit codes (see below) make it easy for RMM platforms to flag machines that need attention.

## How It Works

### 1. Detection

The script reads the three standard Uninstall registry locations (64-bit HKLM, 32-bit WOW6432Node HKLM, and HKCU) and collects every entry whose DisplayName matches `Dell`, minus anything matching `-ExcludePattern`.

### 2. Planning

Each app gets an uninstall plan, chosen in this order of preference:

| Priority | Method | When it is used | What runs |
|---|---|---|---|
| 1 | msiexec | Uninstall command is `msiexec` with a product GUID | `msiexec /x {GUID} /qn /norestart` |
| 2 | msiexec (wrapped) | A setup.exe wraps an MSI (registry key is the GUID and `WindowsInstaller = 1`) | `msiexec /x {GUID} /qn /norestart` |
| 3 | QuietUninstallString | The vendor registered a silent uninstall command | The vendor's command as-is |
| 4 | Dell override | DisplayName matches an entry in `$ExeSilentArgs` | The uninstaller EXE with the override arguments |
| 5 | Inno Setup | Uninstaller is `unins000.exe` (or similar) | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` |
| 5 | InstallShield Suite | Arguments include `-remove` with `-runfromtemp` | Existing arguments plus `-silent` |
| 5 | NSIS | Uninstaller is `uninst.exe` / `uninstall.exe` | `/S` |

Anything that does not fit is **skipped and reported, never run interactively**. An uninstaller showing a prompt would hang indefinitely when run by an RMM agent as SYSTEM. Common skip reasons are InstallShield InstallScript uninstallers (which need a recorded response file), `rundll32`-based uninstall commands, and unknown installer types.

Duplicate entries across registry hives are collapsed to one.

### 3. Uninstall order

EXE uninstalls run first, then MSI uninstalls. Suite-style EXE uninstallers often remove their own MSI components, so running them first avoids breaking the suite. Before each uninstall, the script checks whether the registry entry still exists; if an earlier uninstaller already removed it, the app is marked "Already removed" and skipped.

### 4. Live monitoring

An overall progress bar shows which app is being removed (X of Y). Each uninstall type is then monitored differently:

- **MSI:** the verbose log (written with `/L*v!` so it is flushed line by line) is tailed live, printing new lines only. A second progress bar shows elapsed time and the current MSI action.
- **EXE:** the uninstaller and every process it launches are tracked, with each process printed as it starts and finishes. The script waits for the whole process tree to finish, which matters because NSIS and Inno Setup uninstallers copy themselves to `%TEMP%`, relaunch, and exit immediately. A progress bar shows elapsed time and which processes are still running.

### 5. Verification and result handling

- **MSI:** the msiexec exit code is used (see table below). Failed uninstalls keep their log and print the lines leading up to the failure.
- **EXE:** exit codes from EXE uninstallers are unreliable, so after the process tree finishes the script checks whether the app's registry entry is gone. That check decides the result. Any uninstaller still running after `-ExeTimeoutMinutes` (default 15) is stopped and reported as failed.

### 6. Summary

A results table covering removed, failed, review and skipped apps is printed and saved to a timestamped summary log.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+.
- Must be run as Administrator (checked at startup; the script stops with exit code 1 if not elevated). Running as SYSTEM through an RMM agent also works.
- Write access to the log directory (default `C:\RobTech\DellUninstall`, created automatically).

## Running Directly From GitHub

The script can be run straight from a GitHub repo without saving it to disk. Open an **elevated** PowerShell window (Run as Administrator), then use one of the forms below. Replace `<user>`, `<repo>` and `<branch>` with your own values; the URL must be the **raw** file URL (`raw.githubusercontent.com`), not the normal github.com page.

**Run with default settings:**

```powershell
irm https://raw.githubusercontent.com/<user>/<repo>/<branch>/Remove-DellBloatware.ps1 | iex
```

**Run with parameters** (`iex` cannot pass parameters, so the script is turned into a scriptblock and called):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/<user>/<repo>/<branch>/Remove-DellBloatware.ps1))) -ListOnly
```

The scriptblock form is the better habit even without parameters, because it runs in its own scope and doesn't leave the script's variables and functions behind in your session.

**Older Windows PowerShell 5.1 machines** may fail to connect to GitHub because they default to old TLS versions. Enable TLS 1.2 first:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
```

### Exit codes when run remotely

When the script runs as a `.ps1` file it exits with a real process exit code. When it runs through `iex` or a scriptblock it does **not** call `exit`, because that would close your PowerShell window. Instead it sets `$LASTEXITCODE`. For an RMM job that needs the exit code, end the command with `exit $LASTEXITCODE`:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/<user>/<repo>/<branch>/Remove-DellBloatware.ps1))) -MonitorMode Quiet
exit $LASTEXITCODE
```

### Safety recommendations

Running code straight from the internet as Administrator means whoever can change that file controls every machine that runs it.

- **Pin to a tag or commit for fleet use.** Use a URL like `.../<user>/<repo>/v1.2.0/Remove-DellBloatware.ps1` or `.../<user>/<repo>/<commit-sha>/Remove-DellBloatware.ps1` instead of `main`. An accidental or malicious push to `main` then can't reach your fleet, and every machine runs the exact same version. (Raw URLs on a branch are also cached for a few minutes, so a fresh push may not be picked up immediately.)
- **Protect the branch.** Turn on branch protection and two-factor authentication for anyone with write access to the repo.
- **Optionally verify a hash.** For RMM jobs, check the download against a known SHA-256 before running it. The helper below hashes the downloaded text itself, so run it once against your pinned URL to get the expected value, then paste that value into the job:

```powershell
function Get-TextSha256([string]$Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)) -replace '-'
}

$url  = 'https://raw.githubusercontent.com/<user>/<repo>/<tag>/Remove-DellBloatware.ps1'
$hash = '<expected SHA-256>'   # one-time: Get-TextSha256 (irm $url)
$code = irm $url
if ((Get-TextSha256 $code) -ne $hash) { Write-Error "Hash mismatch - not running."; exit 1 }
& ([scriptblock]::Create($code)) -MonitorMode Quiet
exit $LASTEXITCODE
```

  Hashing the downloaded text (rather than a local copy with `Get-FileHash`) avoids false mismatches from line-ending or BOM differences. Pinning to a tag or commit keeps the hash valid; update it whenever you move to a new version.

- **Private repos** need an access token in the request: `irm $url -Headers @{ Authorization = "token <PAT>" }`. Don't embed a token in scripts; store it in your RMM's secure variables.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-LogDirectory` | `C:\RobTech\DellUninstall` | Where per-app MSI logs and the run summary are written. |
| `-NamePattern` | `\bDell\b` | Regex matched against DisplayName to find target apps. |
| `-ExcludePattern` | *(none)* | One or more regex patterns; matching apps are left alone. |
| `-MonitorMode` | `Summary` | `Summary`: MSI actions, product messages and errors, plus EXE process start/finish. `Full`: every MSI log line (EXE output is the same as Summary). `Quiet`: progress bars only. |
| `-PollMilliseconds` | `500` | How often progress is checked (EXE monitoring uses at least 1000 ms). |
| `-ExeTimeoutMinutes` | `15` | Maximum runtime for an EXE uninstaller before it is stopped. |
| `-SkipExe` | off | Only remove MSI-based apps (the original script's behavior). |
| `-ListOnly` | off | Show the uninstall plan and skipped apps, then exit without changes. |
| `-KeepLogs` | off | Keep MSI logs for successful uninstalls as well as failed ones. |

## Adding Silent Switches for an EXE Uninstaller

If an app is reported as skipped with "Unknown installer type" or "needs a response file", find its silent uninstall switches (vendor documentation, or test on a spare machine) and add an entry to the `$ExeSilentArgs` table near the top of the script:

```powershell
$ExeSilentArgs = [ordered]@{
    'Dell Optimizer'          = '-remove -runfromtemp -silent'
    'Dell Display Manager'    = '/S'
    'Dell Peripheral Manager' = '/S'
    'Dell Pair'               = '/S'
    'Dell Some New App'       = '/uninstall /quiet'   # <- your new entry
}
```

The key is a regex matched against DisplayName. The value replaces the uninstaller's own arguments, and the uninstaller EXE is taken from the app's UninstallString. The shipped entries are based on commonly used switches and should be confirmed against the versions in your fleet.

## Examples

Preview the plan (recommended first run on any new model):

```powershell
.\Remove-DellBloatware.ps1 -ListOnly
```

Remove everything with the default live summary:

```powershell
.\Remove-DellBloatware.ps1
```

Keep Dell Command | Update and touchpad drivers, and watch the full MSI logs:

```powershell
.\Remove-DellBloatware.ps1 -ExcludePattern 'Command \| Update','Touchpad' -MonitorMode Full
```

Quiet RMM run with a longer EXE timeout, keeping all logs for auditing:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Remove-DellBloatware.ps1 -MonitorMode Quiet -ExeTimeoutMinutes 30 -KeepLogs
```

## Result Statuses

**MSI uninstalls** (based on the msiexec exit code):

| msiexec code | Status | Outcome |
|---|---|---|
| 0 | Removed | OK |
| 3010 | Removed (reboot required) | OK |
| 1641 | Removed (reboot initiated) | OK |
| 1605 | Not installed | OK |
| 1618 | Failed - another install in progress | Failed |
| Anything else | Failed | Failed |

**EXE uninstalls** (based on registry verification):

| Situation | Status | Outcome |
|---|---|---|
| Registry entry gone | Removed (verified) | OK |
| Exceeded `-ExeTimeoutMinutes` | Failed - timed out | Failed |
| Uninstaller returned 0/3010/1641 but entry still present | Review | Review |
| Uninstaller returned an error and entry still present | Failed | Failed |

"Review" usually means the uninstaller finishes cleanup on the next reboot. Re-run the script after rebooting to confirm.

## Script Exit Codes

| Code | Meaning |
|---|---|
| 0 | Everything targeted was removed and nothing was skipped. |
| 1 | One or more uninstalls failed or need review. |
| 2 | No failures, but one or more Dell apps were skipped (no known silent uninstall). |

A reboot notice is printed when any uninstall reports that a restart is required.

## Logs

- **Per-app MSI logs:** `<LogDirectory>\<AppName>_<GUID>.log`. Kept on failure, or always with `-KeepLogs`.
- **Run summary:** `<LogDirectory>\Remove-DellBloatware_<yyyyMMdd_HHmmss>.log`.

## Limitations and Cautions

- **The match is broad.** Anything with "Dell" in its name is targeted, which can include Dell Command | Update, audio or touchpad drivers, and docking station firmware tools your team may want to keep. Always run `-ListOnly` on a new model first and use `-ExcludePattern` for anything that should stay.
- **EXE uninstallers vary.** The detected silent switches cover the common installer types, but some vendors add custom behavior. Test new apps on a spare machine before fleet-wide deployment.
- **Timeouts stop processes.** When an EXE uninstaller hits the timeout, its process tree is terminated. If it was mid-way through an MSI operation, Windows Installer rolls that operation back, but a partially removed app may still need manual cleanup.
- **HKCU is per-user.** When run as SYSTEM, the HKCU hive checked is SYSTEM's, not the logged-in user's, so per-user installs may not be found.
- **No automatic reboot.** `/norestart` (and equivalents) are always passed, so schedule a reboot if the summary says one is required.
