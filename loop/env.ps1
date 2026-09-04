# Windows adapter for env.sh. Returns a hashtable; does not inherit the caller's PATH.
$values = @{}
foreach ($line in [IO.File]::ReadAllLines((Join-Path $PSScriptRoot 'env.sh'))) {
    $line = $line.Trim()
    if (!$line -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '^([A-Z_]+)=(?:''([^'']*)''|([0-9]+))$') {
        throw "Invalid literal assignment in loop/env.sh: $line"
    }
    $values[$matches[1]] = if ($matches[2]) { $matches[2] } else { $matches[3] }
}
foreach ($name in @('LOOP_MODEL','LOOP_MAX_TURNS','LOOP_WAIT_SECONDS','LOOP_MAX_ROUNDS','LOOP_ROUND_TIMEOUT_SECONDS')) {
    if (!$values.ContainsKey($name)) { throw "Missing setting: $name" }
}
$runtime = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies'
# Use the complete desktop CLI bundle: the Programs shim omits sandbox helpers.
$codexDir = Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin/9ba750cce02d5e5c'
$ripgrepDir = Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin/e5208f10301fe5e6'
$paths = @(
    $codexDir
    $ripgrepDir
    (Join-Path $runtime 'native/powershell')
    (Join-Path $runtime 'node/bin')
    (Join-Path $runtime 'python')
    (Join-Path $runtime 'python/Scripts')
    (Join-Path $env:ProgramFiles 'Git/cmd')
    (Join-Path $env:ProgramFiles 'Git/usr/bin')
    (Join-Path $env:SystemRoot 'System32')
    $env:SystemRoot
    (Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0')
    (Join-Path $env:SystemRoot 'System32/Wbem')
)
@{
    Model = $values['LOOP_MODEL']
    MaxTurns = [int]$values['LOOP_MAX_TURNS']
    WaitSeconds = [int]$values['LOOP_WAIT_SECONDS']
    MaxRounds = [int]$values['LOOP_MAX_ROUNDS']
    RoundTimeoutSeconds = [int]$values['LOOP_ROUND_TIMEOUT_SECONDS']
    CodexPath = Join-Path $codexDir 'codex.exe'
    ExplicitPath = $paths -join ';'
    TaskName = 'HAVEST-AutonomousLoop'
}
