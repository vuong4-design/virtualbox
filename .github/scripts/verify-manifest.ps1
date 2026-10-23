<#
.SYNOPSIS
    Verify a Cloak build-identity.json manifest.

.DESCRIPTION
    Validates the manifest schema, policy binding IDs, optional build mode,
    firmware family, chipset set and source revision, then recomputes the
    build hash using the same canonical byte stream as CloakBuildHashHex().

.PARAMETER ManifestPath
    Path to build-identity.json.

.PARAMETER RequireCloak
    Require a complete cloak manifest. A stock manifest is rejected.

.PARAMETER ExpectedSourceRevision
    Require this exact source revision.

.PARAMETER ExpectedFirmwareFamily
    Require this firmware family (case-insensitive).

.PARAMETER ExpectedChipsets
    Require this exact chipset set, for example i440fx,piix3.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ManifestPath,
    [switch] $RequireCloak,
    [string] $ExpectedSourceRevision,
    [string] $ExpectedFirmwareFamily,
    [string[]] $ExpectedChipsets
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CloakManifest.psm1') -Force

$AllowedProperties = @(
    'buildMode', 'firmwareFamily', 'pcBiosVersion', 'ovmfVersion',
    'dsdtHash', 'vgaBiosHash', 'biosRomHash', 'supportedChipsets',
    'vmmDevVendorId', 'vmmDevDeviceId', 'vgaVendorId', 'vgaDeviceId',
    'virtioVendorId', 'sourceRevision', 'buildHash'
)
$Failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([string] $Message)
    $script:Failures.Add($Message)
}

$ResolvedPath = $ManifestPath
try {
    $ResolvedPath = (Resolve-Path -LiteralPath $ManifestPath).Path
    $Json = Get-Content -LiteralPath $ResolvedPath -Raw | ConvertFrom-Json
    if ($Json -is [System.Array]) {
        throw 'manifest must be a JSON object'
    }

    foreach ($Name in $Json.PSObject.Properties.Name) {
        if ($AllowedProperties -notcontains $Name) {
            Add-Failure "unknown property '$Name'"
        }
    }

    $BuildMode = Get-CloakStringOrNull $Json 'buildMode'
    $FirmwareFamily = Get-CloakStringOrNull $Json 'firmwareFamily'
    $PcBiosVersion = Get-CloakStringOrNull $Json 'pcBiosVersion'
    $OvmfVersion = Get-CloakStringOrNull $Json 'ovmfVersion'
    $DsdtHash = Get-CloakStringOrNull $Json 'dsdtHash'
    $VgaBiosHash = Get-CloakStringOrNull $Json 'vgaBiosHash'
    $BiosRomHash = Get-CloakStringOrNull $Json 'biosRomHash'
    $SourceRevision = Get-CloakStringOrNull $Json 'sourceRevision'
    $BuildHash = Get-CloakStringOrNull $Json 'buildHash'

    $ChipsetProperty = $Json.PSObject.Properties['supportedChipsets']
    if (-not $ChipsetProperty) {
        throw "missing property 'supportedChipsets'"
    }
    $ChipsetMask = Get-CloakChipsetMask $ChipsetProperty.Value

    $VmmDevVendorId = Get-CloakUInt16Property $Json 'vmmDevVendorId'
    $VmmDevDeviceId = Get-CloakUInt16Property $Json 'vmmDevDeviceId'
    $VgaVendorId = Get-CloakUInt16Property $Json 'vgaVendorId'
    $VgaDeviceId = Get-CloakUInt16Property $Json 'vgaDeviceId'
    $VirtioVendorId = Get-CloakUInt16Property $Json 'virtioVendorId'

    if ($BuildMode -notin @('stock', 'cloak')) {
        Add-Failure "buildMode must be 'stock' or 'cloak'"
    }
    if (-not $SourceRevision) {
        Add-Failure 'sourceRevision must not be empty'
    }
    if ($BuildHash -notmatch '^[0-9A-Fa-f]{64}$') {
        Add-Failure 'buildHash must be 64 hexadecimal characters'
    }

    if ($RequireCloak -or $BuildMode -eq 'cloak') {
        if ($BuildMode -ne 'cloak') {
            Add-Failure 'a cloak manifest is required'
        }
        if (-not $FirmwareFamily) {
            Add-Failure 'firmwareFamily must not be empty'
        }
        if ($ChipsetMask -eq 0) {
            Add-Failure 'supportedChipsets must not be empty'
        }
        foreach ($Entry in @(
            @('dsdtHash', $DsdtHash),
            @('vgaBiosHash', $VgaBiosHash),
            @('biosRomHash', $BiosRomHash)
        )) {
            if ($Entry[1] -notmatch '^sha256:[0-9A-Fa-f]{64}$') {
                Add-Failure "$($Entry[0]) must be sha256:<64 hex characters>"
            }
        }
        if ($VmmDevVendorId -ne 0x80EE -or $VmmDevDeviceId -ne 0xCAFE) {
            Add-Failure 'VMMDev binding must be 80EE:CAFE'
        }
        if ($VgaVendorId -ne 0x80EE -or $VgaDeviceId -ne 0xBEEF) {
            Add-Failure 'VGA binding must be 80EE:BEEF'
        }
        if ($VirtioVendorId -ne 0x1AF4) {
            Add-Failure 'virtio vendor must be 1AF4'
        }
    }

    if ($ExpectedSourceRevision -and $SourceRevision -ne $ExpectedSourceRevision) {
        Add-Failure "sourceRevision mismatch: expected '$ExpectedSourceRevision', got '$SourceRevision'"
    }
    if ($ExpectedFirmwareFamily) {
        if (-not $FirmwareFamily -or $FirmwareFamily -ne $ExpectedFirmwareFamily) {
            Add-Failure "firmwareFamily mismatch: expected '$ExpectedFirmwareFamily', got '$FirmwareFamily'"
        }
    }
    if ($ExpectedChipsets) {
        $ExpectedMask = Get-CloakChipsetMask $ExpectedChipsets
        if ($ChipsetMask -ne $ExpectedMask) {
            Add-Failure "supportedChipsets mismatch: expected mask $ExpectedMask, got $ChipsetMask"
        }
    }

    $ComputedHash = Get-CloakBuildHash `
        -BuildMode $BuildMode `
        -FirmwareFamily $FirmwareFamily `
        -PcBiosVersion $PcBiosVersion `
        -OvmfVersion $OvmfVersion `
        -DsdtHash $DsdtHash `
        -VgaBiosHash $VgaBiosHash `
        -BiosRomHash $BiosRomHash `
        -ChipsetMask $ChipsetMask `
        -VmmDevVendorId $VmmDevVendorId `
        -VmmDevDeviceId $VmmDevDeviceId `
        -VgaVendorId $VgaVendorId `
        -VgaDeviceId $VgaDeviceId `
        -VirtioVendorId $VirtioVendorId `
        -SourceRevision $SourceRevision

    if ($BuildHash -notmatch '^[0-9A-Fa-f]{64}$' -or
        $ComputedHash -ne $BuildHash.ToUpperInvariant()) {
        Add-Failure "buildHash mismatch: expected $ComputedHash, got $BuildHash"
    }
}
catch {
    Add-Failure $_.Exception.Message
}

if ($Failures.Count -gt 0) {
    Write-Host "Manifest verification FAILED: $ResolvedPath"
    foreach ($Failure in $Failures) {
        Write-Host "  - $Failure"
    }
    exit 2
}

Write-Host "Manifest verification OK: $ResolvedPath"
Write-Host "  buildMode=$BuildMode sourceRevision=$SourceRevision buildHash=$BuildHash"
exit 0
