# Windows Task Scheduler registration and graceful lifecycle control.
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Register', 'On', 'Off', 'Status')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$taskName = 'HAVEST-AutonomousLoop'
$configurationWarning = $null
try {
    $configuration = & (Join-Path $PSScriptRoot 'env.ps1')
    if ([string]::IsNullOrWhiteSpace([string]$configuration.TaskName)) {
        throw 'TaskName must be set in loop/env.ps1.'
    }
    $taskName = [string]$configuration.TaskName
}
catch {
    if ($Action -notin @('Off', 'Status')) { throw }
    $configurationWarning = "Could not load loop configuration: $($_.Exception.Message) Using fallback task name '$taskName'; task ownership will still be checked."
    Write-Warning $configurationWarning
}
$taskPath = '\'
$stopPath = Join-Path $PSScriptRoot 'STOP'
$scheduledScript = Join-Path $PSScriptRoot 'scheduled.ps1'

Import-Module ScheduledTasks -ErrorAction Stop

function Get-LoopTask {
    Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
}

function Assert-OwnedTask {
    param($Task)
    if ($null -eq $Task) { return }
    $matches = @($Task.Actions | Where-Object {
        $_.Arguments -and
        $_.Arguments.IndexOf($scheduledScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
    })
    if ($matches.Count -eq 0) {
        throw "Task '$taskName' already belongs to another command. Choose another TaskName in loop/env.ps1."
    }
}

function Get-AbsolutePowerShell {
    $candidates = @(
        (Join-Path $PSHOME 'pwsh.exe')
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe')
    )
    $pwshCommand = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $pwshCommand) { $candidates += $pwshCommand.Source }
    $candidates += Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw 'No PowerShell executable was found.'
}

function Show-LoopStatus {
    $currentTask = Get-LoopTask
    $information = if ($null -ne $currentTask) {
        Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath
    } else { $null }
    $lockPath = Join-Path $repositoryRoot 'logs\loop.lock'
    $lockHeld = $false
    $lockNote = $null
    if (Test-Path -LiteralPath $lockPath) {
        try {
            $probe = [IO.File]::Open($lockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $probe.Dispose()
        }
        catch [IO.IOException] { $lockHeld = $true }
        catch { $lockHeld = $null; $lockNote = $_.Exception.Message }
    }
    $runState = $null
    $statePath = Join-Path $repositoryRoot 'logs\loop-state.json'
    if (Test-Path -LiteralPath $statePath) {
        try { $runState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
        catch { $lockNote = 'Run state is being updated or cannot be read.' }
    }
    $neverRun = $null -ne $information -and $information.LastTaskResult -eq 267011
    [pscustomobject]@{
        TaskName = $taskName
        ConfigurationWarning = $configurationWarning
        Registered = ($null -ne $currentTask)
        State = if ($null -ne $currentTask) { [string]$currentTask.State } else { 'NotRegistered' }
        Enabled = if ($null -ne $currentTask) { [bool]$currentTask.Settings.Enabled } else { $false }
        LastResult = if ($null -ne $information) { $information.LastTaskResult } else { $null }
        LastResultMeaning = if ($null -eq $information) { 'NotRegistered' } elseif ($neverRun) { 'NeverRun' } elseif ($information.LastTaskResult -eq 0) { 'Succeeded' } elseif ($information.LastTaskResult -eq 267009) { 'Running' } else { 'See Task Scheduler result code' }
        LastRun = if ($null -ne $information -and -not $neverRun) { $information.LastRunTime } else { $null }
        NextRun = if ($null -ne $information) { $information.NextRunTime } else { $null }
        StopRequested = Test-Path -LiteralPath $stopPath
        LoopLockHeld = $lockHeld
        LockNote = $lockNote
        LastRecordedRun = $runState
        Repository = $repositoryRoot
        Executable = if ($null -ne $currentTask) { ($currentTask.Actions.Execute -join ', ') } else { $null }
        RestartInterval = if ($null -ne $currentTask) { $currentTask.Settings.RestartInterval } else { $null }
        RestartCount = if ($null -ne $currentTask) { $currentTask.Settings.RestartCount } else { $null }
        ExecutionTimeLimit = if ($null -ne $currentTask) { $currentTask.Settings.ExecutionTimeLimit } else { $null }
    }
}

$existingTask = Get-LoopTask
Assert-OwnedTask -Task $existingTask

switch ($Action) {
    'Register' {
        if ($null -ne $existingTask -and [string]$existingTask.State -eq 'Running') {
            throw 'The task is running. Use Off, wait for the current round to finish, then Register.'
        }
        $powerShellExecutable = Get-AbsolutePowerShell
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scheduledScript
        $taskAction = New-ScheduledTaskAction -Execute $powerShellExecutable -Argument $arguments -WorkingDirectory $repositoryRoot
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity
        $principal = New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -Disable -Hidden `
            -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 999 `
            -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -DisallowHardTerminate -StartWhenAvailable
        $definition = New-ScheduledTask -Action $taskAction -Trigger $trigger -Principal $principal `
            -Settings $settings -Description "Autonomous development loop for $repositoryRoot. Controlled by loop/control.ps1."
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -InputObject $definition -Force | Out-Null
        Write-Host "Registered '$taskName' disabled. No round has been started."
    }
    'On' {
        if ($null -eq $existingTask) { throw 'Register the task first: .\loop\control.ps1 Register' }
        if (Test-Path -LiteralPath $stopPath) { Remove-Item -LiteralPath $stopPath -Force }
        Enable-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null
        Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath
        Write-Host "Enabled and started '$taskName'."
    }
    'Off' {
        Set-Content -LiteralPath $stopPath -Value ('Stop requested at {0:o}' -f [DateTime]::UtcNow) -Encoding UTF8
        if ($null -ne $existingTask) {
            Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath | Out-Null
        }
        Write-Host 'STOP created and automatic starts disabled. An active round will finish before the loop exits.'
    }
    'Status' { }
}

Show-LoopStatus
