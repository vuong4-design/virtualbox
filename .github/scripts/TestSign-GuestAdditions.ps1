#requires -Version 5.1
<#
.SYNOPSIS
  Test-signs Windows x64 Guest Additions for a disposable CI/test VM.
.DESCRIPTION
  Generates a short-lived, non-exportable signing key on the Windows runner.
  Publishes ONLY a public .cer and signed driver files, never a .pfx.
  This is NOT Microsoft attestation, WHQL, or production signing.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $AdditionsDir,

    [string] $TargetOS = '10_RS5_X64',

    [switch] $VerifyOnly,

    [switch] $AllowLocalTestSigning
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$add = (Resolve-Path -LiteralPath $AdditionsDir).Path
$manifestPath = Join-Path $add 'VBoxGATestSigning.json'
$publicCertPath = Join-Path $add 'VBoxGATestSigner.cer'
$infNames = @('VBoxGuest', 'VBoxMouse', 'VBoxVideo', 'VBoxWddm')

function Require-File([string] $path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required file missing: $path"
    }
}
function Invoke-Tool([string] $path, [string[]] $arguments) {
    Write-Host ("Executing: {0} {1}" -f (Split-Path $path -Leaf), ($arguments -join ' '))
    & $path @arguments
    if ($LASTEXITCODE -ne 0) { throw "$path exited with status $LASTEXITCODE" }
}
function Find-KitTool([string] $name) {
    $kit = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kit -PathType Container)) {
        throw "Windows SDK/WDK bin directory missing: $kit"
    }
    $toolMatches = @(Get-ChildItem -LiteralPath $kit -Filter $name -File -Recurse -ErrorAction SilentlyContinue)
    if ($toolMatches.Count -eq 0) { throw "$name unavailable; install the Windows WDK/SDK tools" }
    $preferred = @($toolMatches | Sort-Object -Property @{Expression = { if ($_.DirectoryName -match '[\\/]x64$') { 1 } else { 0 } }; Descending = $true }, @{Expression = { $_.FullName }; Descending = $true})
    return $preferred[0].FullName
}
function Hash-File([string] $file) {
    return (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
}

if ($VerifyOnly) {
    Require-File $manifestPath
    Require-File $publicCertPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Purpose -ne 'CI_TEST_ONLY' -or $manifest.TargetOS -ne $TargetOS) {
        throw 'Unexpected driver signing manifest or target OS'
    }
    $count = 0
    foreach ($item in $manifest.Files) {
        $file = Join-Path $add $item.Name
        Require-File $file
        $hash = Hash-File $file
        if ($hash -ne $item.Sha256) { throw "Signed package file modified since signing: $file" }
        $count++
    }
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($publicCertPath)
    if ($cert.Thumbprint -ne $manifest.CertificateThumbprint) {
        throw 'Public certificate does not match signing manifest'
    }
    $signTool = Find-KitTool 'signtool.exe'
    foreach ($name in $infNames) {
        $cat = Join-Path $add "$name.cat"
        $inf = Join-Path $add "$name.inf"
        Invoke-Tool $signTool @('verify', '/pa', $cat)
        Invoke-Tool $signTool @('verify', '/pa', '/c', $cat, $inf)
    }
    Write-Host "Test signing artifact integrity PASS: $count files and $($infNames.Count) catalogs; thumbprint $($cert.Thumbprint)"
    return
}

if ($env:GITHUB_ACTIONS -ne 'true' -and -not $AllowLocalTestSigning) {
    throw 'This test-signing operation is CI-only by default. For intentional local signing, specify -AllowLocalTestSigning.'
}

if ($TargetOS -ne '10_RS5_X64') {
    throw 'This CI test profile is intended only for Windows 10 1809 (build 17763) x64'
}
foreach ($name in $infNames) {
    Require-File (Join-Path $add "$name.inf")
    Require-File (Join-Path $add "$name.sys")
}
$sysFiles = @(Get-ChildItem -LiteralPath $add -Filter '*.sys' -File)
if ($sysFiles.Count -eq 0) { throw 'No kernel driver binaries to sign' }

$signTool = Find-KitTool 'signtool.exe'
$inf2cat = Find-KitTool 'inf2cat.exe'
Write-Host "SignTool: $signTool"
Write-Host "Inf2Cat: $inf2cat"

# A new test certificate is created PER CI run; only its public half is uploaded.
# A software key is deliberately marked non-exportable.
$cert = New-SelfSignedCertificate -Type CodeSigningCert `
    -Subject "CN=VirtualBox Guest Additions CI TEST ONLY" `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable -KeyUsage DigitalSignature `
    -NotAfter (Get-Date).AddDays(30)

if (-not $cert -or -not $cert.HasPrivateKey) { throw 'Failed to create CI test-signing key' }
Export-Certificate -Cert $cert -FilePath $publicCertPath -Type CERT -Force | Out-Null
# Trust only on the ephemeral CI runner, for signature verification.
Import-Certificate -FilePath $publicCertPath -CertStoreLocation 'Cert:\CurrentUser\Root' | Out-Null
Import-Certificate -FilePath $publicCertPath -CertStoreLocation 'Cert:\CurrentUser\TrustedPublisher' | Out-Null
Write-Host "CI TEST signer thumbprint: $($cert.Thumbprint)"
Write-Warning 'Test certificate: NOT trusted by Windows guests until deliberately imported.'

# Embed .sys signatures before creating the catalogs, since catalogs hash driver files.
foreach ($file in $sysFiles) {
    Invoke-Tool $signTool @('sign', '/fd', 'SHA256', '/sha1', $cert.Thumbprint, '/s', 'My', $file.FullName)
    Invoke-Tool $signTool @('verify', '/pa', $file.FullName)
}

$workRoot = Join-Path $env:RUNNER_TEMP 'vbox-guest-test-signing'
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$stageFiles = @(Get-ChildItem -LiteralPath $add -File |
    Where-Object { $_.Extension.ToLowerInvariant() -notin @('.inf', '.cat', '.pdb') })

foreach ($name in $infNames) {
    $infPath = Join-Path $add "$name.inf"
    $text = [IO.File]::ReadAllText($infPath)
    if ($text -match '(?im)^[ \t]*CatalogFile(?:\.\w+)?[ \t]*=') {
        throw "$name.inf already has a CatalogFile declaration; refusing to overwrite pre-existing signing metadata"
    }
    $m = [regex]::Match($text, '(?im)^[ \t]*DriverVer[ \t]*=[^\r\n]+')
    if (-not $m.Success) { throw "DriverVer not found in generated INF: $infPath" }
    $endOfLine = $text.IndexOf("`n", $m.Index)
    if ($endOfLine -lt 0) { throw "DriverVer is not newline-terminated in $infPath" }
    $text = $text.Insert($endOfLine + 1, "CatalogFile=$name.cat`r`n")
    [IO.File]::WriteAllText($infPath, $text, [Text.Encoding]::ASCII)

    # Inf2Cat requires binaries referenced by the INF in the same package tree.
    # Use a separate folder for each INF so the tool cannot process unrelated INFs.
    $packageDir = Join-Path $workRoot $name
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    foreach ($file in $stageFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageDir $file.Name))) {
            Copy-Item -LiteralPath $file.FullName -Destination $packageDir
        }
    }
    Copy-Item -LiteralPath $infPath -Destination $packageDir -Force
    Invoke-Tool $inf2cat @("/driver:$packageDir", "/os:$TargetOS", '/verbose')
    $catalog = Join-Path $packageDir "$name.cat"
    Require-File $catalog
    Invoke-Tool $signTool @('sign', '/fd', 'SHA256', '/sha1', $cert.Thumbprint, '/s', 'My', $catalog)
    Invoke-Tool $signTool @('verify', '/pa', $catalog)
    Invoke-Tool $signTool @('verify', '/pa', '/c', $catalog, (Join-Path $packageDir "$name.inf"))
    Copy-Item -LiteralPath $catalog -Destination (Join-Path $add "$name.cat") -Force
    Write-Host "CI TEST catalog signed: $name.cat"
}

# Hash every file whose bits must remain intact until NSIS packages them.
$importantFiles = @($sysFiles | ForEach-Object { $_.Name }) +
    @($infNames | ForEach-Object { "$_.inf"; "$_.cat" })
$manifestFiles = @($importantFiles | Sort-Object -Unique | ForEach-Object {
    $p = Join-Path $add $_
    Require-File $p
    [pscustomobject]@{ Name = $_; Sha256 = (Hash-File $p) }
})
$manifest = [ordered]@{
    Purpose = 'CI_TEST_ONLY'
    TargetOS = $TargetOS
    CertificateThumbprint = $cert.Thumbprint
    CertificateSubject = $cert.Subject
    CertificateNotAfterUtc = $cert.NotAfter.ToUniversalTime().ToString('o')
    Files = $manifestFiles
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Host "CI TEST signing completed; signed $($sysFiles.Count) .sys drivers and $($infNames.Count) .cat files"
Write-Host "Public certificate: $publicCertPath"
Write-Host 'The CI test key is not exported. Use the public .cer ONLY on a dedicated test VM.'
