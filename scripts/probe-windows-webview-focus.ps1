param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [Parameter(Mandatory = $true)]
    [string]$ComposerName
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MetaWorkWebViewFocusProbe {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, IntPtr processId);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint source, uint target, bool attach);

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);
}
'@

function Send-MetaWorkKey([byte]$virtualKey) {
    [MetaWorkWebViewFocusProbe]::keybd_event($virtualKey, 0, 0, [UIntPtr]::Zero)
    [MetaWorkWebViewFocusProbe]::keybd_event($virtualKey, 0, 2, [UIntPtr]::Zero)
}

function Find-MetaWorkComposerInput($window, $condition, [int]$waitMilliseconds) {
    $deadline = (Get-Date).AddMilliseconds($waitMilliseconds)
    do {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($window)
        $candidates = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            $condition
        )
        # Header selectors can precede the Composer in the accessibility tree.
        # An unrelated first Edit/ComboBox must not hide the editable input.
        foreach ($candidate in $candidates) {
            $candidatePattern = $null
            if ($candidate.TryGetCurrentPattern(
                [System.Windows.Automation.ValuePattern]::Pattern,
                [ref]$candidatePattern
            )) {
                $bounds = $candidate.Current.BoundingRectangle
                if ($candidate.Current.IsEnabled -and
                    $candidate.Current.IsKeyboardFocusable -and
                    -not $candidatePattern.Current.IsReadOnly -and
                    $bounds.Width -ge 250 -and
                    $bounds.Height -ge 40) {
                    return [pscustomobject]@{
                        Element = $candidate
                        Pattern = $candidatePattern
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    return $null
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
$currentThread = [MetaWorkWebViewFocusProbe]::GetCurrentThreadId()
$targetThread = [MetaWorkWebViewFocusProbe]::GetWindowThreadProcessId($window, [IntPtr]::Zero)
$foregroundWindow = [MetaWorkWebViewFocusProbe]::GetForegroundWindow()
$foregroundThread = [MetaWorkWebViewFocusProbe]::GetWindowThreadProcessId(
    $foregroundWindow,
    [IntPtr]::Zero
)
$currentAttached = [MetaWorkWebViewFocusProbe]::AttachThreadInput(
    $currentThread,
    $targetThread,
    $true
)
$foregroundAttached = $false
if ($foregroundThread -ne 0 -and
    $foregroundThread -ne $targetThread -and
    $foregroundThread -ne $currentThread) {
    $foregroundAttached = [MetaWorkWebViewFocusProbe]::AttachThreadInput(
        $foregroundThread,
        $targetThread,
        $true
    )
}

try {
    [MetaWorkWebViewFocusProbe]::BringWindowToTop($window) | Out-Null
    [MetaWorkWebViewFocusProbe]::SetForegroundWindow($window) | Out-Null
}
finally {
    if ($foregroundAttached) {
        [MetaWorkWebViewFocusProbe]::AttachThreadInput(
            $foregroundThread,
            $targetThread,
            $false
        ) | Out-Null
    }
    if ($currentAttached) {
        [MetaWorkWebViewFocusProbe]::AttachThreadInput(
            $currentThread,
            $targetThread,
            $false
        ) | Out-Null
    }
}
Start-Sleep -Milliseconds 250

$inputType = New-Object System.Windows.Automation.OrCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Edit
    )),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ComboBox
    ))
)
# The approval selector is also a writable ComboBox. Bind to the actual
# Composer name read from the DOM before sending any keyboard or ValuePattern input.
$condition = New-Object System.Windows.Automation.AndCondition(
    $inputType,
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $ComposerName
    ))
)
$composer = Find-MetaWorkComposerInput $window $condition 10000
if ($null -eq $composer) {
    throw 'MetaWork editable Composer input was not exposed to UI Automation'
}
$input = $composer.Element

$bounds = $input.Current.BoundingRectangle
$x = [int]($bounds.Left + ($bounds.Width / 2))
$y = [int]($bounds.Top + [Math]::Min(24, $bounds.Height / 2))
[MetaWorkWebViewFocusProbe]::SetCursorPos($x, $y) | Out-Null
[MetaWorkWebViewFocusProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
[MetaWorkWebViewFocusProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 200

$probe = 'X'
Send-MetaWorkKey 0x58
Start-Sleep -Milliseconds 300
$typedComposer = Find-MetaWorkComposerInput $window $condition 1000
if ($null -eq $typedComposer) {
    throw 'MetaWork Composer disappeared after keyboard input'
}
$received = $typedComposer.Pattern.Current.Value

$typedComposer.Pattern.SetValue('')
Start-Sleep -Milliseconds 100
[MetaWorkWebViewFocusProbe]::SetCursorPos($x, $y) | Out-Null
[MetaWorkWebViewFocusProbe]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
[MetaWorkWebViewFocusProbe]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
Send-MetaWorkKey 0x58
Start-Sleep -Milliseconds 100
Send-MetaWorkKey 0x08
Start-Sleep -Milliseconds 300
$clearedComposer = Find-MetaWorkComposerInput $window $condition 1000
if ($null -eq $clearedComposer -or $clearedComposer.Pattern.Current.Value -ne '') {
    $remaining = if ($null -eq $clearedComposer) { '<missing>' } else { $clearedComposer.Pattern.Current.Value }
    throw "MetaWork Composer focus probe could not clear its temporary input: '$remaining'"
}
if ($null -eq $received -or $received.ToUpperInvariant() -ne $probe) {
    throw "MetaWork Composer did not receive keyboard input after click: '$received'"
}
