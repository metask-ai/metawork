param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [ValidateSet('exercise', 'controls', 'close', 'hit-test', 'hit-test-cleared')]
    [string]$Mode = 'exercise',
    [int]$DragX = 300,
    [int]$DragY = 15,
    [int]$ExcludedX = 40,
    [int]$ExcludedY = 15
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

    [StructLayout(LayoutKind.Sequential)]
    public struct Point {
        public int X;
        public int Y;
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

    [StructLayout(LayoutKind.Sequential)]
    public struct GuiThreadInfo {
        public int Size;
        public uint Flags;
        public IntPtr Active;
        public IntPtr Focus;
        public IntPtr Capture;
        public IntPtr MenuOwner;
        public IntPtr MoveSize;
        public IntPtr Caret;
        public Rect CaretRect;
    }

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr processId);

    [DllImport("user32.dll")]
    public static extern bool GetGUIThreadInfo(uint threadId, ref GuiThreadInfo info);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr window, ref Point point);

    [DllImport("user32.dll")]
    private static extern IntPtr ChildWindowFromPointEx(IntPtr parent, Point point, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageW(IntPtr window, uint message, UIntPtr wParam, IntPtr lParam);

    public static int HitTest(IntPtr root, int x, int y) {
        Point point = new Point { X = x, Y = y };
        IntPtr target = ChildWindowFromPointEx(root, point, 0);
        if (target == IntPtr.Zero) {
            throw new InvalidOperationException("ChildWindowFromPointEx found no target");
        }
        if (!ClientToScreen(root, ref point)) {
            throw new InvalidOperationException("ClientToScreen failed");
        }
        long packed = ((long)(ushort)point.X) | ((long)(ushort)point.Y << 16);
        int result = SendMessageW(target, 0x0084, UIntPtr.Zero, (IntPtr)packed).ToInt32();
        if (result == -1 && target != root) {
            return SendMessageW(root, 0x0084, UIntPtr.Zero, (IntPtr)packed).ToInt32();
        }
        return result;
    }
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

function Invoke-MetaWorkDoubleClick([int]$x, [int]$y) {
    Invoke-MetaWorkClick $x $y
    Start-Sleep -Milliseconds 80
    Invoke-MetaWorkClick $x $y
}

function Invoke-MetaWorkRightClick([int]$x, [int]$y) {
    [MetaWorkChromeProbe]::SetCursorPos($x, $y) | Out-Null
    [MetaWorkChromeProbe]::mouse_event(8, 0, 0, 0, [UIntPtr]::Zero)
    [MetaWorkChromeProbe]::mouse_event(16, 0, 0, 0, [UIntPtr]::Zero)
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
if ($Mode -eq 'hit-test' -or $Mode -eq 'hit-test-cleared') {
    $dragResult = [MetaWorkChromeProbe]::HitTest($window, $DragX, $DragY)
    $excludedResult = [MetaWorkChromeProbe]::HitTest(
        $window,
        $ExcludedX,
        $ExcludedY
    )
    if ($Mode -eq 'hit-test') {
        if ($dragResult -ne 2) {
            throw "drag candidate returned hit-test $dragResult instead of HTCAPTION"
        }
        if ($excludedResult -eq 2) {
            throw "interactive exclusion returned HTCAPTION"
        }
    } elseif ($dragResult -eq 2 -or $excludedResult -eq 2) {
        throw "disconnected drag mirror still returned HTCAPTION: drag=$dragResult exclusion=$excludedResult"
    }
    Write-Output "drag=$dragResult exclusion=$excludedResult"
    return
}

[MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 200
$rect = Get-MetaWorkRect $window

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
    Start-Sleep -Milliseconds 350

    $rect = Get-MetaWorkRect $window
    Invoke-MetaWorkClick ($rect.Right - 75) ($rect.Top + 25)
    Start-Sleep -Milliseconds 350
    if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Renderer maximize control did not maximize the Native window'
    }

    $rect = Get-MetaWorkRect $window
    Invoke-MetaWorkClick ($rect.Right - 75) ($rect.Top + 25)
    Start-Sleep -Milliseconds 350
    if ([MetaWorkChromeProbe]::IsZoomed($window)) {
        throw 'Renderer maximize control did not restore the Native window'
    }

    Write-Output 'minimize=true maximize=true restore=true'
    return
}

$originalLeft = $rect.Left
$originalTop = $rect.Top
$dragX = $rect.Left + [Math]::Min(760, ($rect.Right - $rect.Left) / 2)
$dragY = $rect.Top + 25
Invoke-MetaWorkDrag $dragX $dragY 80 48
Start-Sleep -Milliseconds 350
$rect = Get-MetaWorkRect $window
if ([Math]::Abs($rect.Left - $originalLeft) -lt 12 -and [Math]::Abs($rect.Top - $originalTop) -lt 12) {
    throw 'Renderer titlebar drag did not move the Native window'
}

$menuX = $rect.Left + [Math]::Min(760, ($rect.Right - $rect.Left) / 2)
$menuY = $rect.Top + 25
Invoke-MetaWorkRightClick $menuX $menuY
Start-Sleep -Milliseconds 350
$threadId = [MetaWorkChromeProbe]::GetWindowThreadProcessId($window, [IntPtr]::Zero)
$threadInfo = New-Object MetaWorkChromeProbe+GuiThreadInfo
$threadInfo.Size = [Runtime.InteropServices.Marshal]::SizeOf($threadInfo)
if (-not [MetaWorkChromeProbe]::GetGUIThreadInfo($threadId, [ref]$threadInfo) -or ($threadInfo.Flags -band 28) -eq 0 -or $threadInfo.MenuOwner -eq [IntPtr]::Zero) {
    throw 'Renderer titlebar right-click did not open the Native system menu'
}
[MetaWorkChromeProbe]::keybd_event(0x1b, 0, 0, [UIntPtr]::Zero)
[MetaWorkChromeProbe]::keybd_event(0x1b, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 200

Invoke-MetaWorkClick ($rect.Right - 121) ($rect.Top + 25)
Start-Sleep -Milliseconds 350
if (-not [MetaWorkChromeProbe]::IsIconic($window)) {
    throw 'Renderer minimize control did not minimize the Native window'
}
[MetaWorkChromeProbe]::ShowWindow($window, 9) | Out-Null
[MetaWorkChromeProbe]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 350

$rect = Get-MetaWorkRect $window
Invoke-MetaWorkDoubleClick ($rect.Left + [Math]::Min(760, ($rect.Right - $rect.Left) / 2)) ($rect.Top + 25)
Start-Sleep -Milliseconds 350
if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
    throw 'Renderer titlebar double-click did not maximize the Native window'
}

$rect = Get-MetaWorkRect $window
Invoke-MetaWorkDoubleClick ($rect.Left + [Math]::Min(760, ($rect.Right - $rect.Left) / 2)) ($rect.Top + 25)
Start-Sleep -Milliseconds 350
if ([MetaWorkChromeProbe]::IsZoomed($window)) {
    throw 'Renderer titlebar double-click did not restore the Native window'
}

$rect = Get-MetaWorkRect $window
Invoke-MetaWorkClick ($rect.Right - 75) ($rect.Top + 25)
Start-Sleep -Milliseconds 350
if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
    throw 'Renderer maximize control did not maximize the Native window'
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

Invoke-MetaWorkClick ($restoredRect.Right - 75) ($restoredRect.Top + 25)
Start-Sleep -Milliseconds 350
if (-not [MetaWorkChromeProbe]::IsZoomed($window)) {
    throw 'Renderer maximize control did not re-maximize the Native window'
}
$rect = Get-MetaWorkRect $window
Invoke-MetaWorkClick ($rect.Right - 75) ($rect.Top + 25)
Start-Sleep -Milliseconds 350
if ([MetaWorkChromeProbe]::IsZoomed($window)) {
    throw 'Renderer maximize control did not restore the Native window'
}
