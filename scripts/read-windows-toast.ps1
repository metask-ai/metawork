# Reads what Windows actually put on screen for a toast banner, and clicks it.
#
# The notification-presentation vertical covers a defect in how a banner LOOKS,
# so it has to read the banner rather than the call that produced it. Windows
# composes toast banners without exposing them as enumerable top-level windows
# (neither EnumWindows nor UI Automation reaches them on Windows 10), so the
# screen itself is the only honest source: the vertical captures the banner
# anchor, compares it against a baseline taken moments earlier with nothing
# else moving on screen, and keeps the crop as evidence to read.
#
# Modes:
#   -Capture <png>              save the banner anchor region
#   -Capture <png> -Baseline <png>
#                               also report how much of it changed, and how
#                               much of the change is toast-coloured
#   -Click                      click the banner body, the way a user would
#   -ParkCursor                 move the pointer away from the banner anchor:
#                               Windows keeps a hovered banner on screen for
#                               as long as the pointer rests on it
#   -Dismiss                    close whatever banner is on screen, so the
#                               next case starts from a known-clear anchor
#   -Attribution <png> [-Match <png>]
#                               save the banner's app-attribution strip, and
#                               say whether it is the same application as a
#                               reference strip: other applications raise
#                               banners into the same anchor, and a case that
#                               asserts silence has to ignore theirs
#   -MoveClear <pid>            move that process's main window clear of the
#                               banner anchor, without touching activation, so
#                               its own repainting cannot be read as a banner
#   -ForegroundPid              print the process id owning the foreground
#
# Output is one JSON object on stdout.
[CmdletBinding()]
param(
    [string]$Capture,
    [string]$Baseline,
    [switch]$Click,
    [switch]$ParkCursor,
    [switch]$Dismiss,
    [string]$Attribution,
    [string]$Match,
    [switch]$ForegroundPid,
    [int]$MoveClear = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MetaWorkToastNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint command);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    public const uint NoZOrder = 0x0004;
    public const uint NoActivate = 0x0010;
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    public const uint LeftDown = 0x0002;
    public const uint LeftUp = 0x0004;
    public const int Restore = 9;
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
    // A webview application owns several top-level windows: message-only
    // helpers, the compositor's own, and the one the user sees. Only the
    // last carries a caption, and activating any of the others leaves the
    // host's WM_ACTIVATEAPP unmatched, so the application never learns it
    // came back to the front.
    public static IntPtr MainWindowOf(uint target) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            uint owner; GetWindowThreadProcessId(h, out owner);
            if (owner != target) return true;
            if (!IsWindowVisible(h)) return true;
            // GW_OWNER: skip tool and owned windows.
            if (GetWindow(h, 4) != IntPtr.Zero) return true;
            var caption = new System.Text.StringBuilder(512);
            if (GetWindowTextW(h, caption, 512) <= 0) return true;
            found = h;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@

# Windows anchors a banner at the bottom-right of the primary display, above
# the taskbar. The region is generous enough for the tallest banner the
# application raises (title, task name, body and one action button).
$screenWidth = [MetaWorkToastNative]::GetSystemMetrics(0)
$screenHeight = [MetaWorkToastNative]::GetSystemMetrics(1)
$regionWidth = 400
$regionHeight = 210
$regionLeft = $screenWidth - $regionWidth
$regionTop = $screenHeight - 50 - $regionHeight

function Save-Region([string]$path) {
    $bitmap = New-Object System.Drawing.Bitmap $regionWidth, $regionHeight
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen(
        (New-Object System.Drawing.Point $regionLeft, $regionTop),
        [System.Drawing.Point]::Empty,
        (New-Object System.Drawing.Size $regionWidth, $regionHeight))
    $graphics.Dispose()
    $directory = Split-Path -Parent $path
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    return $bitmap
}

function Compare-Region([System.Drawing.Bitmap]$current, [string]$baselinePath) {
    $before = [System.Drawing.Bitmap]::FromFile($baselinePath)
    try {
        $changed = 0
        $toastColoured = 0
        $total = 0
        # Sampling every third pixel is plenty to separate a banner, which
        # covers most of the anchor, from ordinary repainting behind it.
        for ($y = 0; $y -lt $regionHeight; $y += 3) {
            for ($x = 0; $x -lt $regionWidth; $x += 3) {
                $total++
                $a = $before.GetPixel($x, $y)
                $b = $current.GetPixel($x, $y)
                $delta = [Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B)
                if ($delta -le 24) { continue }
                $changed++
                # A banner is a flat, light, neutral panel. Counting how much
                # of the change looks like one separates it from a window
                # repainting behind the anchor.
                $spread = ([Math]::Max($b.R, [Math]::Max($b.G, $b.B)) - [Math]::Min($b.R, [Math]::Min($b.G, $b.B)))
                if ($b.R -ge 215 -and $b.G -ge 215 -and $b.B -ge 215 -and $spread -le 14) { $toastColoured++ }
            }
        }
        return [pscustomobject]@{
            changedFraction = [Math]::Round($changed / $total, 4)
            toastColouredFraction = [Math]::Round($toastColoured / $total, 4)
        }
    } finally { $before.Dispose() }
}

# A banner is a flat, light, neutral panel anchored at the bottom of the
# region; its top edge moves with its content. Finding that edge is what lets
# the close button be clicked without guessing at a fixed layout.
function Get-PanelTop([System.Drawing.Bitmap]$image) {
    for ($y = 0; $y -lt $regionHeight; $y++) {
        $light = 0
        $counted = 0
        for ($x = 40; $x -lt ($regionWidth - 40); $x += 4) {
            $counted++
            $pixel = $image.GetPixel($x, $y)
            $spread = ([Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B)) - [Math]::Min($pixel.R, [Math]::Min($pixel.G, $pixel.B)))
            if ($pixel.R -ge 215 -and $pixel.G -ge 215 -and $pixel.B -ge 215 -and $spread -le 14) { $light++ }
        }
        if ($counted -gt 0 -and ($light / $counted) -ge 0.95) {
            # Require the panel to continue, so one light scanline in whatever
            # sits behind the anchor is not mistaken for its top edge.
            $run = 0
            for ($probe = $y; $probe -lt [Math]::Min($regionHeight, $y + 40); $probe++) {
                $pixel = $image.GetPixel([int]($regionWidth / 2), $probe)
                $spread = ([Math]::Max($pixel.R, [Math]::Max($pixel.G, $pixel.B)) - [Math]::Min($pixel.R, [Math]::Min($pixel.G, $pixel.B)))
                if ($pixel.R -ge 200 -and $spread -le 20) { $run++ } else { break }
            }
            if ($run -ge 35) { return $y }
        }
    }
    return -1
}

if ($ParkCursor) {
    [void][MetaWorkToastNative]::SetCursorPos(8, 8)
    Write-Output (ConvertTo-Json @{ parked = $true } -Compress)
    exit 0
}

if ($Attribution) {
    $probe = Join-Path $env:TEMP ("metawork-toast-attr-" + [Guid]::NewGuid().ToString("N") + ".png")
    $image = Save-Region $probe
    try {
        $top = Get-PanelTop $image
        if ($top -lt 0) {
            Write-Output (ConvertTo-Json @{ present = $false } -Compress)
            exit 0
        }
        # The strip holding the application's icon and name, relative to the
        # panel's own top edge so a taller or shorter banner reads the same.
        $stripTop = [Math]::Min($regionHeight - 1, $top + 6)
        $stripHeight = [Math]::Min(30, $regionHeight - $stripTop)
        $strip = $image.Clone(
            (New-Object System.Drawing.Rectangle 26, $stripTop, 190, $stripHeight),
            $image.PixelFormat)
        try {
            $directory = Split-Path -Parent $Attribution
            if ($directory -and -not (Test-Path $directory)) {
                New-Item -ItemType Directory -Force -Path $directory | Out-Null
            }
            $strip.Save($Attribution, [System.Drawing.Imaging.ImageFormat]::Png)
            $result = @{ present = $true; panelTop = $top; saved = $Attribution }
            if ($Match) {
                $reference = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Match).Path)
                try {
                    $same = 0
                    $total = 0
                    for ($y = 0; $y -lt [Math]::Min($strip.Height, $reference.Height); $y++) {
                        for ($x = 0; $x -lt [Math]::Min($strip.Width, $reference.Width); $x++) {
                            $total++
                            $a = $strip.GetPixel($x, $y)
                            $b = $reference.GetPixel($x, $y)
                            $delta = [Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B)
                            if ($delta -le 48) { $same++ }
                        }
                    }
                    $result.sameFraction = [Math]::Round($same / $total, 4)
                    $result.sameApplication = ($same / $total) -ge 0.97
                } finally { $reference.Dispose() }
            }
            Write-Output (ConvertTo-Json $result -Compress)
        } finally { $strip.Dispose() }
    } finally {
        $image.Dispose()
        Remove-Item -Force $probe -ErrorAction SilentlyContinue
    }
    exit 0
}

if ($Dismiss) {
    if (-not $Baseline) { throw '-Dismiss needs -Baseline: it must see a banner before it clicks' }
    $probe = Join-Path $env:TEMP ("metawork-toast-dismiss-" + [Guid]::NewGuid().ToString("N") + ".png")
    $image = Save-Region $probe
    try {
        # Two independent signals must agree before a click is synthesized:
        # the anchor has changed against a known-clear capture, and what is
        # there now looks like a banner panel. Neither alone is enough to
        # risk clicking whatever else may be under the anchor.
        $reading = Compare-Region $image (Resolve-Path $Baseline).Path
        $top = Get-PanelTop $image
        if ($reading.changedFraction -le 0.35 -or $reading.toastColouredFraction -le 0.25 -or $top -lt 0) {
            Write-Output (ConvertTo-Json @{
                dismissed = $false
                reason = 'no banner'
                changedFraction = $reading.changedFraction
                toastColouredFraction = $reading.toastColouredFraction
                panelTop = $top
            } -Compress)
            exit 0
        }
        # The close button sits at the panel's top-right corner.
        $x = $regionLeft + $regionWidth - 22
        $y = $regionTop + $top + 26
        [void][MetaWorkToastNative]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 200
        [MetaWorkToastNative]::mouse_event([MetaWorkToastNative]::LeftDown, 0, 0, 0, [UIntPtr]::Zero)
        [MetaWorkToastNative]::mouse_event([MetaWorkToastNative]::LeftUp, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 400
        [void][MetaWorkToastNative]::SetCursorPos(8, 8)
        Start-Sleep -Milliseconds 300
        Write-Output (ConvertTo-Json @{ dismissed = $true; closedAt = @{ x = $x; y = $y } } -Compress)
    } finally {
        $image.Dispose()
        Remove-Item -Force $probe -ErrorAction SilentlyContinue
    }
    exit 0
}

if ($MoveClear -ne 0) {
    $target = [MetaWorkToastNative]::MainWindowOf([uint32]$MoveClear)
    if ($target -eq [IntPtr]::Zero) { throw "no window for pid $MoveClear" }
    # Deliberately no activation: whether the application is frontmost is the
    # fact under test, so this must not change it.
    [void][MetaWorkToastNative]::SetWindowPos(
        $target, [IntPtr]::Zero, 0, 0,
        [Math]::Max(640, $regionLeft - 40), [Math]::Max(480, $regionTop - 40),
        ([MetaWorkToastNative]::NoZOrder -bor [MetaWorkToastNative]::NoActivate))
    Start-Sleep -Milliseconds 500
    $window = [MetaWorkToastNative]::GetForegroundWindow()
    $owner = 0
    [void][MetaWorkToastNative]::GetWindowThreadProcessId($window, [ref]$owner)
    Write-Output (ConvertTo-Json @{ foregroundPid = $owner } -Compress)
    exit 0
}

if ($ForegroundPid) {
    $window = [MetaWorkToastNative]::GetForegroundWindow()
    $owner = 0
    [void][MetaWorkToastNative]::GetWindowThreadProcessId($window, [ref]$owner)
    Write-Output (ConvertTo-Json @{ foregroundPid = $owner } -Compress)
    exit 0
}

if ($Click) {
    # The banner's body sits above its action button; both are inside the
    # anchor region, and a body click is the gesture the Run notification
    # newly routes, so that is the one worth proving.
    $x = $regionLeft + [int]($regionWidth * 0.35)
    $y = $regionTop + [int]($regionHeight * 0.45)
    [void][MetaWorkToastNative]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 150
    [MetaWorkToastNative]::mouse_event([MetaWorkToastNative]::LeftDown, 0, 0, 0, [UIntPtr]::Zero)
    [MetaWorkToastNative]::mouse_event([MetaWorkToastNative]::LeftUp, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 600
    # Leave the anchor: a pointer resting on a banner keeps it on screen, and
    # a stale banner would be read as the next case's.
    [void][MetaWorkToastNative]::SetCursorPos(8, 8)
    Write-Output (ConvertTo-Json @{ clicked = @{ x = $x; y = $y } } -Compress)
    exit 0
}

if (-not $Capture) { throw 'read-windows-toast.ps1 needs a mode' }
$current = Save-Region $Capture
try {
    if (-not $Baseline) {
        Write-Output (ConvertTo-Json @{
            saved = $Capture
            region = @{ x = $regionLeft; y = $regionTop; width = $regionWidth; height = $regionHeight }
        } -Compress)
        exit 0
    }
    $reading = Compare-Region $current (Resolve-Path $Baseline).Path
    Write-Output (ConvertTo-Json @{
        saved = $Capture
        changedFraction = $reading.changedFraction
        toastColouredFraction = $reading.toastColouredFraction
        region = @{ x = $regionLeft; y = $regionTop; width = $regionWidth; height = $regionHeight }
    } -Compress)
} finally { $current.Dispose() }
