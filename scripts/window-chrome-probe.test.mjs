import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

function runPowerShell(script) {
  return execFileSync(
    path.join(
      process.env.SystemRoot,
      "System32",
      "WindowsPowerShell",
      "v1.0",
      "powershell.exe",
    ),
    [
      "-NoProfile",
      "-EncodedCommand",
      Buffer.from(script, "utf16le").toString("base64"),
    ],
    { encoding: "utf8", timeout: 15_000, windowsHide: true },
  );
}

test(
  "Windows taskbar probe rejects prefix collisions and ambiguous buttons",
  {
    skip: process.platform !== "win32",
  },
  () => {
    const probe = fileURLToPath(
      new URL("./probe-windows-window-chrome.ps1", import.meta.url),
    );
    // Load only the pure selector, never the desktop input / process entrypoint.
    const script = `
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile('${probe.replaceAll("'", "''")}', [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $selector = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Select-MetaWorkTaskbarButton'}, $true)
    if (-not $selector) { throw 'Taskbar selector missing' }
    Invoke-Expression $selector.Extent.Text
    function Button([string]$name, [int]$role = 43, [int]$state = 0) {
      return [pscustomobject]@{ Name=$name; Role=$role; State=$state; Left=0; Top=0; Width=100; Height=40 }
    }
    function MustReject([object[]]$items) {
      $rejected = $false
      try { Select-MetaWorkTaskbarButton $items 'MetaWork' | Out-Null } catch { $rejected = $true }
      if (-not $rejected) { throw 'Unsafe taskbar candidates accepted' }
    }
    $correct = Button 'MetaWork - 1 running window'
    $collision = Button 'metawork-site - 5 running windows'
    $exe = Button 'metawork.exe - 1 running window'
    $chosen = Select-MetaWorkTaskbarButton @($collision, $correct, $exe) 'MetaWork'
    if ($chosen.Name -cne $correct.Name) { throw 'Wrong taskbar button selected' }
    $exact = Select-MetaWorkTaskbarButton @((Button 'MetaWork')) 'MetaWork'
    if ($exact.Name -cne 'MetaWork') { throw 'Exact window title rejected' }
    Select-MetaWorkTaskbarButton @((Button 'MetaWork - 1 个运行窗口')) 'MetaWork' | Out-Null
    MustReject @($collision, $exe)
    MustReject @($correct, $correct)
    MustReject @((Button 'MetaWork - 2 running windows'))
    MustReject @((Button 'MetaWork - docs - 1 running window'))
    MustReject @((Button 'MetaWork' 10))
    foreach ($state in @(1, 0x8000, 0x10000)) { MustReject @((Button 'MetaWork' 43 $state)) }
    Write-Output 'taskbar-selector-passed'
  `;
    const output = runPowerShell(script);
    assert.match(output, /taskbar-selector-passed/);
  },
);

test(
  "Windows clipboard lookup binds the measured reply and avoids PowerShell Matches",
  {
    skip: process.platform !== "win32",
  },
  () => {
    const probe = fileURLToPath(
      new URL("./probe-windows-clipboard.ps1", import.meta.url),
    );
    const output = runPowerShell(`
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    Add-Type -AssemblyName WindowsBase, UIAutomationClient, UIAutomationTypes
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile('${probe.replaceAll("'", "''")}', [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
    $selector = $ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Find-MetaWorkButton'}, $true)
    if (-not $selector) { throw 'Clipboard selector missing' }
    Invoke-Expression $selector.Extent.Text
    $script:buttons = @(
      foreach ($entry in @(@('Copy response', 100), @('Copy code', 200), @('Copy response', 300))) {
        [pscustomobject]@{ Current=[pscustomobject]@{ Name=$entry[0]; BoundingRectangle=[System.Windows.Rect]::new(0, $entry[1] - 32, 32, 32) } }
      }
    )
    $root = [pscustomobject]@{}
    $root | Add-Member ScriptMethod FindAll {
      return $script:buttons
    }
    $buttonCondition = $null
    $response = Find-MetaWorkButton '^Copy response$'
    if ($response.Current.BoundingRectangle.Bottom -ne 300) { throw 'Latest response not selected' }
    $code = Find-MetaWorkButton '^Copy code$'
    if ($code.Current.BoundingRectangle.Bottom -ne 200) { throw 'Code button not selected' }
    $rejected = $false
    try { Find-MetaWorkButton '^Absent$' | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Missing clipboard target accepted' }
    # The measured latest reply need not have the largest screen Y.
    $point = [System.Windows.Point]::new(16, 84)
    $measured = Find-MetaWorkButton '^Copy response$' $point
    if ($measured.Current.BoundingRectangle.Bottom -ne 100) { throw 'Measured response ignored in favor of screen order' }
    $rejected = $false
    try { Find-MetaWorkButton '^Copy response$' ([System.Windows.Point]::new(16, 184)) | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Wrong control at measured point accepted' }
    $script:buttons += $script:buttons[0]
    $rejected = $false
    try { Find-MetaWorkButton '^Copy response$' $point | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Ambiguous response point accepted' }
    Write-Output 'clipboard-selector-passed'
  `);
    assert.match(output, /clipboard-selector-passed/);
  },
);
