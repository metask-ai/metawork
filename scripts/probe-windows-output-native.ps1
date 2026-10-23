param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$ExpectedExecutable,
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot,
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][ValidateSet('save', 'cancel', 'reveal')][string]$Mode,
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public static class MetaWorkOutputNativeProbe {
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    private delegate bool EnumChildProc(IntPtr window, IntPtr context);
    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr context);
    [DllImport("user32.dll")]
    private static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr window, StringBuilder name, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")]
    private static extern IntPtr ReadText(IntPtr window, uint message, IntPtr count, StringBuilder text, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="SendMessageTimeoutW")]
    private static extern IntPtr WriteText(IntPtr window, uint message, IntPtr parameter, string text, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")]
    public static extern bool PostMessageW(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);
    public static string Text(IntPtr window) {
        var text = new StringBuilder(4096);
        IntPtr result;
        if (ReadText(window, 0x000D, (IntPtr)text.Capacity, text, 2, 3000, out result) == IntPtr.Zero)
            throw new InvalidOperationException("Native test filename read failed");
        return text.ToString();
    }
    public static void SetText(IntPtr window, string text) {
        IntPtr result;
        if (WriteText(window, 0x000C, IntPtr.Zero, text, 2, 3000, out result) == IntPtr.Zero || result == IntPtr.Zero)
            throw new InvalidOperationException("Native test filename input failed");
    }
    public static IntPtr Control(IntPtr root, int id, string expectedClass) {
        IntPtr found = IntPtr.Zero;
        int matches = 0;
        EnumChildWindows(root, (window, context) => {
            if (GetDlgCtrlID(window) != id) return true;
            var name = new StringBuilder(256);
            GetClassNameW(window, name, name.Capacity);
            if (String.Equals(name.ToString(), expectedClass, StringComparison.OrdinalIgnoreCase)) {
                matches++;
                found = window;
            }
            return true;
        }, IntPtr.Zero);
        return matches == 1 ? found : IntPtr.Zero;
    }
    public static IntPtr ConfirmationButton(IntPtr root, bool yes) {
        IntPtr found = IntPtr.Zero;
        int matches = 0;
        EnumChildWindows(root, (window, context) => {
            var name = new StringBuilder(128);
            var caption = new StringBuilder(128);
            GetClassNameW(window, name, name.Capacity);
            if (name.ToString() != "Button") return true;
            GetWindowTextW(window, caption, caption.Capacity);
            // The native DirectUI overwrite prompt has two ID-0 buttons.
            // Limit this probe to the verified English/Chinese captions.
            string text = caption.ToString();
            bool expected = yes ? text == "&Yes" || text == "Yes" || text == "\u662f(&Y)"
                                : text == "&No" || text == "No" || text == "\u5426(&N)";
            if (expected) { matches++; found = window; }
            return true;
        }, IntPtr.Zero);
        return matches == 1 ? found : IntPtr.Zero;
    }
    public static string[] Controls(IntPtr root) {
        var controls = new List<string>();
        EnumChildWindows(root, (window, context) => {
            var name = new StringBuilder(128);
            var caption = new StringBuilder(128);
            GetClassNameW(window, name, name.Capacity);
            GetWindowTextW(window, caption, caption.Capacity);
            controls.Add(GetDlgCtrlID(window) + ":" + name + ":" + caption);
            return controls.Count < 64;
        }, IntPtr.Zero);
        return controls.ToArray();
    }
}
'@

$process = Get-Process -Id $ProcessId
$heldHandle = $process.Handle
$mainWindow = $process.MainWindowHandle
if ($mainWindow -eq [IntPtr]::Zero) { throw 'Test application main window is unavailable' }
$mainRoot = [System.Windows.Automation.AutomationElement]::FromHandle($mainWindow)
$expected = (Resolve-Path -LiteralPath $ExpectedExecutable).ProviderPath
if (-not [string]::Equals($process.Path, $expected, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The target is not the expected test application'
}
$rootPath = (Resolve-Path -LiteralPath $WorkspaceRoot).ProviderPath.TrimEnd('\')
$source = (Resolve-Path -LiteralPath $SourcePath).ProviderPath
$sourceDirectory = [IO.Path]::GetDirectoryName($source)
if (-not $source.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source must be inside the private test Workspace'
}
if ($Mode -eq 'save') {
    if (-not [IO.Path]::IsPathRooted($Destination)) { throw 'Absolute test destination required' }
    $Destination = [IO.Path]::GetFullPath($Destination)
    if (-not $Destination.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($Destination, $source, [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($Destination)) -PathType Container)) {
        throw 'Destination must be a distinct file inside the private test Workspace'
    }
}

function Assert-Target {
    if ($process.HasExited) { throw 'Test application exited before the native action' }
}

$dialogCondition = New-Object System.Windows.Automation.AndCondition(
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)),
    (New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770'))
)
function Find-Dialogs {
    Assert-Target
    return ,($mainRoot.FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, $dialogCondition))
}
function Assert-Dialog($dialog) {
    Assert-Target
    [uint32]$ownerPid = 0
    $window = [IntPtr]$dialog.Current.NativeWindowHandle
    [MetaWorkOutputNativeProbe]::GetWindowThreadProcessId($window, [ref]$ownerPid) | Out-Null
    if ($window -eq [IntPtr]::Zero -or $ownerPid -ne $ProcessId) { throw 'Native dialog owner changed' }
}
function Find-Control($dialog, [string]$id, $type) {
    Assert-Dialog $dialog
    $nativeClass = if ($type -eq [System.Windows.Automation.ControlType]::Edit) { 'Edit' }
        elseif ($type -eq [System.Windows.Automation.ControlType]::Button) { 'Button' }
        else { throw 'Unsupported native test control' }
    $until = [DateTime]::UtcNow.AddSeconds(5)
    do {
        Assert-Dialog $dialog
        $window = [MetaWorkOutputNativeProbe]::Control([IntPtr]$dialog.Current.NativeWindowHandle, [int]$id, $nativeClass)
        if ($window -ne [IntPtr]::Zero) {
            [uint32]$ownerPid = 0
            [MetaWorkOutputNativeProbe]::GetWindowThreadProcessId($window, [ref]$ownerPid) | Out-Null
            if ($ownerPid -ne $ProcessId) { throw 'Native control owner changed' }
            return $window
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $until)
    throw "Expected exactly one native $nativeClass control: $id"
}

function Invoke-Control($dialog, [string]$id) {
    Assert-Dialog $dialog
    $button = Find-Control $dialog $id ([System.Windows.Automation.ControlType]::Button)
    [MetaWorkOutputNativeProbe]::SetForegroundWindow([IntPtr]$dialog.Current.NativeWindowHandle) | Out-Null
    if (-not [MetaWorkOutputNativeProbe]::PostMessageW($button, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)) { throw 'Native test button input failed' }
}

$success = $false
$overwriteConfirmed = $false
$deadline = [DateTime]::UtcNow.AddSeconds(25)
try {
    if ($Mode -eq 'reveal') {
        # Observe only the exact generated directory and selected fixture.
        # Never close a pre-existing Explorer window or terminate Explorer.
        $shell = New-Object -ComObject Shell.Application
        $before = @{}
        foreach ($window in $shell.Windows()) { $before[[string]$window.HWND] = $true }
        @{ phase='ready'; mode=$Mode } | ConvertTo-Json -Compress
        while ([DateTime]::UtcNow -lt $deadline) {
            Assert-Target
            foreach ($window in $shell.Windows()) {
                try { $folder = $window.Document.Folder.Self.Path } catch { continue }
                if (-not [string]::Equals($folder, $sourceDirectory, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $selected = $window.Document.SelectedItems()
                if ($selected.Count -ne 1 -or -not [string]::Equals(
                    $selected.Item(0).Path, $source, [StringComparison]::OrdinalIgnoreCase)) { continue }
                $newWindow = -not $before.ContainsKey([string]$window.HWND)
                if ($newWindow) { $window.Quit() }
                $success = $true
                @{ mode=$Mode; selectedFixture=$true; newWindow=$newWindow; closedOnlyNewFixtureWindow=$newWindow } |
                    ConvertTo-Json -Compress
                return
            }
            Start-Sleep -Milliseconds 100
        }
        throw 'Explorer did not select the exact private fixture'
    }

    @{ phase='ready'; mode=$Mode } | ConvertTo-Json -Compress
    $dialog = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        $dialogs = Find-Dialogs
        if ($dialogs.Count -gt 1) { throw 'Ambiguous test application dialogs' }
        if ($dialogs.Count -eq 1) { $dialog = $dialogs.Item(0); break }
        Start-Sleep -Milliseconds 100
    }
    if ($null -eq $dialog) {
        $owned = $mainRoot.FindAll([System.Windows.Automation.TreeScope]::Descendants, $dialogCondition)
        $windows = @()
        foreach ($item in $owned) {
            $windows += @{ name=$item.Current.Name; class=$item.Current.ClassName; pid=$item.Current.ProcessId; handle=$item.Current.NativeWindowHandle }
        }
        @{ diagnostic='native-dialog-scope'; main=$mainWindow.ToInt64(); mainName=$mainRoot.Current.Name; ownedDialogs=$windows } | ConvertTo-Json -Compress -Depth 4
        throw 'Native Save As dialog did not appear'
    }
    Assert-Dialog $dialog
    if ($Mode -eq 'cancel') {
        Invoke-Control $dialog '2'
    } else {
        $edit = Find-Control $dialog '1001' ([System.Windows.Automation.ControlType]::Edit)
        if ([MetaWorkOutputNativeProbe]::Text($edit) -ne [IO.Path]::GetFileName($source)) { throw 'Save As default filename differs from the source' }
        Assert-Dialog $dialog
        [MetaWorkOutputNativeProbe]::SetText($edit, $Destination)
        if ([MetaWorkOutputNativeProbe]::Text($edit) -ne $Destination) { throw 'Native filename input did not persist' }
        Invoke-Control $dialog '1'
    }
    while ([DateTime]::UtcNow -lt $deadline) {
        $remaining = Find-Dialogs
        if ($remaining.Count -eq 0) {
            $success = $true
            @{ mode=$Mode; dialogObserved=$true; targetProcessVerified=$true; overwriteConfirmed=$overwriteConfirmed } | ConvertTo-Json -Compress
            return
        }
        if ($Mode -eq 'save' -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            foreach ($confirmation in $remaining) {
                if (-not $confirmation.Current.IsEnabled) { continue }
                Assert-Dialog $confirmation
                $handle = [IntPtr]$confirmation.Current.NativeWindowHandle
                $yes = [MetaWorkOutputNativeProbe]::ConfirmationButton($handle, $true)
                $no = [MetaWorkOutputNativeProbe]::ConfirmationButton($handle, $false)
                if ($yes -ne [IntPtr]::Zero -and $no -ne [IntPtr]::Zero -and -not $overwriteConfirmed) {
                    [uint32]$ownerPid = 0
                    [MetaWorkOutputNativeProbe]::GetWindowThreadProcessId($yes, [ref]$ownerPid) | Out-Null
                    if ($ownerPid -ne $ProcessId) { throw 'Native confirmation owner changed' }
                    [MetaWorkOutputNativeProbe]::SetForegroundWindow($handle) | Out-Null
                    if (-not [MetaWorkOutputNativeProbe]::PostMessageW($yes, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)) {
                        throw 'Native confirmation input failed'
                    }
                    $overwriteConfirmed = $true
                }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    $states = @()
    foreach ($item in (Find-Dialogs)) {
        $entry = @{ name=$item.Current.Name; enabled=$item.Current.IsEnabled; handle=$item.Current.NativeWindowHandle }
        if ($item.Current.IsEnabled) {
            $entry.controls = [MetaWorkOutputNativeProbe]::Controls([IntPtr]$item.Current.NativeWindowHandle)
        }
        $filename = [MetaWorkOutputNativeProbe]::Control([IntPtr]$item.Current.NativeWindowHandle, 1001, 'Edit')
        if ($filename -ne [IntPtr]::Zero) { $entry.filename = [MetaWorkOutputNativeProbe]::Text($filename) }
        $states += $entry
    }
    @{ diagnostic='native-dialog-unfinished'; dialogs=$states } | ConvertTo-Json -Compress -Depth 4
    throw 'Native Save As dialog did not finish'
} finally {
    if (-not $success -and $Mode -ne 'reveal' -and -not $process.HasExited) {
        # Error cleanup is scoped to this live test PID, never a global key.
        for ($attempt = 0; $attempt -lt 3; $attempt++) {
            foreach ($owned in (Find-Dialogs)) {
                if (-not $owned.Current.IsEnabled) { continue }
                Assert-Dialog $owned
                $pattern = $owned.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
                $pattern.Close()
            }
            Start-Sleep -Milliseconds 100
        }
    }
    $process.Dispose()
}
