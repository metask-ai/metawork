param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,
    [Parameter(Mandatory = $true)]
    [int]$Width,
    [Parameter(Mandatory = $true)]
    [int]$Height,
    [switch]$OpenSettings,
    [switch]$SelectFirstTask,
    [switch]$OpenSearch
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MetaWorkVisualCapture {
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
    public static extern bool MoveWindow(
        IntPtr window,
        int x,
        int y,
        int width,
        int height,
        bool repaint
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

    [DllImport("user32.dll")]
    public static extern void keybd_event(
        byte virtualKey,
        byte scanCode,
        uint flags,
        UIntPtr extraInfo
    );
}
'@

Add-Type -AssemblyName System.Drawing

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
$rect = New-Object MetaWorkVisualCapture+Rect
[MetaWorkVisualCapture]::GetWindowRect($window, [ref]$rect) | Out-Null
[MetaWorkVisualCapture]::MoveWindow(
    $window,
    $rect.Left,
    $rect.Top,
    $Width,
    $Height,
    $true
) | Out-Null
[MetaWorkVisualCapture]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 450
[MetaWorkVisualCapture]::GetWindowRect($window, [ref]$rect) | Out-Null

function Invoke-MetaWorkClick([int]$x, [int]$y) {
    [MetaWorkVisualCapture]::SetCursorPos($x, $y) | Out-Null
    [MetaWorkVisualCapture]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [MetaWorkVisualCapture]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Invoke-MetaWorkControlKey([byte]$virtualKey) {
    [MetaWorkVisualCapture]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [MetaWorkVisualCapture]::keybd_event($virtualKey, 0, 0, [UIntPtr]::Zero)
    [MetaWorkVisualCapture]::keybd_event($virtualKey, 0, 2, [UIntPtr]::Zero)
    [MetaWorkVisualCapture]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
}

if ($SelectFirstTask) {
    Invoke-MetaWorkClick ($rect.Left + 120) ($rect.Top + 350)
    Start-Sleep -Milliseconds 450
}

if ($OpenSettings) {
    Invoke-MetaWorkClick ($rect.Left + 132) ($rect.Bottom - 24)
    Start-Sleep -Milliseconds 250
    Invoke-MetaWorkClick ($rect.Left + 132) ($rect.Bottom - 116)
    Start-Sleep -Milliseconds 450
}

if ($OpenSearch) {
    Invoke-MetaWorkClick ($rect.Left + 600) ($rect.Bottom - 72)
    Start-Sleep -Milliseconds 120
    Invoke-MetaWorkControlKey 0x4B
    Start-Sleep -Milliseconds 450
}

$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen(
        $rect.Left,
        $rect.Top,
        0,
        0,
        (New-Object System.Drawing.Size($Width, $Height))
    )
    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}

if ($OpenSearch) {
    [MetaWorkVisualCapture]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    [MetaWorkVisualCapture]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
}
