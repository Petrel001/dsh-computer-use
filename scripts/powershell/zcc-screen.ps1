#requires -Version 5.1
# DSH Computer Use - Windows screenshot: screenshot.
# Supports full screen, single window and single element; writes a PNG to the
# requested path and returns dimensions.
# Overlays:
#   --annotate  draws element boxes + [index] labels from Get-ElementSnapshot,
#               so annotated indices match get-app-state indices exactly.
#   --grid N    draws an N-pixel grid with ABSOLUTE screen-coordinate labels,
#               so coordinates read off the image can be used directly in
#               click --x/--y (aiming aid for models without image input).
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

$script:MaxInlineBytes = 512 * 1024
$script:DefaultGridSize = 100

# Absolute-coordinate grid overlay. Labels are absolute screen coordinates so
# the model can click --x/--y without any conversion.
function Draw-ZccGrid {
    param(
        [Parameter(Mandatory=$true)]$Graphics,
        [Parameter(Mandatory=$true)]$Rect,
        [Parameter(Mandatory=$true)][int]$CellSize
    )
    $lineColor = [System.Drawing.Color]::FromArgb(170, 255, 255, 0)   # translucent yellow
    $pen = New-Object System.Drawing.Pen($lineColor, 1)
    $font = New-Object System.Drawing.Font('Consolas', 9)
    $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(170, 0, 0, 0))
    $fg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 85))
    $labelEvery = 1
    if ($CellSize -lt 40) { $labelEvery = 2 }

    $startX = [int][Math]::Ceiling($Rect.x / $CellSize) * $CellSize
    for ($ax = $startX; $ax -le $Rect.x + $Rect.width; $ax += $CellSize) {
        $lx = $ax - $Rect.x
        $Graphics.DrawLine($pen, $lx, 0, $lx, $Rect.height)
        if ((($ax / $CellSize) % $labelEvery) -eq 0) {
            $label = "$ax"
            $sz = $Graphics.MeasureString($label, $font)
            $Graphics.FillRectangle($bg, $lx + 1, 1, $sz.Width, $sz.Height)
            $Graphics.DrawString($label, $font, $fg, $lx + 1, 1)
        }
    }
    $startY = [int][Math]::Ceiling($Rect.y / $CellSize) * $CellSize
    for ($ay = $startY; $ay -le $Rect.y + $Rect.height; $ay += $CellSize) {
        $ly = $ay - $Rect.y
        $Graphics.DrawLine($pen, 0, $ly, $Rect.width, $ly)
        if ((($ay / $CellSize) % $labelEvery) -eq 0) {
            $label = "$ay"
            $sz = $Graphics.MeasureString($label, $font)
            $Graphics.FillRectangle($bg, 1, $ly + 1, $sz.Width, $sz.Height)
            $Graphics.DrawString($label, $font, $fg, 1, $ly + 1)
        }
    }
    $pen.Dispose(); $font.Dispose(); $bg.Dispose(); $fg.Dispose()
}

function Test-LabelRectOverlaps {
    param($Candidate, $Placed)
    foreach ($r in $Placed) {
        if ($Candidate.x -lt ($r.x + $r.w) -and ($Candidate.x + $Candidate.w) -gt $r.x -and
            $Candidate.y -lt ($r.y + $r.h) -and ($Candidate.y + $Candidate.h) -gt $r.y) {
            return $true
        }
    }
    return $false
}

# Element annotation overlay. Boxes are clipped to the capture rect; oversized
# pure layout containers are skipped to avoid visual clutter while preserving
# exact get-app-state indices. Returns @{ drawn, state_id }.
function Draw-ZccAnnotations {
    param(
        [Parameter(Mandatory=$true)]$Graphics,
        [Parameter(Mandatory=$true)]$Rect,
        [Parameter(Mandatory=$true)]$WindowElement,
        [int64]$Hwnd = 0,
        $App = $null
    )
    $snapshot = Get-ElementSnapshot -WindowElement $WindowElement
    $stateId = Get-SnapshotStateId -Snapshot $snapshot
    if ($Hwnd -gt 0) {
        [void](Save-SnapshotCache -Hwnd $Hwnd -App $App -Snapshot $snapshot -StateId $stateId)
    }

    # Lime first so primary controls remain crisp green (and pixel tests match).
    $palette = @(
        [System.Drawing.Color]::FromArgb(0, 255, 0),
        [System.Drawing.Color]::FromArgb(0, 230, 255),
        [System.Drawing.Color]::FromArgb(255, 165, 0),
        [System.Drawing.Color]::FromArgb(255, 90, 255)
    )
    $pens = @()
    $brushes = @()
    foreach ($col in $palette) {
        $pens += (New-Object System.Drawing.Pen($col, 2))
        $brushes += (New-Object System.Drawing.SolidBrush($col))
    }
    $font = New-Object System.Drawing.Font('Consolas', 11)
    $bg = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 0, 0, 0))
    $placedLabels = New-Object System.Collections.ArrayList
    $captureArea = [double]([Math]::Max(1, $Rect.width) * [Math]::Max(1, $Rect.height))
    $drawn = 0
    $containerRoles = @('Window', 'Pane', 'Group', 'Custom')

    try {
        foreach ($el in $snapshot.elements) {
            if (-not $el.bounds) { continue }
            if ($el.offscreen) { continue }
            if ($el.index -eq 0 -and $el.role -eq 'Window') { continue }
            $b = $el.bounds
            $x1 = [Math]::Max($b.x, $Rect.x)
            $y1 = [Math]::Max($b.y, $Rect.y)
            $x2 = [Math]::Min($b.x + $b.width, $Rect.x + $Rect.width)
            $y2 = [Math]::Min($b.y + $b.height, $Rect.y + $Rect.height)
            if ($x2 -le $x1 -or $y2 -le $y1) { continue }
            $area = [double](($x2 - $x1) * ($y2 - $y1))
            $hasInteractive = (@($el.patterns) | Where-Object { $_ -in @('invoke', 'value', 'toggle', 'select', 'expand') }).Count -gt 0
            if (-not $hasInteractive -and ($containerRoles -contains $el.role) -and ($area / $captureArea) -gt 0.55) {
                continue
            }

            $colorIdx = $drawn % $palette.Count
            $Graphics.DrawRectangle($pens[$colorIdx], ($x1 - $Rect.x), ($y1 - $Rect.y), ($x2 - $x1), ($y2 - $y1))
            $label = "[$($el.index)]"
            $sz = $Graphics.MeasureString($label, $font)
            $lw = [int][Math]::Ceiling($sz.Width)
            $lh = [int][Math]::Ceiling($sz.Height)
            $baseX = $x1 - $Rect.x
            $baseY = [Math]::Max(0, $y1 - $Rect.y - $lh - 1)
            $cand = @{ x = $baseX; y = $baseY; w = $lw; h = $lh }
            if (Test-LabelRectOverlaps -Candidate $cand -Placed $placedLabels) {
                # Try placing inside the top-left of the box, or shifting right
                $alt1 = @{ x = $baseX + 2; y = ($y1 - $Rect.y) + 2; w = $lw; h = $lh }
                if (-not (Test-LabelRectOverlaps -Candidate $alt1 -Placed $placedLabels)) {
                    $cand = $alt1
                } else {
                    $alt2 = @{ x = [Math]::Min($Rect.width - $lw, $baseX + $lw + 4); y = $baseY; w = $lw; h = $lh }
                    if (-not (Test-LabelRectOverlaps -Candidate $alt2 -Placed $placedLabels)) {
                        $cand = $alt2
                    }
                }
            }
            [void]$placedLabels.Add($cand)
            $Graphics.FillRectangle($bg, $cand.x, $cand.y, $sz.Width, $sz.Height)
            $Graphics.DrawString($label, $font, $brushes[$colorIdx], $cand.x, $cand.y)
            $drawn++
        }
    } finally {
        foreach ($p in $pens) { $p.Dispose() }
        foreach ($br in $brushes) { $br.Dispose() }
        $font.Dispose(); $bg.Dispose()
    }
    return @{ drawn = $drawn; state_id = $stateId }
}

function Invoke-PrintWindowCapture {
    param(
        [Parameter(Mandatory=$true)][int64]$Hwnd,
        [Parameter(Mandatory=$true)]$WinRect,
        [Parameter(Mandatory=$true)]$TargetRect
    )
    if ($WinRect.width -le 0 -or $WinRect.height -le 0) { return $null }
    $winBmp = New-Object System.Drawing.Bitmap($WinRect.width, $WinRect.height)
    $wg = [System.Drawing.Graphics]::FromImage($winBmp)
    $ok = $false
    try {
        $hdc = $wg.GetHdc()
        try {
            $ok = [ZccNative]::PrintWindow([IntPtr]$Hwnd, $hdc, 2) # PW_RENDERFULLCONTENT
            if (-not $ok) {
                $ok = [ZccNative]::PrintWindow([IntPtr]$Hwnd, $hdc, 0)
            }
        } finally {
            $wg.ReleaseHdc($hdc)
        }
        if (-not $ok) {
            $winBmp.Dispose()
            return $null
        }
        if ($TargetRect.x -eq $WinRect.x -and $TargetRect.y -eq $WinRect.y -and
            $TargetRect.width -eq $WinRect.width -and $TargetRect.height -eq $WinRect.height) {
            return $winBmp
        }
        $cropBmp = New-Object System.Drawing.Bitmap($TargetRect.width, $TargetRect.height)
        $cg = [System.Drawing.Graphics]::FromImage($cropBmp)
        try {
            $srcRect = New-Object System.Drawing.Rectangle(($TargetRect.x - $WinRect.x), ($TargetRect.y - $WinRect.y), $TargetRect.width, $TargetRect.height)
            $dstRect = New-Object System.Drawing.Rectangle(0, 0, $TargetRect.width, $TargetRect.height)
            $cg.DrawImage($winBmp, $dstRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
        } finally {
            $cg.Dispose()
            $winBmp.Dispose()
        }
        return $cropBmp
    } finally {
        $wg.Dispose()
    }
}

function Invoke-Screenshot {
    $wantAnnotate = [bool]$script:params.annotate
    $gridSize = 0
    if ($null -ne $script:params.grid) {
        # Bare --grid (JSON true) means the default cell size.
        if ($script:params.grid -is [bool]) { $gridSize = $script:DefaultGridSize }
        else { $gridSize = [int]$script:params.grid }
    }
    if ($gridSize -gt 0 -and ($gridSize -lt 20 -or $gridSize -gt 500)) {
        Write-ZccError -Command 'screenshot' -Code 'invalid_arguments' -Message '--grid must be between 20 and 500'
    }

    if (-not $script:params.app -and -not $script:params.screen) {
        Write-ZccError -Command 'screenshot' -Code 'invalid_arguments' -Message 'screenshot requires --app or --screen'
    }
    if ($wantAnnotate -and -not $script:params.app) {
        Write-ZccError -Command 'screenshot' -Code 'invalid_arguments' -Message '--annotate requires --app (element indices come from the window tree)'
    }

    $rect = $null
    $winRect = $null
    $hwnd = 0
    $source = ''
    $desc = $null
    $windowEl = $null
    if ($script:params.screen) {
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $rect = @{ x = $vs.Left; y = $vs.Top; width = $vs.Width; height = $vs.Height }
        $source = 'screen'
    } else {
        $parsed = Resolve-WindowSelector -Selector $script:params.app
        # Only the element/annotate paths need the UIA tree. A plain window
        # screenshot must work even when UIA refuses the window (Chromium
        # windows routinely fail FromHandle), so it resolves via user32 only.
        $hwnd = Resolve-WindowHwnd -Parsed $parsed
        $desc = Get-ProcessWindowDescriptor -Hwnd $hwnd
        $needsUia = ($null -ne $script:params.element) -or ($null -ne $script:params.'element-path') -or $wantAnnotate
        if ($needsUia) {
            $windowEl = Get-UiaWindowElementByHwnd -Hwnd $hwnd
            try {
                $uiaDesc = Get-WindowDescriptor -Element $windowEl
                if ($uiaDesc) { $desc = $uiaDesc }
            } catch {}
        }
        $rc = New-Object ZccNative+RECT
        if ([ZccNative]::GetWindowRect([IntPtr]$hwnd, [ref]$rc)) {
            $winRect = @{ x = $rc.Left; y = $rc.Top; width = $rc.Right - $rc.Left; height = $rc.Bottom - $rc.Top }
        }
        if ($null -ne $script:params.element -and $null -ne $script:params.'element-path') {
            Write-ZccError -Command 'screenshot' -Code 'invalid_arguments' -Message 'provide either --element N or --element-path P, not both'
        }
        if ($null -ne $script:params.element -or $null -ne $script:params.'element-path') {
            # Same targeting path as clicks: cached index -> path -> element with
            # fingerprint verification, so the crop is of the control you saw.
            $resolved = Resolve-ElementTarget -Params $script:params -WindowElement $windowEl
            $el = $resolved.Element
            try {
                $r = $el.Current.BoundingRectangle
                if ([double]::IsNaN($r.Width) -or $r.Width -le 0 -or $r.Height -le 0) {
                    Write-ZccError -Command 'screenshot' -Code 'element_offscreen' -Message "element has no visible bounds"
                }
                $rect = @{ x = [int]$r.X; y = [int]$r.Y; width = [int]$r.Width; height = [int]$r.Height }
            } catch {
                Write-ZccError -Command 'screenshot' -Code 'element_not_found' -Message "element is stale; re-run get-app-state"
            }
            $source = 'element'
        } else {
            if ($null -eq $winRect) {
                Write-ZccError -Command 'screenshot' -Code 'window_not_found' -Message "GetWindowRect failed for hwnd $hwnd"
            }
            $rect = $winRect
            $source = 'window'
        }
    }

    if ($rect.width -le 0 -or $rect.height -le 0) {
        Write-ZccError -Command 'screenshot' -Code 'empty_capture_area' -Message "capture area is empty ($($rect.width)x$($rect.height))"
    }

    $outPath = $script:params.out
    if (-not $outPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $outPath = Join-Path $env:TEMP "dsh-computer-use-$stamp-$([Guid]::NewGuid().ToString('N').Substring(0,8)).png"
    }
    $outPath = [IO.Path]::GetFullPath($outPath)

    $bmp = $null
    $captureMethod = 'screen'
    $warning = $null
    $preferPrintWindow = ($hwnd -gt 0 -and $winRect -and $desc -and (-not $desc.foreground))
    if ($preferPrintWindow) {
        $bmp = Invoke-PrintWindowCapture -Hwnd $hwnd -WinRect $winRect -TargetRect $rect
        if ($null -ne $bmp) { $captureMethod = 'printwindow' }
    }
    if ($null -eq $bmp) {
        $bmp = New-Object System.Drawing.Bitmap($rect.width, $rect.height)
        $gScreen = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $gScreen.CopyFromScreen($rect.x, $rect.y, 0, 0, $bmp.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
            if ($desc -and (-not $desc.foreground) -and $source -ne 'screen') {
                $warning = 'window was not in the foreground; captured screen pixels may reflect overlapping windows'
            }
        } catch {
            $gScreen.Dispose()
            $bmp.Dispose()
            $bmp = $null
            if ($hwnd -gt 0 -and $winRect) {
                $bmp = Invoke-PrintWindowCapture -Hwnd $hwnd -WinRect $winRect -TargetRect $rect
                if ($null -ne $bmp) { $captureMethod = 'printwindow' }
            }
            if ($null -eq $bmp) { throw }
        } finally {
            if ($null -ne $bmp -and $captureMethod -eq 'screen') { $gScreen.Dispose() }
        }
    }

    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $annotatedCount = 0
    $annotatedStateId = $null
    try {
        # Overlays: grid first, annotations on top (labels stay readable).
        if ($gridSize -gt 0) { $null = Draw-ZccGrid -Graphics $g -Rect $rect -CellSize $gridSize }
        if ($wantAnnotate -and $windowEl) {
            $ann = Draw-ZccAnnotations -Graphics $g -Rect $rect -WindowElement $windowEl -Hwnd $hwnd -App $desc
            $annotatedCount = $ann.drawn
            $annotatedStateId = $ann.state_id
        }
        $dir = Split-Path -Parent $outPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $g.Dispose()
        $bmp.Dispose()
    }

    $item = Get-Item $outPath
    $result = [ordered]@{
        path = $outPath
        width = $rect.width
        height = $rect.height
        bytes = $item.Length
        capture = $source
        capture_method = $captureMethod
        bounds = $rect
        annotated = $wantAnnotate
        annotated_elements = $annotatedCount
        grid = $gridSize
    }
    if ($annotatedStateId) { $result.state_id = $annotatedStateId }
    if ($desc) { $result.app = $desc }
    if ($script:params.inline) {
        if ($item.Length -gt $script:MaxInlineBytes) {
            $result.warning = "image is $([int]($item.Length/1024)) KiB, over the $($script:MaxInlineBytes/1024) KiB inline limit; read the file instead"
        } else {
            $result.base64_png = [Convert]::ToBase64String([IO.File]::ReadAllBytes($outPath))
        }
    }
    Write-ZccResult -Command 'screenshot' -Result $result -Warning $warning
}

function Invoke-ZccScreenDispatch {
    param([Parameter(Mandatory=$true)][string]$Command, $Params)
    $script:params = $Params
    if ($Command -eq 'screenshot') {
        Invoke-ZccMain -Command 'screenshot' -Body { Invoke-Screenshot }
    } else {
        Write-ZccError -Command $Command -Code 'unknown_command' -Message "zcc-screen.ps1 does not handle command '$Command'"
    }
}

if (-not $FunctionsOnly) {
    if (-not $Command -or -not $ParamsFile) {
        Write-ZccError -Command ($Command -or 'unknown') -Code 'invalid_arguments' -Message 'Command and ParamsFile are required'
    }
    Set-ZccOutFile -Path $OutFile
    $script:ZccCurrentParams = (Get-Content -Raw -Path $ParamsFile | ConvertFrom-Json)
    Invoke-ZccScreenDispatch -Command $Command -Params $script:ZccCurrentParams
}
