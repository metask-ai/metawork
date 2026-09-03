param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [string]$CredentialEnvironmentVariable = 'METAWORK_READINESS_CREDENTIAL',
    [int]$HoldMilliseconds = 2500
)

$ErrorActionPreference = 'Stop'

if ($HoldMilliseconds -lt 1000 -or $HoldMilliseconds -gt 10000) {
    throw 'HoldMilliseconds must be between 1000 and 10000'
}
$credential = [Environment]::GetEnvironmentVariable(
    $CredentialEnvironmentVariable,
    [EnvironmentVariableTarget]::Process
)
if ([string]::IsNullOrEmpty($credential)) {
    throw "credential environment variable $CredentialEnvironmentVariable is empty"
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MetaWorkSecureInputProbe {
    public delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, System.Text.StringBuilder value, int capacity);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindowEx(
        IntPtr parent,
        IntPtr after,
        string className,
        string windowName
    );

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr SetFocus(IntPtr window);

    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wparam, IntPtr lparam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "SendMessageW")]
    public static extern IntPtr SendTextMessage(IntPtr window, uint message, IntPtr wparam, string lparam);

    public static IntPtr FindTopLevelWindow(int processId, string className) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            uint owner;
            GetWindowThreadProcessId(window, out owner);
            if (owner != processId) return true;
            var value = new System.Text.StringBuilder(256);
            GetClassName(window, value, value.Capacity);
            if (!String.Equals(value.ToString(), className, StringComparison.Ordinal))
                return true;
            found = window;
            return false;
        }, IntPtr.Zero);
        return found;
    }
}
'@
$deadline = (Get-Date).AddSeconds(15)
$dialogHandle = [IntPtr]::Zero
while ($dialogHandle -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
    $dialogHandle = [MetaWorkSecureInputProbe]::FindTopLevelWindow(
        $ProcessId,
        'MetaWorkSecureInput'
    )
    if ($dialogHandle -eq [IntPtr]::Zero) {
        Start-Sleep -Milliseconds 50
    }
}
if ($dialogHandle -eq [IntPtr]::Zero) {
    throw "secure input dialog did not appear for process $ProcessId"
}
$dialog = [System.Windows.Automation.AutomationElement]::FromHandle($dialogHandle)
if ($null -eq $dialog) {
    throw 'secure input dialog did not expose an AutomationElement'
}

$editHandle = [MetaWorkSecureInputProbe]::FindWindowEx(
    $dialogHandle,
    [IntPtr]::Zero,
    'EDIT',
    $null
)
if ($editHandle -eq [IntPtr]::Zero) {
    throw 'secure input dialog has no Edit control'
}
$edit = [System.Windows.Automation.AutomationElement]::FromHandle($editHandle)
if ($null -eq $edit) {
    throw 'secure input Edit control did not expose an AutomationElement'
}
if ($dialogHandle -eq [IntPtr]::Zero -or $editHandle -eq [IntPtr]::Zero) {
    throw 'secure input controls omitted native window handles'
}
[MetaWorkSecureInputProbe]::SetForegroundWindow($dialogHandle) | Out-Null
[MetaWorkSecureInputProbe]::SetFocus($editHandle) | Out-Null
if ([MetaWorkSecureInputProbe]::SendTextMessage(
    $editHandle,
    0x000C,
    [IntPtr]::Zero,
    $credential
).ToInt64() -eq 0) {
    throw 'secure input Edit control rejected bounded text input'
}
$passwordCharacter = [MetaWorkSecureInputProbe]::SendMessage(
    $editHandle,
    0x00D2,
    [IntPtr]::Zero,
    [IntPtr]::Zero
).ToInt64()
if ($passwordCharacter -eq 0) {
    throw 'secure input Edit control has no password masking character'
}
$isPassword = [bool]$edit.GetCurrentPropertyValue(
    [System.Windows.Automation.AutomationElement]::IsPasswordProperty
)
if (-not $isPassword) {
    throw 'secure input Edit control is not exposed as a UIA password field'
}
$valuePatternObject = $null
$valueReadable = $false
if ($edit.TryGetCurrentPattern(
    [System.Windows.Automation.ValuePattern]::Pattern,
    [ref]$valuePatternObject
)) {
    try {
        $null = ([System.Windows.Automation.ValuePattern]$valuePatternObject).Current.Value
        $valueReadable = $true
    } catch {
        # UI Automation must deny Value access for password fields.
    }
}
if ($valueReadable) {
    throw 'secure input credential is readable through UI Automation ValuePattern'
}

$holdDeadline = (Get-Date).AddMilliseconds($HoldMilliseconds)
while ((Get-Date) -lt $holdDeadline) {
    Start-Sleep -Milliseconds 100
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if (-not $process.Responding) {
        throw 'MetaWork stopped responding while secure input remained open'
    }
    $currentDialogHandle = [MetaWorkSecureInputProbe]::FindTopLevelWindow(
        $ProcessId,
        'MetaWorkSecureInput'
    )
    if ($currentDialogHandle -eq [IntPtr]::Zero) {
        throw 'secure input dialog closed before explicit confirmation'
    }
}

$buttonHandle = [MetaWorkSecureInputProbe]::FindWindowEx(
    $dialogHandle,
    [IntPtr]::Zero,
    'BUTTON',
    'Save connection'
)
if ($buttonHandle -eq [IntPtr]::Zero) {
    throw 'secure input dialog has no Save connection action'
}
[MetaWorkSecureInputProbe]::SendMessage(
    $buttonHandle,
    0x00F5,
    [IntPtr]::Zero,
    [IntPtr]::Zero
) | Out-Null

[ordered]@{
    password = $isPassword
    valueReadable = $valueReadable
    holdMilliseconds = $HoldMilliseconds
    submitted = $true
} | ConvertTo-Json -Compress
