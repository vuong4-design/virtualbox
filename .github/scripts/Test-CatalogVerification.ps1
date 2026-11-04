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
$interleavedVBoxMouseLog = @'
Verifying: D:\a\_temp\vbox-guest-test-signing\VBoxMouse\VBoxMouse.inf
File is signed in catalog:
D:\a\_temp\vbox-guest-test-signing\VBoxMouse\vboxmouse.cat
Hash of file (sha1):
7416BEF318980A74BDBCDAC7E4EE94B2C0DFBB90
SignTool Error: A certificate chain processed, but terminated in a
root Signing Certificate Chain: Issued to: VirtualBox Guest Additions CI TEST ONLY certificate which is not
trusted by the trust provider. SignTool Error: File not valid:
D:\a\_temp\vbox-guest-test-signing\VBoxMouse\VBoxMouse.inf
Issued by: VirtualBox Guest Additions CI TEST ONLY
Expires: Fri Dec 04 08:17:57 2026
SHA1 hash: 7882EC9F5B341FF608C03B67F2E19F843F10E047
File is not timestamped.
Number of files successfully Verified: 0 Number of warnings: 0 Number of errors: 1
'@
if (-not (Test-CatalogUntrustedRootOnly $interleavedVBoxMouseLog)) {
    throw 'FAIL: actual VBoxMouse log with interleaved stdout/stderr was rejected'
}

$joinedSeparateStreams = @'
Verifying: D:\a\_temp\VBoxMouse\VBoxMouse.inf
File is signed in catalog: D:\a\_temp\VBoxMouse\vboxmouse.cat
Hash of file (sha1): 7416BEF318980A74BDBCDAC7E4EE94B2C0DFBB90
Signing Certificate Chain: Issued to: VirtualBox Guest Additions CI TEST ONLY
SignTool Error: A certificate chain processed, but terminated in a root certificate which is not trusted by the trust provider.
SignTool Error: File not valid: D:\a\_temp\VBoxMouse\VBoxMouse.inf
'@
if (-not (Test-CatalogUntrustedRootOnly $joinedSeparateStreams)) {
    throw 'FAIL: separated streams trust-only failure was rejected'
}

$extraNegativeCases = @{
    'Interleaved extra error' = $interleavedVBoxMouseLog + "`nSignTool Error: File hash mismatch"
    'Interleaved no member' = $interleavedVBoxMouseLog.Replace('File is signed in catalog:', 'File is NOT signed in catalog:')
    'Interleaved untrusted text removed' = $interleavedVBoxMouseLog.Replace('certificate which is not', 'certificate which is')
}
foreach ($item in $extraNegativeCases.GetEnumerator()) {
    if (Test-CatalogUntrustedRootOnly $item.Value) {
        throw "FAIL: interleaved erroneous output allowed: $($item.Key)"
    }
}
Write-Host 'Catalog verification policy tests: PASS (3 accepted trust-only, 8 rejected invalid cases)'
