#requires -Version 5.1
# Self-contained tests for the CI catalog-verification policy; no WDK needed.
$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot 'TestSign-GuestAdditions.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Cannot parse signing script' }
$functions = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-CatalogUntrustedRootOnly'
}, $true))
if ($functions.Count -ne 1) { throw 'Test-CatalogUntrustedRootOnly not found exactly once' }
. ([scriptblock]::Create($functions[0].Extent.Text))

$validLog = @'
Verifying: D:\a\_temp\vbox-guest-test-signing\VBoxGuest\VBoxGuest.inf
File is signed in catalog:
D:\a\_temp\vbox-guest-test-signing\VBoxGuest\vboxguest.cat
Hash of file (sha1):
D96FE11D2F41153F27D48AA3C846491B947A6543
Signing Certificate Chain:
Issued to: VirtualBox Guest Additions CI TEST ONLY
Number of files successfully Verified: 0
Number of errors: 1
SignTool Error: A certificate chain processed, but
terminated in a root  certificate which is not trusted by the trust provider.
SignTool Error: File not valid:
D:\a\_temp\vbox-guest-test-signing\VBoxGuest\VBoxGuest.inf
'@
if (-not (Test-CatalogUntrustedRootOnly $validLog)) {
    throw 'FAIL: expected untrusted CI root was rejected'
}
$negativeCases = @{
    'No catalog membership' = $validLog.Replace('File is signed in catalog:', 'File is NOT signed in catalog:')
    'No catalog hash' = $validLog.Replace('Hash of file (sha1):', 'No file hash (sha1):')
    'Other trust failure' = $validLog.Replace('which is not trusted by the trust provider', 'which has an expired certificate')
    'Extra signature error' = $validLog + "`nSignTool Error: Hash mismatch in catalog member"
    'No file-not-valid detail' = $validLog.Replace('SignTool Error: File not valid:', 'File not valid:')
}
foreach ($item in $negativeCases.GetEnumerator()) {
    if (Test-CatalogUntrustedRootOnly $item.Value) {
        throw "FAIL: unexpected verification error was allowed: $($item.Key)"
    }
}
Write-Host 'Catalog verification policy tests: PASS (1 expected trust-only, 5 rejected invalid cases)'
