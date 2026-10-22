param([Parameter(Mandatory = $true)][string]$FilePath)
$ErrorActionPreference = 'Stop'
# A producer started from PowerShell 7 can inherit its module search path into
# Windows PowerShell. Select the security module belonging to this process.
Import-Module "$PSHOME/Modules/Microsoft.PowerShell.Security/Microsoft.PowerShell.Security.psd1"
$signature = Get-AuthenticodeSignature -LiteralPath $FilePath
if ($signature.Status -ne 'Valid') {
    throw "Office vendor artifact has no valid Authenticode signature"
}
