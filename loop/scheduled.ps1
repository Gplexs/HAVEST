# Task Scheduler entry point: never depend on the interactive terminal's PATH.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    $configuration = & (Join-Path $PSScriptRoot 'env.ps1')
    if ([string]::IsNullOrWhiteSpace([string]$configuration.ExplicitPath)) {
        throw 'ExplicitPath must be set in loop/env.ps1.'
    }
    $env:PATH = [string]$configuration.ExplicitPath
    Set-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot 'loop.ps1')
    $runnerExitCode = $LASTEXITCODE
    if ($null -eq $runnerExitCode) { $runnerExitCode = 0 }
    exit [int]$runnerExitCode
}
catch {
    $failureMessage = '[{0:o}] Scheduled entry failed: {1}' -f [DateTime]::UtcNow, $_.Exception.Message
    try {
        $logDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
        New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $logDirectory ('scheduler-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))) -Value $failureMessage -Encoding UTF8
    }
    catch { }
    [Console]::Error.WriteLine($failureMessage)
    exit 1
}
