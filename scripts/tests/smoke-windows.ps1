#requires -Version 5.1
# DSH Computer Use - Windows backend smoke test (end-to-end action flow).
# Target: target-app.ps1, a SEPARATE real process running a WinForms form with a
# real message loop (like any real desktop app) that logs control events to a
# file. That makes input injection verifiable without reading images.
# Verified: status / list-apps / get-app-state / state cache + path targeting /
#           stale_state / find / wait / verification (wait-for, expect-change) /
#           clipboard preservation / audit log / deny list / set-value / type /
#           keypress / click (semantic, path, coordinate fallback) / scroll /
#           move / screenshot (+annotate/grid) / error + usage contract.
# Pure ASCII on purpose (see the code-page note in zcc-common.ps1).
#
# PowerShell 5.1 decodes a native child's stdout with [Console]::OutputEncoding
# (the ANSI code page on Chinese Windows). Node writes UTF-8, so any element name
# with Chinese characters used to corrupt the JSON before it reached
# ConvertFrom-Json. Pin the encoding first - this test failed 100% on zh-CN
# machines without it.
param(
    [string]$PluginRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
)

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# Non-ASCII test text is built from code points on purpose: this file must stay
# pure ASCII so PowerShell 5.1 (ANSI code page) parses it identically anywhere.
$zhText = -join @(0x4E2D, 0x6587, 0x8F93, 0x5165 | ForEach-Object { [char]$_ })

$ErrorActionPreference = 'Stop'
$cli = Join-Path $PluginRoot 'scripts\computer-control.mjs'
$targetApp = Join-Path $PSScriptRoot 'target-app.ps1'
$script:passed = 0
$script:failed = 0

function Invoke-Cli {
    param([string[]]$CliArgs)
    $json = & node $cli @CliArgs
    $exit = $LASTEXITCODE
    return @{ Exit = $exit; Json = ($json | ConvertFrom-Json) }
}

function Invoke-CliTimed {
    param([string[]]$CliArgs)
    $started = Get-Date
    $result = Invoke-Cli @CliArgs
    $result.ElapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    return $result
}

function Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "[PASS] $Name $Detail"
        $script:passed++
    } else {
        Write-Host "[FAIL] $Name $Detail"
        $script:failed++
    }
}

$src = @'
using System;
using System.Runtime.InteropServices;
public static class ZccTestFg {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
}
'@
Add-Type -TypeDefinition $src

function Force-Foreground {
    param([int64]$Hwnd)
    $target = [IntPtr]$Hwnd
    if ([ZccTestFg]::GetForegroundWindow() -eq $target) { return }
    $fg = [ZccTestFg]::GetForegroundWindow()
    $fgPid = 0
    $fgThread = [ZccTestFg]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $thisThread = [ZccTestFg]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $thisThread) {
        $attached = [ZccTestFg]::AttachThreadInput($thisThread, $fgThread, $true)
    }
    try { [void][ZccTestFg]::SetForegroundWindow($target) } finally {
        if ($attached) { [void][ZccTestFg]::AttachThreadInput($thisThread, $fgThread, $false) }
    }
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# Pixel-level overlay verification: proves the annotation boxes / grid labels
# were really painted, instead of trusting the envelope flags alone.
function Test-ImageHasColor {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ValidateSet('lime','yellow')][string]$Kind
    )
    $bmp = New-Object System.Drawing.Bitmap($Path)
    try {
        for ($x = 0; $x -lt $bmp.Width; $x++) {
            for ($y = 0; $y -lt $bmp.Height; $y++) {
                $c = $bmp.GetPixel($x, $y)
                if ($Kind -eq 'lime') {
                    # annotation box/label color: (0,255,0)
                    if ($c.G -gt 200 -and $c.R -lt 100 -and $c.B -lt 100) { return $true }
                } else {
                    # grid label text color: (255,255,85)
                    if ($c.R -gt 200 -and $c.G -gt 200 -and $c.B -lt 160) { return $true }
                }
            }
        }
        return $false
    } finally {
        $bmp.Dispose()
    }
}

# ---- launch the target app ---------------------------------------------------
$runTag = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$readyFile = Join-Path $env:TEMP "dsh-cu-ready-$runTag.txt"
$eventsFile = Join-Path $env:TEMP "dsh-cu-events-$runTag.log"
Write-Host "== launching target app (events: $eventsFile) =="
$targetProc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $targetApp,
    '-ReadyFile', $readyFile, '-EventsFile', $eventsFile
) -PassThru -WindowStyle Normal

$hwnd = 0
$deadline = (Get-Date).AddSeconds(20)
while ($hwnd -eq 0 -and (Get-Date) -lt $deadline) {
    if (Test-Path $readyFile) {
        $text = (Get-Content -Raw -Path $readyFile).Trim()
        if ($text) { $hwnd = [int64]$text }
    }
    if (-not $hwnd) { Start-Sleep -Milliseconds 200 }
}
if ($hwnd -eq 0) {
    Stop-Process -Id $targetProc.Id -Force -ErrorAction SilentlyContinue
    throw 'target app did not report a window handle within 20s'
}
Write-Host "target hwnd=$hwnd pid=$($targetProc.Id)"
Force-Foreground -Hwnd $hwnd
Start-Sleep -Milliseconds 600

# A locked session cannot receive input at all. Say it loudly instead of letting
# 20 assertions fail with a mystery.
$bootStatus = Invoke-Cli @('status')
$script:sessionLocked = [bool]$bootStatus.Json.result.session_locked
if ($script:sessionLocked) {
    Write-Host '!! session_locked: Windows refuses foreground switching and input injection.'
    Write-Host '!! Unlock the interactive desktop before running the full suite.'
}

function Get-State {
    return (Invoke-Cli @('get-app-state', '--app', "hwnd:$hwnd"))
}

function Find-Role {
    param($Elements, [string]$Role, [string]$Name = $null)
    return ($Elements | Where-Object {
        $_.role -eq $Role -and (-not $Name -or "$($_.name)" -eq $Name)
    } | Select-Object -First 1)
}

function Wait-EditValue {
    param([string]$Expected, [int]$TimeoutSeconds = 6)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-State
        $el = $state.Json.result.elements | Where-Object { $_.role -eq 'Edit' } | Select-Object -First 1
        if ($el -and "$($el.value)" -eq $Expected) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Wait-EditContains {
    param([string]$Needle, [int]$TimeoutSeconds = 6)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-State
        $el = $state.Json.result.elements | Where-Object { $_.role -eq 'Edit' } | Select-Object -First 1
        if ($el -and "$($el.value)".Contains($Needle)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Wait-Event {
    param([string]$EventName, [int]$TimeoutSeconds = 6)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path $eventsFile) -and (Select-String -Path $eventsFile -Pattern $EventName -Quiet)) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

try {
    Write-Host '== status =='
    $status = Invoke-Cli @('status')
    Check 'status ok' ($status.Json.ok -eq $true) "backend=$($status.Json.result.backend)"
    Check 'status advertises find + wait' (($status.Json.result.capabilities -contains 'find') -and ($status.Json.result.capabilities -contains 'wait'))
    Check 'status reports thread_desktop' ($null -ne $status.Json.result.thread_desktop) "thread=$($status.Json.result.thread_desktop) mismatch=$($status.Json.result.desktop_mismatch)"

    Write-Host '== list-apps =='
    $apps = Invoke-Cli @('list-apps')
    $win = $apps.Json.result.windows | Where-Object { $_.hwnd -eq $hwnd }
    Check 'target window visible in list-apps' ($null -ne $win) "title='$($win.title)' pid=$($win.pid)"
    Check 'list-apps carries class + visible facts' ($win.class -and $win.visible -eq $true) "class=$($win.class)"

    Write-Host '== get-app-state =='
    $state = Get-State
    Check 'get-app-state ok' ($state.Json.ok -eq $true)
    $elements = $state.Json.result.elements
    $btnEl = Find-Role -Elements $elements -Role 'Button' -Name 'ClickMe'
    $slowEl = Find-Role -Elements $elements -Role 'Button' -Name 'SlowReveal'
    $chkEl = $elements | Where-Object { $_.role -eq 'CheckBox' } | Select-Object -First 1
    $editEl = $elements | Where-Object { $_.role -eq 'Edit' } | Select-Object -First 1
    $panelEl = $elements | Where-Object { $_.automation_id -eq 'CoordPanel' -or ($_.role -eq 'Pane' -and $_.name -eq 'CoordPanel') } | Select-Object -First 1
    Check 'button element found' ($null -ne $btnEl) "index=$($btnEl.index) patterns=$($btnEl.patterns -join ',')"
    Check 'slow-reveal element found' ($null -ne $slowEl) "index=$($slowEl.index)"
    Check 'checkbox element found' ($null -ne $chkEl)
    Check 'edit element found' ($null -ne $editEl) "index=$($editEl.index)"
    Check 'named pane element found' ($null -ne $panelEl) "index=$($panelEl.index)"
    Check 'state_id reported' ($state.Json.result.state_id -match '^[0-9a-f]{12}$')
    Check 'state cache written' ($state.Json.result.state_cached -eq $true)
    Check 'elements carry a path' ($btnEl.path -and $btnEl.path.StartsWith('0.'))

    Write-Host '== state_id stability =='
    $stateAgain = Get-State
    Check 'idle snapshot keeps the same state_id' ($stateAgain.Json.result.state_id -eq $state.Json.result.state_id)

    Write-Host '== get-app-state --compact and --scope-element =='
    $compactState = Invoke-Cli @('get-app-state', '--app', "hwnd:$hwnd", '--compact')
    Check 'compact state ok and omits elements[]' ($compactState.Json.ok -eq $true -and $compactState.Json.result.compact -eq $true -and $null -eq $compactState.Json.result.elements -and -not [string]::IsNullOrWhiteSpace($compactState.Json.result.text))
    Check 'compact state_id matches full state_id' ($compactState.Json.result.state_id -eq $state.Json.result.state_id)
    $scopedState = Invoke-Cli @('get-app-state', '--app', "hwnd:$hwnd", '--scope-element', "$($btnEl.index)")
    Check 'scoped state ok with smaller element count' ($scopedState.Json.ok -eq $true -and $scopedState.Json.result.scoped -eq $true -and $scopedState.Json.result.element_count -lt $state.Json.result.element_count)
    Check 'scoped state preserves root path' ($scopedState.Json.result.elements[0].path -eq $btnEl.path)
    # Restore full window cache for subsequent assertions
    $null = Get-State

    Write-Host '== set-value (ValuePattern) + closed-loop cache refresh =='
    $sv = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', 'set-value-works', '--expect-change')
    Check 'set-value --expect-change ok' ($sv.Json.ok -eq $true -and $sv.Json.action_sent -eq $true -and $sv.Json.result.state_changed -eq $true)
    Check 'value round-trips via UIA value' (Wait-EditValue -Expected 'set-value-works')
    # Verify that --expect-change refreshed the disk cache so --state-id works immediately without re-running get-app-state
    $svFollowUp = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', 'cache-closed-loop', '--state-id', "$($sv.Json.result.state_id)")
    Check 'expect-change refreshed state cache for immediate --state-id reuse' ($svFollowUp.Json.ok -eq $true)
    Check 'closed-loop value landed' (Wait-EditValue -Expected 'cache-closed-loop')

    Write-Host '== type (focus + SendKeys) =='
    $tp = Invoke-Cli @('type', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', '+typed')
    Check 'type ok' ($tp.Json.ok -eq $true)
    # Caret position after ValuePattern.SetValue is implementation-defined, so
    # the invariant is: the typed text landed inside the edit, keeping the old
    # content. (No caret-position assumption.)
    Check 'typed text landed in the edit (caret-independent)' (Wait-EditContains -Needle '+typed')

    Write-Host '== keypress (end, shift+home selects, typing replaces) =='
    # NOTE: Win32 EDIT controls do not implement Ctrl+A (select-all is
    # app-dependent, e.g. Notepad handles it itself). shift+home is a stock
    # EDIT shortcut that IS verifiable: it selects from caret to line start.
    $sv2 = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', 'selectme')
    Check 'set-value reset ok' ($sv2.Json.ok -eq $true)
    Check 'reset value landed' (Wait-EditValue -Expected 'selectme')
    $kp = Invoke-Cli @('keypress', '--app', "hwnd:$hwnd", '--keys', 'end')
    Check 'keypress end ok' ($kp.Json.ok -eq $true) "send_keys=$($kp.Json.result.send_keys)"
    $kps = Invoke-Cli @('keypress', '--app', "hwnd:$hwnd", '--keys', 'shift+home')
    Check 'keypress shift+home ok' ($kps.Json.ok -eq $true -and $kps.Json.action_sent -eq $true) "send_keys=$($kps.Json.result.send_keys)"
    $kpr = Invoke-Cli @('type', '--app', "hwnd:$hwnd", '--text', 'Z')
    Check 'type after selection ok' ($kpr.Json.ok -eq $true)
    # If shift+home really selected everything, 'Z' replaced the whole content.
    Check 'shift+home selected to line start (Z replaced content)' (Wait-EditValue -Expected 'Z')

    Write-Host '== type with submit (enter) =='
    $sv3 = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', 'base')
    Check 'set-value reset ok (submit test)' ($sv3.Json.ok -eq $true)
    $kpe = Invoke-Cli @('keypress', '--app', "hwnd:$hwnd", '--keys', 'end')
    Check 'keypress end ok (submit test)' ($kpe.Json.ok -eq $true)
    $tp2 = Invoke-Cli @('type', '--app', "hwnd:$hwnd", '--text', 'X', '--submit')
    Check 'type with submit ok' ($tp2.Json.ok -eq $true)
    Check 'enter did not corrupt the edit value' (Wait-EditValue -Expected 'baseX')

    Write-Host '== clipboard preservation (non-ASCII paste) =='
    $clipboardReady = $true
    try {
        [System.Windows.Forms.Clipboard]::SetText('clipboard-sentinel')
    } catch {
        $clipboardReady = $false
        Check 'clipboard sentinel can be set' $false "$($_.Exception.Message)"
    }
    $svClear = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text=')
    Check 'clear for clipboard test ok' ($svClear.Json.ok -eq $true)
    $tpZh = Invoke-Cli @('type', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', $zhText)
    Check 'non-ASCII type ok' ($tpZh.Json.ok -eq $true -and $tpZh.Json.result.clipboard_restored -eq $true)
    Check 'non-ASCII text landed in the edit' (Wait-EditContains -Needle $zhText)
    if ($clipboardReady) {
        Check 'user clipboard was restored' ([System.Windows.Forms.Clipboard]::GetText() -eq 'clipboard-sentinel') "clipboard='$([System.Windows.Forms.Clipboard]::GetText())'"
    }

    Write-Host '== click (semantic UIA InvokePattern) =='
    $clk = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($btnEl.index)")
    Check 'click ok' ($clk.Json.ok -eq $true) "method=$($clk.Json.result.method)"
    Check 'button click reached the target app (uia-invoke)' (Wait-Event -EventName 'button-click')
    Check 'button click changed the UI (label -> clicked)' ((Get-State).Json.result.elements | Where-Object { $_.role -eq 'Text' -and $_.name -eq 'clicked' } | Measure-Object | ForEach-Object { $_.Count -gt 0 })

    Write-Host '== click by element path =='
    $pathClick = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element-path', "$($btnEl.path)")
    Check 'element-path click ok' ($pathClick.Json.ok -eq $true -and $pathClick.Json.result.target.resolve -eq 'path') "method=$($pathClick.Json.result.method) path=$($btnEl.path)"

    Write-Host '== click with --wait-for (delayed UI change) =='
    # Coordinate click on purpose: the semantic Invoke path can itself take
    # seconds (provider-dependent), which would hide the 1.2 s delayed change
    # and make this assertion pass without ever polling.
    $slowState = Get-State
    $slowNow = $slowState.Json.result.elements | Where-Object { $_.role -eq 'Button' -and $_.name -eq 'SlowReveal' } | Select-Object -First 1
    $slowX = $slowNow.bounds.x + [int]($slowNow.bounds.width / 2)
    $slowY = $slowNow.bounds.y + [int]($slowNow.bounds.height / 2)
    $slowClick = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--x', "$slowX", '--y', "$slowY", '--wait-for', 'name:slow-done', '--wait-timeout', '8000')
    Check 'click --wait-for verified ok' ($slowClick.Json.ok -eq $true -and $slowClick.Json.result.verification.matched -eq $true) "elapsed=$($slowClick.Json.result.verification.elapsed_ms)ms polls=$($slowClick.Json.result.verification.polls)"
    Check 'wait polling really waited for the delayed change' ($slowClick.Json.result.verification.elapsed_ms -ge 800 -and $slowClick.Json.result.verification.polls -ge 2) "elapsed=$($slowClick.Json.result.verification.elapsed_ms)ms polls=$($slowClick.Json.result.verification.polls)"
    Check 'delayed change observed in state' ((Get-State).Json.result.elements | Where-Object { $_.name -eq 'slow-done' } | Measure-Object | ForEach-Object { $_.Count -gt 0 })

    Write-Host '== click --wait-for timeout (fails closed, action reported) =='
    $missState = Get-State
    $slowMiss = $missState.Json.result.elements | Where-Object { $_.role -eq 'Button' -and $_.name -eq 'SlowReveal' } | Select-Object -First 1
    $missClick = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($slowMiss.index)", '--wait-for', 'name:never-appears', '--wait-timeout', '800')
    Check 'unmet wait -> verification_timeout, exit 1' ($missClick.Exit -eq 1 -and $missClick.Json.error.code -eq 'verification_timeout') "code=$($missClick.Json.error.code)"
    Check 'timed-out action still reports its result' ($missClick.Json.action_sent -eq $true -and $null -ne $missClick.Json.result.verification)
    Check 'timed-out wait reports matched=false' ($missClick.Json.result.verification.matched -eq $false)

    Write-Host '== wait command =='
    $wFor = Invoke-Cli @('wait', '--app', "hwnd:$hwnd", '--for', 'role:button,name:ClickMe', '--timeout', '2000')
    Check 'wait --for existing element matched' ($wFor.Json.ok -eq $true -and $wFor.Json.result.matched -eq $true) "polls=$($wFor.Json.result.polls)"
    $wGone = Invoke-Cli @('wait', '--app', "hwnd:$hwnd", '--gone', 'name:never-appears', '--timeout', '2000')
    Check 'wait --gone absent element matched' ($wGone.Json.ok -eq $true -and $wGone.Json.result.matched -eq $true)
    $wMiss = Invoke-Cli @('wait', '--app', "hwnd:$hwnd", '--for', 'name:never-appears', '--timeout', '700')
    Check 'wait timeout -> verification_timeout' ($wMiss.Exit -eq 1 -and $wMiss.Json.error.code -eq 'verification_timeout') "code=$($wMiss.Json.error.code) elapsed=$($wMiss.Json.result.elapsed_ms)ms"

    Write-Host '== find + closed-loop verification cache refresh =='
    $find = Invoke-Cli @('find', '--app', "hwnd:$hwnd", '--role', 'button', '--name', 'ClickMe')
    Check 'find locates the button' ($find.Json.ok -eq $true -and $find.Json.result.count -eq 1 -and $find.Json.result.matches[0].index -eq $btnEl.index) "index=$($find.Json.result.matches[0].index)"
    $findNone = Invoke-Cli @('find', '--app', "hwnd:$hwnd", '--role', 'button', '--name', 'NoSuchButton')
    Check 'find with no match is a successful empty result' ($findNone.Json.ok -eq $true -and $findNone.Json.result.count -eq 0)
    $findCache = Invoke-Cli @('find', '--app', "hwnd:$hwnd", '--role', 'button', '--name', 'ClickMe', '--use-cache', '--max-age', '60000')
    Check 'find --use-cache reads the cached snapshot' ($findCache.Json.result.source -eq 'cache') "source=$($findCache.Json.result.source)"
    $svWait = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', 'wait-loop-val', '--wait-for', 'role:Edit,value:wait-loop-val', '--state-id', "$($find.Json.result.state_id)")
    Check 'find refreshed state cache and --wait-for verified set-value' ($svWait.Json.ok -eq $true -and $svWait.Json.result.verification.matched -eq $true)
    $svAfterWait = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($editEl.index)", '--text', 'after-wait-loop', '--state-id', "$($svWait.Json.result.state_id)")
    Check 'wait-for refreshed state cache for immediate --state-id reuse' ($svAfterWait.Json.ok -eq $true)

    Write-Host '== stale_state contract =='
    $stale = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($btnEl.index)", '--state-id', 'deadbeefdead')
    Check 'wrong --state-id -> stale_state, exit 1' ($stale.Exit -eq 1 -and $stale.Json.error.code -eq 'stale_state') "code=$($stale.Json.error.code)"
    $fresh = Get-State
    $freshBtn = $fresh.Json.result.elements | Where-Object { $_.role -eq 'Button' -and $_.name -eq 'ClickMe' } | Select-Object -First 1
    $freshClick = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($freshBtn.index)", '--state-id', "$($fresh.Json.result.state_id)")
    Check 'current --state-id accepted' ($freshClick.Json.ok -eq $true) "state=$($fresh.Json.result.state_id)"

    Write-Host '== expect-change contract =='
    # Re-read the tree here: earlier assertions changed labels/values, and a
    # cached index is only valid while its control identity still matches.
    $stateNow = Get-State
    $moveElement = $stateNow.Json.result.elements | Where-Object { $_.automation_id -eq 'MoveZone' } | Select-Object -First 1
    $noChange = Invoke-Cli @('move', '--app', "hwnd:$hwnd", '--element', "$($moveElement.index)", '--expect-change')
    Check 'move --expect-change -> no_state_change, exit 1' ($noChange.Exit -eq 1 -and $noChange.Json.error.code -eq 'no_state_change') "code=$($noChange.Json.error.code)"
    Check 'no-op detection still reports the action' ($noChange.Json.action_sent -eq $true -and $noChange.Json.result.state_changed -eq $false)

    Write-Host '== audit log =='
    $auditPath = Join-Path $env:TEMP "dsh-cu-audit-$runTag.jsonl"
    $env:CUA_AUDIT_PATH = $auditPath
    try {
        $auditState = Get-State
        $auditBtn = $auditState.Json.result.elements | Where-Object { $_.role -eq 'Button' -and $_.name -eq 'ClickMe' } | Select-Object -First 1
        $null = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($auditBtn.index)")
        $auditText = $(if (Test-Path $auditPath) { Get-Content -Raw -Path $auditPath } else { '' })
        Check 'audit log written for a mutating action' ($auditText -match '"command":"click"') 
        Check 'audit log records the target window' ($auditText -match 'DSH-CU-TARGET')
        Check 'audit log never records typed text' (-not $auditText.Contains($zhText))
    } finally {
        Remove-Item env:CUA_AUDIT_PATH -ErrorAction SilentlyContinue
        Remove-Item $auditPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host '== deny list =='
    $env:CUA_DENY_TITLES = 'DSH-CU-TARGET'
    try {
        $blocked = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($btnEl.index)")
        Check 'deny-listed window -> target_blocked, exit 1' ($blocked.Exit -eq 1 -and $blocked.Json.error.code -eq 'target_blocked') "code=$($blocked.Json.error.code)"
    } finally {
        Remove-Item env:CUA_DENY_TITLES -ErrorAction SilentlyContinue
    }

    Write-Host '== click (coordinate fallback on named pane) =='
    $statePanes = Get-State
    $panelNow = $statePanes.Json.result.elements | Where-Object { $_.automation_id -eq 'CoordPanel' } | Select-Object -First 1
    $chkNow = $statePanes.Json.result.elements | Where-Object { $_.role -eq 'CheckBox' } | Select-Object -First 1
    $clk2 = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($panelNow.index)")
    Check 'coordinate-fallback click ok' ($clk2.Json.ok -eq $true) "method=$($clk2.Json.result.method)"
    Check 'panel click reached the target app (mouse_event)' (Wait-Event -EventName 'panel-click')

    Write-Host '== click checkbox (TogglePattern) =='
    $clk3 = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($chkNow.index)")
    Check 'checkbox click ok' ($clk3.Json.ok -eq $true) "method=$($clk3.Json.result.method)"
    Check 'checkbox click reached the target app (uia-toggle)' (Wait-Event -EventName 'checkbox-click')

    Write-Host '== click combobox (ExpandCollapsePattern expand + collapse) =='
    $comboEl = $statePanes.Json.result.elements | Where-Object { $_.role -eq 'ComboBox' } | Select-Object -First 1
    Check 'combobox element found' ($null -ne $comboEl)
    if ($comboEl) {
        $exp1 = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($comboEl.index)")
        Check 'combobox first click expands (uia-expand)' ($exp1.Json.ok -eq $true -and $exp1.Json.result.method -eq 'uia-expand') "method=$($exp1.Json.result.method)"
        $exp2 = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', "$($comboEl.index)")
        Check 'combobox second click collapses (uia-collapse)' ($exp2.Json.ok -eq $true -and $exp2.Json.result.method -eq 'uia-collapse') "method=$($exp2.Json.result.method)"
    }

    Write-Host '== trajectory log (CUA_TRAJECTORY_PATH) =='
    $trajPath = Join-Path $env:TEMP "dsh-cu-traj-$runTag.jsonl"
    $env:CUA_TRAJECTORY_PATH = $trajPath
    try {
        $trajState = Get-State
        $trajEdit = $trajState.Json.result.elements | Where-Object { $_.role -eq 'Edit' } | Select-Object -First 1
        $null = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($trajEdit.index)", '--text', 'traj-secret-text', '--expect-change')
        $trajText = $(if (Test-Path $trajPath) { Get-Content -Raw -Path $trajPath } else { '' })
        Check 'trajectory log written for state and action' ($trajText -match '"command":"get-app-state"' -and $trajText -match '"command":"set-value"')
        Check 'trajectory log includes duration_ms' ($trajText -match '"duration_ms":\d+')
        Check 'trajectory log omits raw text by default' (-not $trajText.Contains('traj-secret-text'))
    } finally {
        Remove-Item env:CUA_TRAJECTORY_PATH -ErrorAction SilentlyContinue
        Remove-Item $trajPath -Force -ErrorAction SilentlyContinue
    }

    Write-Host '== scroll =='
    $scr = Invoke-Cli @('scroll', '--app', "hwnd:$hwnd", '--direction', 'down', '--amount', '1')
    Check 'scroll down ok' ($scr.Json.ok -eq $true -and $scr.Json.action_sent -eq $true)
    $scrH = Invoke-Cli @('scroll', '--app', "hwnd:$hwnd", '--direction', 'right', '--amount', '1')
    Check 'scroll right ok' ($scrH.Json.ok -eq $true -and $scrH.Json.result.direction -eq 'right')

    Write-Host '== move (hover): element center + explicit coordinate =='
    Check 'move-zone element found' ($null -ne $moveElement) "index=$($moveElement.index)"
    if ($moveElement) {
        $zb = $moveElement.bounds
        # Nudge the cursor away first: Windows delivers no WM_MOUSEMOVE when the
        # position does not change, so a prior action may have parked the cursor
        # exactly on the target point and the move would produce no event at all.
        $nudgeX = $win.bounds.x + 10
        $nudgeY = $win.bounds.y + 10
        $null = Invoke-Cli @('move', '--app', "hwnd:$hwnd", '--x', "$nudgeX", '--y', "$nudgeY")
        $mv1 = Invoke-Cli @('move', '--app', "hwnd:$hwnd", '--element', "$($moveElement.index)")
        Check 'move to element center ok' ($mv1.Json.ok -eq $true -and $mv1.Json.action_sent -eq $true) "method=$($mv1.Json.result.method)"
        $expectCx = $zb.x + [int]($zb.width / 2)
        $expectCy = $zb.y + [int]($zb.height / 2)
        Check 'cursor reached element center' (Wait-Event -EventName "mouse-move $expectCx,$expectCy" -TimeoutSeconds 10) "expected $expectCx,$expectCy"
        $mx = $zb.x + 30
        $my = $zb.y + 40
        $null = Invoke-Cli @('move', '--app', "hwnd:$hwnd", '--x', "$nudgeX", '--y', "$nudgeY")
        $mv2 = Invoke-Cli @('move', '--app', "hwnd:$hwnd", '--x', "$mx", '--y', "$my")
        Check 'move to explicit coordinate ok' ($mv2.Json.ok -eq $true) "target=$mx,$my"
        Check 'cursor reached explicit coordinate' (Wait-Event -EventName "mouse-move $mx,$my" -TimeoutSeconds 10)
    }

    Write-Host '== screenshot =='
    $shotPath = Join-Path $env:TEMP "dsh-cu-smoke-$runTag.png"
    $shot = Invoke-Cli @('screenshot', '--app', "hwnd:$hwnd", '--out', $shotPath)
    Check 'screenshot ok' ($shot.Json.ok -eq $true -and (Test-Path $shotPath)) "$($shot.Json.result.width)x$($shot.Json.result.height) bytes=$($shot.Json.result.bytes)"

    Write-Host '== screenshot --screen =='
    $screenShotPath = Join-Path $env:TEMP "dsh-cu-smoke-screen-$runTag.png"
    $shot2 = Invoke-Cli @('screenshot', '--screen', '--out', $screenShotPath)
    Check 'screen screenshot ok' ($shot2.Json.ok -eq $true -and (Test-Path $screenShotPath)) "$($shot2.Json.result.width)x$($shot2.Json.result.height)"

    Write-Host '== screenshot --annotate (element overlay + cache refresh) =='
    $annotatePath = Join-Path $env:TEMP "dsh-cu-smoke-annotate-$runTag.png"
    $shot3 = Invoke-Cli @('screenshot', '--app', "hwnd:$hwnd", '--out', $annotatePath, '--annotate')
    Check 'annotated screenshot ok' ($shot3.Json.ok -eq $true -and (Test-Path $annotatePath)) "annotated_elements=$($shot3.Json.result.annotated_elements)"
    Check 'annotated reports drawn elements and state_id' ($shot3.Json.result.annotated -eq $true -and $shot3.Json.result.annotated_elements -gt 0 -and $shot3.Json.result.state_id -match '^[0-9a-f]{12}$')
    Check 'annotation boxes are actually painted (lime pixels present)' ((Test-Path $annotatePath) -and (Test-ImageHasColor -Path $annotatePath -Kind 'lime'))
    if ($shot3.Json.ok -eq $true -and $shot3.Json.result.state_id) {
        $annEdit = (Get-State).Json.result.elements | Where-Object { $_.role -eq 'Edit' } | Select-Object -First 1
        $shotAgain = Invoke-Cli @('screenshot', '--app', "hwnd:$hwnd", '--out', $annotatePath, '--annotate')
        $svAnn = Invoke-Cli @('set-value', '--app', "hwnd:$hwnd", '--element', "$($annEdit.index)", '--text', 'from-annotate', '--state-id', "$($shotAgain.Json.result.state_id)")
        Check 'annotated screenshot refreshed state cache for --state-id' ($svAnn.Json.ok -eq $true)
    }

    Write-Host '== screenshot --grid 100 (absolute coordinate grid) =='
    $gridPath = Join-Path $env:TEMP "dsh-cu-smoke-grid-$runTag.png"
    $shot4 = Invoke-Cli @('screenshot', '--app', "hwnd:$hwnd", '--out', $gridPath, '--grid', '100')
    Check 'grid screenshot ok' ($shot4.Json.ok -eq $true -and (Test-Path $gridPath)) "grid=$($shot4.Json.result.grid)"
    Check 'grid labels are actually painted (yellow pixels present)' ((Test-Path $gridPath) -and (Test-ImageHasColor -Path $gridPath -Kind 'yellow'))

    Write-Host '== screenshot --annotate --grid (combined) =='
    $bothPath = Join-Path $env:TEMP "dsh-cu-smoke-both-$runTag.png"
    $shot5 = Invoke-Cli @('screenshot', '--app', "hwnd:$hwnd", '--out', $bothPath, '--annotate', '--grid')
    Check 'combined overlay ok' ($shot5.Json.ok -eq $true -and (Test-Path $bothPath)) "annotated_elements=$($shot5.Json.result.annotated_elements) grid=$($shot5.Json.result.grid)"
    Check 'bare --grid falls back to default 100' ($shot5.Json.result.grid -eq 100)

    Write-Host '== annotate requires --app (usage contract) =='
    $annotateBad = Invoke-Cli @('screenshot', '--screen', '--annotate')
    Check 'annotate without app -> invalid_arguments' ($annotateBad.Exit -eq 2 -and $annotateBad.Json.error.code -eq 'invalid_arguments') "code=$($annotateBad.Json.error.code)"

    Write-Host '== error contract =='
    $bad = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', '9999')
    Check 'stale index -> element_not_found' ($bad.Exit -eq 1 -and $bad.Json.ok -eq $false -and $bad.Json.error.code -eq 'element_not_found') "code=$($bad.Json.error.code)"

    Write-Host '== usage contract =='
    $usage = Invoke-Cli @('click')
    Check 'missing --app -> invalid_arguments, exit 2' ($usage.Exit -eq 2 -and $usage.Json.error.code -eq 'invalid_arguments') "exit=$($usage.Exit) code=$($usage.Json.error.code)"

    $unknown = Invoke-Cli @('frobnicate')
    Check 'unknown command -> unknown_command, exit 2' ($unknown.Exit -eq 2 -and $unknown.Json.error.code -eq 'unknown_command') "exit=$($unknown.Exit)"

    $conflict = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', '1', '--wait-for', 'name:x', '--wait-gone', 'name:y')
    Check 'conflicting wait flags -> invalid_arguments, exit 2' ($conflict.Exit -eq 2 -and $conflict.Json.error.code -eq 'invalid_arguments') "code=$($conflict.Json.error.code)"

    $typo = Invoke-Cli @('click', '--app', "hwnd:$hwnd", '--element', '1', '--wait-fro', 'name:x')
    Check 'unknown flag -> invalid_arguments, exit 2' ($typo.Exit -eq 2 -and $typo.Json.error.code -eq 'invalid_arguments') "code=$($typo.Json.error.code)"
} catch {
    # Never abort without a RESULT line: a mid-run exception (e.g. clipboard
    # locked by another process) must still produce a verdict.
    Write-Host "[FATAL] $($_.Exception.Message)"
    $script:failed++
} finally {
    Stop-Process -Id $targetProc.Id -Force -ErrorAction SilentlyContinue
    Remove-Item $readyFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "RESULT: passed=$($script:passed) failed=$($script:failed)"
if ($script:failed -gt 0) { exit 1 }
exit 0