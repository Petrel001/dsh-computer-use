#requires -Version 5.1
# DSH Computer Use - Windows shared library (UIAutomation + user32 P/Invoke + JSON envelope).
# Dot-sourced by zcc-apps.ps1 / zcc-state.ps1 / zcc-action.ps1 / zcc-screen.ps1.
# NOTE: this file is pure ASCII on purpose. PowerShell 5.1 decodes BOM-less .ps1
# files with the machine's ANSI code page (GBK on Chinese Windows), which corrupts
# UTF-8 text and can even swallow newlines. Keep all .ps1 files ASCII-only.
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# ---- P/Invoke: foreground switching, input injection, fast process lookup ---
# mouse_event/keybd_event instead of SendInput: SendInput needs struct-array
# marshalling that is fragile in one-shot script scenarios; mouse_event covers
# click/move/wheel, and SendKeys (System.Windows.Forms) covers keystrokes.
$ZccNativeSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class ZccAbortException : Exception {
    public ZccAbortException() : base("zcc_abort") {}
}

public static class ZccNative {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, int dwData, int dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDesktop(uint dwThreadId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
    [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr OpenInputDesktop(uint dwFlags, bool fInherit, uint dwDesiredAccess);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseDesktop(IntPtr hDesktop);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool GetUserObjectInformationW(IntPtr hObj, int nIndex, StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);
    [DllImport("user32.dll")] public static extern IntPtr FindWindowExW(IntPtr hWndParent, IntPtr hWndChildAfter, [MarshalAs(UnmanagedType.LPWStr)] string lpszClass, [MarshalAs(UnmanagedType.LPWStr)] string lpszWindow);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeoutW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool QueryFullProcessImageNameW(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref uint lpdwSize);

    public static string GetProcessImagePath(uint pid) {
        if (pid == 0) return "";
        IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (h == IntPtr.Zero) return "";
        try {
            StringBuilder sb = new StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            if (QueryFullProcessImageNameW(h, 0, sb, ref size)) {
                return sb.ToString(0, (int)size);
            }
            return "";
        } finally {
            CloseHandle(h);
        }
    }

    public static string GetProcessShortName(uint pid) {
        string path = GetProcessImagePath(pid);
        if (string.IsNullOrEmpty(path)) return "";
        return Path.GetFileNameWithoutExtension(path);
    }

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
        public int length; public int flags; public int showCmd;
        public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
    }
}
'@

function Initialize-ZccNative {
    if ('ZccNative' -as [type]) { return }
    $cacheBase = $env:CUA_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($cacheBase)) {
        $base = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
        $cacheBase = Join-Path $base 'dsh-computer-use\state'
    }
    try {
        if (-not (Test-Path -LiteralPath $cacheBase)) {
            New-Item -ItemType Directory -Path $cacheBase -Force | Out-Null
        }
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ZccNativeSource))
            $hashTag = -join ($hashBytes[0..5] | ForEach-Object { $_.ToString('x2') })
        } finally {
            $sha.Dispose()
        }
        $dllPath = Join-Path $cacheBase "zcc-native-$hashTag.dll"
        if (Test-Path -LiteralPath $dllPath) {
            Add-Type -Path $dllPath
            if ('ZccNative' -as [type]) { return }
        }
        $tmpDll = Join-Path $cacheBase ("zcc-native-" + [Guid]::NewGuid().ToString('N') + ".dll")
        Add-Type -TypeDefinition $ZccNativeSource -OutputAssembly $tmpDll
        try {
            Move-Item -LiteralPath $tmpDll -Destination $dllPath -Force
            Add-Type -Path $dllPath
        } catch {
            Remove-Item -LiteralPath $tmpDll -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $dllPath) {
                Add-Type -Path $dllPath
            }
        }
    } catch {}
    if (-not ('ZccNative' -as [type])) {
        Add-Type -TypeDefinition $ZccNativeSource
    }
}
Initialize-ZccNative

# Per-monitor DPI awareness. Without it, coordinates from UIA, CopyFromScreen
# captures and SetCursorPos injection can disagree on mixed-DPI multi-monitor
# setups. Best effort: when the host already set awareness the call fails
# harmlessly, and an older Windows may not expose the API at all.
# CUA_DPI_AWARE=0 keeps the default awareness (diagnostics / provider quirks).
if ($env:CUA_DPI_AWARE -ne '0') {
    try { [void][ZccNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch {
        try { [void][ZccNative]::SetProcessDPIAware() } catch {}
    }
}

$script:ZccGwOwner = 4
$script:ZccGwlExStyle = -20
$script:ZccWsExToolWindow = 0x00000080
$script:ZccDwmaCloaked = 14
$script:ZccPlacementMaximized = 3
$script:ZccPlacementMinimized = 2

# Force a window into the foreground. A background process (the normal case for
# an agent CLI) cannot call SetForegroundWindow directly - Windows foreground
# lock silently ignores it. The AttachThreadInput dance shares our thread's
# input queue with the current foreground thread so the call is honored.
function Set-WindowForegroundSafe {
    param([Parameter(Mandatory=$true)][int64]$Hwnd)
    $target = [IntPtr]$Hwnd
    if ([ZccNative]::IsIconic($target)) {
        [void][ZccNative]::ShowWindow($target, 9) # SW_RESTORE
    }
    $fg = [ZccNative]::GetForegroundWindow()
    if ($fg -eq $target) {
        [void][ZccNative]::BringWindowToTop($target)
        return
    }
    $fgPid = 0
    $fgThread = [ZccNative]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $thisThread = [ZccNative]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $thisThread) {
        $attached = [ZccNative]::AttachThreadInput($thisThread, $fgThread, $true)
    }
    try {
        [void][ZccNative]::SetForegroundWindow($target)
        [void][ZccNative]::BringWindowToTop($target)
    } finally {
        if ($attached) { [void][ZccNative]::AttachThreadInput($thisThread, $fgThread, $false) }
    }
}

$script:ZccMouseLeftDown = 0x0002
$script:ZccMouseLeftUp = 0x0004
$script:ZccMouseRightDown = 0x0008
$script:ZccMouseRightUp = 0x0010
$script:ZccMouseMiddleDown = 0x0020
$script:ZccMouseMiddleUp = 0x0040
$script:ZccWheel = 0x0800
$script:ZccHWheel = 0x01000
$script:ZccWheelDelta = 120

# ---- Selector resolution ---------------------------------------------------
# Selector forms: pid:<n> / hwnd:<n> / name:<process-name substring> / title:<window-title substring>
function Resolve-WindowSelector {
    param([Parameter(Mandatory=$true)][string]$Selector)
    $s = $Selector.Trim()
    if ($s -match '^(pid|hwnd|name|title):(.*)$') {
        return @{ Kind = $Matches[1]; Value = $Matches[2] }
    }
    # Bare string is treated as a window-title substring (most common model usage).
    return @{ Kind = 'title'; Value = $s }
}

function Get-UiaWindowElement {
    param([Parameter(Mandatory=$true)]$Parsed)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    switch ($Parsed.Kind) {
        'pid' {
            $procId = 0
            if (-not [int]::TryParse($Parsed.Value, [ref]$procId)) { throw "selector pid value is not an integer: $($Parsed.Value)" }
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $procId)
            $found = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
            if ($found.Count -eq 0) { throw "no UIA window found for pid $procId" }
            return $found
        }
        'hwnd' {
            $hwnd = 0
            if (-not [int]::TryParse($Parsed.Value, [ref]$hwnd)) { throw "selector hwnd value is not an integer: $($Parsed.Value)" }
            # FromHandle throws a raw COM error ("unrecognized error") for dead or
            # UIA-refusing windows; normalize it to the stable window_not_found.
            $el = $null
            try { $el = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$hwnd) } catch { $el = $null }
            if ($null -eq $el) { throw "no UIA element for hwnd $hwnd" }
            return @($el)
        }
        default {
            $needle = $Parsed.Value
            if ([string]::IsNullOrWhiteSpace($needle)) { throw "selector $($Parsed.Kind) value is empty" }
            $cond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Window)
            $all = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
            $matched = @()
            foreach ($w in $all) {
                $name = $w.Current.Name
                $procName = ''
                try { $procName = (Get-Process -Id $w.Current.ProcessId -ErrorAction SilentlyContinue).ProcessName } catch {}
                if ($Parsed.Kind -eq 'name') {
                    if ($procName -and $procName.ToLower().Contains($needle.ToLower())) { $matched += $w }
                } else {
                    if ($name -and $name.ToLower().Contains($needle.ToLower())) { $matched += $w }
                }
            }
            if ($matched.Count -eq 0) { throw "no window matches $($Parsed.Kind) '$needle'" }
            if ($matched.Count -gt 1) {
                $titles = ($matched | ForEach-Object { "$($_.Current.Name) [hwnd=$($_.Current.NativeWindowHandle)]" }) -join '; '
                throw "selector $($Parsed.Kind) '$needle' matches $($matched.Count) windows: $titles. Use pid: or hwnd: to disambiguate."
            }
            return $matched
        }
    }
}

# UIA-INDEPENDENT window resolution: returns the hwnd (int64) for a selector
# using user32/EnumWindows only. Plain screenshots and focus must not depend on
# UIA: Edge/Chromium windows routinely refuse AutomationElement.FromHandle
# ("unrecognized error") while GetWindowRect keeps working fine.
# EnumWindows also sees dialogs and secondary windows, which Get-Process's
# MainWindowHandle silently ignores - matching only main windows made
# `title:<dialog title>` unusable for actions.
function Resolve-WindowHwnd {
    param([Parameter(Mandatory=$true)]$Parsed)
    switch ($Parsed.Kind) {
        'hwnd' {
            $h = 0
            if (-not [int64]::TryParse($Parsed.Value, [ref]$h)) { throw "selector hwnd value is not an integer: $($Parsed.Value)" }
            if (-not [ZccNative]::IsWindow([IntPtr]$h)) { throw "no live window for hwnd $h (it may have been closed or recreated)" }
            return $h
        }
        'pid' {
            $p = 0
            if (-not [int]::TryParse($Parsed.Value, [ref]$p)) { throw "selector pid value is not an integer: $($Parsed.Value)" }
            $candidates = @(Get-TopLevelWindows | Where-Object { [int]$_.pid -eq $p })
            if ($candidates.Count -eq 0) { throw "no window found for pid $p" }
            # A process may own several windows; the topmost (z-order) one is the
            # one a human would call "the app window".
            return [int64]$candidates[0].hwnd
        }
        default {
            $needle = $Parsed.Value.Trim()
            if ([string]::IsNullOrWhiteSpace($needle)) { throw "selector $($Parsed.Kind) value is empty" }
            $candidates = @(Get-TopLevelWindows | Where-Object {
                if ($Parsed.Kind -eq 'name') {
                    $_.process -and ([string]$_.process).ToLowerInvariant().Contains($needle.ToLowerInvariant())
                } else {
                    $_.title -and ([string]$_.title).ToLowerInvariant().Contains($needle.ToLowerInvariant())
                }
            })
            if ($candidates.Count -eq 0) { throw "no window matches $($Parsed.Kind) '$needle'" }
            if ($candidates.Count -gt 1) {
                $titles = ($candidates | ForEach-Object { "$($_.title) [hwnd=$($_.hwnd)]" }) -join '; '
                throw "selector $($Parsed.Kind) '$needle' matches $($candidates.Count) windows: $titles. Use pid: or hwnd: to disambiguate."
            }
            return [int64]$candidates[0].hwnd
        }
    }
}

# Resolve one specific top-level window to its UIA element. FromHandle is exact
# (no ambiguity, no re-listing); a root-children lookup is the fallback for
# providers that refuse FromHandle.
function Get-UiaWindowElementByHwnd {
    param([Parameter(Mandatory=$true)][int64]$Hwnd)
    # Prefer the UIA root-children element: it carries the provider's real
    # control types (Button/Edit/CheckBox...). AutomationElement.FromHandle
    # can hand back the HWND-based legacy proxy instead, whose whole subtree
    # degrades to ControlType=Pane - semantically useless for targeting.
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Window)
    try {
        foreach ($candidate in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
            try {
                if ([int64]$candidate.Current.NativeWindowHandle -eq $Hwnd) { return $candidate }
            } catch {}
        }
    } catch {}
    $element = $null
    try { $element = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd) } catch { $element = $null }
    if ($null -ne $element) { return $element }
    throw "window $Hwnd does not expose a UIA element tree; the app may be a Chromium/Electron renderer without accessibility enabled, or the window is not responding"
}

function Get-ProcessNameFast {
    param([int]$ProcessId, $ProcessMap = $null)
    if ($ProcessId -le 0) { return '' }
    if ($ProcessMap -and $ProcessMap.ContainsKey($ProcessId)) {
        return [string]$ProcessMap[$ProcessId]
    }
    $name = ''
    try { $name = [ZccNative]::GetProcessShortName([uint32]$ProcessId) } catch {}
    if (-not $name) {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if ($proc) { $name = $proc.ProcessName }
        } catch {}
    }
    if ($ProcessMap) { $ProcessMap[$ProcessId] = $name }
    return $name
}

# Minimal window descriptor built from process facts only (no UIA).
function Get-ProcessWindowDescriptor {
    param([Parameter(Mandatory=$true)][int64]$Hwnd)
    $procId = 0
    [void][ZccNative]::GetWindowThreadProcessId([IntPtr]$Hwnd, [ref]$procId)
    $procPath = ''
    $procName = ''
    try { $procPath = [ZccNative]::GetProcessImagePath([uint32]$procId) } catch {}
    if ($procPath) {
        $procName = [IO.Path]::GetFileNameWithoutExtension($procPath)
    } else {
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { $procName = $proc.ProcessName; $procPath = $proc.Path }
        } catch {}
    }
    # Per-window facts, not Get-Process MainWindowTitle: an agent may target a
    # dialog or a secondary window, whose title differs from the main window's.
    $title = Get-WindowTitleText -Hwnd $Hwnd
    $class = Get-WindowClassText -Hwnd $Hwnd
    $rc = New-Object ZccNative+RECT
    $bounds = $null
    if ([ZccNative]::GetWindowRect([IntPtr]$Hwnd, [ref]$rc)) {
        $bounds = @{ x = $rc.Left; y = $rc.Top; width = $rc.Right - $rc.Left; height = $rc.Bottom - $rc.Top }
    }
    return @{
        hwnd = $Hwnd
        pid = $procId
        process = $procName
        process_path = $procPath
        title = $title
        class = $class
        bounds = $bounds
        foreground = ([IntPtr]$Hwnd -eq [ZccNative]::GetForegroundWindow())
        uia = $false
    }
}

function Get-WindowDescriptor {
    param([Parameter(Mandatory=$true)]$Element)
    $c = $Element.Current
    $procId = $c.ProcessId
    $procPath = ''
    $procName = ''
    try { $procPath = [ZccNative]::GetProcessImagePath([uint32]$procId) } catch {}
    if ($procPath) {
        $procName = [IO.Path]::GetFileNameWithoutExtension($procPath)
    } else {
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($proc) { $procName = $proc.ProcessName; $procPath = $proc.Path }
        } catch {}
    }
    $bounds = $null
    try {
        $r = $c.BoundingRectangle
        if (-not [double]::IsNaN($r.Width) -and $r.Width -gt 0) {
            $bounds = @{ x = [int]$r.X; y = [int]$r.Y; width = [int]$r.Width; height = [int]$r.Height }
        }
    } catch {}
    $hwnd = [int64]$c.NativeWindowHandle
    return @{
        hwnd = $hwnd
        pid = $procId
        process = $procName
        process_path = $procPath
        title = $c.Name
        class = $(if ($hwnd -ne 0) { Get-WindowClassText -Hwnd $hwnd } else { '' })
        bounds = $bounds
        foreground = ($hwnd -ne 0 -and [IntPtr]$hwnd -eq [ZccNative]::GetForegroundWindow())
    }
}

# ---- Element helpers ---------------------------------------------------------
# NOTE: AutomationElement.GetCurrentPattern throws when the pattern is not
# supported (it does not return null). All pattern probing must go through
# Test-HasPattern / Get-ElementPattern try-catch wrappers.
# $Pattern is an AutomationPattern instance (e.g. [InvokePattern]::Pattern),
# not a [type]; GetCurrentPattern takes the instance.
function Test-HasPattern {
    param(
        [Parameter(Mandatory=$true)]$Element,
        [Parameter(Mandatory=$true)]$Pattern
    )
    try { $null = $Element.GetCurrentPattern($Pattern); return $true } catch { return $false }
}

function Get-ElementPattern {
    param(
        [Parameter(Mandatory=$true)]$Element,
        [Parameter(Mandatory=$true)]$Pattern
    )
    try { return $Element.GetCurrentPattern($Pattern) } catch { return $null }
}

function Get-ElementValueText {
    param([Parameter(Mandatory=$true)]$Element)
    try {
        $vp = $Element.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if ($vp) { return [string]$vp.Current.Value }
    } catch {}
    return $null
}

function Get-ElementToggleState {
    param([Parameter(Mandatory=$true)]$Element)
    try {
        $tp = $Element.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if ($tp) {
            switch ($tp.Current.ToggleState) {
                'On' { return 'on' }
                'Off' { return 'off' }
                default { return 'indeterminate' }
            }
        }
    } catch {}
    return $null
}

function Get-ElementSelectedState {
    param([Parameter(Mandatory=$true)]$Element)
    try {
        $sp = $Element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
        if ($sp) { return [bool]$sp.Current.IsSelected }
    } catch {}
    return $null
}

# Interactive control types are always collected; container types only when
# named (suppresses pure layout noise from raw UIA trees).
$script:ZccInteractiveTypes = @(
    'Button', 'Edit', 'CheckBox', 'RadioButton', 'ComboBox', 'List', 'ListItem',
    'MenuItem', 'Menu', 'Tab', 'TabItem', 'Hyperlink', 'Slider', 'Spinner',
    'Tree', 'TreeItem', 'DataItem', 'DataGrid', 'StatusBar', 'ToolBar',
    'ScrollBar', 'ProgressBar', 'Group'
)

function Test-InteractiveControlType {
    param([Parameter(Mandatory=$true)][string]$ProgrammaticName)
    $short = $ProgrammaticName -replace '^ControlType\.', ''
    return $script:ZccInteractiveTypes -contains $short
}

# THE single element-tree traversal. Both get-app-state (text + elements) and the
# screenshot --annotate overlay MUST come from here, so annotated indices match
# the state indices exactly. Collection rule: interactive control types are
# always collected; container types only when named or carrying an automation id
# (suppresses pure layout noise from raw UIA trees).
function Get-ElementSnapshot {
    param(
        [Parameter(Mandatory=$true)]$WindowElement,
        [int]$MaxElements = 2000,
        [int]$MaxDepth = 40,
        [string]$RootPath = '0'
    )
    $script:SnapElements = New-Object System.Collections.ArrayList
    $script:SnapLines = New-Object System.Collections.ArrayList
    $script:SnapTruncated = $false
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

    $visit = {
        param($Node, [int]$Depth, [int]$ParentIndex, [string]$Path)

        if ($script:SnapTruncated) { return }
        if ($script:SnapElements.Count -ge $MaxElements) { $script:SnapTruncated = $true; return }
        if ($Depth -gt $MaxDepth) { return }

        $c = $Node.Current
        $role = ($c.ControlType.ProgrammaticName -replace '^ControlType\.', '')
        $name = $c.Name
        $automationId = $c.AutomationId

        $interactive = Test-InteractiveControlType -ProgrammaticName $c.ControlType.ProgrammaticName
        $named = (-not [string]::IsNullOrWhiteSpace($name)) -or (-not [string]::IsNullOrWhiteSpace($automationId))
        if (-not ($interactive -or $named)) { return }

        $index = $script:SnapElements.Count
        # GetSupportedPatterns() is ONE cross-process call; probing each pattern
        # separately costs one round-trip per pattern per element and dominates
        # snapshot time on large trees. The probe list stays as a fallback for
        # providers that throw from GetSupportedPatterns().
        $patterns = @()
        $supported = $null
        try { $supported = $Node.GetSupportedPatterns() } catch { $supported = $null }
        if ($null -ne $supported) {
            foreach ($p in $supported) {
                switch ($p.ProgrammaticName) {
                    'InvokePatternIdentifiers.Pattern' { $patterns += 'invoke' }
                    'ValuePatternIdentifiers.Pattern' { $patterns += 'value' }
                    'TogglePatternIdentifiers.Pattern' { $patterns += 'toggle' }
                    'SelectionItemPatternIdentifiers.Pattern' { $patterns += 'select' }
                    'ExpandCollapsePatternIdentifiers.Pattern' { $patterns += 'expand' }
                    'ScrollPatternIdentifiers.Pattern' { $patterns += 'scroll' }
                    'TextPatternIdentifiers.Pattern' { $patterns += 'text' }
                    'SelectionPatternIdentifiers.Pattern' { $patterns += 'selection' }
                    'ScrollItemPatternIdentifiers.Pattern' { $patterns += 'scrollitem' }
                    'RangeValuePatternIdentifiers.Pattern' { $patterns += 'range' }
                    'WindowPatternIdentifiers.Pattern' { $patterns += 'window' }
                }
            }
        } else {
            foreach ($pair in @(
                @{ n = 'invoke';    t = [System.Windows.Automation.InvokePattern]::Pattern },
                @{ n = 'value';     t = [System.Windows.Automation.ValuePattern]::Pattern },
                @{ n = 'toggle';    t = [System.Windows.Automation.TogglePattern]::Pattern },
                @{ n = 'select';    t = [System.Windows.Automation.SelectionItemPattern]::Pattern },
                @{ n = 'expand';    t = [System.Windows.Automation.ExpandCollapsePattern]::Pattern },
                @{ n = 'scroll';    t = [System.Windows.Automation.ScrollPattern]::Pattern },
                @{ n = 'text';      t = [System.Windows.Automation.TextPattern]::Pattern }
            )) {
                if (Test-HasPattern -Element $Node -Pattern $pair.t) { $patterns += $pair.n }
            }
        }

        $bounds = $null
        $offscreen = $false
        try {
            $r = $c.BoundingRectangle
            if (-not [double]::IsNaN($r.Width) -and $r.Width -gt 0 -and $r.Height -gt 0) {
                $bounds = @{ x = [int]$r.X; y = [int]$r.Y; width = [int]$r.Width; height = [int]$r.Height }
            }
            $offscreen = [bool]$c.IsOffscreen
        } catch {}

        $value = $null
        if ($patterns -contains 'value') { $value = Get-ElementValueText -Element $Node }
        $toggle = $null
        if ($patterns -contains 'toggle') { $toggle = Get-ElementToggleState -Element $Node }
        $selected = $null
        if ($patterns -contains 'select') { $selected = Get-ElementSelectedState -Element $Node }

        $entry = [ordered]@{
            index = $index
            path = $Path
            role = $role
            name = $name
            depth = $Depth
            parent = $ParentIndex
            enabled = [bool]$c.IsEnabled
            offscreen = $offscreen
            patterns = $patterns
        }
        if ($automationId) { $entry.automation_id = $automationId }
        if ($null -ne $value) { $entry.value = $value }
        if ($null -ne $toggle) { $entry.toggle = $toggle }
        if ($null -ne $selected) { $entry.selected = $selected }
        if ($bounds) { $entry.bounds = $bounds }

        [void]$script:SnapElements.Add($entry)

        # One line per element in the text tree, indented by depth. The model
        # mostly reads text; precise targeting uses the elements array.
        $indent = '  ' * [Math]::Min($Depth, 20)
        $flags = @()
        if (-not $entry.enabled) { $flags += 'disabled' }
        if ($offscreen) { $flags += 'offscreen' }
        if ($null -ne $selected -and $selected) { $flags += 'selected' }
        if ($null -ne $toggle) { $flags += $toggle }
        $flagText = ''
        if ($flags.Count -gt 0) { $flagText = ' {' + ($flags -join ',') + '}' }
        $nameText = ''
        if ($name) { $nameText = ' "' + $name + '"' }
        $valText = ''
        if ($null -ne $value -and $value -ne '' -and $value -ne $name) {
            $shortVal = ($value -replace '[\r\n]+', ' ')
            if ($shortVal.Length -gt 80) { $shortVal = $shortVal.Substring(0, 77) + '...' }
            $valText = ' ="' + $shortVal + '"'
        }
        [void]$script:SnapLines.Add("$indent[$index] $role$nameText$valText$flagText")

        $child = $walker.GetFirstChild($Node)
        $childPosition = 0
        while ($child -ne $null) {
            & $visit $child ($Depth + 1) $index ("$Path.$childPosition")
            if ($script:SnapTruncated) { return }
            $child = $walker.GetNextSibling($child)
            $childPosition++
        }
    }

    & $visit $WindowElement 0 -1 $RootPath
    return @{ elements = $script:SnapElements; lines = $script:SnapLines; truncated = $script:SnapTruncated }
}

# Locate the element at TargetIndex. Uses the same traversal as
# Get-ElementSnapshot, so indices match what get-app-state reported.
function Find-ElementByIndex {
    param(
        [Parameter(Mandatory=$true)]$WindowElement,
        [Parameter(Mandatory=$true)][int]$TargetIndex
    )
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $script:Found = $null
    $script:FoundPath = $null
    $script:Counter = 0

    $visit = {
        param($Node, [int]$Depth, [string]$Path)
        if ($null -ne $script:Found -or $Depth -gt 40) { return }
        $c = $Node.Current
        $interactive = Test-InteractiveControlType -ProgrammaticName $c.ControlType.ProgrammaticName
        $named = (-not [string]::IsNullOrWhiteSpace($c.Name)) -or (-not [string]::IsNullOrWhiteSpace($c.AutomationId))
        if ($interactive -or $named) {
            if ($script:Counter -eq $TargetIndex) {
                $script:Found = $Node
                $script:FoundPath = $Path
                return
            }
            $script:Counter++
        }
        $child = $walker.GetFirstChild($Node)
        $childPos = 0
        while ($child -ne $null) {
            & $visit $child ($Depth + 1) ("$Path.$childPos")
            if ($null -ne $script:Found) { return }
            $child = $walker.GetNextSibling($child)
            $childPos++
        }
    }
    & $visit $WindowElement 0 '0'
    if ($null -eq $script:Found) { throw "no element with index $TargetIndex in current state; re-run get-app-state" }
    return $script:Found
}

# Path addressing: get-app-state records each element's child-position chain in
# the raw ControlView tree ("0.2.1"). Walking that chain visits only the nodes
# on the way down instead of re-walking and re-filtering the whole tree, so an
# action costs a few cross-process calls instead of a full snapshot.
function Find-ElementByPath {
    param(
        [Parameter(Mandatory=$true)]$WindowElement,
        [Parameter(Mandatory=$true)][string]$Path
    )
    $segments = @($Path.Split('.') | Where-Object { $_ -ne '' })
    if ($segments.Count -eq 0) { throw "element path '$Path' is empty" }
    if ($segments[0] -ne '0') { throw "element path '$Path' must start at the window root '0'" }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $node = $WindowElement
    for ($i = 1; $i -lt $segments.Count; $i++) {
        $position = 0
        if (-not [int]::TryParse($segments[$i], [ref]$position) -or $position -lt 0) {
            throw "element path '$Path' is not numeric at segment $i"
        }
        $child = $walker.GetFirstChild($node)
        $walked = 0
        while ($null -ne $child -and $walked -lt $position) {
            $child = $walker.GetNextSibling($child)
            $walked++
        }
        if ($null -eq $child) {
            throw "element path '$Path' no longer exists in the current tree; re-run get-app-state"
        }
        $node = $child
    }
    return $node
}

# Identity used to prove a cached index still points at the same control.
function Get-ElementFingerprint {
    param([Parameter(Mandatory=$true)]$Element)
    $c = $Element.Current
    return @{
        role = ($c.ControlType.ProgrammaticName -replace '^ControlType\.', '')
        name = [string]$c.Name
        automation_id = [string]$c.AutomationId
    }
}

# ---- JSON envelope ------------------------------------------------------------
$script:ZccOutFile = $null
$script:ZccWorkerMode = $false
$script:ZccCommandStartedAt = $null

function Set-ZccOutFile {
    param([string]$Path)
    if ($Path) { $script:ZccOutFile = $Path }
}

function Stop-ZccExecution {
    if ($script:ZccWorkerMode) {
        throw (New-Object ZccAbortException)
    }
    exit 1
}

function Write-ZccTrajectory {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [bool]$Ok = $true,
        [bool]$ActionSent = $false,
        [string]$ErrorCode = $null,
        $Result = $null
    )
    $path = $env:CUA_TRAJECTORY_PATH
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $durationMs = $null
        if ($null -ne $script:ZccCommandStartedAt) {
            $durationMs = [int]((Get-Date) - $script:ZccCommandStartedAt).TotalMilliseconds
        }
        $entry = [ordered]@{
            ts = (Get-Date).ToUniversalTime().ToString('o')
            command = $Command
            platform = 'win32'
            ok = $Ok
            action_sent = $ActionSent
        }
        if ($null -ne $durationMs) { $entry.duration_ms = $durationMs }
        if (-not [string]::IsNullOrWhiteSpace($env:CUA_TRACE_ID)) { $entry.trace_id = [string]$env:CUA_TRACE_ID }
        if (-not [string]::IsNullOrWhiteSpace($env:CUA_STEP_ID)) { $entry.step_id = [string]$env:CUA_STEP_ID }
        if (-not [string]::IsNullOrWhiteSpace($env:CUA_SUBGOAL)) { $entry.subgoal = [string]$env:CUA_SUBGOAL }
        if ($ErrorCode) { $entry.error_code = $ErrorCode }
        if ($Result) {
            if ($Result.app) {
                $entry.window = [ordered]@{
                    hwnd = $Result.app.hwnd
                    pid = $Result.app.pid
                    process = $Result.app.process
                    title = $Result.app.title
                }
            }
            if ($Result.state_before) { $entry.state_before = $Result.state_before }
            if ($Result.resolved_from_state_id) { $entry.resolved_from_state_id = $Result.resolved_from_state_id }
            if ($Result.state_id) { $entry.state_after = $Result.state_id }
            if ($Result.target) { $entry.target = $Result.target }
            if ($Result.method) { $entry.method = $Result.method }
            if ($null -ne $Result.length) { $entry.text_length = $Result.length }
            if ($Result.keys) { $entry.keys = $Result.keys }
            if ($Result.direction) { $entry.direction = $Result.direction }
            if ($null -ne $Result.amount) { $entry.amount = $Result.amount }
            if ($Result.verification) { $entry.verification = $Result.verification }
            if ($Result.path -and $Command -eq 'screenshot') { $entry.screenshot_path = $Result.path }
            if ($Result.text -and $Command -eq 'get-app-state') { $entry.tree_text = $Result.text }
            elseif ($Result.state_id -and $script:ZccLastSnapshotText -and $script:ZccLastSnapshotStateId -eq $Result.state_id) {
                $entry.tree_after = $script:ZccLastSnapshotText
            }
            if ($env:CUA_TRAJECTORY_INCLUDE_TEXT -eq '1' -and $null -ne $script:ZccCurrentParams -and $null -ne $script:ZccCurrentParams.text) {
                $entry.text = [string]$script:ZccCurrentParams.text
            }
        }
        $line = ($entry | ConvertTo-Json -Compress -Depth 8) + "`n"
        [IO.File]::AppendAllText($path, $line, (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

function Write-ZccText {
    param([Parameter(Mandatory=$true)][string]$Text)
    if ($script:ZccOutFile) {
        [IO.File]::WriteAllText($script:ZccOutFile, $Text, (New-Object Text.UTF8Encoding($false)))
    } else {
        [Console]::Out.Write($Text)
    }
}

function Write-ZccResult {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        $Result,
        [bool]$ActionSent = $false,
        $Warning = $null
    )
    Write-ZccTrajectory -Command $Command -Ok $true -ActionSent $ActionSent -Result $Result
    $envelope = [ordered]@{
        ok = $true
        command = $Command
        platform = 'win32'
        action_sent = $ActionSent
        result = $Result
    }
    if ($Warning) { $envelope.warning = $Warning }
    $json = $envelope | ConvertTo-Json -Compress -Depth 12
    Write-ZccText -Text $json
}

function Write-ZccError {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$Code,
        [Parameter(Mandatory=$true)][string]$Message
    )
    Write-ZccTrajectory -Command $Command -Ok $false -ActionSent $false -ErrorCode $Code
    $envelope = [ordered]@{
        ok = $false
        command = $Command
        platform = 'win32'
        error = [ordered]@{ code = $Code; message = $Message }
    }
    Write-ZccText -Text ($envelope | ConvertTo-Json -Compress -Depth 6)
    Stop-ZccExecution
}

# Stable error-code mapping: callers must not branch on error text.
function ConvertTo-ZccErrorCode {
    param([Parameter(Mandatory=$true)]$ErrorRecord)
    $msg = "$($ErrorRecord.Exception.Message)"
    # Most specific first: generic fragments ('is empty') must not swallow the
    # stable codes that callers branch on.
    if ($msg -match '^stale state') { return 'stale_state' }
    if ($msg -match '^no cached state') { return 'state_cache_missing' }
    if ($msg -match 'could not bring window .* foreground') { return 'focus_failed' }
    if ($msg -match 'session is locked') { return 'session_locked' }
    if ($msg -match 'blocked by CUA_DENY') { return 'target_blocked' }
    if ($msg -match 'clipboard is locked') { return 'clipboard_unavailable' }
    if ($msg -match 'unknown predicate key|predicate specification is empty|provide either --element N or --element-path P') { return 'invalid_arguments' }
    if ($msg -match 'no longer exists in the current tree') { return 'stale_state' }
    if ($msg -match 'element path .* (is empty|must start at the window root|is not numeric)') { return 'invalid_arguments' }
    if ($msg -match 'no window matches|no UIA window found|no UIA element for hwnd|no live window|no window found for pid') { return 'window_not_found' }
    if ($msg -match 'matches \d+ windows') { return 'window_ambiguous' }
    if ($msg -match 'not an integer|is empty') { return 'invalid_selector' }
    if ($msg -match 'no element with index') { return 'element_not_found' }
    if ($msg -match 'does not support') { return 'action_unavailable' }
    if ($msg -match 'outside the virtual screen|no clickable point|no visible bounds') { return 'coordinates_out_of_bounds' }
    if ($msg -match 'access is denied|permission') { return 'permission_denied' }
    return 'backend_error'
}

function Invoke-ZccMain {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][scriptblock]$Body
    )
    $script:ZccCommandStartedAt = Get-Date
    try {
        & $Body
    } catch [ZccAbortException] {
        if ($script:ZccWorkerMode) { throw }
    } catch {
        Write-ZccError -Command $Command -Code (ConvertTo-ZccErrorCode -ErrorRecord $_) -Message $_.Exception.Message
    }
}

# ============================================================================
# Window enumeration without UIA (fast, complete, filterable)
# ============================================================================
# UIA's root-children enumeration is slow, misses owned dialogs and reports
# DWM-cloaked ghosts (UWP suspended windows, 1x1 helper windows parked at
# -32000). EnumWindows sees every top-level window, and user32 facts are enough
# to decide what an agent can actually use.
$script:ZccShellClasses = @(
    'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'DV2ControlHost',
    'Windows.UI.Core.CoreWindow', 'ApplicationManager_DesktopShellWindow',
    'TaskListThumbnailWnd', 'ForegroundStaging', 'MultitaskingViewFrame',
    'XamlExplorerHostIslandWindow'
)

function Get-WindowTitleText {
    param([int64]$Hwnd)
    try {
        $sb = New-Object System.Text.StringBuilder 1024
        $n = [ZccNative]::GetWindowTextW([IntPtr]$Hwnd, $sb, $sb.Capacity)
        if ($n -gt 0) { return $sb.ToString(0, $n) }
    } catch {}
    return ''
}

function Get-WindowClassText {
    param([int64]$Hwnd)
    try {
        $sb = New-Object System.Text.StringBuilder 256
        $n = [ZccNative]::GetClassNameW([IntPtr]$Hwnd, $sb, $sb.Capacity)
        if ($n -gt 0) { return $sb.ToString(0, $n) }
    } catch {}
    return ''
}

function Get-NativeWindowDescriptor {
    param([int64]$Hwnd, [int]$ZOrder = 0, $ProcessMap = $null)
    $procId = 0
    [void][ZccNative]::GetWindowThreadProcessId([IntPtr]$Hwnd, [ref]$procId)
    $title = Get-WindowTitleText -Hwnd $Hwnd
    $class = Get-WindowClassText -Hwnd $Hwnd
    $visible = $false
    try { $visible = [ZccNative]::IsWindowVisible([IntPtr]$Hwnd) } catch {}
    $cloaked = $false
    try {
        $cloakedValue = 0
        if ([ZccNative]::DwmGetWindowAttribute([IntPtr]$Hwnd, $script:ZccDwmaCloaked, [ref]$cloakedValue, 4) -eq 0) {
            $cloaked = ($cloakedValue -ne 0)
        }
    } catch {}
    $owner = 0
    try { $owner = [int64][ZccNative]::GetWindow([IntPtr]$Hwnd, [uint32]$script:ZccGwOwner) } catch {}
    $exStyle = 0
    try { $exStyle = [ZccNative]::GetWindowLong([IntPtr]$Hwnd, $script:ZccGwlExStyle) } catch {}
    $showCommand = 0
    $placement = $null
    try {
        $placement = New-Object ZccNative+WINDOWPLACEMENT
        $placement.length = [System.Runtime.InteropServices.Marshal]::SizeOf($placement)
        if ([ZccNative]::GetWindowPlacement([IntPtr]$Hwnd, [ref]$placement)) { $showCommand = $placement.showCmd }
    } catch {
        $placement = $null
    }
    $minimized = ($showCommand -eq $script:ZccPlacementMinimized)
    $maximized = ($showCommand -eq $script:ZccPlacementMaximized)
    $bounds = $null
    if ($minimized -and $null -ne $placement) {
        # A minimized window's live rect is parked off-screen; the restored
        # rect is what an agent needs for bounds-relative work.
        $nr = $placement.rcNormalPosition
        $bounds = @{ x = $nr.Left; y = $nr.Top; width = $nr.Right - $nr.Left; height = $nr.Bottom - $nr.Top }
    } else {
        $rc = New-Object ZccNative+RECT
        if ([ZccNative]::GetWindowRect([IntPtr]$Hwnd, [ref]$rc)) {
            $bounds = @{ x = $rc.Left; y = $rc.Top; width = $rc.Right - $rc.Left; height = $rc.Bottom - $rc.Top }
        }
    }
    $procName = ''
    if ($ProcessMap -and $ProcessMap.ContainsKey([int]$procId)) { $procName = [string]$ProcessMap[[int]$procId] }
    return [ordered]@{
        hwnd = $Hwnd
        pid = $procId
        process = $procName
        title = $title
        class = $class
        bounds = $bounds
        visible = $visible
        minimized = $minimized
        maximized = $maximized
        cloaked = $cloaked
        owned = ($owner -ne 0)
        tool_window = (($exStyle -band $script:ZccWsExToolWindow) -ne 0)
        foreground = ([IntPtr]$Hwnd -eq [ZccNative]::GetForegroundWindow())
        z_order = $ZOrder
    }
}

function Test-ControllableWindow {
    param([Parameter(Mandatory=$true)]$Descriptor)
    if (-not $Descriptor.visible) { return $false }
    if ($Descriptor.cloaked) { return $false }
    if ($Descriptor.tool_window) { return $false }
    if ($null -eq $Descriptor.bounds) { return $false }
    if ($Descriptor.bounds.width -lt 1 -or $Descriptor.bounds.height -lt 1) { return $false }
    if ([string]::IsNullOrWhiteSpace($Descriptor.title) -and [string]::IsNullOrWhiteSpace($Descriptor.class)) { return $false }
    if ($script:ZccShellClasses -contains $Descriptor.class -and [string]::IsNullOrWhiteSpace($Descriptor.title)) { return $false }
    return $true
}

function Get-TopLevelWindows {
    param([bool]$IncludeAll = $false)
    $processMap = @{}
    $script:ZccWindowEntries = New-Object System.Collections.ArrayList
    $script:ZccProcessMap = $processMap
    $script:ZccIncludeAll = $IncludeAll
    $script:ZccEnumError = $null
    # No GetNewClosure(): a closure is created in a fresh session state where the
    # dot-sourced helpers are not visible, and EnumWindows then "succeeds" with
    # zero windows. A plain scriptblock delegate runs in this runspace.
    # Resolve process names ONLY for windows that pass Test-ControllableWindow
    # (or when IncludeAll is requested), avoiding a full Get-Process scan.
    $callback = [ZccNative+EnumWindowsProc]{
        param([IntPtr]$Handle, [IntPtr]$Param)
        try {
            $desc = Get-NativeWindowDescriptor -Hwnd ([int64]$Handle) -ZOrder $script:ZccWindowEntries.Count -ProcessMap $null
            if ($script:ZccIncludeAll -or (Test-ControllableWindow -Descriptor $desc)) {
                $desc.process = Get-ProcessNameFast -ProcessId ([int]$desc.pid) -ProcessMap $script:ZccProcessMap
                [void]$script:ZccWindowEntries.Add($desc)
            }
        } catch {
            if ($null -eq $script:ZccEnumError) { $script:ZccEnumError = $_.Exception.Message }
        }
        return $true
    }
    [void][ZccNative]::EnumWindows($callback, [IntPtr]::Zero)
    if ($script:ZccWindowEntries.Count -eq 0) {
        # EnumWindows is the fast path, not a single point of failure: fall back
        # to the UIA root listing so a broken callback never yields an empty
        # window catalog.
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Window)
        foreach ($element in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
            try {
                $hwnd = [int64]$element.Current.NativeWindowHandle
                if ($hwnd -eq 0) { continue }
                $desc = Get-NativeWindowDescriptor -Hwnd $hwnd -ZOrder $script:ZccWindowEntries.Count -ProcessMap $null
                if ($IncludeAll -or (Test-ControllableWindow -Descriptor $desc)) {
                    $desc.process = Get-ProcessNameFast -ProcessId ([int]$desc.pid) -ProcessMap $script:ZccProcessMap
                    [void]$script:ZccWindowEntries.Add($desc)
                }
            } catch {}
        }
    }
    return $script:ZccWindowEntries
}

# ============================================================================
# State cache: index -> path -> element, with freshness proof
# ============================================================================
# get-app-state persists the element table next to a state_id. Actions can then
# resolve an index without re-walking the tree, and MUST fail closed
# (stale_state) when the cached fingerprint no longer matches the live control.
function Get-StateCacheDir {
    $dir = $env:CUA_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $base = $env:LOCALAPPDATA
        if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
        $dir = Join-Path $base 'dsh-computer-use\state'
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-StateCachePath {
    param([int64]$Hwnd)
    return (Join-Path (Get-StateCacheDir) "win-$Hwnd.json")
}

function Clear-OldStateCache {
    param([string]$Dir)
    try {
        $cutoff = (Get-Date).AddDays(-1)
        foreach ($file in (Get-ChildItem -LiteralPath $Dir -Filter 'win-*.json' -ErrorAction SilentlyContinue)) {
            if ($file.LastWriteTime -lt $cutoff) { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {}
}

function Save-StateCache {
    param(
        [int64]$Hwnd,
        [string]$StateId,
        $App,
        $Elements,
        [bool]$Truncated = $false,
        [bool]$Scoped = $false
    )
    if ($Hwnd -le 0) { return $false }
    try {
        $dir = Get-StateCacheDir
        Clear-OldStateCache -Dir $dir
        $entry = [ordered]@{
            state_id = $StateId
            captured_at = (Get-Date).ToUniversalTime().ToString('o')
            hwnd = $Hwnd
            truncated = $Truncated
            scoped = $Scoped
            app = $App
            elements = @($Elements)
        }
        $json = $entry | ConvertTo-Json -Compress -Depth 8
        $tmp = Join-Path $dir ("tmp-" + [Guid]::NewGuid().ToString('N') + ".json")
        [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination (Get-StateCachePath -Hwnd $Hwnd) -Force
        return $true
    } catch {
        # A cache write failure must never fail the snapshot itself; actions
        # simply fall back to a full index scan.
        return $false
    }
}

function Save-SnapshotCache {
    param(
        [int64]$Hwnd,
        $App = $null,
        $Snapshot,
        [string]$StateId = $null,
        [bool]$Scoped = $false
    )
    if ($Hwnd -le 0 -or $null -eq $Snapshot) { return $false }
    if ([string]::IsNullOrEmpty($StateId)) { $StateId = Get-SnapshotStateId -Snapshot $Snapshot }
    if ($null -ne $Snapshot.lines) {
        $script:ZccLastSnapshotText = ($Snapshot.lines -join "`n")
        $script:ZccLastSnapshotStateId = $StateId
    }
    if ($null -eq $App) { $App = Get-ProcessWindowDescriptor -Hwnd $Hwnd }
    return (Save-StateCache -Hwnd $Hwnd -StateId $StateId -App $App -Elements $Snapshot.elements -Truncated ([bool]$Snapshot.truncated) -Scoped $Scoped)
}

function Get-StateCache {
    param([int64]$Hwnd)
    $path = Get-StateCachePath -Hwnd $Hwnd
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        # Explicit UTF-8: Get-Content defaults to the ANSI code page in
        # PowerShell 5.1, which corrupts Chinese element names and makes the
        # whole cache unparsable (silently degrading every action to a full
        # tree scan).
        $json = [IO.File]::ReadAllText($path, (New-Object Text.UTF8Encoding($false)))
        return ($json | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# ============================================================================
# Predicates and waiting
# ============================================================================
# Spec syntax: comma-separated key:value pairs; commas inside a value are fine
# as long as the next token does not look like another key. Values are
# case-insensitive substrings unless the key says otherwise.
$script:ZccPredicateKeys = @(
    'role', 'name', 'value', 'id', 'automation-id', 'automation_id',
    'enabled', 'pattern', 'patterns', 'toggle', 'selected', 'text'
)

function ConvertFrom-PredicateSpec {
    param([Parameter(Mandatory=$true)][string]$Spec)
    $pattern = ',(?=(?:' + (($script:ZccPredicateKeys | ForEach-Object { [regex]::Escape($_) }) -join '|') + '):)'
    $parts = [regex]::Split($Spec, $pattern)
    $predicates = @()
    foreach ($part in $parts) {
        $p = $part.Trim()
        if ($p -eq '') { continue }
        $colon = $p.IndexOf(':')
        if ($colon -lt 1) {
            # Bare text is shorthand for a name/value/id substring match.
            $predicates += @{ key = 'text'; value = $p }
            continue
        }
        $key = $p.Substring(0, $colon).Trim().ToLowerInvariant()
        $value = $p.Substring($colon + 1).Trim()
        if ($script:ZccPredicateKeys -notcontains $key) {
            throw "unknown predicate key '$key'; supported: $($script:ZccPredicateKeys -join ', ')"
        }
        $predicates += @{ key = $key; value = $value }
    }
    if ($predicates.Count -eq 0) { throw "predicate specification is empty" }
    return $predicates
}

function Test-ElementPredicate {
    param([Parameter(Mandatory=$true)]$Element, [Parameter(Mandatory=$true)]$Predicates)
    foreach ($pred in $Predicates) {
        $key = $pred.key
        $want = ([string]$pred.value).ToLowerInvariant()
        switch ($key) {
            'role' {
                if (-not ([string]$Element.role).ToLowerInvariant().Contains($want)) { return $false }
            }
            'name' {
                if (-not ([string]$Element.name).ToLowerInvariant().Contains($want)) { return $false }
            }
            'value' {
                if (-not ([string]$Element.value).ToLowerInvariant().Contains($want)) { return $false }
            }
            'id' {
                if (-not ([string]$Element.automation_id).ToLowerInvariant().Contains($want)) { return $false }
            }
            'automation-id' {
                if (-not ([string]$Element.automation_id).ToLowerInvariant().Contains($want)) { return $false }
            }
            'automation_id' {
                if (-not ([string]$Element.automation_id).ToLowerInvariant().Contains($want)) { return $false }
            }
            'enabled' {
                $expect = @('true', '1', 'yes') -contains $want
                if ([bool]$Element.enabled -ne $expect) { return $false }
            }
            'pattern' {
                if (-not (@($Element.patterns) -contains $want)) { return $false }
            }
            'patterns' {
                if (-not (@($Element.patterns) -contains $want)) { return $false }
            }
            'toggle' {
                if ("$($Element.toggle)".ToLowerInvariant() -ne $want) { return $false }
            }
            'selected' {
                $expect = @('true', '1', 'yes') -contains $want
                if ([bool]$Element.selected -ne $expect) { return $false }
            }
            'text' {
                $hay = ("$($Element.name) $($Element.value) $($Element.automation_id)").ToLowerInvariant()
                if (-not $hay.Contains($want)) { return $false }
            }
            default { return $false }
        }
    }
    return $true
}

function Find-MatchingElement {
    param([Parameter(Mandatory=$true)]$Elements, [Parameter(Mandatory=$true)]$Predicates, [int]$Limit = 1)
    $matches = New-Object System.Collections.ArrayList
    foreach ($el in $Elements) {
        if (Test-ElementPredicate -Element $el -Predicates $Predicates) {
            [void]$matches.Add($el)
            if ($matches.Count -ge $Limit) { break }
        }
    }
    return $matches
}

function Get-SnapshotStateId {
    param($Snapshot)
    # Hash the full observable state, not just the human-readable text tree:
    # the text omits values, toggles, selection and bounds, so a ValuePattern
    # write or a checkbox toggle would otherwise produce an unchanged state_id
    # and --expect-change would report a false no-op.
    $parts = New-Object System.Collections.ArrayList
    foreach ($el in @($Snapshot.elements)) {
        $b = $el.bounds
        $bounds = ''
        if ($b) { $bounds = "$($b.x),$($b.y),$($b.width),$($b.height)" }
        [void]$parts.Add((
            "$($el.index)|$($el.path)|$($el.role)|$($el.name)|$($el.value)|" +
            "$($el.toggle)|$($el.selected)|$($el.enabled)|$($el.offscreen)|$bounds"
        ))
    }
    [void]$parts.Add("count=$(@($Snapshot.elements).Count);truncated=$($Snapshot.truncated)")
    $text = $parts -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash[0..5] | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
    }
}

# Poll the tree until the predicate matches (or stops matching, with -Gone).
# Every poll takes a fresh snapshot; the returned state_id is the snapshot the
# decision was made against.
function Wait-ForPredicate {
    param(
        [Parameter(Mandatory=$true)]$WindowElement,
        [Parameter(Mandatory=$true)][string]$Spec,
        [bool]$Gone = $false,
        [int]$TimeoutMs = 5000,
        [int]$IntervalMs = 250,
        [int64]$Hwnd = 0,
        $App = $null
    )
    $predicates = ConvertFrom-PredicateSpec -Spec $Spec
    $started = Get-Date
    $polls = 0
    if ($Hwnd -le 0) {
        try { $Hwnd = [int64]$WindowElement.Current.NativeWindowHandle } catch { $Hwnd = 0 }
    }
    while ($true) {
        $snapshot = Get-ElementSnapshot -WindowElement $WindowElement -MaxElements 2000
        $found = Find-MatchingElement -Elements $snapshot.elements -Predicates $predicates -Limit 1
        $polls++
        $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
        $ok = $(if ($Gone) { $found.Count -eq 0 } else { $found.Count -gt 0 })
        if ($ok) {
            $stateId = Get-SnapshotStateId -Snapshot $snapshot
            [void](Save-SnapshotCache -Hwnd $Hwnd -App $App -Snapshot $snapshot -StateId $stateId)
            $result = [ordered]@{
                matched = $true
                gone = $Gone
                elapsed_ms = $elapsed
                polls = $polls
                state_id = $stateId
            }
            if ($found.Count -gt 0) { $result.element = $found[0] }
            return $result
        }
        if ($elapsed -ge $TimeoutMs) {
            $stateId = Get-SnapshotStateId -Snapshot $snapshot
            [void](Save-SnapshotCache -Hwnd $Hwnd -App $App -Snapshot $snapshot -StateId $stateId)
            return [ordered]@{
                matched = $false
                gone = $Gone
                elapsed_ms = $elapsed
                polls = $polls
                truncated = $snapshot.truncated
                state_id = $stateId
            }
        }
        Start-Sleep -Milliseconds $IntervalMs
    }
}

# ============================================================================
# Safety: foreground assertion, deny list, audit, clipboard
# ============================================================================
# Foreground switching is a PRECONDITION for input injection, not a nicety: if
# the switch is refused, keystrokes and clicks land in whatever window happens
# to be on top. Fail closed instead of injecting blind.
# The lock screen / UAC secure desktop switches the input desktop away from
# "Default". While that is active NO process can activate a window or receive
# injected input - the honest answer is session_locked, not a generic
# focus_failed (and definitely not "input sent").
function Get-InputDesktopName {
    $handle = [IntPtr]::Zero
    try {
        $handle = [ZccNative]::OpenInputDesktop(0, $false, 0x0100) # DESKTOP_READOBJECTS
    } catch {
        return 'unknown'
    }
    if ($handle -eq [IntPtr]::Zero) { return 'unavailable' }
    try {
        $buffer = New-Object System.Text.StringBuilder 256
        $needed = 0
        if ([ZccNative]::GetUserObjectInformationW($handle, 2, $buffer, 256, [ref]$needed)) {
            return $buffer.ToString()
        }
        return 'unknown'
    } finally {
        [void][ZccNative]::CloseDesktop($handle)
    }
}

function Get-ThreadDesktopName {
    $handle = [IntPtr]::Zero
    try {
        $handle = [ZccNative]::GetThreadDesktop([ZccNative]::GetCurrentThreadId())
    } catch {
        return 'unknown'
    }
    if ($handle -eq [IntPtr]::Zero) { return 'unknown' }
    try {
        $buffer = New-Object System.Text.StringBuilder 256
        $needed = 0
        if ([ZccNative]::GetUserObjectInformationW($handle, 2, $buffer, 256, [ref]$needed)) {
            return $buffer.ToString()
        }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Test-SessionLocked {
    $desktop = Get-InputDesktopName
    if ($desktop -ne 'Default' -and $desktop -ne 'unknown') { return $true }
    # The lock screen can own the foreground while the input desktop still
    # reports Default (RDP / fast user switching). Its process is the give-away:
    # no amount of SetForegroundWindow retries gets past it.
    $foreground = [ZccNative]::GetForegroundWindow()
    $foregroundPid = 0
    [void][ZccNative]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
    $foregroundProcess = Get-ProcessNameFast -ProcessId $foregroundPid
    return ($foregroundProcess -eq 'LockApp' -or $foregroundProcess -eq 'LogonUI')
}

function Assert-ForegroundWindow {
    param([Parameter(Mandatory=$true)][int64]$Hwnd, [int]$Attempts = 3)
    if (Test-SessionLocked) {
        throw "the interactive session is locked; unlock the machine before sending input"
    }
    $target = [IntPtr]$Hwnd
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        Set-WindowForegroundSafe -Hwnd $Hwnd
        Start-Sleep -Milliseconds 80
        if ([ZccNative]::GetForegroundWindow() -eq $target) { return }
    }
    throw "could not bring window $Hwnd to the foreground; refusing to inject input into an unknown window"
}

function Assert-TargetAllowed {
    param($Descriptor)
    $denyTitles = $env:CUA_DENY_TITLES
    if (-not [string]::IsNullOrWhiteSpace($denyTitles)) {
        foreach ($pattern in ($denyTitles -split '[,;]')) {
            $needle = $pattern.Trim()
            if ($needle -and ([string]$Descriptor.title).ToLowerInvariant().Contains($needle.ToLowerInvariant())) {
                throw "target window is blocked by CUA_DENY_TITLES ('$needle')"
            }
        }
    }
    $denyProcesses = $env:CUA_DENY_PROCESSES
    if (-not [string]::IsNullOrWhiteSpace($denyProcesses)) {
        foreach ($pattern in ($denyProcesses -split '[,;]')) {
            $needle = $pattern.Trim()
            if ($needle -and ([string]$Descriptor.process).ToLowerInvariant().Contains($needle.ToLowerInvariant())) {
                throw "target process is blocked by CUA_DENY_PROCESSES ('$needle')"
            }
        }
    }
}

# Append-only JSONL audit trail of mutating actions. Never records typed text -
# only metadata and lengths - so it is safe to keep on.
function Write-ZccAudit {
    param([string]$Command, $Descriptor, $Target, $Extra)
    $path = $env:CUA_AUDIT_PATH
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
        $window = $null
        if ($Descriptor) {
            $window = [ordered]@{
                hwnd = $Descriptor.hwnd
                pid = $Descriptor.pid
                process = $Descriptor.process
                title = $Descriptor.title
            }
        }
        $entry = [ordered]@{
            ts = (Get-Date).ToUniversalTime().ToString('o')
            command = $Command
            platform = 'win32'
            window = $window
            target = $Target
            extra = $Extra
        }
        $line = ($entry | ConvertTo-Json -Compress -Depth 6) + "`n"
        [IO.File]::AppendAllText($path, $line, (New-Object Text.UTF8Encoding($false)))
    } catch {}
}

# Clipboard snapshot/restore so pasting non-ASCII text does not silently
# destroy whatever the user had copied.
function Get-ClipboardSnapshot {
    # Prefer the TEXT representation: it always round-trips. The raw OLE data
    # object is kept only as a fallback for non-text clipboards, because
    # re-publishing a foreign IDataObject can leave an empty clipboard.
    $snapshot = @{ kind = 'none'; text = $null; data = $null }
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $snapshot.text = [System.Windows.Forms.Clipboard]::GetText()
            $snapshot.kind = 'text'
            return $snapshot
        }
    } catch {}
    try {
        $data = [System.Windows.Forms.Clipboard]::GetDataObject()
        if ($data) {
            $snapshot.data = $data
            $snapshot.kind = 'data'
        }
    } catch {}
    return $snapshot
}

function Restore-ClipboardSnapshot {
    param($Snapshot)
    if (-not $Snapshot -or $Snapshot.kind -eq 'none') { return $true }
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            if ($Snapshot.kind -eq 'text' -and $null -ne $Snapshot.text) {
                [System.Windows.Forms.Clipboard]::SetText($Snapshot.text)
                return $true
            }
            if ($Snapshot.data) {
                [System.Windows.Forms.Clipboard]::SetDataObject($Snapshot.data, $true)
                return $true
            }
        } catch {
            Start-Sleep -Milliseconds 80
        }
    }
    return $false
}

function Set-ClipboardTextRobust {
    param([Parameter(Mandatory=$true)][string]$Text)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($Text)
            return
        } catch {
            Start-Sleep -Milliseconds 80
        }
    }
    throw "clipboard is locked by another process; cannot paste non-ASCII text"
}

# ============================================================================
# Action targeting and completion
# ============================================================================
# Resolve --path or --element against the state cache. A cached index is only
# trusted while the resolved control still matches the cached fingerprint;
# otherwise the answer is stale_state, never a guess.
function Resolve-ElementTarget {
    param(
        [Parameter(Mandatory=$true)]$Params,
        [Parameter(Mandatory=$true)]$WindowElement
    )
    if ($null -ne $Params.'element-path' -and $null -ne $Params.element) {
        throw "provide either --element N or --element-path P, not both"
    }
    if ($null -ne $Params.'element-path') {
        return @{
            Element = (Find-ElementByPath -WindowElement $WindowElement -Path ([string]$Params.'element-path'))
            Method = 'path'
            Path = [string]$Params.'element-path'
        }
    }
    $index = [int]$Params.element
    $parsed = Resolve-WindowSelector -Selector $Params.app
    $hwnd = Resolve-WindowHwnd -Parsed $parsed
    $cache = Get-StateCache -Hwnd $hwnd
    if ($null -ne $Params.'state-id') {
        if ($null -eq $cache) {
            throw "no cached state for this window; run get-app-state before using --state-id"
        }
        if ([string]$cache.state_id -ne [string]$Params.'state-id') {
            throw "stale state: snapshot '$($Params.'state-id')' is not the latest for this window ('$($cache.state_id)'); re-run get-app-state"
        }
    }
    if ($null -ne $cache) {
        $procId = 0
        [void][ZccNative]::GetWindowThreadProcessId([IntPtr]$hwnd, [ref]$procId)
        if ($cache.app -and [int]$cache.app.hwnd -eq $hwnd -and [int]$cache.app.pid -eq $procId) {
            $entry = $null
            foreach ($candidate in @($cache.elements)) {
                if ([int]$candidate.index -eq $index) { $entry = $candidate; break }
            }
            if ($entry -and $entry.path) {
                $element = Find-ElementByPath -WindowElement $WindowElement -Path ([string]$entry.path)
                $fingerprint = Get-ElementFingerprint -Element $element
                $cachedName = [string]$entry.name
                $cachedId = [string]$entry.automation_id
                $roleOk = ($fingerprint.role -eq [string]$entry.role)
                $nameOk = ($fingerprint.name -eq $cachedName)
                $idOk = ($fingerprint.automation_id -eq $cachedId)
                # Identity rule: the role must match, AND at least one stable
                # identifier must match. Neither identifier is stable on its own:
                #  - WinForms edits expose the current VALUE as UIA Name, so the
                #    name changes every time you type (id stays "InputBox");
                #  - some WinForms controls generate a per-instance automation id
                #    (id changes, name stays "ClickMe").
                # Requiring both would refuse to re-type into a field you just
                # filled; requiring only the path would click shifted widgets.
                $identityOk = $roleOk -and ($nameOk -or ($idOk -and $cachedId -ne ''))
                if (-not $identityOk) {
                    throw "stale state: element $index is now $($fingerprint.role) '$($fingerprint.name)' [id=$($fingerprint.automation_id)], but the snapshot recorded $($entry.role) '$cachedName' [id=$cachedId]; re-run get-app-state"
                }
                return @{
                    Element = $element
                    Method = 'index-path'
                    Index = $index
                    Path = [string]$entry.path
                    StateId = [string]$cache.state_id
                }
            }
        }
    }
    # No usable cache: fall back to the full traversal (slower, still correct).
    return @{
        Element = (Find-ElementByIndex -WindowElement $WindowElement -TargetIndex $index)
        Method = 'index-scan'
        Index = $index
        Path = $script:FoundPath
    }
}

function Get-PreActionStateId {
    param($Params, $WindowElement)
    if (-not $Params.'expect-change') { return $null }
    # The baseline must be measured immediately BEFORE the action: an older
    # cached snapshot could already differ from the live UI, which would turn
    # every no-op into a false "changed".
    if ($null -eq $WindowElement) {
        $parsed = Resolve-WindowSelector -Selector $Params.app
        $WindowElement = Get-UiaWindowElementByHwnd -Hwnd (Resolve-WindowHwnd -Parsed $parsed)
    }
    $snapshot = Get-ElementSnapshot -WindowElement $WindowElement -MaxElements 2000
    return (Get-SnapshotStateId -Snapshot $snapshot)
}

function Write-ZccErrorResult {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$Code,
        [Parameter(Mandatory=$true)][string]$Message,
        $Result = $null,
        [bool]$ActionSent = $true
    )
    Write-ZccTrajectory -Command $Command -Ok $false -ActionSent $ActionSent -ErrorCode $Code -Result $Result
    $envelope = [ordered]@{
        ok = $false
        command = $Command
        platform = 'win32'
        action_sent = $ActionSent
        error = [ordered]@{ code = $Code; message = $Message }
    }
    if ($null -ne $Result) { $envelope.result = $Result }
    Write-ZccText -Text ($envelope | ConvertTo-Json -Compress -Depth 12)
    Stop-ZccExecution
}

# Shared completion path for every mutating command: optional post-action
# verification (--wait-for / --wait-gone), optional no-op detection
# (--expect-change), audit record, then the success envelope.
function Complete-ZccAction {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)]$Result,
        $WindowElement,
        [Parameter(Mandatory=$true)]$Params,
        [string]$PreStateId = $null,
        [string]$StateId = $null
    )
    $windowEl = $WindowElement
    $targetHwnd = 0
    if ($Result -and $Result.app -and $Result.app.hwnd) { $targetHwnd = [int64]$Result.app.hwnd }
    $needsTree = ($Params.'wait-for' -or $Params.'wait-gone' -or $Params.'expect-change')
    if ($needsTree -and $null -eq $windowEl) {
        $parsed = Resolve-WindowSelector -Selector $Params.app
        if ($targetHwnd -le 0) { $targetHwnd = Resolve-WindowHwnd -Parsed $parsed }
        $windowEl = Get-UiaWindowElementByHwnd -Hwnd $targetHwnd
    }
    if (-not [string]::IsNullOrEmpty($PreStateId)) { $Result.state_before = $PreStateId }
    # The snapshot the target element was resolved against. This is NOT the
    # current UI state (that only appears as result.state_id after verification),
    # so it is reported under its own name to avoid implying freshness.
    if (-not [string]::IsNullOrEmpty($StateId)) { $Result.resolved_from_state_id = $StateId }

    if ($Params.'wait-for' -or $Params.'wait-gone') {
        $gone = [bool]$Params.'wait-gone'
        $spec = $(if ($gone) { [string]$Params.'wait-gone' } else { [string]$Params.'wait-for' })
        $timeoutMs = 5000
        if ($null -ne $Params.'wait-timeout') { $timeoutMs = [int]$Params.'wait-timeout' }
        $wait = Wait-ForPredicate -WindowElement $windowEl -Spec $spec -Gone $gone -TimeoutMs $timeoutMs -IntervalMs 250 -Hwnd $targetHwnd -App $Result.app
        $verification = [ordered]@{
            kind = $(if ($gone) { 'wait_gone' } else { 'wait_for' })
            spec = $spec
            ok = [bool]$wait.matched
            matched = [bool]$wait.matched
            elapsed_ms = $wait.elapsed_ms
            polls = $wait.polls
            state_id = $wait.state_id
        }
        if ($wait.element) { $verification.element = $wait.element }
        $Result.verification = $verification
        $Result.state_id = $wait.state_id
        if (-not $wait.matched) {
            Write-ZccErrorResult -Command $Command -Code 'verification_timeout' `
                -Message ("condition '$spec' was not met within $timeoutMs ms; the action was sent but the expected UI state never appeared") `
                -Result $Result
            return
        }
        $windowEl = $null
    }

    if ($Params.'expect-change') {
        if ($null -eq $windowEl) {
            $parsed = Resolve-WindowSelector -Selector $Params.app
            if ($targetHwnd -le 0) { $targetHwnd = Resolve-WindowHwnd -Parsed $parsed }
            $windowEl = Get-UiaWindowElementByHwnd -Hwnd $targetHwnd
        }
        $snapshot = Get-ElementSnapshot -WindowElement $windowEl -MaxElements 2000
        $newStateId = Get-SnapshotStateId -Snapshot $snapshot
        [void](Save-SnapshotCache -Hwnd $targetHwnd -App $Result.app -Snapshot $snapshot -StateId $newStateId)
        $Result.state_id = $newStateId
        $Result.state_changed = ($newStateId -ne $PreStateId)
        if (-not $Result.state_changed) {
            Write-ZccErrorResult -Command $Command -Code 'no_state_change' `
                -Message ("UI state did not change after the action (state_id $newStateId); the action may have been a no-op") `
                -Result $Result
            return
        }
    }

    Write-ZccResult -Command $Command -Result $Result -ActionSent $true
}
