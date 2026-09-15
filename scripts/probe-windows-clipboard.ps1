param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [Parameter(Mandatory = $true)]
    [string]$ExpectedPlainPath,
    [Parameter(Mandatory = $true)]
    [int]$ExpectedBytes,
    [Parameter(Mandatory = $true)]
    [string]$Marker,
    [string]$ExpectedCode
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MetaWorkClipboardProbe {
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
[MetaWorkClipboardProbe]::SetForegroundWindow($window) | Out-Null
Start-Sleep -Milliseconds 250
$root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
$buttonCondition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
    [System.Windows.Automation.ControlType]::Button
)

function Find-MetaWorkButton([string]$pattern) {
    $items = $root.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants,
        $buttonCondition
    )
    $matches = @()
    foreach ($item in $items) {
        if ($item.Current.Name -match $pattern) {
            $matches += $item
        }
    }
    if ($matches.Count -eq 0) {
        throw "MetaWork clipboard target not found: $pattern"
    }
    return $matches |
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

function Wait-MetaWorkCopyFeedback(
    [System.Windows.Automation.AutomationElement]$button
) {
    $feedbackDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $feedbackDeadline) {
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
    throw 'MetaWork did not expose successful copy feedback'
}

function Read-MetaWorkClipboard([scriptblock]$accept) {
    $lastError = $null
    $clipboardDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $clipboardDeadline) {
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
    throw 'MetaWork clipboard payload did not reach the expected state'
}

Clear-MetaWorkClipboard
$responseButton = Find-MetaWorkButton '^(\u590d\u5236\u56de\u590d|Copy response)$'
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

$codeVerified = $false
if (-not [string]::IsNullOrEmpty($ExpectedCode)) {
    Clear-MetaWorkClipboard
    $codeButton = Find-MetaWorkButton '^(\u590d\u5236\u4ee3\u7801|Copy code)$'
    Invoke-MetaWorkButton $codeButton
    Wait-MetaWorkCopyFeedback $codeButton
    $plainOnly = Read-MetaWorkClipboard {
        param($plain, $html, $formats)
        return $plain -eq $ExpectedCode -and [string]::IsNullOrEmpty($html)
    }
    if ($plainOnly.Plain -ne $ExpectedCode -or
        -not [string]::IsNullOrEmpty($plainOnly.Html)) {
        throw 'Windows code copy did not produce exact plain-only code'
    }
    $codeVerified = $true
}

Write-Output (
    'clipboard=true bytes={0} html=true marker={1} code={2} formats={3}' -f
    $ExpectedBytes,
    $Marker,
    $codeVerified.ToString().ToLowerInvariant(),
    ($formats -join ',')
)
