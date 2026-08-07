param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [ValidateSet('drag', 'resize', 'controls', 'close')]
    [string]$Mode = 'drag'
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MetaWorkChromeProbe {
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
    public static extern bool IsIconic(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr window);

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
[MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 200
$rect = Get-MetaWorkRect $window

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
