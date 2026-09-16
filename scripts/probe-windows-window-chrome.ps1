param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [ValidateSet('doubleclick', 'drag', 'resize', 'top-resize', 'controls', 'close', 'minimize', 'activated')]
    [string]$Mode = 'drag'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MetaWorkChromeProbe {
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
    public static extern int GetSystemMetrics(int index);

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
$deadline = (Get-Date).AddSeconds(10)
while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 100
    $process.Refresh()
}
if ($process.MainWindowHandle -eq 0) {
    throw "MetaWork process $ProcessId has no main window"
}

$window = $process.MainWindowHandle
[MetaWorkChromeProbe]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
[MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 200
$rect = Get-MetaWorkRect $window

if ($Mode -eq 'top-resize') {
    [MetaWorkChromeProbe]::ShowWindow($window, 9) | Out-Null
    foreach ($edge in @('top', 'top-left', 'top-right')) {
        # SetWindowPos establishes a repeatable precondition only. All changes
        # checked below must be caused by real OS mouse input.
        if (-not [MetaWorkChromeProbe]::SetWindowPos($window, [IntPtr](-1), 100, 100, 900, 620, 0x0010)) {
            throw 'Could not establish top-resize precondition'
        }
        Start-Sleep -Milliseconds 250
        $before = Get-MetaWorkRect $window
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
        if ($pointerRoot -ne $window) { throw "Another window covers the top-resize input point ($x,$($point.Y)); expected=$window actual=$pointerRoot" }
        $packed = ([long]($point.X -band 0xffff)) -bor ([long]($point.Y -band 0xffff) -shl 16)
        $nativeHit = [MetaWorkChromeProbe]::SendMessageW($window, 0x0084, [UIntPtr]::Zero, [IntPtr]$packed)
        Write-Output "edge=$edge screen=$($point.X),$($point.Y) client=$($client.Right)x$($client.Bottom) nativeHit=$nativeHit"
        try {
            Invoke-MetaWorkDrag $x ($origin.Y + 2) $dx 40
        }
        finally {
            [MetaWorkChromeProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        }
        Start-Sleep -Milliseconds 250
        $after = Get-MetaWorkRect $window
        if ([Math]::Abs(($after.Top - $before.Top) - 40) -gt 3 -or
            [Math]::Abs($after.Bottom - $before.Bottom) -gt 2) {
            throw "$edge mouse resize failed: top $($before.Top)->$($after.Top), bottom $($before.Bottom)->$($after.Bottom)"
        }
        $expectedLeft = $before.Left + $(if ($edge -eq 'top-left') { 40 } else { 0 })
        $expectedRight = $before.Right + $(if ($edge -eq 'top-right') { -40 } else { 0 })
        if ([Math]::Abs($after.Left - $expectedLeft) -gt 3 -or
            [Math]::Abs($after.Right - $expectedRight) -gt 3) {
            throw "$edge mouse resize moved the wrong horizontal edge"
        }
        Write-Output "$edge=true"
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
