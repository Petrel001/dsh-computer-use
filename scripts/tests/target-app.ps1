#requires -Version 5.1
# DSH Computer Use - 冒烟测试目标应用（真实进程 + 真实消息循环）。
# 由 smoke-windows.ps1 启动、验证、结束后销毁。控件事件追加写入日志文件，
# 使测试可以在不读图的前提下验证点击/输入是否真正到达目标应用。
# 用法: powershell -File target-app.ps1 -ReadyFile <path> [-EventsFile <path>]
param(
    [Parameter(Mandatory=$true)][string]$ReadyFile,
    [string]$EventsFile = (Join-Path $env:TEMP 'dsh-cu-target-events.log')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Log-Event {
    param([string]$Text)
    Add-Content -Path $EventsFile -Value "$([DateTime]::UtcNow.ToString('o')) $Text"
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DSH-CU-TARGET'
$form.Size = New-Object System.Drawing.Size(440, 520)
$form.TopMost = $true
$form.StartPosition = 'CenterScreen'

$btn = New-Object System.Windows.Forms.Button
$btn.Text = 'ClickMe'
$btn.Size = New-Object System.Drawing.Size(120, 40)
$btn.Location = New-Object System.Drawing.Point(20, 20)
$btn.Add_Click({
    Log-Event 'button-click'
    # Immediate state change: makes --wait-for / --expect-change assertions
    # observable without reading pixels.
    $lbl.Text = 'clicked'
})

$chk = New-Object System.Windows.Forms.CheckBox
$chk.Text = 'ToggleMe'
$chk.Location = New-Object System.Drawing.Point(20, 70)
$chk.Size = New-Object System.Drawing.Size(120, 30)
$chk.Add_Click({ Log-Event 'checkbox-click' })

$txt = New-Object System.Windows.Forms.TextBox
$txt.Name = 'InputBox'
$txt.Location = New-Object System.Drawing.Point(20, 110)
$txt.Size = New-Object System.Drawing.Size(360, 30)

$lbl = New-Object System.Windows.Forms.Label
$lbl.Name = 'StatusLabel'
$lbl.Text = 'ready'
$lbl.Location = New-Object System.Drawing.Point(20, 150)
$lbl.Size = New-Object System.Drawing.Size(360, 24)

# Delayed state change: a click that only becomes visible ~500ms later, so a
# wait --for / --wait-for assertion really has to poll instead of matching the
# state that was already on screen.
$slowBtn = New-Object System.Windows.Forms.Button
$slowBtn.Text = 'SlowReveal'
$slowBtn.Size = New-Object System.Drawing.Size(120, 40)
$slowBtn.Location = New-Object System.Drawing.Point(160, 20)
$slowTimer = New-Object System.Windows.Forms.Timer
# Long enough that a wait --for really has to poll: UIA Invoke for this WinForms
# provider can take seconds on its own, so a short delay would be masked by the
# click call itself.
$slowTimer.Interval = 1200
$slowTimer.Add_Tick({
    $slowTimer.Stop()
    $lbl.Text = 'slow-done'
    Log-Event 'slow-label-done'
})
$slowBtn.Add_Click({
    Log-Event 'slow-button-click'
    $slowTimer.Start()
})

$panel = New-Object System.Windows.Forms.Panel
$panel.Name = 'CoordPanel'
$panel.AccessibleName = 'CoordPanel'
$panel.Location = New-Object System.Drawing.Point(20, 180)
$panel.Size = New-Object System.Drawing.Size(360, 60)
$panel.BorderStyle = 'FixedSingle'
$panel.Add_Click({ Log-Event 'panel-click' })

# Mouse-move logging in ABSOLUTE screen coordinates (PointToScreen), throttled
# to >3px moves so the move command's cursor positioning is verifiable from the
# event log without reading pixels.
$script:LastMX = -1000
$script:LastMY = -1000

# A large empty panel dedicated to hover/move verification: the form-level
# MouseMove does not fire over child controls (WinForms does not bubble mouse
# events), so the move tests aim at this panel's area.
$moveZone = New-Object System.Windows.Forms.Panel
$moveZone.Name = 'MoveZone'
$moveZone.AccessibleName = 'MoveZone'
$moveZone.Location = New-Object System.Drawing.Point(20, 250)
$moveZone.Size = New-Object System.Drawing.Size(380, 150)
$moveZone.BorderStyle = 'FixedSingle'
$moveZone.Add_MouseMove({
    param($s, $e)
    $p = $moveZone.PointToScreen($e.Location)
    if ($env:DSH_CU_DEBUG -eq '1') {
        Log-Event "zone-mouse-move-raw $($p.X),$($p.Y)"
    }
    if ([Math]::Abs($p.X - $script:LastMX) -gt 3 -or [Math]::Abs($p.Y - $script:LastMY) -gt 3) {
        $script:LastMX = $p.X
        $script:LastMY = $p.Y
        Log-Event "mouse-move $($p.X),$($p.Y)"
    }
})

$combo = New-Object System.Windows.Forms.ComboBox
$combo.Name = 'ModeCombo'
$combo.AccessibleName = 'ModeCombo'
$combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$combo.Items.Add('Alpha')
[void]$combo.Items.Add('Beta')
$combo.SelectedIndex = 0
$combo.Location = New-Object System.Drawing.Point(20, 415)
$combo.Size = New-Object System.Drawing.Size(200, 28)

$form.Add_Activated({ Log-Event 'form-activated' })
$form.Add_Deactivate({ Log-Event 'form-deactivated' })

$form.Controls.AddRange(@($btn, $slowBtn, $chk, $txt, $lbl, $panel, $moveZone, $combo))
$form.Add_FormClosed({ Log-Event 'form-closed' })

$form.Show()
# Pump once so the window is really created, then announce readiness.
# NOTE: the form's Shown event needs a running message loop to be delivered,
# which is why readiness is announced here instead of in an Add_Shown handler.
[System.Windows.Forms.Application]::DoEvents()
[IO.File]::WriteAllText($ReadyFile, "$($form.Handle.ToInt64())", (New-Object System.Text.UTF8Encoding($false)))
Log-Event "ready hwnd=$($form.Handle.ToInt64())"
[System.Windows.Forms.Application]::Run($form)
