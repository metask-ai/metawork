param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [ValidateSet('exercise', 'close')]
    [string]$Mode = 'exercise'
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

if ($Mode -eq 'close') {
    Invoke-MetaWorkClick ($rect.Right - 29) ($rect.Top + 25)
    return
}

$originalLeft = $rect.Left
$originalTop = $rect.Top
$dragX = $rect.Left + [Math]::Min(760, ($rect.Right - $rect.Left) / 2)
$dragY = $rect.Top + 25
[MetaWorkChromeProbe]::SetCursorPos($dragX, $dragY) | Out-Null
[MetaWorkChromeProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 80
[MetaWorkChromeProbe]::SetCursorPos($dragX + 12, $dragY + 8) | Out-Null
Start-Sleep -Milliseconds 300
for ($step = 2; $step -le 8; $step++) {
    [MetaWorkChromeProbe]::SetCursorPos(
        $dragX + (10 * $step),
        $dragY + (6 * $step)
    ) | Out-Null
    Start-Sleep -Milliseconds 55
}
[MetaWorkChromeProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 350
$rect = Get-MetaWorkRect $window
if ([Math]::Abs($rect.Left - $originalLeft) -lt 12 -and [Math]::Abs($rect.Top - $originalTop) -lt 12) {
    throw 'Renderer titlebar drag did not move the Native window'
}

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
