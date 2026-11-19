#requires -Version 5.1
# DSH Computer Use - Windows accessibility state: get-app-state / find / wait.
# Every element carries an index (the action target), a stable path, role, name,
# value, state flags, supported patterns and screen bounds.
# get-app-state also persists a state cache so actions can resolve an index
# without re-walking the tree and can prove the snapshot is still current.
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

function Resolve-StateWindow {
    param([Parameter(Mandatory=$true)][string]$Selector)
    $parsed = Resolve-WindowSelector -Selector $Selector
    $hwnd = Resolve-WindowHwnd -Parsed $parsed
    $element = Get-UiaWindowElementByHwnd -Hwnd $hwnd
    $desc = $null
    try { $desc = Get-WindowDescriptor -Element $element } catch { $desc = Get-ProcessWindowDescriptor -Hwnd $hwnd }
    return @{ hwnd = $hwnd; element = $element; desc = $desc }
}

function Enable-ChromiumAccessibilityHint {
    param([int64]$Hwnd)
    try {
        $out = [IntPtr]::Zero
        # WM_GETOBJECT (0x003D) with OBJID_CLIENT (-4) nudges Chromium/Electron to build its AX tree.
        [void][ZccNative]::SendMessageTimeoutW([IntPtr]$Hwnd, [uint32]0x003D, [IntPtr]::Zero, [IntPtr](-4), [uint32]2, [uint32]300, [ref]$out)
        $renderChild = [ZccNative]::FindWindowExW([IntPtr]$Hwnd, [IntPtr]::Zero, 'Chrome_RenderWidgetHostHWND', $null)
        if ($renderChild -ne [IntPtr]::Zero) {
            [void][ZccNative]::SendMessageTimeoutW($renderChild, [uint32]0x003D, [IntPtr]::Zero, [IntPtr](-4), [uint32]2, [uint32]300, [ref]$out)
        }
        Start-Sleep -Milliseconds 150
    } catch {}
}

function Invoke-GetAppState {
    if (-not $script:params.app) {
        Write-ZccError -Command 'get-app-state' -Code 'invalid_arguments' -Message 'get-app-state requires app selector'
    }
    if ($null -ne $script:params.'scope-element' -and $null -ne $script:params.'scope-path') {
        Write-ZccError -Command 'get-app-state' -Code 'invalid_arguments' -Message 'provide either --scope-element N or --scope-path P, not both'
    }
    $maxElements = 2000
    if ($null -ne $script:params.'max-elements') { $maxElements = [int]$script:params.'max-elements' }
    $compact = [bool]$script:params.compact

    $w = Resolve-StateWindow -Selector $script:params.app
    $targetRoot = $w.element
    $rootPath = '0'
    $scoped = $false

    if ($null -ne $script:params.'scope-element' -or $null -ne $script:params.'scope-path') {
        $scoped = $true
        $scopeParams = @{ app = $script:params.app }
        if ($null -ne $script:params.'scope-element') { $scopeParams.element = $script:params.'scope-element' }
        if ($null -ne $script:params.'scope-path') { $scopeParams.'element-path' = $script:params.'scope-path' }
        $resolved = Resolve-ElementTarget -Params $scopeParams -WindowElement $w.element
        $targetRoot = $resolved.Element
        if ($resolved.Path) { $rootPath = [string]$resolved.Path }
    }

    try {
        $snapshot = Get-ElementSnapshot -WindowElement $targetRoot -MaxElements $maxElements -RootPath $rootPath
        if (-not $scoped -and $snapshot.elements.Count -le 3 -and $w.desc.class -like 'Chrome_WidgetWin*') {
            Enable-ChromiumAccessibilityHint -Hwnd $w.hwnd
            $retry = Get-ElementSnapshot -WindowElement $targetRoot -MaxElements $maxElements -RootPath $rootPath
            if ($retry.elements.Count -gt $snapshot.elements.Count) {
                $snapshot = $retry
            }
        }
    } catch {
        # A Chromium/Electron window with accessibility disabled has no tree to
        # walk. Say so explicitly instead of returning a misleadingly tiny one.
        throw "failed to read the accessibility tree: $($_.Exception.Message). Chromium/Electron windows expose no tree until accessibility is enabled; use screenshot --grid/--annotate and coordinate clicks for those windows."
    }
    $stateId = Get-SnapshotStateId -Snapshot $snapshot
    $stateCached = Save-SnapshotCache -Hwnd $w.hwnd -App $w.desc -Snapshot $snapshot -StateId $stateId -Scoped $scoped

    $result = [ordered]@{
        app = $w.desc
        state_id = $stateId
        state_cached = $stateCached
        element_count = $snapshot.elements.Count
        truncated = $snapshot.truncated
        scoped = $scoped
        compact = $compact
        text = ($snapshot.lines -join "`n")
    }
    if ($scoped) { $result.scope_path = $rootPath }
    if (-not $compact) {
        $result.elements = $snapshot.elements
    }
    Write-ZccResult -Command 'get-app-state' -Result $result
}

function Invoke-Find {
    if (-not $script:params.app) {
        Write-ZccError -Command 'find' -Code 'invalid_arguments' -Message 'find requires app selector'
    }
    if (-not $script:params.role -and -not $script:params.name -and -not $script:params.value) {
        Write-ZccError -Command 'find' -Code 'invalid_arguments' -Message 'find requires at least one of --role, --name, --value'
    }
    $limit = 20
    if ($null -ne $script:params.limit) { $limit = [int]$script:params.limit }
    $useCache = [bool]$script:params.'use-cache'
    $maxAge = 2000
    if ($null -ne $script:params.'max-age') { $maxAge = [int]$script:params.'max-age' }

    $w = Resolve-StateWindow -Selector $script:params.app
    $elements = $null
    $stateId = $null
    $source = 'live'
    $truncated = $false

    if ($useCache) {
        $cache = Get-StateCache -Hwnd $w.hwnd
        if ($null -ne $cache -and $cache.captured_at) {
            try {
                $captured = [DateTime]::Parse($cache.captured_at).ToUniversalTime()
                $ageMs = [int](([DateTime]::UtcNow) - $captured).TotalMilliseconds
                $cacheFresh = ($ageMs -ge 0 -and $ageMs -le $maxAge)
                if ($cacheFresh -and $cache.app -and [int]$cache.app.hwnd -eq $w.hwnd) {
                    $elements = @($cache.elements)
                    $stateId = [string]$cache.state_id
                    $source = 'cache'
                    $truncated = [bool]$cache.truncated
                }
            } catch {}
        }
    }
    if ($null -eq $elements) {
        $snapshot = Get-ElementSnapshot -WindowElement $w.element -MaxElements 2000
        $elements = @($snapshot.elements)
        $stateId = Get-SnapshotStateId -Snapshot $snapshot
        $truncated = $snapshot.truncated
        $source = 'live'
        [void](Save-SnapshotCache -Hwnd $w.hwnd -App $w.desc -Snapshot $snapshot -StateId $stateId)
    }

    $roleNeedle = ([string]$script:params.role).ToLowerInvariant()
    $nameNeedle = ([string]$script:params.name).ToLowerInvariant()
    $valueNeedle = ([string]$script:params.value).ToLowerInvariant()
    $nameExact = [bool]$script:params.'name-exact'
    $matches = New-Object System.Collections.ArrayList
    foreach ($el in $elements) {
        if ($roleNeedle -and -not ([string]$el.role).ToLowerInvariant().Contains($roleNeedle)) { continue }
        if ($nameNeedle) {
            $candidateName = ([string]$el.name).ToLowerInvariant()
            if ($nameExact) { if ($candidateName -ne $nameNeedle) { continue } }
            else { if (-not $candidateName.Contains($nameNeedle)) { continue } }
        }
        if ($valueNeedle -and -not ([string]$el.value).ToLowerInvariant().Contains($valueNeedle)) { continue }
        [void]$matches.Add($el)
        if ($matches.Count -ge $limit + 1) { break }
    }
    $truncatedByLimit = ($matches.Count -gt $limit)
    if ($truncatedByLimit) { $matches.RemoveAt($matches.Count - 1) }

    $result = [ordered]@{
        app = $w.desc
        state_id = $stateId
        source = $source
        count = $matches.Count
        limit = $limit
        truncated = ($truncated -or $truncatedByLimit)
        matches = $matches
    }
    Write-ZccResult -Command 'find' -Result $result
}

function Invoke-Wait {
    if (-not $script:params.app) {
        Write-ZccError -Command 'wait' -Code 'invalid_arguments' -Message 'wait requires app selector'
    }
    if ($script:params.for -and $script:params.gone) {
        Write-ZccError -Command 'wait' -Code 'invalid_arguments' -Message 'wait requires exactly one of --for or --gone'
    }
    if (-not $script:params.for -and -not $script:params.gone) {
        Write-ZccError -Command 'wait' -Code 'invalid_arguments' -Message 'wait requires --for <spec> or --gone <spec>'
    }
    $timeoutMs = 5000
    if ($null -ne $script:params.timeout) { $timeoutMs = [int]$script:params.timeout }
    $intervalMs = 250
    if ($null -ne $script:params.interval) { $intervalMs = [int]$script:params.interval }

    $w = Resolve-StateWindow -Selector $script:params.app
    $gone = [bool]$script:params.gone
    $spec = $(if ($gone) { [string]$script:params.gone } else { [string]$script:params.for })
    $wait = Wait-ForPredicate -WindowElement $w.element -Spec $spec -Gone $gone -TimeoutMs $timeoutMs -IntervalMs $intervalMs -Hwnd $w.hwnd -App $w.desc

    $result = [ordered]@{
        app = $w.desc
        kind = $(if ($gone) { 'wait_gone' } else { 'wait_for' })
        spec = $spec
        matched = [bool]$wait.matched
        elapsed_ms = $wait.elapsed_ms
        polls = $wait.polls
        state_id = $wait.state_id
    }
    if ($wait.element) { $result.element = $wait.element }
    if (-not $wait.matched) {
        Write-ZccErrorResult -Command 'wait' -Code 'verification_timeout' `
            -Message ("condition '$spec' was not met within $timeoutMs ms") -Result $result -ActionSent $false
        return
    }
    Write-ZccResult -Command 'wait' -Result $result
}

function Invoke-ZccStateDispatch {
    param([Parameter(Mandatory=$true)][string]$Command, $Params)
    $script:params = $Params
    switch ($Command) {
        'get-app-state' { Invoke-ZccMain -Command 'get-app-state' -Body { Invoke-GetAppState } }
        'find'          { Invoke-ZccMain -Command 'find' -Body { Invoke-Find } }
        'wait'          { Invoke-ZccMain -Command 'wait' -Body { Invoke-Wait } }
        default {
            Write-ZccError -Command $Command -Code 'unknown_command' -Message "zcc-state.ps1 does not handle command '$Command'"
        }
    }
}

if (-not $FunctionsOnly) {
    if (-not $Command -or -not $ParamsFile) {
        Write-ZccError -Command ($Command -or 'unknown') -Code 'invalid_arguments' -Message 'Command and ParamsFile are required'
    }
    Set-ZccOutFile -Path $OutFile
    $script:ZccCurrentParams = (Get-Content -Raw -Path $ParamsFile | ConvertFrom-Json)
    Invoke-ZccStateDispatch -Command $Command -Params $script:ZccCurrentParams
}