#requires -Version 5.1
# DSH Computer Use - Windows window catalog: status / list-apps / list-windows.
# EnumWindows + user32 facts instead of UIA root-children: faster, sees owned
# dialogs and secondary windows, and drops DWM-cloaked ghosts and tool windows.
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

function Get-WindowEntries {
    param($Selector = $null, [bool]$IncludeAll = $false)
    $entries = @()
    foreach ($desc in (Get-TopLevelWindows -IncludeAll $IncludeAll)) {
        if ($Selector) {
            $parsed = Resolve-WindowSelector -Selector $Selector
            $hit = $false
            switch ($parsed.Kind) {
                'pid'   { if ([int]$desc.pid -eq [int]$parsed.Value.Trim()) { $hit = $true } }
                'hwnd'  { if ("$($desc.hwnd)" -eq $parsed.Value.Trim()) { $hit = $true } }
                'name'  { if ($desc.process -and ([string]$desc.process).ToLowerInvariant().Contains($parsed.Value.Trim().ToLowerInvariant())) { $hit = $true } }
                default { if ($desc.title -and ([string]$desc.title).ToLowerInvariant().Contains($parsed.Value.Trim().ToLowerInvariant())) { $hit = $true } }
            }
            if (-not $hit) { continue }
        }
        $entries += $desc
    }
    return $entries
}

function Invoke-ZccAppsDispatch {
    param([Parameter(Mandatory=$true)][string]$Command, $Params)
    switch ($Command) {
        'status' {
            Invoke-ZccMain -Command 'status' -Body {
                $windows = Get-WindowEntries
                $inputDesktop = Get-InputDesktopName
                $threadDesktop = Get-ThreadDesktopName
                $result = [ordered]@{
                    platform = 'win32'
                    backend = 'uiautomation'
                    capabilities = @('status', 'stop-worker', 'list-apps', 'list-windows', 'get-app-state', 'find', 'wait',
                                     'screenshot', 'focus', 'move', 'click', 'type', 'keypress', 'scroll',
                                     'drag', 'set-value')
                    window_count = $windows.Count
                    input_desktop = $inputDesktop
                    thread_desktop = $threadDesktop
                    desktop_mismatch = ($threadDesktop -ne 'unknown' -and $inputDesktop -ne 'unknown' -and $threadDesktop -ne $inputDesktop)
                    session_locked = (Test-SessionLocked)
                    worker_mode = [bool]$script:ZccWorkerMode
                    state_cache_dir = (Get-StateCacheDir)
                    audit_enabled = (-not [string]::IsNullOrWhiteSpace($env:CUA_AUDIT_PATH))
                    trajectory_enabled = (-not [string]::IsNullOrWhiteSpace($env:CUA_TRAJECTORY_PATH))
                    deny_list_active = ((-not [string]::IsNullOrWhiteSpace($env:CUA_DENY_TITLES)) -or (-not [string]::IsNullOrWhiteSpace($env:CUA_DENY_PROCESSES)))
                    notes = 'Windows backend: UIAutomation semantic actions first, coordinate mouse/keyboard injection as fallback. Actions verify freshness (state cache fingerprint) and can wait for the expected UI change.'
                }
                Write-ZccResult -Command 'status' -Result $result
            }
        }
        'list-apps' {
            Invoke-ZccMain -Command 'list-apps' -Body {
                $includeAll = [bool]$Params.all
                $entries = @(Get-WindowEntries -IncludeAll $includeAll)
                $limit = 200
                $truncated = $false
                if ($entries.Count -gt $limit) { $entries = $entries[0..($limit - 1)]; $truncated = $true }
                $result = [ordered]@{
                    windows = $entries
                    count = $entries.Count
                    truncated = $truncated
                    filtered = (-not $includeAll)
                }
                Write-ZccResult -Command 'list-apps' -Result $result
            }
        }
        'list-windows' {
            if (-not $Params.app) { Write-ZccError -Command 'list-windows' -Code 'invalid_arguments' -Message 'list-windows requires app selector' }
            Invoke-ZccMain -Command 'list-windows' -Body {
                $entries = @(Get-WindowEntries -Selector $Params.app -IncludeAll ([bool]$Params.all))
                $result = [ordered]@{ windows = $entries; count = $entries.Count; truncated = $false }
                Write-ZccResult -Command 'list-windows' -Result $result
            }
        }
        default {
            Write-ZccError -Command $Command -Code 'unknown_command' -Message "zcc-apps.ps1 does not handle command '$Command'"
        }
    }
}

if (-not $FunctionsOnly) {
    if (-not $Command -or -not $ParamsFile) {
        Write-ZccError -Command ($Command -or 'unknown') -Code 'invalid_arguments' -Message 'Command and ParamsFile are required'
    }
    Set-ZccOutFile -Path $OutFile
    $script:ZccCurrentParams = (Get-Content -Raw -Path $ParamsFile | ConvertFrom-Json)
    Invoke-ZccAppsDispatch -Command $Command -Params $script:ZccCurrentParams
}