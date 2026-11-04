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
function Get-InfPackageFiles([string] $content) {
    $inSourceDisksFiles = $false
    $fileNames = @()
    foreach ($line in ($content -split '\r?\n')) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            $inSourceDisksFiles = ($Matches[1] -match '^SourceDisksFiles(?:\..+)?$')
            continue
        }
        if (-not $inSourceDisksFiles -or $line -match '^\s*(;|$)') { continue }
        if ($line -match '^\s*([^=;]+?)\s*=') {
            $fileNames += $Matches[1].Trim()
        }
    }
    if ($fileNames.Count -eq 0) { throw 'INF has no SourceDisksFiles entries to catalog' }
    return $fileNames | Sort-Object -Unique
}

function Assert-TestSignature([string] $file, [string] $thumbprint) {
    Require-File $file
    $sig = Get-AuthenticodeSignature -LiteralPath $file
    $signer = $sig.SignerCertificate
    if (-not $signer -or $signer.Thumbprint -ne $thumbprint) {
        throw "CI test signature signer mismatch for $file (status=$($sig.Status))"
    }
    # The CI runner does NOT trust the self-signed test root. Validation
    # must not import certificates into Root, which may prompt indefinitely.
    $trustOnly = $sig.Status -eq 'NotTrusted' -or (
        $sig.Status -eq 'UnknownError' -and
        $sig.StatusMessage -match '(?i)not trusted|untrusted root|0x800b0109|0x800b010a'
    )
    if ($sig.Status -ne 'Valid' -and -not $trustOnly) {
        throw "Unexpected signature status for $file : $($sig.Status) / $($sig.StatusMessage)"
    }
    Write-Host "TEST SIGNATURE OK: $(Split-Path $file -Leaf) (trust=$($sig.Status); signer=$($signer.Thumbprint))"
}
function Test-CatalogUntrustedRootOnly([string] $message) {
    # SignTool splits success details and error messages across stdout/stderr.
    # PowerShell 2>&1 can interleave them in a surprising order (observed:
    # '...terminated in a root Signing Certificate Chain: ... certificate which...').
    # The caller now captures the streams separately. Parse the error segments
    # defensively as well, without accepting missing member/hash or extra errors.
    $flat = [regex]::Replace($message, '\s+', ' ')
    if ($flat -notmatch '(?i)\bFile is signed in catalog:\s+\S+') { return $false }
    if ($flat -notmatch '(?i)\bHash of file \((sha1|sha256)\):\s*[0-9a-f]{40,64}\b') { return $false }
    $errors = [regex]::Matches($flat, '(?i)SignTool Error:')
    if ($errors.Count -ne 2) { return $false }
    $chainError = $flat.Substring($errors[0].Index, $errors[1].Index - $errors[0].Index)
    $fileError = $flat.Substring($errors[1].Index)
    $trustStart = $chainError -match '(?i)^SignTool Error:\s*A certificate chain processed, but terminated in a root\b'
    $trustEnd = $chainError -match '(?i)\bcertificate which is not trusted by the trust provider\.'
    $fileNotValid = $fileError -match '(?i)^SignTool Error:\s*File not valid:'
    return ($trustStart -and $trustEnd -and $fileNotValid)
}
function Assert-CatalogMember([string] $signTool, [string] $catalog, [string] $inf) {
    # Never merge native stdout/stderr via 2>&1. Capturing separately avoids
    # an untrusted-root sentence being split by verbose certificate-chain text.
    $stdoutLog = [IO.Path]::GetTempFileName()
    $stderrLog = [IO.Path]::GetTempFileName()
    try {
        $verifyArgs = 'verify /pa /v /c "{0}" "{1}"' -f $catalog, $inf
        $process = Start-Process -FilePath $signTool -ArgumentList $verifyArgs `
            -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
        $stdout = [IO.File]::ReadAllText($stdoutLog)
        $stderr = [IO.File]::ReadAllText($stderrLog)
        $message = $stdout + [Environment]::NewLine + $stderr
        if ($process.ExitCode -eq 0) { Write-Host "Catalog member verified: $inf"; return }
        if (-not (Test-CatalogUntrustedRootOnly $message)) {
            throw "Catalog member verification failed for $inf (exit=$($process.ExitCode)): $message"
        }
        Write-Host "Catalog member found and hashed; only test-root trust failed (expected on CI): $inf"
    }
    finally {
        Remove-Item -LiteralPath $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    }
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
        Assert-TestSignature $cat $cert.Thumbprint
        Assert-CatalogMember $signTool $cat $inf
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
Write-Host 'SIGN-PHASE 1/4: Prepare isolated CI test certificate'

# A new test certificate is created PER CI run; only its public half is uploaded.
# A software key is deliberately marked non-exportable.
$cert = New-SelfSignedCertificate -Type CodeSigningCert `
    -Subject "CN=VirtualBox Guest Additions CI TEST ONLY" `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
    -KeyExportPolicy NonExportable -KeyUsage DigitalSignature `
    -NotAfter (Get-Date).AddDays(30)

if (-not $cert -or -not $cert.HasPrivateKey) { throw 'Failed to create CI test-signing key' }
Write-Host "Development certificate created: $($cert.Thumbprint)"
Export-Certificate -Cert $cert -FilePath $publicCertPath -Type CERT -Force | Out-Null
# Never import an ephemeral test cert into CI Root/TrustedPublisher.
# Hosted Windows runners can present an interactive trust prompt and hang.
Write-Host "CI TEST signer thumbprint: $($cert.Thumbprint)"
Write-Host 'Skipped Root/TrustedPublisher import on CI (no interactive trust dialog).'
Write-Warning 'Test certificate is intentionally untrusted in CI and on guest by default.'

Write-Host "SIGN-PHASE 2/4: Sign $($sysFiles.Count) kernel drivers"
# Embed .sys signatures before creating the catalogs, since catalogs hash driver files.
foreach ($file in $sysFiles) {
    Invoke-Tool $signTool @('sign', '/fd', 'SHA256', '/sha1', $cert.Thumbprint, '/s', 'My', $file.FullName)
    Assert-TestSignature $file.FullName $cert.Thumbprint
}

$workRoot = Join-Path $env:RUNNER_TEMP 'vbox-guest-test-signing'
New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
$protectedFiles = @($sysFiles | ForEach-Object { $_.Name })

Write-Host 'SIGN-PHASE 3/4: Generate and sign four driver catalogs'
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

    # Copy exactly the files declared by the generated INF, not unrelated
    # installer binaries that kBuild could legitimately rebuild later.
    $packageDir = Join-Path $workRoot $name
    New-Item -ItemType Directory -Path $packageDir -Force | Out-Null
    $declaredFiles = @(Get-InfPackageFiles $text)
    foreach ($fileName in $declaredFiles) {
        $sourceFile = Join-Path $add $fileName
        Require-File $sourceFile
        Copy-Item -LiteralPath $sourceFile -Destination $packageDir -Force
        $protectedFiles += $fileName
    }
    Copy-Item -LiteralPath $infPath -Destination $packageDir -Force
    Invoke-Tool $inf2cat @("/driver:$packageDir", "/os:$TargetOS", '/verbose')
    $catalog = Join-Path $packageDir "$name.cat"
    Require-File $catalog
    Invoke-Tool $signTool @('sign', '/fd', 'SHA256', '/sha1', $cert.Thumbprint, '/s', 'My', $catalog)
    Assert-TestSignature $catalog $cert.Thumbprint
    Assert-CatalogMember $signTool $catalog (Join-Path $packageDir "$name.inf")
    Copy-Item -LiteralPath $catalog -Destination (Join-Path $add "$name.cat") -Force
    Write-Host "CI TEST catalog signed: $name.cat"
}

Write-Host 'SIGN-PHASE 4/4: Record driver package integrity hashes'
# Hash signed drivers and exact INF-declared files, not unrelated installer
# helpers that may be regenerated during the kBuild packing pass.
$importantFiles = @($protectedFiles) +
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
