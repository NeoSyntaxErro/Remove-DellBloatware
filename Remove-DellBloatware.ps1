<#
.SYNOPSIS
    Detects and silently uninstalls Dell software (MSI and EXE based), with live monitoring.

.DESCRIPTION
    Scans the Uninstall registry keys for Dell software and builds an uninstall plan for each app:

      MSI  - msiexec /x {GUID} /qn. The MSI verbose log is tailed live.
      EXE  - The vendor uninstaller is run with silent switches (QuietUninstallString, a known
             Dell override, or switches for the detected installer type: NSIS, Inno Setup,
             InstallShield Suite). The uninstaller's process tree is watched live, a timeout
             stops hung uninstallers, and removal is verified against the registry afterwards.

    EXE uninstalls run first because suite uninstallers often remove their own MSI components.
    Apps whose silent switches cannot be determined are skipped and reported, never run
    interactively (an interactive prompt would hang forever under an RMM/SYSTEM context).

.PARAMETER LogDirectory
    Folder for the per-app MSI logs and the run summary log. Created if missing.

.PARAMETER NamePattern
    Regex used to match DisplayName in the Uninstall registry keys. Default matches the word "Dell".

.PARAMETER ExcludePattern
    One or more regex patterns. Any matching app is skipped (e.g. 'Command \| Update', 'Touchpad').

.PARAMETER MonitorMode
    Summary (default) - MSI: actions, product messages, errors. EXE: processes starting/finishing.
    Full              - MSI: every log line. EXE: same as Summary.
    Quiet             - progress bars only.

.PARAMETER ExeTimeoutMinutes
    Maximum time an EXE uninstaller (and its child processes) may run before being stopped.

.PARAMETER SkipExe
    Only remove MSI-based apps (the original script's behavior).

.PARAMETER ListOnly
    Show the uninstall plan and exit without uninstalling anything.

.PARAMETER KeepLogs
    Keep MSI logs for successful uninstalls too (failed logs are always kept).

.EXAMPLE
    .\Remove-DellBloatware.ps1 -ListOnly

.EXAMPLE
    .\Remove-DellBloatware.ps1 -ExcludePattern 'Command \| Update','Touchpad' -MonitorMode Full

.NOTES
    Scripted by: Steffen Teall

    Repo: https://github.com/NeoSyntaxErro/Remove-DellBloatware

    Run directly from GitHub (elevated PowerShell, no download needed):
      Defaults:        irm https://raw.githubusercontent.com/NeoSyntaxErro/Remove-DellBloatware/main/Remove-DellBloatware.ps1 | iex
      With parameters: & ([scriptblock]::Create((irm https://raw.githubusercontent.com/NeoSyntaxErro/Remove-DellBloatware/main/Remove-DellBloatware.ps1))) -ListOnly

    Exit codes: 0 = all removed, 1 = one or more failed / need review, 2 = no failures but some apps skipped.
#>
[CmdletBinding()]
param(
    [string]$LogDirectory = "C:\RobTech\DellUninstall",   # Assumed MSP directory
    [string]$NamePattern = '\bDell\b',
    [string[]]$ExcludePattern = @(),
    [ValidateSet('Summary', 'Full', 'Quiet')]
    [string]$MonitorMode = 'Summary',
    [int]$PollMilliseconds = 500,
    [int]$ExeTimeoutMinutes = 15,
    [switch]$SkipExe,
    [switch]$ListOnly,
    [switch]$KeepLogs
)

# True when run as a .ps1 file; False when run via iex or a scriptblock.
# Used at the end so remote runs don't close the PowerShell window.
$RunningAsFile = [bool]$MyInvocation.MyCommand.Path

#region Configuration -------------------------------------------------------------------------
# Known silent arguments for Dell EXE uninstallers.
#   Key   = regex matched against DisplayName
#   Value = arguments passed to the uninstaller EXE from UninstallString (replaces its own args)
# Add entries here when an app is reported as "Skipped - unknown installer type".
# Verify new entries on a test machine first.
$ExeSilentArgs = [ordered]@{
    'Dell Optimizer'          = '-remove -runfromtemp -silent'
    'Dell Display Manager'    = '/S'
    'Dell Peripheral Manager' = '/S'
    'Dell Pair'               = '/S'
}

$guidCore  = '[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}'
$guidRegex = "(?i)\bmsiexec(\.exe)?\b.*?\{(?<guid>$guidCore)\}"
#endregion

#region Logging helper ---------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = "$(Get-Date -Format 'HH:mm:ss') - $Message"
    Write-Host $line -ForegroundColor $Color
    Add-Content -LiteralPath $SummaryLog -Value $line
}
#endregion


#region Planning helpers ----------------------------------------------------------------------
# Splits an uninstall command into the EXE path and its arguments.
# Handles quoted paths and unquoted paths containing spaces.
function Split-CommandLine {
    param([string]$CommandLine)
    $cmd = $CommandLine.Trim()
    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        if ($end -lt 0) { return $null }
        return [pscustomobject]@{
            FilePath  = $cmd.Substring(1, $end - 1)
            Arguments = $cmd.Substring($end + 1).Trim()
        }
    }
    $m = [regex]::Match($cmd, '^(?<exe>.+?\.exe)(?:\s+(?<args>.*))?$', 'IgnoreCase')
    if ($m.Success) {
        return [pscustomobject]@{
            FilePath  = $m.Groups['exe'].Value
            Arguments = $m.Groups['args'].Value.Trim()
        }
    }
    return $null
}

function Set-Plan {
    param(
        [System.Collections.IDictionary]$Plan,
        [string]$Type, [string]$Method, [string]$Reason,
        [string]$Guid, [string]$FilePath, [string]$Arguments
    )
    foreach ($key in $PSBoundParameters.Keys) {
        if ($key -ne 'Plan') { $Plan[$key] = $PSBoundParameters[$key] }
    }
    [pscustomobject]$Plan
}

# Decides HOW an app will be uninstalled. Order of preference:
#   1. msiexec + GUID in the uninstall command
#   2. EXE-wrapped MSI (registry key is the product code and WindowsInstaller = 1)
#   3. QuietUninstallString supplied by the vendor
#   4. Known Dell override from $ExeSilentArgs
#   5. Silent switches for the detected installer type
function Get-UninstallPlan {
    param($App)

    $plan = [ordered]@{
        DisplayName  = $App.DisplayName
        Version      = $App.DisplayVersion
        Type         = $null      # MSI | EXE | Skip
        Method       = $null
        Guid         = $null
        FilePath     = $null
        Arguments    = $null
        RegistryPath = $App.PSPath
        Reason       = $null
    }

    $cmd = if ($App.QuietUninstallString) { $App.QuietUninstallString } else { $App.UninstallString }

    # 1. Standard MSI
    if ($cmd) {
        $m = [regex]::Match($cmd, $guidRegex)
        if ($m.Success) {
            return Set-Plan $plan -Type MSI -Method 'msiexec' -Guid ('{' + $m.Groups['guid'].Value.ToUpper() + '}')
        }
    }

    # 2. MSI hidden behind a setup.exe wrapper
    if ($App.WindowsInstaller -eq 1 -and $App.PSChildName -match "^\{$guidCore\}$") {
        return Set-Plan $plan -Type MSI -Method 'msiexec (wrapped)' -Guid $App.PSChildName.ToUpper()
    }

    if ([string]::IsNullOrWhiteSpace($cmd)) { return Set-Plan $plan -Type Skip -Reason 'No uninstall command in registry' }
    if ($SkipExe)                           { return Set-Plan $plan -Type Skip -Reason 'EXE uninstall disabled (-SkipExe)' }

    # 3. Vendor-supplied silent command
    if ($App.QuietUninstallString) {
        $parsed = Split-CommandLine $App.QuietUninstallString
        if ($parsed) {
            return Set-Plan $plan -Type EXE -Method 'QuietUninstallString' -FilePath $parsed.FilePath -Arguments $parsed.Arguments
        }
    }

    $parsed = Split-CommandLine $App.UninstallString
    if (-not $parsed) { return Set-Plan $plan -Type Skip -Reason "Could not parse uninstall command: $($App.UninstallString)" }

    $exeName = Split-Path -Path $parsed.FilePath -Leaf
    $exeArgs = $parsed.Arguments

    if ($exeName -match '^(rundll32|cmd|powershell|wscript|cscript)(\.exe)?$') {
        return Set-Plan $plan -Type Skip -Reason "Unsupported uninstall host ($exeName)"
    }

    # 4. Known Dell overrides
    foreach ($pattern in $ExeSilentArgs.Keys) {
        if ($App.DisplayName -match $pattern) {
            return Set-Plan $plan -Type EXE -Method 'Dell override' -FilePath $parsed.FilePath -Arguments $ExeSilentArgs[$pattern]
        }
    }

    # 5. Installer-type detection
    $isInstallShieldPath = $parsed.FilePath -match 'InstallShield Installation Information'

    if ($exeName -match '^unins\d{3}\.exe$') {
        return Set-Plan $plan -Type EXE -Method 'Inno Setup' -FilePath $parsed.FilePath `
            -Arguments ("$exeArgs /VERYSILENT /SUPPRESSMSGBOXES /NORESTART").Trim()
    }
    if ($exeArgs -match '(?i)-remove\b' -and ($exeArgs -match '(?i)-runfromtemp' -or $isInstallShieldPath)) {
        return Set-Plan $plan -Type EXE -Method 'InstallShield Suite' -FilePath $parsed.FilePath `
            -Arguments ("$exeArgs -silent").Trim()
    }
    if ($isInstallShieldPath -or $exeArgs -match '(?i)-removeonly|-l0x') {
        return Set-Plan $plan -Type Skip -Reason 'InstallShield InstallScript uninstaller needs a response file - add an override'
    }
    if ($exeName -match '^(uninst|uninstall|uninstaller)\.exe$') {
        return Set-Plan $plan -Type EXE -Method 'NSIS' -FilePath $parsed.FilePath -Arguments ("$exeArgs /S").Trim()
    }

    return Set-Plan $plan -Type Skip -Reason "Unknown installer type ($exeName) - add an entry to `$ExeSilentArgs"
}
#endregion

#region Monitoring helpers --------------------------------------------------------------------
# Tails an MSI log while msiexec runs.
function Watch-MsiLog {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$LogFile,
        [string]$AppName,
        [string]$Mode,
        [int]$PollMs
    )

    $reader       = $null
    $actionCount  = 0
    $currentStep  = 'Starting...'
    $stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()
    $summaryRegex = '(?i)(Action start \d|Product: |Return value 3|\bError \d{4}\b)'
    $actionRegex  = 'Action start [\d:]+: (?<action>[^.]+)\.'

    try {
        while ($true) {
            # Capture exit state BEFORE reading so the final lines are drained after exit.
            $exited = $Process.HasExited

            # Open the log once it exists. Share flags let msiexec keep writing while we read.
            if (-not $reader -and (Test-Path -LiteralPath $LogFile)) {
                try {
                    $fs = [System.IO.File]::Open($LogFile, [System.IO.FileMode]::Open,
                          [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite, Delete')
                    # $true = auto-detect encoding from BOM (MSI logs are often UTF-16)
                    $reader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
                } catch {
                    $reader = $null   # File still locked/being created; try again next poll
                }
            }

            # Read only the NEW lines since the last poll.
            if ($reader) {
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }

                    $m = [regex]::Match($line, $actionRegex)
                    if ($m.Success) {
                        $actionCount++
                        $currentStep = $m.Groups['action'].Value
                    }

                    $show = switch ($Mode) {
                        'Full'    { $true }
                        'Summary' { $line -match $summaryRegex }
                        default   { $false }
                    }
                    if ($show) {
                        $color = if ($line -match '(?i)Return value 3|\bError \d{4}\b') { 'Red' }
                                 elseif ($line -match 'Product: ') { 'Green' }
                                 else { 'DarkGray' }
                        Write-Host "$(Get-Date -Format 'HH:mm:ss') - $line" -ForegroundColor $color
                    }
                }
            }

            Write-Progress -Id 2 -ParentId 1 -Activity $AppName `
                -Status ("Elapsed {0:mm\:ss} | Actions run: {1}" -f $stopwatch.Elapsed, $actionCount) `
                -CurrentOperation $currentStep

            if ($exited) { break }
            Start-Sleep -Milliseconds $PollMs
        }
    } finally {
        if ($reader) { $reader.Dispose() }
        Write-Progress -Id 2 -Activity $AppName -Completed
    }
}

# Watches an EXE uninstaller and every process it spawns until all have exited.
# Needed because many uninstallers (NSIS, Inno Setup) copy themselves to %TEMP%,
# relaunch, and exit immediately - waiting on the original process alone returns too early.
function Watch-ExeProcessTree {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ExeName,
        [string]$AppName,
        [string]$Mode,
        [int]$PollMs,
        [int]$TimeoutMinutes
    )

    $tracked   = @{ $Process.Id = @{ Name = $ExeName; Created = $null } }   # PID -> name + creation time
    $finished  = @{}
    $startTime = (Get-Date).AddSeconds(-5)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollMs    = [Math]::Max($PollMs, 1000)   # CIM queries are heavier than reading a log file
    $timedOut  = $false

    while ($true) {
        # Check the root BEFORE the snapshot, so any child it spawned before exiting is in the snapshot.
        $rootExited = $Process.HasExited
        $snapshot   = @(Get-CimInstance -ClassName Win32_Process `
                        -Property ProcessId, ParentProcessId, Name, CreationDate -ErrorAction SilentlyContinue)

        # Adopt new descendants (repeat so grandchildren are found in the same pass).
        do {
            $found = $false
            foreach ($p in $snapshot) {
                $procId = [int]$p.ProcessId
                if ($tracked.ContainsKey($procId)) { continue }
                if ($tracked.ContainsKey([int]$p.ParentProcessId) -and $p.CreationDate -ge $startTime) {
                    $tracked[$procId] = @{ Name = $p.Name; Created = $p.CreationDate }
                    $found = $true
                    if ($Mode -ne 'Quiet') {
                        Write-Host "$(Get-Date -Format 'HH:mm:ss') - Started:  $($p.Name) (PID $procId)" -ForegroundColor DarkGray
                    }
                }
            }
        } while ($found)

        # Which tracked processes are still running? (CreationDate check guards against PID reuse.)
        $alive = @(foreach ($p in $snapshot) {
            $procId = [int]$p.ProcessId
            if ($procId -eq $Process.Id) {
                if (-not $rootExited) { $p }
            } elseif ($tracked.ContainsKey($procId) -and $tracked[$procId].Created -eq $p.CreationDate) {
                $p
            }
        })
        $aliveIds = @($alive | ForEach-Object { [int]$_.ProcessId })

        foreach ($procId in @($tracked.Keys)) {
            if (-not $finished.ContainsKey($procId) -and $aliveIds -notcontains $procId) {
                if ($procId -eq $Process.Id -and -not $rootExited) { continue }
                $finished[$procId] = $true
                if ($Mode -ne 'Quiet') {
                    Write-Host "$(Get-Date -Format 'HH:mm:ss') - Finished: $($tracked[$procId].Name) (PID $procId)" -ForegroundColor DarkGray
                }
            }
        }

        $running = ($alive | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', '
        if (-not $running) { $running = '(finishing)' }
        Write-Progress -Id 2 -ParentId 1 -Activity $AppName `
            -Status ("Elapsed {0:mm\:ss} | Processes seen: {1}" -f $stopwatch.Elapsed, $tracked.Count) `
            -CurrentOperation "Running: $running"

        if ($rootExited -and $alive.Count -eq 0) { break }

        if ($stopwatch.Elapsed.TotalMinutes -ge $TimeoutMinutes) {
            $timedOut = $true
            foreach ($p in $alive) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
            if (-not $Process.HasExited) { try { $Process.Kill() } catch { } }
            break
        }

        Start-Sleep -Milliseconds $pollMs
    }

    Write-Progress -Id 2 -Activity $AppName -Completed
    [pscustomobject]@{ TimedOut = $timedOut; ProcessCount = $tracked.Count }
}
#endregion

#region Main ---------------------------------------------------------------------------------
# Everything runs inside a scriptblock so it can 'return' an exit code instead of calling 'exit',
# which would close the PowerShell window when the script is run via iex from GitHub.
$scriptExitCode = @(& {
    # Admin check (explicit instead of #Requires, which does not apply when run via iex).
    $isAdmin = try {
        ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
    if (-not $isAdmin) {
        Write-Host "This script must be run as Administrator (or SYSTEM)." -ForegroundColor Red
        return 1
    }

    # Log directory and run summary log
    if (-not (Test-Path -LiteralPath $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }
    $SummaryLog = Join-Path $LogDirectory ("Remove-DellBloatware_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    #region Detection -----------------------------------------------------------------------------
    $paths = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    Write-Log "Scanning registry for software matching '$NamePattern'..." Cyan

    $software = foreach ($path in $paths) {
        Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -match $NamePattern } |
            Select-Object DisplayName, DisplayVersion, UninstallString, QuietUninstallString,
                          WindowsInstaller, PSChildName, PSPath
    }

    if ($ExcludePattern.Count -gt 0) {
        $software = $software | Where-Object {
            $name = $_.DisplayName
            $hit  = $ExcludePattern | Where-Object { $name -match $_ } | Select-Object -First 1
            if ($hit) { Write-Log "Excluded: $name (matched '$hit')" DarkYellow; $false } else { $true }
        }
    }

    $plans = @(foreach ($app in $software) { Get-UninstallPlan -App $app })

    # Confirm EXE uninstallers actually exist on disk.
    foreach ($p in $plans | Where-Object Type -eq 'EXE') {
        $expanded = [Environment]::ExpandEnvironmentVariables($p.FilePath)
        if (Test-Path -LiteralPath $expanded) {
            $p.FilePath = $expanded
        } else {
            $p.Type   = 'Skip'
            $p.Reason = "Uninstaller not found: $($p.FilePath)"
        }
    }

    # De-duplicate (same product can be listed under more than one hive).
    # EXE uninstalls run first: suite uninstallers often remove their own MSI components.
    $queue = @($plans | Where-Object Type -ne 'Skip' |
        Group-Object { if ($_.Type -eq 'MSI') { $_.Guid } else { "$($_.FilePath)|$($_.Arguments)" } } |
        ForEach-Object { $_.Group[0] } |
        Sort-Object @{ Expression = { $_.Type -eq 'MSI' } }, DisplayName)

    $skipped = @($plans | Where-Object Type -eq 'Skip' | Sort-Object DisplayName -Unique)

    if ($queue.Count -gt 0) {
        Write-Log "Uninstall plan ($($queue.Count) app(s)):" Cyan
        $queue | Select-Object Type, Method, DisplayName, Version,
            @{ n = 'Target'; e = { if ($_.Type -eq 'MSI') { $_.Guid } else { "`"$($_.FilePath)`" $($_.Arguments)" } } } |
            Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
    }

    if ($skipped.Count -gt 0) {
        Write-Log "Skipping $($skipped.Count) app(s) that cannot be removed silently:" DarkYellow
        $skipped | Select-Object DisplayName, Reason | Format-Table -AutoSize -Wrap | Out-String -Width 250 | Write-Host
    }

    if ($ListOnly) {
        Write-Log "-ListOnly specified. No changes made." Yellow
        return 0
    }

    if ($queue.Count -eq 0) {
        Write-Log "No removable Dell software found. Nothing to do." Green
        if ($skipped.Count -gt 0) { return 2 } else { return 0 }
    }
    #endregion

    #region Uninstall + Monitor -------------------------------------------------------------------
    $results      = [System.Collections.Generic.List[object]]::new()
    $rebootNeeded = $false
    $total        = $queue.Count
    $i            = 0

    foreach ($item in $queue) {
        $i++
        Write-Progress -Id 1 -Activity 'Removing Dell software' `
            -Status "[$i/$total] $($item.DisplayName)" -PercentComplete ((($i - 1) / $total) * 100)
        Write-Log "[$i/$total] [$($item.Type)] Uninstalling $($item.DisplayName)" Cyan

        # An earlier suite uninstaller may already have removed this one.
        if (-not (Test-Path -LiteralPath $item.RegistryPath)) {
            Write-Log "  Already removed (likely by an earlier uninstaller in this run)." Green
            $results.Add([pscustomobject]@{
                Type = $item.Type; DisplayName = $item.DisplayName; Outcome = 'OK'
                Status = 'Already removed'; ExitCode = $null; Seconds = 0
            })
            continue
        }

        $timer = [System.Diagnostics.Stopwatch]::StartNew()

        if ($item.Type -eq 'MSI') {
            # ---------------- MSI ----------------
            $safeName = $item.DisplayName -replace '[^\w\-\.]+', '_'
            $appLog   = Join-Path $LogDirectory ("{0}_{1}.log" -f $safeName, $item.Guid.Trim('{}'))
            Remove-Item -LiteralPath $appLog -ErrorAction Ignore

            # /L*v! = verbose log, flushed line-by-line so the live monitor sees output immediately.
            $msiArgs = "/x $($item.Guid) /qn /norestart /L*v! `"$appLog`""
            $proc    = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -PassThru
            $null    = $proc.Handle   # Caches the handle so ExitCode is populated (known PowerShell quirk)

            Watch-MsiLog -Process $proc -LogFile $appLog -AppName $item.DisplayName `
                         -Mode $MonitorMode -PollMs $PollMilliseconds

            $proc.WaitForExit()
            $timer.Stop()
            $exitCode = $proc.ExitCode

            $status = switch ($exitCode) {
                0       { 'Removed' }
                3010    { 'Removed (reboot required)' }
                1641    { 'Removed (reboot initiated)' }
                1605    { 'Not installed' }
                1618    { 'Failed - another install in progress' }
                default { 'Failed' }
            }
            $outcome = if ($exitCode -in 0, 1605, 1641, 3010) { 'OK' } else { 'Failed' }
            if ($exitCode -in 1641, 3010) { $rebootNeeded = $true }

            if ($outcome -eq 'OK') {
                if (-not $KeepLogs) { Remove-Item -LiteralPath $appLog -ErrorAction Ignore }
            } elseif (Test-Path -LiteralPath $appLog) {
                # Show the lines leading up to the first failure instead of dumping the whole log.
                $content = @(Get-Content -LiteralPath $appLog)
                $hit     = $content | Select-String -Pattern 'Return value 3' | Select-Object -First 1
                $excerpt = if ($hit) {
                    $content[[Math]::Max(0, $hit.LineNumber - 21)..($hit.LineNumber - 1)]
                } else {
                    $content | Select-Object -Last 25
                }
                Write-Host "  ---- Log excerpt ($appLog) ----" -ForegroundColor DarkYellow
                $excerpt | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkYellow }
                Write-Host "  ---------------------" -ForegroundColor DarkYellow
            }
        }
        else {
            # ---------------- EXE ----------------
            Write-Log "  Method: $($item.Method) | `"$($item.FilePath)`" $($item.Arguments)" DarkGray

            $startParams = @{
                FilePath         = $item.FilePath
                WorkingDirectory = Split-Path -Path $item.FilePath -Parent
                WindowStyle      = 'Hidden'
                PassThru         = $true
            }
            if ($item.Arguments) { $startParams.ArgumentList = $item.Arguments }

            try {
                $proc = Start-Process @startParams -ErrorAction Stop
                $null = $proc.Handle
            } catch {
                $timer.Stop()
                Write-Log "  Failed to start uninstaller: $($_.Exception.Message)" Red
                $results.Add([pscustomobject]@{
                    Type = 'EXE'; DisplayName = $item.DisplayName; Outcome = 'Failed'
                    Status = 'Failed - could not start'; ExitCode = $null; Seconds = 0
                })
                continue
            }

            $watch = Watch-ExeProcessTree -Process $proc -ExeName (Split-Path $item.FilePath -Leaf) `
                        -AppName $item.DisplayName -Mode $MonitorMode -PollMs $PollMilliseconds `
                        -TimeoutMinutes $ExeTimeoutMinutes
            $timer.Stop()
            $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { $null }

            # EXE exit codes are unreliable, so verify against the registry.
            Start-Sleep -Seconds 2
            $stillPresent = Test-Path -LiteralPath $item.RegistryPath

            if ($watch.TimedOut) {
                $status  = "Failed - timed out after $ExeTimeoutMinutes min (likely waiting on a hidden prompt)"
                $outcome = 'Failed'
            } elseif (-not $stillPresent) {
                $status  = 'Removed (verified)'
                $outcome = 'OK'
                if ($exitCode -in 1641, 3010) { $status = 'Removed (reboot required)'; $rebootNeeded = $true }
            } elseif ($exitCode -in 0, 1641, 3010) {
                $status  = 'Review - uninstaller reported success but entry still present (may clear after reboot)'
                $outcome = 'Review'
                if ($exitCode -in 1641, 3010) { $rebootNeeded = $true }
            } else {
                $status  = 'Failed'
                $outcome = 'Failed'
            }
        }

        $color = switch ($outcome) { 'OK' { 'Green' } 'Review' { 'Yellow' } default { 'Red' } }
        Write-Log "  ExitCode $exitCode - $status ($([int]$timer.Elapsed.TotalSeconds)s)" $color

        $results.Add([pscustomobject]@{
            Type        = $item.Type
            DisplayName = $item.DisplayName
            Outcome     = $outcome
            Status      = $status
            ExitCode    = $exitCode
            Seconds     = [int]$timer.Elapsed.TotalSeconds
        })
    }

    Write-Progress -Id 1 -Activity 'Removing Dell software' -Completed
    #endregion

    #region Summary -------------------------------------------------------------------------------
    foreach ($s in $skipped) {
        $results.Add([pscustomobject]@{
            Type = '-'; DisplayName = $s.DisplayName; Outcome = 'Skipped'
            Status = $s.Reason; ExitCode = $null; Seconds = 0
        })
    }

    $failed = @($results | Where-Object { $_.Outcome -in 'Failed', 'Review' })

    Write-Log "===== Results =====" Cyan
    $results | Format-Table -AutoSize -Wrap | Out-String -Width 250 |
        Tee-Object -FilePath $SummaryLog -Append | Write-Host

    if ($rebootNeeded) { Write-Log "One or more uninstalls require a reboot to finish." Yellow }
    Write-Log "Summary log: $SummaryLog" Gray

    if ($failed.Count -gt 0) {
        Write-Log "$($failed.Count) of $total uninstall(s) failed or need review." Red
        return 1
    }
    if ($skipped.Count -gt 0) {
        Write-Log "All $total uninstall(s) succeeded, but $($skipped.Count) app(s) were skipped." Yellow
        return 2
    }
    Write-Log "All $total uninstall(s) completed successfully." Green
    return 0
    #endregion
})[-1]
#endregion

if ($RunningAsFile) { exit $scriptExitCode }   # .ps1 file (RMM, scheduled task): real process exit code
$global:LASTEXITCODE = $scriptExitCode          # iex / scriptblock: keep the session open
