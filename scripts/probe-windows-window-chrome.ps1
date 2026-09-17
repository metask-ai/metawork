param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [ValidateSet('doubleclick', 'drag', 'resize', 'top-resize', 'top-lifecycle', 'paint', 'paint-stationary', 'controls', 'close', 'minimize', 'activated', 'input-case', 'control-state', 'control-click')]
    [string]$Mode = 'drag',
    [string]$ColorHex,
    [string]$OutputPath,
    [int]$ProbeWidth = 900,
    [ValidateRange(1, 3)]
    [int]$Repeat = 1,
    [switch]$AllMonitors,
    [switch]$Direct,
    [switch]$KeepTopmost,
    [string]$InputCase,
    [int]$DoubleClickMilliseconds = 0,
    [int]$PointX = 300,
    [int]$PointY = 20,
    [long]$WindowHandle = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class MetaWorkChromeProbe {
    [DllImport("user32.dll")]
    public static extern uint GetGuiResources(IntPtr process, uint flags);

    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
    [StructLayout(LayoutKind.Sequential)]
    public struct CursorInfo {
        public uint Size, Flags;
        public IntPtr Cursor;
        public Point Position;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorInfo(ref CursorInfo info);

    [DllImport("user32.dll")]
    public static extern IntPtr LoadCursorW(IntPtr instance, IntPtr name);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string name, string title);
    [StructLayout(LayoutKind.Sequential)]
    public struct Point {
        public int X;
        public int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MinMaxInfo {
        public Point Reserved, MaxSize, MaxPosition, MinTrackSize, MaxTrackSize;
    }

    [DllImport("user32.dll", EntryPoint="SendMessageW")]
    public static extern IntPtr GetMinMaxInfo(IntPtr window, uint message, UIntPtr wparam, ref MinMaxInfo info);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr window, ref Point point);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(Point point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr window, uint flags);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassNameW(IntPtr window, StringBuilder name, int length);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessageW(IntPtr window, uint message, UIntPtr wparam, IntPtr lparam);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr window);

    [DllImport("user32.dll")]
    public static extern uint GetDoubleClickTime();

    [DllImport("user32.dll")]
    public static extern bool SetDoubleClickTime(uint milliseconds);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetricsForDpi(int index, uint dpi);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr window,
        IntPtr insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags
    );

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(
        uint flags,
        uint dx,
        uint dy,
        uint data,
        UIntPtr extraInfo
    );

}
'@

function Get-MetaWorkRect([IntPtr]$window) {
    $rect = New-Object MetaWorkChromeProbe+Rect
    if (-not [MetaWorkChromeProbe]::GetWindowRect($window, [ref]$rect)) {
        throw 'GetWindowRect failed'
    }
    return $rect
}

function Get-MetaWorkSizeLimits([IntPtr]$window) {
    $limits = New-Object MetaWorkChromeProbe+MinMaxInfo
    # WM_GETMINMAXINFO overrides caller-supplied defaults; DefWindowProc does
    # not populate an empty structure for a manually sent message.
    $dpi = [MetaWorkChromeProbe]::GetDpiForWindow($window)
    $minimum = New-Object MetaWorkChromeProbe+Point
    $minimum.X = [MetaWorkChromeProbe]::GetSystemMetricsForDpi(34, $dpi)
    $minimum.Y = [MetaWorkChromeProbe]::GetSystemMetricsForDpi(35, $dpi)
    $maximum = New-Object MetaWorkChromeProbe+Point
    $maximum.X = [MetaWorkChromeProbe]::GetSystemMetricsForDpi(59, $dpi)
    $maximum.Y = [MetaWorkChromeProbe]::GetSystemMetricsForDpi(60, $dpi)
    $limits.MinTrackSize = $minimum
    $limits.MaxTrackSize = $maximum
    [MetaWorkChromeProbe]::GetMinMaxInfo($window, 0x0024, [UIntPtr]::Zero, [ref]$limits) | Out-Null
    if ($limits.MinTrackSize.X -le 0 -or $limits.MinTrackSize.Y -le 0) {
        throw 'Window did not provide its native minimum tracking size'
    }
    return $limits
}

function Invoke-MetaWorkClick([int]$x, [int]$y) {
    [MetaWorkChromeProbe]::SetCursorPos($x, $y) | Out-Null
    [MetaWorkChromeProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [MetaWorkChromeProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Invoke-MetaWorkTitleClick([int]$x, [int]$y) {
    [MetaWorkChromeProbe]::SetCursorPos($x, $y) | Out-Null
    [MetaWorkChromeProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [MetaWorkChromeProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Invoke-MetaWorkTitleDoubleClick([int]$x, [int]$y, [int]$gap) {
    Invoke-MetaWorkTitleClick $x $y
    Start-Sleep -Milliseconds $gap
    Invoke-MetaWorkTitleClick $x $y
}

function Invoke-MetaWorkDrag([int]$x, [int]$y, [int]$deltaX, [int]$deltaY) {
    [MetaWorkChromeProbe]::SetCursorPos($x, $y) | Out-Null
    [MetaWorkChromeProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    for ($step = 1; $step -le 8; $step++) {
        [MetaWorkChromeProbe]::SetCursorPos(
            $x + [Math]::Round($deltaX * $step / 8),
            $y + [Math]::Round($deltaY * $step / 8)
        ) | Out-Null
        Start-Sleep -Milliseconds 55
    }
    [MetaWorkChromeProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

$process = Get-Process -Id $ProcessId
$window = [IntPtr]$WindowHandle
if ($WindowHandle -eq 0) {
    $deadline = (Get-Date).AddSeconds(10)
    while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }
    $window = $process.MainWindowHandle
}
$windowProcessId = [uint32]0
[MetaWorkChromeProbe]::GetWindowThreadProcessId($window, [ref]$windowProcessId) | Out-Null
if (-not [MetaWorkChromeProbe]::IsWindow($window) -or $windowProcessId -ne $ProcessId) {
    throw "Window does not belong to the test process $ProcessId"
}
[MetaWorkChromeProbe]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
if ($Mode -eq 'control-state') {
    @{
        handle = $window.ToInt64().ToString()
        visible = [MetaWorkChromeProbe]::IsWindowVisible($window)
        minimized = [MetaWorkChromeProbe]::IsIconic($window)
        maximized = [MetaWorkChromeProbe]::IsZoomed($window)
        dpi = [MetaWorkChromeProbe]::GetDpiForWindow($window)
        rect = Get-MetaWorkRect $window
    } | ConvertTo-Json -Compress
    return
}
$wasTopmost = ([MetaWorkChromeProbe]::GetWindowLongPtrW($window, -20).ToInt64() -band 8) -ne 0
[MetaWorkChromeProbe]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
if ($Direct -and (-not [MetaWorkChromeProbe]::IsWindowVisible($window) -or
    [MetaWorkChromeProbe]::IsIconic($window) -or [MetaWorkChromeProbe]::IsZoomed($window))) {
    throw 'Direct resize requires an already visible, restored window'
}
try {
if ($Mode -ne 'paint-stationary') {
    # Keep real mouse input on this test-owned window, even if Codex takes focus.
    if (-not [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr](-1), 0, 0, 0, 0, 0x0013)) {
        throw 'Could not establish unobscured pointer input'
    }
    [MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Milliseconds 200
} elseif (-not $wasTopmost) {
    throw 'Stationary paint requires the harness to keep its window unobscured before changing the DOM'
}
$rect = Get-MetaWorkRect $window

if ($Mode -eq 'control-click') {
    if (-not [MetaWorkChromeProbe]::IsWindowVisible($window) -or [MetaWorkChromeProbe]::IsIconic($window)) {
        throw 'Control input requires a visible, non-minimized test window'
    }
    $point = New-Object MetaWorkChromeProbe+Point
    $scale = [MetaWorkChromeProbe]::GetDpiForWindow($window) / 96.0
    $point.X = [int]($PointX * $scale)
    $point.Y = [int]($PointY * $scale)
    if (-not [MetaWorkChromeProbe]::ClientToScreen($window, [ref]$point)) { throw 'ClientToScreen failed' }
    if ([MetaWorkChromeProbe]::GetAncestor([MetaWorkChromeProbe]::WindowFromPoint($point), 2) -ne $window) {
        throw 'Control input point is obscured'
    }
    Invoke-MetaWorkClick $point.X $point.Y
    return
}

if ($Mode -eq 'top-resize') {
    if ($Direct -and ($AllMonitors -or $Repeat -ne 1)) { throw 'Direct resize must be the first input on the current window' }
    if (-not $Direct) { [MetaWorkChromeProbe]::ShowWindow($window, 9) | Out-Null }
    $userBefore = [MetaWorkChromeProbe]::GetGuiResources($process.Handle, 1)
    $gdiBefore = [MetaWorkChromeProbe]::GetGuiResources($process.Handle, 0)
    $positions = @(@{ X = 100; Y = 100 })
    if ($AllMonitors) {
        Add-Type -AssemblyName System.Windows.Forms
        $positions = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            @{ X = $_.WorkingArea.Left + 60; Y = $_.WorkingArea.Top + 60 }
        })
    }
    foreach ($position in $positions) {
    for ($iteration = 0; $iteration -lt $Repeat; $iteration++) {
    $edges = if ($Direct) { @('top') } else { @('top', 'top-left', 'top-right') }
    foreach ($edge in $edges) {
        # SetWindowPos establishes a repeatable precondition only. All changes
        # checked below must be caused by real OS mouse input. The direct
        # lifecycle probe must not resize or restore the window beforehand.
        if (-not $Direct) {
            if (-not [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr](-1), $position.X, $position.Y, 900, 620, 0x0010)) {
                throw 'Could not establish top-resize precondition'
            }
            Start-Sleep -Milliseconds 250
            # Query after moving to the target monitor so SDK/OS minimum sizes
            # already reflect its DPI. Leave room for the 40 physical-pixel drag.
            $limits = Get-MetaWorkSizeLimits $window
            $width = [Math]::Max(900, $limits.MinTrackSize.X + 80)
            $height = [Math]::Max(620, $limits.MinTrackSize.Y + 80)
            if ($width -gt $limits.MaxTrackSize.X -or $height -gt $limits.MaxTrackSize.Y) {
                throw 'Monitor tracking limits leave insufficient room for the resize probe'
            }
            if (-not [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr]::Zero, 0, 0, $width, $height, 0x0016)) {
                throw 'Could not establish DPI-aware top-resize dimensions'
            }
            Start-Sleep -Milliseconds 200
        }
        $before = Get-MetaWorkRect $window
        $dy = 40
        if ($Direct) {
            $limits = Get-MetaWorkSizeLimits $window
            if ($before.Bottom - $before.Top - $limits.MinTrackSize.Y -lt 40) {
                Add-Type -AssemblyName System.Windows.Forms
                $area = [System.Windows.Forms.Screen]::FromHandle($window).WorkingArea
                if ($before.Top - $area.Top -lt 40 -or
                    $before.Bottom - $before.Top + 40 -gt $limits.MaxTrackSize.Y) {
                    throw 'Current window has insufficient room for a direct top resize'
                }
                $dy = -40
            }
        }
        $client = New-Object MetaWorkChromeProbe+Rect
        $origin = New-Object MetaWorkChromeProbe+Point
        if (-not [MetaWorkChromeProbe]::GetClientRect($window, [ref]$client) -or
            -not [MetaWorkChromeProbe]::ClientToScreen($window, [ref]$origin)) {
            throw 'Could not read the physical client frame'
        }
        $x = $origin.X + [int]($client.Right / 2)
        $dx = 0
        if ($edge -eq 'top-left') { $x = $origin.X + 2; $dx = 40 }
        if ($edge -eq 'top-right') { $x = $origin.X + $client.Right - 3; $dx = -40 }
        $point = New-Object MetaWorkChromeProbe+Point
        $point.X = $x
        $point.Y = $origin.Y + 2
        $pointerRoot = [MetaWorkChromeProbe]::GetAncestor([MetaWorkChromeProbe]::WindowFromPoint($point), 2)
        if ($pointerRoot -ne $window) {
            $coverProcessId = [uint32]0
            [MetaWorkChromeProbe]::GetWindowThreadProcessId($pointerRoot, [ref]$coverProcessId) | Out-Null
            $coverClass = [System.Text.StringBuilder]::new(256)
            [MetaWorkChromeProbe]::GetClassNameW($pointerRoot, $coverClass, 256) | Out-Null
            throw "Another window covers the top-resize input point ($x,$($point.Y)); expected=$window actual=$pointerRoot process=$coverProcessId class=$coverClass"
        }
        $packed = ([long]($point.X -band 0xffff)) -bor ([long]($point.Y -band 0xffff) -shl 16)
        $nativeHit = [MetaWorkChromeProbe]::SendMessageW($window, 0x0084, [UIntPtr]::Zero, [IntPtr]$packed)
        $dpi = [MetaWorkChromeProbe]::GetDpiForWindow($window)
        Write-Output "edge=$edge screen=$($point.X),$($point.Y) dpi=$dpi client=$($client.Right)x$($client.Bottom) nativeHit=$nativeHit"
        [MetaWorkChromeProbe]::SetCursorPos($point.X, $point.Y) | Out-Null
        Start-Sleep -Milliseconds 100
        $cursor = New-Object MetaWorkChromeProbe+CursorInfo
        $cursor.Size = [System.Runtime.InteropServices.Marshal]::SizeOf($cursor)
        $cursorId = switch ($edge) { 'top' {32645} 'top-left' {32642} 'top-right' {32643} }
        if (-not [MetaWorkChromeProbe]::GetCursorInfo([ref]$cursor) -or
            $cursor.Cursor -ne [MetaWorkChromeProbe]::LoadCursorW([IntPtr]::Zero, [IntPtr]$cursorId)) {
            throw "$edge did not expose the native resize cursor"
        }
        try {
            Invoke-MetaWorkDrag $x ($origin.Y + 2) $dx $dy
        }
        finally {
            [MetaWorkChromeProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        }
        Start-Sleep -Milliseconds 250
        $after = Get-MetaWorkRect $window
        if ([Math]::Abs(($after.Top - $before.Top) - $dy) -gt 3 -or
            [Math]::Abs($after.Bottom - $before.Bottom) -gt 2) {
            [MetaWorkChromeProbe]::GetCursorInfo([ref]$cursor) | Out-Null
            throw "$edge mouse resize failed: top $($before.Top)->$($after.Top), bottom $($before.Bottom)->$($after.Bottom); pointer=$($cursor.Position.X),$($cursor.Position.Y) expected=$($x + $dx),$($origin.Y + 2 + $dy)"
        }
        $expectedLeft = $before.Left + $(if ($edge -eq 'top-left') { 40 } else { 0 })
        $expectedRight = $before.Right + $(if ($edge -eq 'top-right') { -40 } else { 0 })
        if ([Math]::Abs($after.Left - $expectedLeft) -gt 3 -or
            [Math]::Abs($after.Right - $expectedRight) -gt 3) {
            throw "$edge mouse resize moved the wrong horizontal edge"
        }
        Write-Output "$edge=true direct=$Direct deltaY=$dy"
    }
    }
    }
    $userAfter = [MetaWorkChromeProbe]::GetGuiResources($process.Handle, 1)
    $gdiAfter = [MetaWorkChromeProbe]::GetGuiResources($process.Handle, 0)
    # The first input can lazily allocate native/WebView resources. The normal
    # fixture and repeated drags below still enforce the steady-state bound.
    if (-not $Direct -and ($userAfter -gt $userBefore + 4 -or $gdiAfter -gt $gdiBefore + 4)) {
        throw "Resize resources grew: USER $userBefore->$userAfter; GDI $gdiBefore->$gdiAfter"
    }
    Write-Output "resizeResources=USER:$userBefore->$userAfter,GDI:$gdiBefore->$gdiAfter"
    return
}

if ($Mode -eq 'paint' -or $Mode -eq 'paint-stationary') {
    # The isolated WebView test injects a contrasting DOM strip. Read real
    # desktop pixels, including the native child, both while stationary and
    # after covering and resizing.
    Add-Type -AssemblyName System.Drawing,System.Windows.Forms
    if ($Mode -eq 'paint') {
        if (-not [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr](-1), 100, 100, $ProbeWidth, 620, 0x0040)) {
            throw 'Paint resize setup failed'
        }
        Start-Sleep -Milliseconds 180
    }
    $origin = New-Object MetaWorkChromeProbe+Point
    $client = New-Object MetaWorkChromeProbe+Rect
    if (-not [MetaWorkChromeProbe]::ClientToScreen($window, [ref]$origin) -or
        -not [MetaWorkChromeProbe]::GetClientRect($window, [ref]$client)) { throw 'Paint geometry unavailable' }
    if ($Mode -eq 'paint') {
        $cover = New-Object System.Windows.Forms.Form
        try {
            $cover.FormBorderStyle = 'None'; $cover.StartPosition = 'Manual'
            $cover.SetBounds($origin.X, $origin.Y, $client.Right, 70)
            $cover.BackColor = [System.Drawing.Color]::Black; $cover.TopMost = $true
            $cover.Show(); [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 180
        } finally { $cover.Close(); $cover.Dispose() }
        Start-Sleep -Milliseconds 200
    }
    $bitmap = New-Object System.Drawing.Bitmap $client.Right,24
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($origin.X, $origin.Y, 0, 0, $bitmap.Size)
        if ($OutputPath) {
            [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($OutputPath)) | Out-Null
            $bitmap.Save($OutputPath)
        }
        $expected = [System.Drawing.ColorTranslator]::FromHtml($ColorHex).ToArgb()
        foreach ($x in @(12, [int]($client.Right / 2), ($client.Right - 12))) {
            foreach ($y in @(1, 4, 6, 12, 20)) {
                if ($bitmap.GetPixel($x, $y).ToArgb() -ne $expected) {
                    throw "Native input child occludes WebView pixels at $x,$y; expected $ColorHex"
                }
            }
        }
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
    Write-Output "paint=$ColorHex width=$($client.Right) stationary=$($Mode -eq 'paint-stationary') occlusionRecovery=$($Mode -eq 'paint')"
    return
}

if ($Mode -eq 'top-lifecycle') {
    [MetaWorkChromeProbe]::ShowWindow($window, 9) | Out-Null
    [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr]::Zero, 100, 100, 900, 620, 0x0014) | Out-Null
    Start-Sleep -Milliseconds 250
    $rect = Get-MetaWorkRect $window
    $x = [int](($rect.Left + $rect.Right) / 2)
    $origin = New-Object MetaWorkChromeProbe+Point
    [MetaWorkChromeProbe]::ClientToScreen($window, [ref]$origin) | Out-Null
    $gap = [Math]::Max(20, [Math]::Min(60, [MetaWorkChromeProbe]::GetDoubleClickTime() / 8))
    Invoke-MetaWorkTitleClick $x ($origin.Y + 25)
    Start-Sleep -Milliseconds $gap
    Invoke-MetaWorkTitleClick $x ($origin.Y + 2)
    Start-Sleep -Milliseconds $gap
    Invoke-MetaWorkTitleClick $x ($origin.Y + 25)
    Start-Sleep -Milliseconds 100
    if ([MetaWorkChromeProbe]::IsZoomed($window)) { throw 'Native edge press failed to reset the titlebar sequence' }
    Start-Sleep -Milliseconds ([MetaWorkChromeProbe]::GetDoubleClickTime() + 100)
    Invoke-MetaWorkTitleDoubleClick $x ($origin.Y + 2) $gap
    Start-Sleep -Milliseconds 250
    $vertical = Get-MetaWorkRect $window
    if (($vertical.Bottom - $vertical.Top) -le ($rect.Bottom - $rect.Top) + 50 -or
        $vertical.Left -ne $rect.Left -or $vertical.Right -ne $rect.Right) {
        throw 'Top-edge double click did not retain native vertical sizing behavior'
    }
    $inputChild = [MetaWorkChromeProbe]::FindWindowExW($window, [IntPtr]::Zero, 'MetaWorkSystemWebViewTopResize', '')
    if ($inputChild -eq [IntPtr]::Zero) { throw 'Input child unavailable' }
    [MetaWorkChromeProbe]::ShowWindow($window, 3) | Out-Null
    Start-Sleep -Milliseconds 200
    if ([MetaWorkChromeProbe]::IsWindowVisible($inputChild)) { throw 'Maximized window retains the resize input layer' }
    [MetaWorkChromeProbe]::ShowWindow($window, 9) | Out-Null
    [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr]::Zero, 100, 100, 900, 620, 0x0014) | Out-Null
    Start-Sleep -Milliseconds 200
    if (-not [MetaWorkChromeProbe]::IsWindowVisible($inputChild)) { throw 'Restored window lost the resize input layer' }
    Write-Output 'edgeSequenceReset=true nativeEdgeDoubleClick=true maximizedLayerHidden=true restoredLayerVisible=true'
    return
}

if ($Mode -eq 'input-case') {
    $originalTime = [MetaWorkChromeProbe]::GetDoubleClickTime()
    try {
        if ($DoubleClickMilliseconds -ne 0 -and -not [MetaWorkChromeProbe]::SetDoubleClickTime($DoubleClickMilliseconds)) {
            throw 'Could not establish the non-default double-click time'
        }
        $time = [int][MetaWorkChromeProbe]::GetDoubleClickTime()
        $width = [MetaWorkChromeProbe]::GetSystemMetrics(36)
        $height = [MetaWorkChromeProbe]::GetSystemMetrics(37)
        [MetaWorkChromeProbe]::ShowWindow($window, 9) | Out-Null
        [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr]::Zero, 100, 100, 900, 620, 0x0014) | Out-Null
        Start-Sleep -Milliseconds ([Math]::Max($time, $originalTime) + 100)
        function Get-InputPoint([int]$x, [int]$y) {
            $point = New-Object MetaWorkChromeProbe+Point
            $scale = [MetaWorkChromeProbe]::GetDpiForWindow($window) / 96.0
            $point.X = [int]($x * $scale)
            $point.Y = [int]($y * $scale)
            if (-not [MetaWorkChromeProbe]::ClientToScreen($window, [ref]$point)) { throw 'ClientToScreen failed' }
            return $point
        }
        if ($InputCase -eq 'blur-reset') { Add-Type -AssemblyName System.Windows.Forms }
        $point = Get-InputPoint $PointX $PointY
        $before = Get-MetaWorkRect $window
        $gap = if ($DoubleClickMilliseconds -ge 800) { 550 } else { 60 }
        $expectedMaximized = $false
        switch ($InputCase) {
            { $_ -in @('pair', 'timeout', 'distance-inside', 'distance-outside', 'quad', 'content-reset', 'control-reset', 'blur-reset') } {
                Invoke-MetaWorkTitleClick $point.X $point.Y
                if ($InputCase -eq 'timeout') { Start-Sleep -Milliseconds ($time + 100) }
                elseif ($InputCase -eq 'content-reset') {
                    $other = Get-InputPoint 300 100
                    Invoke-MetaWorkTitleClick $other.X $other.Y
                } elseif ($InputCase -eq 'control-reset') {
                    $other = Get-InputPoint 400 20
                    Invoke-MetaWorkTitleClick $other.X $other.Y
                } elseif ($InputCase -eq 'blur-reset') {
                    # A separate native window causes real WebView blur, then focus.
                    $otherWindow = New-Object System.Windows.Forms.Form
                    try {
                        $otherWindow.Show()
                        [MetaWorkChromeProbe]::SetForegroundWindow($otherWindow.Handle) | Out-Null
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 60
                        [MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
                        Start-Sleep -Milliseconds 60
                    } finally { $otherWindow.Dispose() }
                } else { Start-Sleep -Milliseconds $gap }
                $dx = if ($InputCase -eq 'distance-inside') { [Math]::Floor($width / 2) }
                      elseif ($InputCase -eq 'distance-outside') { [Math]::Floor($width / 2) + 1 } else { 0 }
                Invoke-MetaWorkTitleClick ($point.X + $dx) $point.Y
                Start-Sleep -Milliseconds 160
                $expectedMaximized = $InputCase -in @('pair', 'distance-inside', 'quad')
                if ([MetaWorkChromeProbe]::IsZoomed($window) -ne $expectedMaximized) {
                    throw "Input case $InputCase did not respect native double-click semantics"
                }
                if ($InputCase -eq 'quad') {
                    $point = Get-InputPoint $PointX $PointY
                    Invoke-MetaWorkTitleClick $point.X $point.Y
                    Start-Sleep -Milliseconds 60
                    if (-not [MetaWorkChromeProbe]::IsZoomed($window)) { throw 'Third click toggled twice' }
                    Invoke-MetaWorkTitleClick $point.X $point.Y
                    Start-Sleep -Milliseconds 160
                    if ([MetaWorkChromeProbe]::IsZoomed($window)) { throw 'Fourth click did not restore' }
                    $expectedMaximized = $false
                }
            }
            'drag' {
                Invoke-MetaWorkDrag $point.X $point.Y 80 48
                Start-Sleep -Milliseconds 120
                $after = Get-MetaWorkRect $window
                if ([Math]::Abs($after.Left - $before.Left) -lt 12) { throw 'Draggable title did not move window' }
            }
            'no-drag' {
                Invoke-MetaWorkDrag $point.X $point.Y 80 48
                Start-Sleep -Milliseconds 120
                $after = Get-MetaWorkRect $window
                if ($after.Left -ne $before.Left -or $after.Top -ne $before.Top) { throw 'Excluded input moved window' }
            }
            default { throw "Unknown input case $InputCase" }
        }
        [ordered]@{ case=$InputCase; timeMs=$time; distanceWidth=$width; distanceHeight=$height; dpi=[MetaWorkChromeProbe]::GetDpiForWindow($window); passed=$true } | ConvertTo-Json -Compress
    } finally {
        if (-not [MetaWorkChromeProbe]::SetDoubleClickTime($originalTime) -or [MetaWorkChromeProbe]::GetDoubleClickTime() -ne $originalTime) {
            throw 'Could not restore the original system double-click time'
        }
    }
    return
}

if ($Mode -eq 'doubleclick') {
    $doubleClickTime = [int][MetaWorkChromeProbe]::GetDoubleClickTime()
    $gap = [Math]::Max(30, [Math]::Min(100, [Math]::Floor($doubleClickTime / 4)))
    $titleX = $rect.Left + [Math]::Min(600, ($rect.Right - $rect.Left) / 2)
    $titleY = $rect.Top + 25
    $contentY = $rect.Top + 100

    Invoke-MetaWorkTitleClick $titleX $titleY
    Start-Sleep -Milliseconds ($doubleClickTime + 100)
    Invoke-MetaWorkTitleClick $titleX $titleY
    Start-Sleep -Milliseconds 150
    if ([MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Titlebar presses outside GetDoubleClickTime were classified as a double click'
    }
    Invoke-MetaWorkTitleClick $titleX $contentY

    $distance = [Math]::Max(
        [MetaWorkChromeProbe]::GetSystemMetrics(36),
        [MetaWorkChromeProbe]::GetSystemMetrics(37)
    ) + 8
    Invoke-MetaWorkTitleClick $titleX $titleY
    Start-Sleep -Milliseconds $gap
    Invoke-MetaWorkTitleClick ($titleX + $distance) $titleY
    Start-Sleep -Milliseconds 150
    if ([MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Titlebar presses outside the system double-click rectangle were classified as a double click'
    }
    Invoke-MetaWorkTitleClick $titleX $contentY

    Invoke-MetaWorkTitleClick $titleX $titleY
    Start-Sleep -Milliseconds $gap
    Invoke-MetaWorkTitleClick $titleX $contentY
    Start-Sleep -Milliseconds $gap
    Invoke-MetaWorkTitleClick $titleX $titleY
    Start-Sleep -Milliseconds 120
    if ([MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'A content-area pointer press did not reset the titlebar double-click sequence'
    }
    Start-Sleep -Milliseconds $gap
    Invoke-MetaWorkTitleClick $titleX $titleY
    Start-Sleep -Milliseconds 350
    if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Renderer titlebar double click did not maximize the Native window'
    }

    $rect = Get-MetaWorkRect $window
    $titleX = $rect.Left + (($rect.Right - $rect.Left) / 2)
    $titleY = $rect.Top + 25
    Invoke-MetaWorkTitleClick $titleX $titleY
    Start-Sleep -Milliseconds 120
    if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'A third titlebar click toggled the Native window again'
    }
    Invoke-MetaWorkTitleClick $titleX ($rect.Top + 100)
    Invoke-MetaWorkTitleDoubleClick $titleX $titleY $gap
    Start-Sleep -Milliseconds 350
    if ([MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Renderer titlebar double click did not restore the Native window'
    }

    Write-Output 'doubleClickMaximize=true doubleClickRestore=true timeoutRejected=true distanceRejected=true contentReset=true tripleClickStable=true'
    return
}

if ($Mode -eq 'resize') {
    $originalWidth = $rect.Right - $rect.Left
    $originalHeight = $rect.Bottom - $rect.Top
    foreach ($size in @(
        @(980, 700),
        @(760, 620),
        @(460, 560),
        @(200, 200)
    )) {
        if (-not [MetaWorkChromeProbe]::SetWindowPos(
            $window,
            [IntPtr]::Zero,
            0,
            0,
            $size[0],
            $size[1],
            0x0016
        )) {
            throw "SetWindowPos failed for $($size[0])x$($size[1])"
        }
        Start-Sleep -Milliseconds 180
        $resized = Get-MetaWorkRect $window
        $width = $resized.Right - $resized.Left
        $height = $resized.Bottom - $resized.Top
        if ($size[0] -eq 200 -and ($width -lt 320 -or $height -lt 520)) {
            throw "Native minimum size was not enforced: ${width}x${height}"
        }
    }
    [MetaWorkChromeProbe]::SetWindowPos(
        $window,
        [IntPtr]::Zero,
        0,
        0,
        $originalWidth,
        $originalHeight,
        0x0016
    ) | Out-Null
    Start-Sleep -Milliseconds 250
    Write-Output 'resize=true nativeMinimum=true'
    return
}

if ($Mode -eq 'close') {
    Invoke-MetaWorkClick ($rect.Right - 29) ($rect.Top + 25)
    Start-Sleep -Milliseconds 350
    $process.Refresh()
    if ($process.HasExited) {
        throw 'Renderer close control exited the MetaWork process instead of applying close_policy = hide'
    }
    if (-not [MetaWorkChromeProbe]::IsWindow($window)) {
        throw 'Renderer close control destroyed the Native window instead of applying close_policy = hide'
    }
    if ([MetaWorkChromeProbe]::IsWindowVisible($window)) {
        throw 'Renderer close control did not hide the Native window'
    }
    Write-Output 'hidden=true processAlive=true windowAlive=true'
    return
}

if ($Mode -eq 'minimize') {
    [MetaWorkChromeProbe]::ShowWindow($window, 6) | Out-Null
    Start-Sleep -Milliseconds 350
    if (-not [MetaWorkChromeProbe]::IsIconic($window)) {
        throw 'Native window did not enter the minimized precondition'
    }
    Write-Output 'minimized=true'
    return
}

if ($Mode -eq 'activated') {
    $activationDeadline = (Get-Date).AddSeconds(10)
    while ((-not [MetaWorkChromeProbe]::IsWindowVisible($window) -or [MetaWorkChromeProbe]::IsIconic($window)) -and (Get-Date) -lt $activationDeadline) {
        Start-Sleep -Milliseconds 100
    }
    if (-not [MetaWorkChromeProbe]::IsWindowVisible($window)) {
        throw 'Repeated launch did not show the existing Native window'
    }
    if ([MetaWorkChromeProbe]::IsIconic($window)) {
        throw 'Repeated launch did not restore the minimized Native window'
    }
    Write-Output 'visible=true restored=true'
    return
}

if ($Mode -eq 'controls') {
    Invoke-MetaWorkClick ($rect.Right - 121) ($rect.Top + 25)
    Start-Sleep -Milliseconds 350
    if (-not [MetaWorkChromeProbe]::IsIconic($window)) {
        throw 'Renderer minimize control did not minimize the Native window'
    }

    [MetaWorkChromeProbe]::ShowWindow($window, 9) | Out-Null
    [MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
    # The minimize command's Renderer promise is throttled while the WebView is
    # hidden. Give its finally handler one resumed event-loop turn so controls
    # are enabled before the next independent action.
    Start-Sleep -Milliseconds 1000

    $rect = Get-MetaWorkRect $window
    Invoke-MetaWorkClick ($rect.Right - 75) ($rect.Top + 25)
    Start-Sleep -Milliseconds 500
    if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Renderer maximize control did not maximize the Native window'
    }

    $rect = Get-MetaWorkRect $window
    Invoke-MetaWorkClick ($rect.Right - 75) ($rect.Top + 25)
    Start-Sleep -Milliseconds 500
    if ([MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Renderer maximize control did not restore the Native window'
    }

    Write-Output 'minimize=true maximize=true restore=true'
    return
}

if ($Mode -eq 'drag') {
    $originalLeft = $rect.Left
    $originalTop = $rect.Top
    $dragX = $rect.Left + [Math]::Min(600, ($rect.Right - $rect.Left) / 2)
    $dragY = $rect.Top + 25
    Invoke-MetaWorkDrag $dragX $dragY 80 48
    Start-Sleep -Milliseconds 350
    $rect = Get-MetaWorkRect $window
    if ([Math]::Abs($rect.Left - $originalLeft) -lt 12 -and [Math]::Abs($rect.Top - $originalTop) -lt 12) {
        throw 'Renderer titlebar drag did not move the Native window'
    }

    [MetaWorkChromeProbe]::ShowWindow($window, 3) | Out-Null
    [MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
    Start-Sleep -Milliseconds 350
    if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Native window did not enter the maximized precondition'
    }
    $maximizedRect = Get-MetaWorkRect $window
    $dragX = $maximizedRect.Left + (($maximizedRect.Right - $maximizedRect.Left) / 2)
    $dragY = $maximizedRect.Top + 25
    Invoke-MetaWorkDrag $dragX $dragY 96 64
    Start-Sleep -Milliseconds 350
    if ([MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Dragging the maximized Renderer titlebar did not restore the Native window'
    }
    $restoredRect = Get-MetaWorkRect $window
    if ($restoredRect.Right - $restoredRect.Left -ge $maximizedRect.Right - $maximizedRect.Left) {
        throw 'Dragging the maximized Renderer titlebar did not recover the restored width'
    }
    if ([Math]::Abs($restoredRect.Left - $maximizedRect.Left) -lt 24 -and [Math]::Abs($restoredRect.Top - $maximizedRect.Top) -lt 24) {
        throw 'Dragging the maximized Renderer titlebar did not continue moving after restore'
    }
    Write-Output 'drag=true maximizedRestore=true'
    return
}
} finally {
    if (-not $wasTopmost -and -not $KeepTopmost -and [MetaWorkChromeProbe]::IsWindow($window)) {
        [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null
    }
}
