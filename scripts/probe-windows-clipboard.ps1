param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPlainPath,
    [Parameter(Mandatory = $true)]
    [int]$ExpectedBytes,
    [Parameter(Mandatory = $true)]
    [string]$Marker,
    [Parameter(Mandatory = $true)]
    [double]$TargetClientX,
    [Parameter(Mandatory = $true)]
    [double]$TargetClientY,
    [Parameter(Mandatory = $true)]
    [double]$ViewportWidth,
    [Parameter(Mandatory = $true)]
    [double]$ViewportHeight,
    [switch]$CodeOnly,
    [string]$ExpectedCode
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MetaWorkClipboardProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct Point { public int X; public int Y; }

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint source, uint target, bool attach);
    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(Point point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr window, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct Rect { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr window, out Rect rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr window, ref Point point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr window, IntPtr after,
        int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

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

$expected = [System.IO.File]::ReadAllText(
    $ExpectedPlainPath,
    [System.Text.UTF8Encoding]::new($false, $true)
)
$actualExpectedBytes = [System.Text.Encoding]::UTF8.GetByteCount($expected)
if ($actualExpectedBytes -ne $ExpectedBytes) {
    throw "Expected fixture byte count was $actualExpectedBytes, not $ExpectedBytes"
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
[MetaWorkClipboardProbe]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null
[MetaWorkClipboardProbe]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 250
$root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
$buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button
)

function Find-MetaWorkButton([string]$pattern, [object]$expectedPoint = $null) {
    $items = $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $buttonCondition
    )
    $matchingButtons = @()
    foreach ($item in $items) {
        if ($item.Current.Name -match $pattern -and
            ($null -eq $expectedPoint -or $item.Current.BoundingRectangle.Contains($expectedPoint))) {
            $matchingButtons += $item
        }
    }
    if ($matchingButtons.Count -eq 0) {
        throw "MetaWork clipboard target not found: $pattern"
    }
    if ($null -ne $expectedPoint -and $matchingButtons.Count -ne 1) {
        throw "Ambiguous MetaWork clipboard target at the measured point: $pattern"
    }
    return $matchingButtons |
        Sort-Object { $_.Current.BoundingRectangle.Bottom } |
        Select-Object -Last 1
}

function Invoke-MetaWorkButton([System.Windows.Automation.AutomationElement]$button) {
    $scrollPattern = $null
    if ($button.TryGetCurrentPattern(
        [System.Windows.Automation.ScrollItemPattern]::Pattern,
        [ref]$scrollPattern
    )) {
        $scrollPattern.ScrollIntoView()
        Start-Sleep -Milliseconds 180
    }
    Restore-MetaWorkForeground
    $button.SetFocus()
    Start-Sleep -Milliseconds 100
    $rectangle = $button.Current.BoundingRectangle
    if ($rectangle.Width -le 0 -or $rectangle.Height -le 0) {
        throw "MetaWork clipboard target has no clickable rectangle: $($button.Current.Name)"
    }
    $x = [int]($rectangle.Left + ($rectangle.Width / 2))
    $y = [int]($rectangle.Top + ($rectangle.Height / 2))
    [MetaWorkClipboardProbe]::SetCursorPos($x, $y) | Out-Null
    # Code-copy controls become interactive on hover. Give the Renderer one
    # frame before producing the physical user gesture required by Clipboard.
    Start-Sleep -Milliseconds 160
    $point = New-Object MetaWorkClipboardProbe+Point
    $point.X = $x
    $point.Y = $y
    $hitRoot = [MetaWorkClipboardProbe]::GetAncestor([MetaWorkClipboardProbe]::WindowFromPoint($point), 2)
    $foreground = [MetaWorkClipboardProbe]::GetForegroundWindow()
    $diagnostic = @{
        target=$button.Current.Name
        bounds=@{ x=$rectangle.Left; y=$rectangle.Top; width=$rectangle.Width; height=$rectangle.Height }
        offscreen=$button.Current.IsOffscreen
        enabled=$button.Current.IsEnabled
        window=$window.ToInt64().ToString()
        hitRoot=$hitRoot.ToInt64().ToString()
        foreground=$foreground.ToInt64().ToString()
    } | ConvertTo-Json -Compress
    Write-Output "clipboardInput=$diagnostic"
    if ($hitRoot -ne $window -or $foreground -ne $window -or
        $button.Current.IsOffscreen -or -not $button.Current.IsEnabled) {
        throw "Clipboard input target is not currently actionable: $diagnostic"
    }
    $hit = [System.Windows.Automation.AutomationElement]::FromPoint(
        [System.Windows.Point]::new($x, $y))
    while ($null -ne $hit -and -not $hit.Equals($button) -and -not $hit.Equals($root)) {
        $hit = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($hit)
    }
    if ($null -eq $hit -or -not $hit.Equals($button)) {
        throw "Clipboard point does not hit the selected button: $diagnostic"
    }
    [MetaWorkClipboardProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [MetaWorkClipboardProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}

function Clear-MetaWorkClipboard() {
    $lastError = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            [System.Windows.Forms.Clipboard]::Clear()
            return
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 50
        }
    }
    throw $lastError
}

function Restore-MetaWorkForeground() {
    $foreground = [MetaWorkClipboardProbe]::GetForegroundWindow()
    if ($foreground -eq $window) { return }
    $targetProcessId = [uint32]0
    $foregroundProcessId = [uint32]0
    $currentThread = [MetaWorkClipboardProbe]::GetCurrentThreadId()
    $targetThread = [MetaWorkClipboardProbe]::GetWindowThreadProcessId($window, [ref]$targetProcessId)
    $foregroundThread = [MetaWorkClipboardProbe]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId)
    $targetAttached = [MetaWorkClipboardProbe]::AttachThreadInput($currentThread, $targetThread, $true)
    $foregroundAttached = $false
    try {
        if ($foregroundThread -ne 0 -and $foregroundThread -ne $targetThread -and $foregroundThread -ne $currentThread) {
            $foregroundAttached = [MetaWorkClipboardProbe]::AttachThreadInput($foregroundThread, $targetThread, $true)
        }
        [MetaWorkClipboardProbe]::BringWindowToTop($window) | Out-Null
        [MetaWorkClipboardProbe]::SetForegroundWindow($window) | Out-Null
    } finally {
        if ($foregroundAttached) { [MetaWorkClipboardProbe]::AttachThreadInput($foregroundThread, $targetThread, $false) | Out-Null }
        if ($targetAttached) { [MetaWorkClipboardProbe]::AttachThreadInput($currentThread, $targetThread, $false) | Out-Null }
    }
    Start-Sleep -Milliseconds 40
}

function Wait-MetaWorkCopyFeedback(
    [System.Windows.Automation.AutomationElement]$button
) {
    $feedbackDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $feedbackDeadline) {
        Restore-MetaWorkForeground
        try {
            $name = $button.Current.Name
            if ($name -match '^(\u5df2\u590d\u5236|Copied)$') {
                return
            }
            if ($name -match '^(\u590d\u5236\u5931\u8d25|Copy failed)$') {
                throw "MetaWork reported clipboard failure: $name"
            }
        }
        catch {
            if ($_.Exception.Message -match '^MetaWork reported clipboard failure:') {
                throw
            }
            Start-Sleep -Milliseconds 40
        }
    }
    $foregroundProcessId = [uint32]0
    $foreground = [MetaWorkClipboardProbe]::GetForegroundWindow()
    [MetaWorkClipboardProbe]::GetWindowThreadProcessId($foreground, [ref]$foregroundProcessId) | Out-Null
    $foregroundOwner = if ($foregroundProcessId -ne 0) { (Get-Process -Id $foregroundProcessId).ProcessName } else { 'none' }
    throw "MetaWork did not expose successful copy feedback; lastName=$name; foreground=$foreground; owner=$foregroundOwner"
}

function Read-MetaWorkClipboard([scriptblock]$accept) {
    $lastError = $null
    $clipboardDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $clipboardDeadline) {
        Restore-MetaWorkForeground
        try {
            $data = [System.Windows.Forms.Clipboard]::GetDataObject()
            $plain = [System.Windows.Forms.Clipboard]::GetText(
                [System.Windows.Forms.TextDataFormat]::UnicodeText
            )
            $html = [System.Windows.Forms.Clipboard]::GetText(
                [System.Windows.Forms.TextDataFormat]::Html
            )
            $formats = @($data.GetFormats($false))
            if (& $accept $plain $html $formats) {
                return [PSCustomObject]@{
                    Plain = $plain
                    Html = $html
                    Formats = $formats
                }
            }
        }
        catch {
            $lastError = $_
        }
        Start-Sleep -Milliseconds 50
    }
    if ($null -ne $lastError) {
        throw $lastError
    }
    $plainBytes = [System.Text.Encoding]::UTF8.GetByteCount($plain.Replace("`r`n", "`n"))
    throw "MetaWork clipboard payload did not reach the expected state; plainBytes=$plainBytes expectedBytes=$ExpectedBytes htmlHasMarker=$($html.Contains($Marker)) formats=$($formats -join ',')"
}

$wasTopmost = ([MetaWorkClipboardProbe]::GetWindowLongPtrW($window, -20).ToInt64() -band 8) -ne 0
try {
# The standalone test owns this window. Keep the physical-input target
# unobscured and focused until asynchronous rich clipboard work is complete.
if (-not [MetaWorkClipboardProbe]::SetWindowPos($window, [IntPtr](-1), 0, 0, 0, 0, 0x0013)) {
    throw 'Could not establish unobscured clipboard input'
}
[MetaWorkClipboardProbe]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 100

if ($ViewportWidth -le 0 -or $ViewportHeight -le 0) { throw 'Clipboard input requires observed viewport bounds' }
$client = New-Object MetaWorkClipboardProbe+Rect
if (-not [MetaWorkClipboardProbe]::GetClientRect($window, [ref]$client)) { throw 'Could not read clipboard client bounds' }
$targetPoint = New-Object MetaWorkClipboardProbe+Point
$targetPoint.X = [int]($TargetClientX * ($client.Right - $client.Left) / $ViewportWidth)
$targetPoint.Y = [int]($TargetClientY * ($client.Bottom - $client.Top) / $ViewportHeight)
if (-not [MetaWorkClipboardProbe]::ClientToScreen($window, [ref]$targetPoint)) {
    throw 'Could not map the measured clipboard point to the test window'
}
$measuredPoint = [System.Windows.Point]::new($targetPoint.X, $targetPoint.Y)
if ($CodeOnly) {
    if ([string]::IsNullOrEmpty($ExpectedCode)) { throw 'Code probe requires expected code' }
    Clear-MetaWorkClipboard
    $codeButton = Find-MetaWorkButton '^(\u590d\u5236\u4ee3\u7801|Copy code)$' $measuredPoint
    Invoke-MetaWorkButton $codeButton
    Wait-MetaWorkCopyFeedback $codeButton
    $plainOnly = Read-MetaWorkClipboard {
        param($plain, $html, $formats)
        return $plain -eq $ExpectedCode -and [string]::IsNullOrEmpty($html)
    }
    if ($plainOnly.Plain -ne $ExpectedCode -or -not [string]::IsNullOrEmpty($plainOnly.Html)) {
        throw 'Windows code copy did not produce exact plain-only code'
    }
    Write-Output 'clipboard=true code=true html=false'
} else {
Clear-MetaWorkClipboard
$responseButton = Find-MetaWorkButton '^(\u590d\u5236\u56de\u590d|Copy response)$' $measuredPoint
Invoke-MetaWorkButton $responseButton
Wait-MetaWorkCopyFeedback $responseButton
$rich = Read-MetaWorkClipboard {
    param($plain, $html, $formats)
    $normalized = $plain.Replace("`r`n", "`n")
    return $normalized -eq $expected -and
        $html.Contains($Marker) -and
        ($formats -match 'HTML').Count -gt 0 -and
        ($formats -match 'UnicodeText|Text').Count -gt 0
}
$plain = $rich.Plain
$html = $rich.Html
$formats = @($rich.Formats)
$normalizedPlain = $plain.Replace("`r`n", "`n")
if ($normalizedPlain -ne $expected) {
    throw 'Windows clipboard plain text was truncated or changed beyond CRLF translation'
}
if ([System.Text.Encoding]::UTF8.GetByteCount($normalizedPlain) -ne $ExpectedBytes) {
    throw 'Windows clipboard plain text byte count changed'
}
if ($html -notmatch '(?i)<h1\b' -or
    $html -notmatch '(?i)<table\b' -or
    $html -notmatch '(?i)<pre\b' -or
    $html -notmatch '(?i)<code\b') {
    throw 'Windows clipboard HTML lost required Markdown semantics'
}
if ($html -match '(?i)<(?:button|script|img)\b') {
    throw 'Windows clipboard HTML included forbidden active or product elements'
}

Write-Output (
    'clipboard=true bytes={0} html=true marker={1} formats={2}' -f
    $ExpectedBytes,
    $Marker,
    ($formats -join ',')
)
}
} finally {
    if (-not $wasTopmost) {
        [MetaWorkClipboardProbe]::SetWindowPos($window, [IntPtr](-2), 0, 0, 0, 0, 0x0013) | Out-Null
    }
}
