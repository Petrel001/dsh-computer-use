#requires -Version 5.1
# DSH Computer Use - Windows action execution: focus / click / type / keypress / scroll / drag / set-value / move.
# Semantic-first: UIA patterns (Invoke/Value/Toggle/Select/Scroll) first, real
# mouse/keyboard injection as the fallback path.
# Every path that injects input asserts the target window is really foreground
# first (focus_failed otherwise), and every action can verify its effect with
# --wait-for / --wait-gone / --expect-change.
# Pure ASCII on purpose (see the code-page note in zcc-common.ps1).
param(
    [string]$Command = '',
    [string]$ParamsFile = '',
    [string]$OutFile = '',
    [switch]$FunctionsOnly
)

if (-not $FunctionsOnly) {
    . "$PSScriptRoot\zcc-common.ps1"
}

# ---- Element helpers ---------------------------------------------------------
function Ensure-ElementInView {
    param([Parameter(Mandatory=$true)]$Element)
    try {
        $off = [bool]$Element.Current.IsOffscreen
        $r = $Element.Current.BoundingRectangle
        $empty = [double]::IsNaN($r.Width) -or $r.Width -le 0 -or $r.Height -le 0
        if ($off -or $empty) {
            $si = Get-ElementPattern -Element $Element -Pattern ([System.Windows.Automation.ScrollItemPattern]::Pattern)
            if ($si) {
                $si.ScrollIntoView()
                Start-Sleep -Milliseconds 60
            }
        }
    } catch {}
}

function Get-ElementCenter {
    param([Parameter(Mandatory=$true)]$Element)
    Ensure-ElementInView -Element $Element
    $c = $Element.Current
    # Bounds center FIRST: it is deterministic and matches the bounds that
    # get-app-state reports, so a coordinate derived from state data targets
    # exactly the same pixel. GetClickablePoint can differ by a fractional
    # pixel (which [int] truncation then turns into a -1px drift).
    $r = $c.BoundingRectangle
    if (-not [double]::IsNaN($r.Width) -and $r.Width -gt 0 -and $r.Height -gt 0) {
        return @{ x = [int]($r.X + $r.Width / 2); y = [int]($r.Y + $r.Height / 2) }
    }
    # Fallback for elements without a usable rectangle (some custom controls).
    try {
        $pt = $Element.GetClickablePoint()
        return @{ x = [int]$pt.X; y = [int]$pt.Y }
    } catch {}
    throw "element has no clickable point or bounds (offscreen element cannot be clicked by coordinates)"
}

function Invoke-UiaInvokeSafe {
    param(
        [Parameter(Mandatory=$true)]$InvokePattern,
        [int]$TargetPid = 0,
        [int64]$TargetHwnd = 0
    )
    $ps = [PowerShell]::Create()
    try {
        [void]$ps.AddScript('param($p) $p.Invoke()').AddArgument($InvokePattern)
        $iar = $ps.BeginInvoke()
        if ($iar.AsyncWaitHandle.WaitOne(1500)) {
            [void]$ps.EndInvoke($iar)
            if ($ps.HadErrors -and $ps.Streams.Error.Count -gt 0) {
                throw $ps.Streams.Error[0].Exception
            }
            return 'uia-invoke'
        }
        # If Invoke() blocked past 1.5s, check whether the app opened a modal
        # dialog (whose nested message loop blocks synchronous Invoke() until
        # dismissed).
        $fg = [int64][ZccNative]::GetForegroundWindow()
        if ($fg -ne 0 -and $fg -ne $TargetHwnd -and $TargetPid -gt 0) {
            $fgPid = 0
            [void][ZccNative]::GetWindowThreadProcessId([IntPtr]$fg, [ref]$fgPid)
            if ($fgPid -eq $TargetPid) {
                return 'uia-invoke-modal'
            }
        }
        if ($iar.AsyncWaitHandle.WaitOne(10000)) {
            [void]$ps.EndInvoke($iar)
            if ($ps.HadErrors -and $ps.Streams.Error.Count -gt 0) {
                throw $ps.Streams.Error[0].Exception
            }
            return 'uia-invoke'
        }
        return 'uia-invoke-async'
    } finally {
        # Dispose asynchronously on timeout so a blocked modal Invoke does not hang Dispose()
        try {
            if ($ps.InvocationStateInfo.State -eq 'Running') {
                [void]$ps.BeginStop($null, $null)
            } else {
                $ps.Dispose()
            }
        } catch {}
    }
}

function Assert-CoordinatesInScreen {
    param([int]$X, [int]$Y)
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($X -lt $vs.Left -or $X -ge $vs.Left + $vs.Width -or $Y -lt $vs.Top -or $Y -ge $vs.Top + $vs.Height) {
        throw "coordinates ($X,$Y) are outside the virtual screen ($($vs.Left),$($vs.Top)-$($vs.Left+$vs.Width),$($vs.Top+$vs.Height))"
    }
}

# ---- Input injection -----------------------------------------------------------
function Invoke-MouseClick {
    param([int]$X, [int]$Y, [string]$Button = 'left', [bool]$Double = $false)
    Assert-CoordinatesInScreen -X $X -Y $Y
    [void][ZccNative]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 30
    if ($Button -eq 'right') {
        [ZccNative]::mouse_event($script:ZccMouseRightDown, $X, $Y, 0, 0)
        [ZccNative]::mouse_event($script:ZccMouseRightUp, $X, $Y, 0, 0)
    } elseif ($Button -eq 'middle') {
        [ZccNative]::mouse_event($script:ZccMouseMiddleDown, $X, $Y, 0, 0)
        [ZccNative]::mouse_event($script:ZccMouseMiddleUp, $X, $Y, 0, 0)
    } else {
        [ZccNative]::mouse_event($script:ZccMouseLeftDown, $X, $Y, 0, 0)
        [ZccNative]::mouse_event($script:ZccMouseLeftUp, $X, $Y, 0, 0)
        if ($Double) {
            Start-Sleep -Milliseconds 40
            [ZccNative]::mouse_event($script:ZccMouseLeftDown, $X, $Y, 0, 0)
            [ZccNative]::mouse_event($script:ZccMouseLeftUp, $X, $Y, 0, 0)
        }
    }
}

function ConvertTo-SendKeysText {
    param([Parameter(Mandatory=$true)][string]$Text)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ('+^%~(){}'.IndexOf($ch) -ge 0) { [void]$sb.Append('{'); [void]$sb.Append($ch); [void]$sb.Append('}') }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

$script:ZccKeyMap = @{
    'enter' = '{ENTER}'; 'return' = '{ENTER}'; 'tab' = '{TAB}'; 'esc' = '{ESC}'; 'escape' = '{ESC}'
    'space' = ' '; 'backspace' = '{BACKSPACE}'; 'bs' = '{BACKSPACE}'; 'delete' = '{DEL}'; 'del' = '{DEL}'
    'insert' = '{INS}'; 'ins' = '{INS}'; 'up' = '{UP}'; 'down' = '{DOWN}'; 'left' = '{LEFT}'; 'right' = '{RIGHT}'
    'home' = '{HOME}'; 'end' = '{END}'; 'pageup' = '{PGUP}'; 'pgup' = '{PGUP}'
    'pagedown' = '{PGDN}'; 'pgdn' = '{PGDN}'; 'capslock' = '{CAPSLOCK}'
    'f1' = '{F1}'; 'f2' = '{F2}'; 'f3' = '{F3}'; 'f4' = '{F4}'; 'f5' = '{F5}'; 'f6' = '{F6}'
    'f7' = '{F7}'; 'f8' = '{F8}'; 'f9' = '{F9}'; 'f10' = '{F10}'; 'f11' = '{F11}'; 'f12' = '{F12}'
}
$script:ZccModifierMap = @{ 'ctrl' = '^'; 'control' = '^'; 'alt' = '%'; 'shift' = '+' }

function ConvertTo-SendKeysChord {
    param([Parameter(Mandatory=$true)][string]$Chord)
    $parts = $Chord.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($parts.Count -eq 0) { throw "empty key chord" }
    $prefix = ''
    $main = $null
    foreach ($part in $parts) {
        $lower = $part.ToLower()
        if ($script:ZccModifierMap.ContainsKey($lower)) { $prefix += $script:ZccModifierMap[$lower] }
        elseif ($script:ZccKeyMap.ContainsKey($lower)) { $main = $script:ZccKeyMap[$lower] }
        elseif ($part.Length -eq 1) { $main = (ConvertTo-SendKeysText -Text $part) }
        else { throw "unknown key '$part'; supported: ctrl/alt/shift + named keys (enter,tab,esc,space,up,down,...,f1-f12) or single characters" }
    }
    if ($null -eq $main) { throw "chord '$Chord' has modifiers but no main key" }
    if ($prefix -ne '') { return $prefix + '(' + $main + ')' }
    return $main
}

function ConvertTo-SendKeysSequence {
    param([Parameter(Mandatory=$true)][string]$Keys)
    $chords = $Keys.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    if ($chords.Count -eq 0) { throw "keys specification is empty" }
    return (($chords | ForEach-Object { ConvertTo-SendKeysChord -Chord $_ }) -join '')
}

function Send-TypeText {
    param([Parameter(Mandatory=$true)][string]$Text, [bool]$KeepClipboard = $false)
    Add-Type -AssemblyName System.Windows.Forms
    # Non-ASCII text (e.g. Chinese) goes through the clipboard: SendKeys Unicode
    # support depends on the active keyboard layout and is unreliable. The user's
    # clipboard is snapshotted first and restored afterwards - silently replacing
    # it would be a destructive side effect nobody asked for.
    $isAscii = $true
    foreach ($ch in $Text.ToCharArray()) { if ([int]$ch -gt 127) { $isAscii = $false; break } }
    if ($isAscii) {
        # ConvertTo-SendKeysText escapes SendKeys metacharacters (+^%~(){});
        # without it a leading '+' is read as the Shift modifier and silently
        # capitalizes the next character instead of typing a literal plus.
        [System.Windows.Forms.SendKeys]::SendWait((ConvertTo-SendKeysText -Text $Text))
        [System.Windows.Forms.SendKeys]::Flush()
        return $true
    }
    $snapshot = $null
    if (-not $KeepClipboard) { $snapshot = Get-ClipboardSnapshot }
    $restored = $true
    try {
        Set-ClipboardTextRobust -Text $Text
        Start-Sleep -Milliseconds 60
        [System.Windows.Forms.SendKeys]::SendWait('^v')
        [System.Windows.Forms.SendKeys]::Flush()
        # Give the target app time to consume the paste before the clipboard is
        # handed back; restoring immediately can paste stale content instead.
        Start-Sleep -Milliseconds 250
    } finally {
        if ($snapshot) { $restored = Restore-ClipboardSnapshot -Snapshot $snapshot }
    }
    return $restored
}

function Send-KeySequence {
    param([Parameter(Mandatory=$true)][string]$SendKeys)
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait($SendKeys)
    [System.Windows.Forms.SendKeys]::Flush()
}

# ---- Command implementations -----------------------------------------------------
# Resolve the action window: hwnd + descriptor WITHOUT UIA (works for Chromium
# windows that refuse FromHandle); the UIA element is only fetched when element
# targeting is requested.
function Resolve-ActionWindow {
    param(
        [Parameter(Mandatory=$true)]$Parsed,
        [bool]$NeedUia = $false
    )
    $hwnd = Resolve-WindowHwnd -Parsed $Parsed
    $desc = Get-ProcessWindowDescriptor -Hwnd $hwnd
    $windowEl = $null
    if ($NeedUia) {
        # FromHandle on the already-resolved hwnd: no ambiguity and no reliance
        # on UIA's root-children listing, which can order/report windows
        # differently from user32 (and misses sessions with ghost windows).
        $windowEl = Get-UiaWindowElementByHwnd -Hwnd $hwnd
        # Enrich with the UIA view (authoritative title/bounds) when available.
        # The UIA hwnd also becomes authoritative for foreground switching:
        # a process's MainWindowHandle can be a console window while the real UI
        # window is a hosted WinForms/WPF form.
        try {
            $uiaDesc = Get-WindowDescriptor -Element $windowEl
            if ($uiaDesc -and $uiaDesc.hwnd) { $desc = $uiaDesc }
        } catch {}
    }
    return @{ hwnd = $hwnd; desc = $desc; windowEl = $windowEl }
}

function Test-ElementTargeting {
    return (($null -ne $script:params.element) -or ($null -ne $script:params.'element-path'))
}

function Invoke-Focus {
    if (-not $script:params.app) { Write-ZccError -Command 'focus' -Code 'invalid_arguments' -Message 'focus requires app selector' }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed
    Assert-TargetAllowed -Descriptor $w.desc
    Assert-ForegroundWindow -Hwnd $w.hwnd
    Write-ZccAudit -Command 'focus' -Descriptor $w.desc -Target @{ hwnd = $w.hwnd } -Extra $null
    Write-ZccResult -Command 'focus' -Result $w.desc -ActionSent $true
}

function Invoke-Click {
    if (-not $script:params.app) { Write-ZccError -Command 'click' -Code 'invalid_arguments' -Message 'click requires app selector' }
    if ($null -ne $script:params.element -and $null -ne $script:params.'element-path') {
        Write-ZccError -Command 'click' -Code 'invalid_arguments' -Message 'provide either --element N or --element-path P, not both'
    }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed -NeedUia (Test-ElementTargeting)
    $windowEl = $w.windowEl
    $desc = $w.desc
    Assert-TargetAllowed -Descriptor $desc
    $preStateId = Get-PreActionStateId -Params $script:params -WindowElement $windowEl

    $method = 'coordinate'
    $target = $null
    $targetInfo = $null
    $resolvedElement = $null
    $resolvedStateId = $null
    $button = $(if ($script:params.button) { $script:params.button } else { 'left' })
    $double = [bool]$script:params.double
    # Semantic patterns can only express a plain left single click; anything
    # else (right/middle/double) must go through real mouse input so the target
    # app sees the actual button/window message it expects.
    $forceCoordinate = ($button -ne 'left') -or $double

    if (Test-ElementTargeting) {
        $resolved = Resolve-ElementTarget -Params $script:params -WindowElement $windowEl
        $el = $resolved.Element
        $resolvedElement = $el
        $targetInfo = @{ index = $resolved.Index; path = $resolved.Path; resolve = $resolved.Method }
        $resolvedStateId = $resolved.StateId
        if (-not $forceCoordinate) {
            $invoke = Get-ElementPattern -Element $el -Pattern ([System.Windows.Automation.InvokePattern]::Pattern)
            if ($invoke) {
                $method = Invoke-UiaInvokeSafe -InvokePattern $invoke -TargetPid ([int]$desc.pid) -TargetHwnd ([int64]$w.hwnd)
            } else {
                $select = Get-ElementPattern -Element $el -Pattern ([System.Windows.Automation.SelectionItemPattern]::Pattern)
                if ($select) { $select.Select(); $method = 'uia-select' }
                else {
                    $toggle = Get-ElementPattern -Element $el -Pattern ([System.Windows.Automation.TogglePattern]::Pattern)
                    if ($toggle) { $toggle.Toggle(); $method = 'uia-toggle' }
                    else {
                        $expand = Get-ElementPattern -Element $el -Pattern ([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
                        if ($expand) {
                            if ($expand.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) {
                                $expand.Collapse(); $method = 'uia-collapse'
                            } else {
                                $expand.Expand(); $method = 'uia-expand'
                            }
                        }
                    }
                }
            }
        }
        if ($method -eq 'coordinate') {
            $pt = Get-ElementCenter -Element $el
            Assert-ForegroundWindow -Hwnd $w.hwnd
            Invoke-MouseClick -X $pt.x -Y $pt.y -Button $button -Double $double
            $method = $(if ($forceCoordinate) { 'coordinate' } else { 'coordinate-fallback' })
            $target = $pt
        }
    } elseif ($null -ne $script:params.x -and $null -ne $script:params.y) {
        Assert-ForegroundWindow -Hwnd $w.hwnd
        Invoke-MouseClick -X ([int]$script:params.x) -Y ([int]$script:params.y) -Button $button -Double $double
        $target = @{ x = [int]$script:params.x; y = [int]$script:params.y }
    } else {
        Write-ZccError -Command 'click' -Code 'invalid_arguments' -Message 'click requires --element N or --element-path P or --x/--y'
    }

    if ($null -eq $target -and $null -ne $resolvedElement) {
        try { $target = Get-ElementCenter -Element $resolvedElement } catch { $target = $null }
    }

    $result = [ordered]@{
        app = $desc
        method = $method
        button = $button
        double = $double
    }
    if ($targetInfo) { $result.target = $targetInfo }
    if ($target) { $result.at = $target }
    Write-ZccAudit -Command 'click' -Descriptor $desc -Target $result.target -Extra @{ method = $method; button = $button; double = $double }
    Complete-ZccAction -Command 'click' -Result $result -WindowElement $windowEl -Params $script:params -PreStateId $preStateId -StateId $resolvedStateId
}

function Invoke-Type {
    if (-not $script:params.app) { Write-ZccError -Command 'type' -Code 'invalid_arguments' -Message 'type requires app selector' }
    if ($null -eq $script:params.text) { Write-ZccError -Command 'type' -Code 'invalid_arguments' -Message 'type requires --text' }
    if ($null -ne $script:params.element -and $null -ne $script:params.'element-path') {
        Write-ZccError -Command 'type' -Code 'invalid_arguments' -Message 'provide either --element N or --element-path P, not both'
    }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed -NeedUia (Test-ElementTargeting)
    $windowEl = $w.windowEl
    $desc = $w.desc
    Assert-TargetAllowed -Descriptor $desc
    $preStateId = Get-PreActionStateId -Params $script:params -WindowElement $windowEl
    # Typing needs the window to own the keyboard focus; fail closed rather than
    # send the text into whatever window happens to be on top.
    Assert-ForegroundWindow -Hwnd $w.hwnd

    $focused = $null
    $targetInfo = $null
    $resolvedStateId = $null
    if (Test-ElementTargeting) {
        $resolved = Resolve-ElementTarget -Params $script:params -WindowElement $windowEl
        $el = $resolved.Element
        $targetInfo = @{ index = $resolved.Index; path = $resolved.Path; resolve = $resolved.Method }
        $resolvedStateId = $resolved.StateId
        try { $el.SetFocus(); $focused = $resolved.Index }
        catch {
            $pt = Get-ElementCenter -Element $el
            Invoke-MouseClick -X $pt.x -Y $pt.y
        }
    }
    Start-Sleep -Milliseconds 50
    $clipboardRestored = Send-TypeText -Text $script:params.text -KeepClipboard ([bool]$script:params.'keep-clipboard')
    if ($script:params.submit) {
        Start-Sleep -Milliseconds 80
        Send-KeySequence -SendKeys '{ENTER}'
    }
    $result = [ordered]@{
        app = $desc
        length = "$($script:params.text)".Length
        focused_element = $focused
        submitted = [bool]$script:params.submit
        clipboard_restored = $clipboardRestored
    }
    if ($targetInfo) { $result.target = $targetInfo }
    Write-ZccAudit -Command 'type' -Descriptor $desc -Target $targetInfo -Extra @{ length = "$($script:params.text)".Length; submit = [bool]$script:params.submit }
    Complete-ZccAction -Command 'type' -Result $result -WindowElement $windowEl -Params $script:params -PreStateId $preStateId -StateId $resolvedStateId
}

function Invoke-Keypress {
    if (-not $script:params.app) { Write-ZccError -Command 'keypress' -Code 'invalid_arguments' -Message 'keypress requires app selector' }
    if (-not $script:params.keys) { Write-ZccError -Command 'keypress' -Code 'invalid_arguments' -Message 'keypress requires --keys' }
    if ($null -ne $script:params.element -and $null -ne $script:params.'element-path') {
        Write-ZccError -Command 'keypress' -Code 'invalid_arguments' -Message 'provide either --element N or --element-path P, not both'
    }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed -NeedUia (Test-ElementTargeting)
    $windowEl = $w.windowEl
    $desc = $w.desc
    Assert-TargetAllowed -Descriptor $desc
    $preStateId = Get-PreActionStateId -Params $script:params -WindowElement $windowEl
    Assert-ForegroundWindow -Hwnd $w.hwnd
    $targetInfo = $null
    $resolvedStateId = $null
    if (Test-ElementTargeting) {
        $resolved = Resolve-ElementTarget -Params $script:params -WindowElement $windowEl
        $targetInfo = @{ index = $resolved.Index; path = $resolved.Path; resolve = $resolved.Method }
        $resolvedStateId = $resolved.StateId
        try { $resolved.Element.SetFocus() } catch {}
    }
    $sendKeys = ConvertTo-SendKeysSequence -Keys $script:params.keys
    Start-Sleep -Milliseconds 40
    Send-KeySequence -SendKeys $sendKeys
    $result = [ordered]@{ app = $desc; keys = $script:params.keys; send_keys = $sendKeys }
    if ($targetInfo) { $result.target = $targetInfo }
    Write-ZccAudit -Command 'keypress' -Descriptor $desc -Target $targetInfo -Extra @{ keys = $script:params.keys }
    Complete-ZccAction -Command 'keypress' -Result $result -WindowElement $windowEl -Params $script:params -PreStateId $preStateId -StateId $resolvedStateId
}

function Invoke-Scroll {
    if (-not $script:params.app) { Write-ZccError -Command 'scroll' -Code 'invalid_arguments' -Message 'scroll requires app selector' }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed -NeedUia (Test-ElementTargeting)
    $windowEl = $w.windowEl
    $desc = $w.desc
    Assert-TargetAllowed -Descriptor $desc
    $direction = $(if ($script:params.direction) { $script:params.direction } else { 'down' })
    if (@('up', 'down', 'left', 'right') -notcontains $direction) {
        Write-ZccError -Command 'scroll' -Code 'invalid_arguments' -Message 'scroll --direction must be up, down, left or right'
    }
    $amount = 3
    if ($null -ne $script:params.amount) { $amount = [int]$script:params.amount }
    $preStateId = Get-PreActionStateId -Params $script:params -WindowElement $windowEl

    $method = 'wheel'
    $targetInfo = $null
    $resolvedStateId = $null
    $pt = $null
    $isHorizontal = ($direction -eq 'left' -or $direction -eq 'right')
    if (Test-ElementTargeting) {
        $resolved = Resolve-ElementTarget -Params $script:params -WindowElement $windowEl
        $targetInfo = @{ index = $resolved.Index; path = $resolved.Path; resolve = $resolved.Method }
        $resolvedStateId = $resolved.StateId
        $pt = Get-ElementCenter -Element $resolved.Element
        # semantic scroll first: a wheel event over a child control frequently
        # does nothing, while ScrollPattern reaches the actual scroll provider.
        $scrollPattern = Get-ElementPattern -Element $resolved.Element -Pattern ([System.Windows.Automation.ScrollPattern]::Pattern)
        $canScroll = $false
        if ($scrollPattern) {
            if ($isHorizontal) { $canScroll = [bool]$scrollPattern.Current.HorizontallyScrollable }
            else { $canScroll = [bool]$scrollPattern.Current.VerticallyScrollable }
        }
        if ($canScroll) {
            $horizontal = [System.Windows.Automation.ScrollAmount]::NoAmount
            $vertical = [System.Windows.Automation.ScrollAmount]::NoAmount
            if ($direction -eq 'up') { $vertical = [System.Windows.Automation.ScrollAmount]::LargeDecrement }
            elseif ($direction -eq 'down') { $vertical = [System.Windows.Automation.ScrollAmount]::LargeIncrement }
            elseif ($direction -eq 'left') { $horizontal = [System.Windows.Automation.ScrollAmount]::LargeDecrement }
            elseif ($direction -eq 'right') { $horizontal = [System.Windows.Automation.ScrollAmount]::LargeIncrement }
            try {
                for ($i = 0; $i -lt $amount; $i++) {
                    $scrollPattern.Scroll($horizontal, $vertical)
                    Start-Sleep -Milliseconds 60
                }
                $method = 'uia-scroll'
            } catch {
                $method = 'wheel'
            }
        }
    } elseif ($null -ne $script:params.x -and $null -ne $script:params.y) {
        $pt = @{ x = [int]$script:params.x; y = [int]$script:params.y }
    } else {
        $r = $desc.bounds
        if (-not $r) { Write-ZccError -Command 'scroll' -Code 'window_has_no_bounds' -Message 'window bounds unavailable; pass --element or --x/--y' }
        $pt = @{ x = $r.x + [int]($r.width / 2); y = $r.y + [int]($r.height / 2) }
    }

    if ($method -eq 'wheel') {
        Assert-ForegroundWindow -Hwnd $w.hwnd
        Assert-CoordinatesInScreen -X $pt.x -Y $pt.y
        [void][ZccNative]::SetCursorPos($pt.x, $pt.y)
        Start-Sleep -Milliseconds 40
        if ($isHorizontal) {
            $delta = $script:ZccWheelDelta * $amount
            if ($direction -eq 'left') { $delta = -$delta }
            [ZccNative]::mouse_event($script:ZccHWheel, $pt.x, $pt.y, $delta, 0)
        } else {
            $delta = $script:ZccWheelDelta * $amount
            if ($direction -eq 'down') { $delta = -$delta }
            [ZccNative]::mouse_event($script:ZccWheel, $pt.x, $pt.y, $delta, 0)
        }
    }

    $result = [ordered]@{ app = $desc; direction = $direction; amount = $amount; at = $pt; method = $method }
    if ($targetInfo) { $result.target = $targetInfo }
    Write-ZccAudit -Command 'scroll' -Descriptor $desc -Target $targetInfo -Extra @{ direction = $direction; amount = $amount }
    Complete-ZccAction -Command 'scroll' -Result $result -WindowElement $windowEl -Params $script:params -PreStateId $preStateId -StateId $resolvedStateId
}

function Invoke-Drag {
    if (-not $script:params.app) { Write-ZccError -Command 'drag' -Code 'invalid_arguments' -Message 'drag requires app selector' }
    if (-not $script:params.path) { Write-ZccError -Command 'drag' -Code 'invalid_arguments' -Message 'drag requires --path "x,y>x,y>x,y"' }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed
    $desc = $w.desc
    Assert-TargetAllowed -Descriptor $desc

    $points = @()
    foreach ($seg in ($script:params.path -split '>')) {
        $xy = $seg.Trim() -split ','
        if ($xy.Count -ne 2) { Write-ZccError -Command 'drag' -Code 'invalid_arguments' -Message "drag path segment '$seg' is not x,y" }
        $px = 0; $py = 0
        if (-not [int]::TryParse($xy[0].Trim(), [ref]$px) -or -not [int]::TryParse($xy[1].Trim(), [ref]$py)) {
            Write-ZccError -Command 'drag' -Code 'invalid_arguments' -Message "drag path segment '$seg' is not integer x,y"
        }
        Assert-CoordinatesInScreen -X $px -Y $py
        $points += @{ x = $px; y = $py }
    }
    if ($points.Count -lt 2) { Write-ZccError -Command 'drag' -Code 'invalid_arguments' -Message 'drag path needs at least 2 points' }

    Assert-ForegroundWindow -Hwnd $w.hwnd
    [void][ZccNative]::SetCursorPos($points[0].x, $points[0].y)
    Start-Sleep -Milliseconds 60
    [ZccNative]::mouse_event($script:ZccMouseLeftDown, $points[0].x, $points[0].y, 0, 0)
    for ($i = 1; $i -lt $points.Count; $i++) {
        Start-Sleep -Milliseconds 30
        [void][ZccNative]::SetCursorPos($points[$i].x, $points[$i].y)
    }
    Start-Sleep -Milliseconds 60
    $last = $points[$points.Count - 1]
    [ZccNative]::mouse_event($script:ZccMouseLeftUp, $last.x, $last.y, 0, 0)
    $result = [ordered]@{ app = $desc; points = $points }
    Write-ZccAudit -Command 'drag' -Descriptor $desc -Target @{ points = $points } -Extra $null
    Write-ZccResult -Command 'drag' -Result $result -ActionSent $true
}

function Invoke-SetValue {
    if (-not $script:params.app) { Write-ZccError -Command 'set-value' -Code 'invalid_arguments' -Message 'set-value requires app selector' }
    if ($null -eq $script:params.element -and $null -eq $script:params.'element-path') { Write-ZccError -Command 'set-value' -Code 'invalid_arguments' -Message 'set-value requires --element N or --element-path P' }
    if ($null -eq $script:params.text) { Write-ZccError -Command 'set-value' -Code 'invalid_arguments' -Message 'set-value requires --text' }
    if ($null -ne $script:params.element -and $null -ne $script:params.'element-path') {
        Write-ZccError -Command 'set-value' -Code 'invalid_arguments' -Message 'provide either --element N or --element-path P, not both'
    }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed -NeedUia $true
    $windowEl = $w.windowEl
    $desc = $w.desc
    Assert-TargetAllowed -Descriptor $desc
    $preStateId = Get-PreActionStateId -Params $script:params -WindowElement $windowEl
    $resolved = Resolve-ElementTarget -Params $script:params -WindowElement $windowEl
    $vp = Get-ElementPattern -Element $resolved.Element -Pattern ([System.Windows.Automation.ValuePattern]::Pattern)
    if (-not $vp) {
        Write-ZccError -Command 'set-value' -Code 'action_unavailable' -Message "element does not support ValuePattern; use type after focusing it"
    }
    # ValuePattern writes through the accessibility provider: no keystrokes and
    # no foreground steal, so this is the least invasive way to fill a field.
    $vp.SetValue([string]$script:params.text)
    $targetInfo = @{ index = $resolved.Index; path = $resolved.Path; resolve = $resolved.Method }
    $resolvedStateId = $resolved.StateId
    $result = [ordered]@{ app = $desc; length = "$($script:params.text)".Length; target = $targetInfo }
    Write-ZccAudit -Command 'set-value' -Descriptor $desc -Target $targetInfo -Extra @{ length = "$($script:params.text)".Length }
    Complete-ZccAction -Command 'set-value' -Result $result -WindowElement $windowEl -Params $script:params -PreStateId $preStateId -StateId $resolvedStateId
}

# move: position the cursor without clicking. Opens hover menus / tooltips and
# pre-positions for drag. Foreground is asserted because hover state only
# appears while the window is active - and because a failed switch would park
# the cursor over a different window.
function Invoke-Move {
    if (-not $script:params.app) { Write-ZccError -Command 'move' -Code 'invalid_arguments' -Message 'move requires app selector' }
    $parsed = Resolve-WindowSelector -Selector $script:params.app
    $w = Resolve-ActionWindow -Parsed $parsed -NeedUia (Test-ElementTargeting)
    $windowEl = $w.windowEl
    $desc = $w.desc
    Assert-TargetAllowed -Descriptor $desc
    $preStateId = Get-PreActionStateId -Params $script:params -WindowElement $windowEl

    $method = 'coordinate'
    $target = $null
    $targetInfo = $null
    $resolvedStateId = $null
    if (Test-ElementTargeting) {
        $resolved = Resolve-ElementTarget -Params $script:params -WindowElement $windowEl
        $target = Get-ElementCenter -Element $resolved.Element
        $method = 'element'
        $targetInfo = @{ index = $resolved.Index; path = $resolved.Path; resolve = $resolved.Method }
        $resolvedStateId = $resolved.StateId
    } elseif ($null -ne $script:params.x -and $null -ne $script:params.y) {
        $target = @{ x = [int]$script:params.x; y = [int]$script:params.y }
    } else {
        Write-ZccError -Command 'move' -Code 'invalid_arguments' -Message 'move requires --element N or --element-path P or --x/--y'
    }

    Assert-ForegroundWindow -Hwnd $w.hwnd
    Assert-CoordinatesInScreen -X $target.x -Y $target.y
    [void][ZccNative]::SetCursorPos($target.x, $target.y)
    $result = [ordered]@{
        app = $desc
        method = $method
        target = $targetInfo
        at = $target
    }
    Write-ZccAudit -Command 'move' -Descriptor $desc -Target $targetInfo -Extra @{ at = $target }
    Complete-ZccAction -Command 'move' -Result $result -WindowElement $windowEl -Params $script:params -PreStateId $preStateId -StateId $resolvedStateId
}

function Invoke-ZccActionDispatch {
    param([Parameter(Mandatory=$true)][string]$Command, $Params)
    $script:params = $Params
    switch ($Command) {
        'focus'      { Invoke-ZccMain -Command 'focus' -Body { Invoke-Focus } }
        'click'      { Invoke-ZccMain -Command 'click' -Body { Invoke-Click } }
        'type'       { Invoke-ZccMain -Command 'type' -Body { Invoke-Type } }
        'keypress'   { Invoke-ZccMain -Command 'keypress' -Body { Invoke-Keypress } }
        'scroll'     { Invoke-ZccMain -Command 'scroll' -Body { Invoke-Scroll } }
        'drag'       { Invoke-ZccMain -Command 'drag' -Body { Invoke-Drag } }
        'set-value'  { Invoke-ZccMain -Command 'set-value' -Body { Invoke-SetValue } }
        'move'       { Invoke-ZccMain -Command 'move' -Body { Invoke-Move } }
        default {
            Write-ZccError -Command $Command -Code 'unknown_command' -Message "zcc-action.ps1 does not handle command '$Command'"
        }
    }
}

if (-not $FunctionsOnly) {
    if (-not $Command -or -not $ParamsFile) {
        Write-ZccError -Command ($Command -or 'unknown') -Code 'invalid_arguments' -Message 'Command and ParamsFile are required'
    }
    Set-ZccOutFile -Path $OutFile
    $script:ZccCurrentParams = (Get-Content -Raw -Path $ParamsFile | ConvertFrom-Json)
    Invoke-ZccActionDispatch -Command $Command -Params $script:ZccCurrentParams
}