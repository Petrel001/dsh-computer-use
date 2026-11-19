#requires -Version 5.1
# DSH Computer Use - Persistent warm PowerShell worker (file-queue IPC).
# Keeps UIAutomation, System.Drawing, System.Windows.Forms and ZccNative warm in
# memory across consecutive agent turns, avoiding ~600-800ms cold starts while
# staying 100% compatible with sandboxes that block named/stdio pipes.
# Pure ASCII on purpose (see the code-page note in zcc-common.ps1).
param(
    [Parameter(Mandatory=$true)][string]$StateDir,
    [int]$IdleMs = 60000,
    [string]$Version = '1'
)

$ErrorActionPreference = 'Stop'
$env:CUA_STATE_DIR = $StateDir

. "$PSScriptRoot\zcc-common.ps1"
. "$PSScriptRoot\zcc-apps.ps1" -FunctionsOnly
. "$PSScriptRoot\zcc-state.ps1" -FunctionsOnly
. "$PSScriptRoot\zcc-action.ps1" -FunctionsOnly
. "$PSScriptRoot\zcc-screen.ps1" -FunctionsOnly

$script:ZccWorkerMode = $true

$workerRoot = Join-Path $StateDir 'worker'
$queueDir = Join-Path $workerRoot 'queue'
if (-not (Test-Path -LiteralPath $queueDir)) { New-Item -ItemType Directory -Path $queueDir -Force | Out-Null }

$metaPath = Join-Path $workerRoot 'worker.json'
$stopFlagPath = Join-Path $workerRoot 'stop.flag'
Remove-Item -LiteralPath $stopFlagPath -Force -ErrorAction SilentlyContinue

$meta = [ordered]@{
    pid = $PID
    version = $Version
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    queue_dir = $queueDir
}
$metaTmp = Join-Path $workerRoot ("worker-" + [Guid]::NewGuid().ToString('N') + ".tmp")
[IO.File]::WriteAllText($metaTmp, ($meta | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
Move-Item -LiteralPath $metaTmp -Destination $metaPath -Force

$envKeys = @(
    'CUA_STATE_DIR',
    'CUA_AUDIT_PATH',
    'CUA_DENY_TITLES',
    'CUA_DENY_PROCESSES',
    'CUA_TRAJECTORY_PATH',
    'CUA_TRAJECTORY_INCLUDE_TEXT',
    'CUA_TRACE_ID',
    'CUA_SUBGOAL',
    'CUA_STEP_ID',
    'CUA_DPI_AWARE'
)

$dispatchMap = @{
    'status'        = 'apps'
    'list-apps'     = 'apps'
    'list-windows'  = 'apps'
    'get-app-state' = 'state'
    'find'          = 'state'
    'wait'          = 'state'
    'focus'         = 'action'
    'click'         = 'action'
    'type'          = 'action'
    'keypress'      = 'action'
    'scroll'        = 'action'
    'drag'          = 'action'
    'set-value'     = 'action'
    'move'          = 'action'
    'screenshot'    = 'screen'
}

function Invoke-WorkerRequest {
    param([Parameter(Mandatory=$true)][string]$ReqPath)
    $raw = [IO.File]::ReadAllText($ReqPath, (New-Object Text.UTF8Encoding($false)))
    $req = $raw | ConvertFrom-Json
    $reqId = [string]$req.id
    $cmd = [string]$req.command
    $outFile = [string]$req.outFile
    $doneFile = Join-Path $queueDir "$reqId.done"

    $savedEnv = @{}
    foreach ($k in $envKeys) {
        $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        if ($null -ne $req.env -and $req.env.PSObject.Properties[$k]) {
            $val = $req.env.$k
            if ($null -eq $val -or [string]$val -eq '') {
                [Environment]::SetEnvironmentVariable($k, $null, 'Process')
            } else {
                [Environment]::SetEnvironmentVariable($k, [string]$val, 'Process')
            }
        }
    }

    try {
        Set-ZccOutFile -Path $outFile
        $script:ZccCurrentParams = $req.params
        $script:ZccLastSnapshotText = $null
        $script:ZccLastSnapshotStateId = $null
        $target = $dispatchMap[$cmd]
        try {
            switch ($target) {
                'apps'   { Invoke-ZccAppsDispatch -Command $cmd -Params $req.params }
                'state'  { Invoke-ZccStateDispatch -Command $cmd -Params $req.params }
                'action' { Invoke-ZccActionDispatch -Command $cmd -Params $req.params }
                'screen' { Invoke-ZccScreenDispatch -Command $cmd -Params $req.params }
                default  { Write-ZccError -Command $cmd -Code 'unknown_command' -Message "unknown command '$cmd'" }
            }
        } catch [ZccAbortException] {
            # Error envelope already written to $outFile.
        } catch {
            try {
                Write-ZccError -Command $cmd -Code (ConvertTo-ZccErrorCode -ErrorRecord $_) -Message $_.Exception.Message
            } catch [ZccAbortException] {}
        }
    } finally {
        foreach ($k in $envKeys) {
            [Environment]::SetEnvironmentVariable($k, $savedEnv[$k], 'Process')
        }
        try {
            $doneTmp = Join-Path $queueDir "$reqId.done.tmp"
            [IO.File]::WriteAllText($doneTmp, '1', (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $doneTmp -Destination $doneFile -Force
        } catch {}
    }
}

$lastActive = Get-Date
try {
    while ($true) {
        if (Test-Path -LiteralPath $stopFlagPath) { break }
        $requests = @(Get-ChildItem -LiteralPath $queueDir -Filter '*.req.json' -ErrorAction SilentlyContinue | Sort-Object Name)
        if ($requests.Count -gt 0) {
            foreach ($file in $requests) {
                $procPath = $file.FullName -replace '\.req\.json$', '.proc.json'
                try {
                    Move-Item -LiteralPath $file.FullName -Destination $procPath -Force
                } catch {
                    continue
                }
                try {
                    Invoke-WorkerRequest -ReqPath $procPath
                } finally {
                    Remove-Item -LiteralPath $procPath -Force -ErrorAction SilentlyContinue
                }
                $lastActive = Get-Date
                if (Test-Path -LiteralPath $stopFlagPath) { break }
            }
            continue
        }
        $idleElapsed = ((Get-Date) - $lastActive).TotalMilliseconds
        if ($idleElapsed -ge $IdleMs) { break }
        if ($idleElapsed -lt 2000) {
            Start-Sleep -Milliseconds 10
        } else {
            Start-Sleep -Milliseconds 25
        }
    }
} finally {
    try {
        if (Test-Path -LiteralPath $metaPath) {
            $cur = [IO.File]::ReadAllText($metaPath, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
            if ([int]$cur.pid -eq $PID) {
                Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
    Remove-Item -LiteralPath $stopFlagPath -Force -ErrorAction SilentlyContinue
}
