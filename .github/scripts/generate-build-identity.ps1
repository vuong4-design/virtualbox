<#
.SYNOPSIS
    Generate a Cloak build-identity.json manifest.

.DESCRIPTION
    Writes the canonical build manifest consumed by verify-manifest.ps1 and,
    for cloak builds, by the runtime build-identity checks. The build hash is
    computed with the same canonical byte stream as CloakBuildHashHex().

.PARAMETER BuildMode
    "stock" or "cloak". Defaults to stock.

.PARAMETER SourceRevision
    Exact source revision (normally the git commit SHA).

.PARAMETER FirmwareFamily
    Firmware family for cloak builds, for example ami.

.PARAMETER Chipsets
    Supported chipsets: i440fx, piix3, ich9.

.PARAMETER OutputPath
    Destination path for build-identity.json.
#>
[CmdletBinding()]
param(
    [ValidateSet('stock', 'cloak')][string] $BuildMode = 'stock',
    [Parameter(Mandatory = $true)][string] $SourceRevision,
    $FirmwareFamily,
    $PcBiosVersion,
    $OvmfVersion,
    $DsdtHash,
    $VgaBiosHash,
    $BiosRomHash,
    [string[]] $Chipsets = @(),
    [string] $VmmDevVendorId = '80EE',
    [string] $VmmDevDeviceId = 'CAFE',
    [string] $VgaVendorId = '80EE',
    [string] $VgaDeviceId = 'BEEF',
    [string] $VirtioVendorId = '1AF4',
    [Parameter(Mandatory = $true)][string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CloakManifest.psm1') -Force

if ($SourceRevision -notmatch '^[0-9A-Fa-f]{7,64}$') {
    throw 'SourceRevision must be a 7-64 character hexadecimal revision'
}

$ChipsetSet = @{}
foreach ($Entry in @($Chipsets)) {
    foreach ($Part in ($Entry -split ',')) {
        $Name = $Part.Trim().ToLowerInvariant()
        if (-not $Name) {
            throw 'Chipsets contains an empty name'
        }
        $ChipsetSet[$Name] = $true
    }
}
$ChipsetMask = Get-CloakChipsetMask @($ChipsetSet.Keys)
$ChipsetNames = @('i440fx', 'piix3', 'ich9') | Where-Object { $ChipsetSet.ContainsKey($_) }
$VmmDevVendor = Get-CloakUInt16 $VmmDevVendorId 'vmmDevVendorId'
$VmmDevDevice = Get-CloakUInt16 $VmmDevDeviceId 'vmmDevDeviceId'
$VgaVendor = Get-CloakUInt16 $VgaVendorId 'vgaVendorId'
$VgaDevice = Get-CloakUInt16 $VgaDeviceId 'vgaDeviceId'
$VirtioVendor = Get-CloakUInt16 $VirtioVendorId 'virtioVendorId'

if ($BuildMode -eq 'cloak') {
    if (-not $FirmwareFamily) {
        throw 'FirmwareFamily is required for a cloak manifest'
    }
    if ($ChipsetMask -eq 0) {
        throw 'Chipsets must not be empty for a cloak manifest'
    }
    foreach ($Entry in @(
        @('DsdtHash', $DsdtHash),
        @('VgaBiosHash', $VgaBiosHash),
        @('BiosRomHash', $BiosRomHash)
    )) {
        if ($Entry[1] -notmatch '^sha256:[0-9A-Fa-f]{64}$') {
            throw "$($Entry[0]) must be sha256:<64 hex characters>"
        }
    }
}

$BuildHash = Get-CloakBuildHash `
    -BuildMode $BuildMode `
    -FirmwareFamily $FirmwareFamily `
    -PcBiosVersion $PcBiosVersion `
    -OvmfVersion $OvmfVersion `
    -DsdtHash $DsdtHash `
    -VgaBiosHash $VgaBiosHash `
    -BiosRomHash $BiosRomHash `
    -ChipsetMask $ChipsetMask `
    -VmmDevVendorId $VmmDevVendor `
    -VmmDevDeviceId $VmmDevDevice `
    -VgaVendorId $VgaVendor `
    -VgaDeviceId $VgaDevice `
    -VirtioVendorId $VirtioVendor `
    -SourceRevision $SourceRevision

$Manifest = [ordered]@{
    buildMode         = $BuildMode;
    firmwareFamily    = $FirmwareFamily;
    pcBiosVersion     = $PcBiosVersion;
    ovmfVersion       = $OvmfVersion;
    dsdtHash          = $DsdtHash;
    vgaBiosHash       = $VgaBiosHash;
    biosRomHash       = $BiosRomHash;
    supportedChipsets = @($ChipsetNames);
    vmmDevVendorId    = ('{0:X4}' -f $VmmDevVendor);
    vmmDevDeviceId    = ('{0:X4}' -f $VmmDevDevice);
    vgaVendorId       = ('{0:X4}' -f $VgaVendor);
    vgaDeviceId       = ('{0:X4}' -f $VgaDevice);
    virtioVendorId    = ('{0:X4}' -f $VirtioVendor);
    sourceRevision    = $SourceRevision;
    buildHash         = $BuildHash;
}

$ResolvedOutput = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$OutputDir = Split-Path -Parent $ResolvedOutput
if ($OutputDir -and -not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$Json = $Manifest | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($ResolvedOutput, $Json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

Write-Host "Wrote build identity manifest: $ResolvedOutput"
Write-Host "  buildMode=$BuildMode sourceRevision=$SourceRevision buildHash=$BuildHash"
exit 0
