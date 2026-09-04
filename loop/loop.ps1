[CmdletBinding()]
param(
    [switch]$SmokeTest,
    [ValidateRange(0, 2147483647)][int]$MaxRounds = 0,
    [ValidateRange(0, 86400)][int]$WaitSeconds = 0
)

# Support the Windows PowerShell command shown in README; the worker needs .NET 6+.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    $workerShell = Join-Path $env:USERPROFILE '.cache/codex-runtimes/codex-primary-runtime/dependencies/native/powershell/pwsh.exe'
    if (!(Test-Path -LiteralPath $workerShell)) { throw 'PowerShell 7 is required. Install it or update the workerShell path.' }
    & $workerShell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @PSBoundParameters
    exit $LASTEXITCODE
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$logRoot = Join-Path $projectRoot 'logs'
$stopFile = Join-Path $PSScriptRoot 'STOP'
$stateFile = Join-Path $logRoot 'loop-state.json'
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + $PID
$runLog = $null
$lockStream = $null
$child = $null
$childStarted = $false
$exitCode = 0
$round = 0
$mode = if ($SmokeTest) { 'smoke' } else { 'development' }
$state = [ordered]@{ pid=$PID; runId=$runId; startedAt=(Get-Date).ToString('o'); mode=$mode; round=0; codexPid=$null; status='starting' }

function Write-LoopLog([string]$Message) {
    $entry = '{0} {1}' -f (Get-Date).ToString('o'), $Message
    Write-Host $entry
    if ($runLog) { [IO.File]::AppendAllText($runLog, $entry + [Environment]::NewLine, [Text.UTF8Encoding]::new($false)) }
}

function Save-LoopState {
    # Atomic replacement lets Status read while a round is starting/stopping.
    $temporary = $stateFile + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $stateFile, $true)
}

function Read-CodexEvent([string]$Line, [hashtable]$Stats, [int]$TurnLimit) {
    if (!$Line.Trim()) { return }
    try { $event = ConvertFrom-Json -InputObject $Line -AsHashtable } catch { throw 'Codex emitted invalid JSON; inspect the events log.' }
    switch ($event.type) {
        'thread.started' {
            $Stats.threadId = $event.thread_id
            Write-LoopLog "ROUND $round THREAD $($Stats.threadId)"
        }
        'turn.started' {
            $Stats.turns++
            if ($Stats.turns -gt $TurnLimit) { throw "Turn limit exceeded: $TurnLimit" }
        }
        'turn.completed' { $Stats.completed++; $Stats.usage = $event.usage }
        'turn.failed' { $Stats.failed = $true }
        'item.completed' {
            if ($event.item.type -eq 'agent_message') { $Stats.lastMessage = $event.item.text }
        }
    }
}

try {
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
    # The OS releases this exclusive lock after a crash. The file itself may remain.
    try { $lockStream = [IO.File]::Open((Join-Path $logRoot 'loop.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { Write-Host 'Another loop owns logs/loop.lock; no duplicate runner started.'; exit 0 }

    $dailyLog = Join-Path $logRoot (Get-Date -Format 'yyyy-MM-dd')
    New-Item -ItemType Directory -Path $dailyLog -Force | Out-Null
    $runLog = Join-Path $dailyLog "$runId-$mode.log"
    Write-LoopLog "RUN START mode=$mode pid=$PID"
    $settings = & (Join-Path $PSScriptRoot 'env.ps1')
    $env:PATH = $settings.ExplicitPath
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GCM_INTERACTIVE = 'Never'
    $limit = if ($PSBoundParameters.ContainsKey('MaxRounds')) { $MaxRounds } else { $settings.MaxRounds }
    $delay = if ($PSBoundParameters.ContainsKey('WaitSeconds')) { $WaitSeconds } else { $settings.WaitSeconds }
    if ($SmokeTest -and !$PSBoundParameters.ContainsKey('MaxRounds')) { $limit = 2 }
    if ($SmokeTest -and $limit -eq 0) { throw 'SmokeTest needs a finite MaxRounds.' }
    if ($settings.MaxTurns -lt 1 -or $settings.RoundTimeoutSeconds -lt 1 -or $limit -lt 0 -or $delay -lt 0) { throw 'Invalid loop settings.' }
    if (!(Test-Path -LiteralPath $settings.CodexPath -PathType Leaf)) { throw "Codex executable missing: $($settings.CodexPath)" }
    foreach ($relative in @('loop/PROMPT.md','docs/feedback/INBOX.md','docs/DESIGN.md','docs/STATUS.md')) {
        if (!(Test-Path -LiteralPath (Join-Path $projectRoot $relative) -PathType Leaf)) { throw "Required file missing: $relative" }
    }
    & git -C $projectRoot rev-parse --verify HEAD 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Initialize Git and create the first commit before running the loop.' }
    Write-LoopLog "CONFIG model=$($settings.Model) maxTurns=$($settings.MaxTurns) maxRounds=$limit waitSeconds=$delay timeoutSeconds=$($settings.RoundTimeoutSeconds)"
    Save-LoopState

    while ($true) {
        if (Test-Path -LiteralPath $stopFile) { Write-LoopLog 'STOP observed; normal exit.'; break }
        if ($limit -gt 0 -and $round -ge $limit) { Write-LoopLog "MAX_ROUNDS reached: $limit; normal exit."; break }
        $round++
        $dailyLog = Join-Path $logRoot (Get-Date -Format 'yyyy-MM-dd')
        New-Item -ItemType Directory -Path $dailyLog -Force | Out-Null
        $base = Join-Path $dailyLog ('{0}-{1}-round-{2:D4}' -f $runId, $mode, $round)
        $stats = @{ threadId=$null; turns=0; completed=0; failed=$false; lastMessage=''; usage=$null }
        $roundStart = Get-Date
        $roundExit = 1
        $stdoutWriter = $null
        $stderrWriter = $null
        $roundError = $null

        # This is a NEW process and a NEW thread on every iteration. Never resume/fork.
        $prompt = "Read loop/PROMPT.md and carry out exactly one iteration following it. Read docs/feedback/INBOX.md first. Use the repository files for memory. Finish this one iteration and exit."
        if ($SmokeTest) {
            # Test-only override lives here, never in the durable development prompt.
            $prompt = "This invocation is read-only infrastructure smoke test round $round. Read loop/PROMPT.md, docs/feedback/INBOX.md, docs/DESIGN.md, and docs/STATUS.md as UTF-8 to confirm they exist. Do not carry out the development instructions in them during this test. Do not edit any file, run the app, commit, or start development. Reply briefly with SMOKE_OK round=$round and the four paths read."
        }
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $settings.CodexPath
        $info.WorkingDirectory = $projectRoot
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        $info.Environment['PATH'] = $settings.ExplicitPath
        $null = $info.Environment.Remove('CODEX_THREAD_ID')
        $arguments = if ($SmokeTest) {
            @('-a','never','exec','--sandbox','read-only','-c','model_reasoning_effort="low"')
        } else {
            # Git metadata is protected by workspace-write. Automatic review can
            # approve the required commit commands without a human approval prompt.
            @('exec','--approve-for-me')
        }
        $arguments += @('--json','--ephemeral','--color','never','-C',$projectRoot,'--model',$settings.Model)
        $arguments += '-'
        foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
        try {
            $stdoutWriter = [IO.StreamWriter]::new("$base.events.jsonl", $false, [Text.UTF8Encoding]::new($false))
            $stderrWriter = [IO.StreamWriter]::new("$base.stderr.log", $false, [Text.UTF8Encoding]::new($false))
            $stdoutWriter.AutoFlush = $true
            $stderrWriter.AutoFlush = $true
            $child = [Diagnostics.Process]::new()
            $child.StartInfo = $info
            $childStarted = $false
            if (!$child.Start()) { throw 'Could not start codex exec.' }
            $childStarted = $true
            $state.round = $round
            $state.codexPid = $child.Id
            $state.status = 'running'
            Save-LoopState
            Write-LoopLog "ROUND $round START codexPid=$($child.Id) events=$base.events.jsonl"
            $child.StandardInput.WriteLine($prompt)
            $child.StandardInput.Close()
            $outRead = $child.StandardOutput.ReadLineAsync()
            $errRead = $child.StandardError.ReadLineAsync()
            $outDone = $false
            $errDone = $false
            while (!$child.HasExited -or !$outDone -or !$errDone) {
                if (((Get-Date) - $roundStart).TotalSeconds -gt $settings.RoundTimeoutSeconds) { throw "Round timeout after $($settings.RoundTimeoutSeconds) seconds." }
                if (!$outDone -and $outRead.IsCompleted) {
                    $line = $outRead.GetAwaiter().GetResult()
                    if ($null -eq $line) { $outDone = $true } else {
                        $stdoutWriter.WriteLine($line)
                        Read-CodexEvent $line $stats $settings.MaxTurns
                        $outRead = $child.StandardOutput.ReadLineAsync()
                    }
                }
                if (!$errDone -and $errRead.IsCompleted) {
                    $line = $errRead.GetAwaiter().GetResult()
                    if ($null -eq $line) { $errDone = $true } else {
                        $stderrWriter.WriteLine($line)
                        $errRead = $child.StandardError.ReadLineAsync()
                    }
                }
                # STOP is intentionally checked only between rounds, never to kill this child.
                Start-Sleep -Milliseconds 20
            }
            $child.WaitForExit()
            $roundExit = $child.ExitCode
            if ($roundExit -ne 0) { throw "codex exec exited with code $roundExit. See $base.stderr.log" }
            if ($stats.failed -or !$stats.threadId -or $stats.turns -ne 1 -or $stats.completed -ne 1) { throw 'Codex did not complete exactly one fresh user turn.' }
            if ($SmokeTest -and $stats.lastMessage -notmatch "SMOKE_OK round=$round\b") { throw 'Smoke test response is missing its success marker.' }
            [IO.File]::WriteAllText("$base.last-message.txt", $stats.lastMessage, [Text.UTF8Encoding]::new($false))
        } catch {
            $roundError = $_.Exception.Message
            $roundExit = if ($roundExit -eq 0) { 1 } else { $roundExit }
            throw
        } finally {
            if ($child) {
                if ($childStarted -and !$child.HasExited) { $child.Kill($true); $child.WaitForExit() }
                $child.Dispose()
                $child = $null
                $childStarted = $false
            }
            if ($stdoutWriter) { $stdoutWriter.Dispose() }
            if ($stderrWriter) { $stderrWriter.Dispose() }
            $summary = [ordered]@{ runId=$runId; mode=$mode; round=$round; codexPid=$state.codexPid; threadId=$stats.threadId; startedAt=$roundStart.ToString('o'); endedAt=(Get-Date).ToString('o'); turns=$stats.turns; completedTurns=$stats.completed; exitCode=$roundExit; error=$roundError; usage=$stats.usage; lastMessage=$stats.lastMessage }
            [IO.File]::WriteAllText("$base.summary.json", ($summary | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            Write-LoopLog "ROUND $round END exit=$roundExit turns=$($stats.turns) thread=$($stats.threadId)"
        }
        if ($SmokeTest) { Write-LoopLog $stats.lastMessage }
        $state.codexPid = $null
        $state.status = 'waiting'
        Save-LoopState
        if ($limit -gt 0 -and $round -ge $limit) { continue }
        $wakeAt = (Get-Date).AddSeconds($delay)
        while ((Get-Date) -lt $wakeAt -and !(Test-Path -LiteralPath $stopFile)) { Start-Sleep -Milliseconds 250 }
    }
} catch {
    $exitCode = 1
    Write-LoopLog "ERROR $($_.Exception.Message)"
} finally {
    if ($child) { if ($childStarted -and !$child.HasExited) { $child.Kill($true) }; $child.Dispose() }
    if ($lockStream) {
        $state.codexPid = $null
        $state.status = if ($exitCode -eq 0) { 'stopped' } else { 'failed' }
        $state['exitCode'] = $exitCode
        $state['endedAt'] = (Get-Date).ToString('o')
        Save-LoopState
        Write-LoopLog "RUN END exit=$exitCode rounds=$round"
        $lockStream.Dispose()
    }
}
exit $exitCode
