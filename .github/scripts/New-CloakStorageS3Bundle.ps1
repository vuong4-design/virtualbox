#requires -Version 5.1
<#
.SYNOPSIS
  Build a single versioned guest S3/C5 ZIP from the currently checked-out fork.
.DESCRIPTION
  Packages exactly three guest scripts/modules and their SHA-256 manifest.
  No VirtualBox binary build, no VM state changes, no external downloads.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$release = 'S3-C5-2026-11-B4'
$files = @(
    'Test-CloakStorageS3Guest.ps1',
    'CloakStorageC5.psm1',
    'CloakStorageWindowsQuery.psm1'
)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if ([IO.Path]::GetExtension($outputFull) -ine '.zip') {
    throw 'OutputPath must have .zip extension'
}
if ((Test-Path -LiteralPath $outputFull) -and -not $Force) {
    throw 'OutputPath exists; explicitly use -Force to overwrite it'
}
$parent = [IO.Path]::GetDirectoryName($outputFull)
if (-not [IO.Directory]::Exists($parent)) { throw 'OutputPath parent directory must already exist' }
$stage = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'cloak-s3-' + [Guid]::NewGuid().ToString('N'))
try {
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $hashes = @()
    foreach ($file in $files) {
        $source = Join-Path $PSScriptRoot $file
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Missing S3 source: ' + $file) }
        $target = Join-Path $stage $file
        [IO.File]::Copy($source,$target,$false)
        $hashes += [pscustomobject][ordered]@{
            Name = $file
            Sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        }
    }
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Release = $release
        Notes = 'Read-only S3/C5 guest scripts. SHA256 is an integrity check, not a digital signature.'
        Files = $hashes
    }
    [IO.File]::WriteAllText((Join-Path $stage 'CloakStorageS3Manifest.json'),
        ($manifest | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $outputFull -CompressionLevel Optimal -Force
    $zipHash = (Get-FileHash -LiteralPath $outputFull -Algorithm SHA256).Hash
    Write-Host ('PASS: built guest S3/C5 bundle ' + $outputFull)
    Write-Host ('Release: ' + $release)
    Write-Host ('ZIP SHA256: ' + $zipHash)
    Write-Host 'Copy the ZIP into the guest, expand to a new directory, run the script from that directory.'
}
finally {
    if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage,$true) }
}
