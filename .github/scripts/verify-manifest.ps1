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

$ChipsetBits = @{
    'i440fx' = [uint32]1
    'piix3'  = [uint32]2
    'ich9'   = [uint32]4
}
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

function Get-StringOrNull {
    param($Object, [string] $Name)
    $Property = $Object.PSObject.Properties[$Name]
    if (-not $Property) {
        throw "missing property '$Name'"
    }
    if ($null -eq $Property.Value) {
        return $null
    }
    if ($Property.Value -isnot [string]) {
        throw "property '$Name' must be a string or null"
    }
    return [string] $Property.Value
}

function Get-UInt16 {
    param($Value, [string] $Name)
    if ($Value -is [string]) {
        $Text = $Value.Trim()
        if ($Text -match '^0x([0-9A-Fa-f]{1,4})$') {
            $Number = [Convert]::ToUInt32($Matches[1], 16)
        }
        elseif ($Text -match '^([0-9A-Fa-f]{1,4})$') {
            $Number = [Convert]::ToUInt32($Matches[1], 16)
        }
        else {
            throw "property '$Name' must be a 16-bit hexadecimal value"
        }
    }
    elseif ($Value -is [byte] -or $Value -is [uint16] -or $Value -is [int] -or
            $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64]) {
        $Number = [uint64] $Value
    }
    else {
        throw "property '$Name' must be a hexadecimal string or integer"
    }
    if ($Number -gt [uint64]0xFFFF) {
        throw "property '$Name' is outside the 16-bit range"
    }
    return [uint16] $Number
}

function Get-UInt16Property {
    param($Object, [string] $Name)
    $Property = $Object.PSObject.Properties[$Name]
    if (-not $Property) {
        throw "missing property '$Name'"
    }
    return Get-UInt16 $Property.Value $Name
}

function Get-ChipsetMask {
    param($Value)
    if ($null -eq $Value) {
        return [uint32]0
    }
    if ($Value -is [byte] -or $Value -is [uint16] -or $Value -is [int] -or
        $Value -is [uint32] -or $Value -is [long] -or $Value -is [uint64]) {
        $Mask = [uint64] $Value
        if ($Mask -gt [uint64]7) {
            throw 'property supportedChipsets contains unsupported bits'
        }
        return [uint32] $Mask
    }
    $Mask = [uint32]0
    foreach ($Entry in @($Value)) {
        if ($Entry -isnot [string]) {
            throw 'property supportedChipsets must be an array of names'
        }
        foreach ($Part in ($Entry -split ',')) {
            $Name = $Part.Trim().ToLowerInvariant()
            if (-not $Name) {
                throw 'property supportedChipsets contains an empty name'
            }
            if (-not $ChipsetBits.ContainsKey($Name)) {
                throw "unknown chipset '$Name'"
            }
            $Mask = $Mask -bor $ChipsetBits[$Name]
        }
    }
    return [uint32] $Mask
}

function Get-LeUInt16Bytes {
    param([uint16] $Value)
    return [byte[]] @(($Value -band 0xFF), (($Value -shr 8) -band 0xFF))
}

function Get-LeUInt32Bytes {
    param([uint32] $Value)
    return [byte[]] @(
        ($Value -band 0xFF),
        (($Value -shr 8) -band 0xFF),
        (($Value -shr 16) -band 0xFF),
        (($Value -shr 24) -band 0xFF)
    )
}

function Add-HashString {
    param(
        [System.Collections.Generic.List[byte]] $Bytes,
        $Value
    )
    if ($null -eq $Value) {
        $Bytes.AddRange([byte[]] (Get-LeUInt32Bytes ([uint32]::MaxValue)))
        return
    }
    $Text = [string] $Value
    $Encoded = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Bytes.AddRange([byte[]] (Get-LeUInt32Bytes ([uint32] $Encoded.Length)))
    $Bytes.AddRange($Encoded)
}

function Get-BuildHash {
    param(
        $BuildMode,
        $FirmwareFamily,
        $PcBiosVersion,
        $OvmfVersion,
        $DsdtHash,
        $VgaBiosHash,
        $BiosRomHash,
        [uint32] $ChipsetMask,
        [uint16] $VmmDevVendorId,
        [uint16] $VmmDevDeviceId,
        [uint16] $VgaVendorId,
        [uint16] $VgaDeviceId,
        [uint16] $VirtioVendorId,
        $SourceRevision
    )
    $Bytes = [System.Collections.Generic.List[byte]]::new()
    $Bytes.AddRange([System.Text.Encoding]::ASCII.GetBytes('VBoxCloakBuildManifestBuildHashV1'))
    Add-HashString $Bytes $BuildMode
    Add-HashString $Bytes $FirmwareFamily
    Add-HashString $Bytes $PcBiosVersion
    Add-HashString $Bytes $OvmfVersion
    Add-HashString $Bytes $DsdtHash
    Add-HashString $Bytes $VgaBiosHash
    Add-HashString $Bytes $BiosRomHash
    $Bytes.AddRange([byte[]] (Get-LeUInt32Bytes $ChipsetMask))
    foreach ($Binding in @($VmmDevVendorId, $VmmDevDeviceId, $VgaVendorId, $VgaDeviceId, $VirtioVendorId)) {
        $Bytes.AddRange([byte[]] (Get-LeUInt16Bytes $Binding))
    }
    Add-HashString $Bytes $SourceRevision

    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash($Bytes.ToArray())
    }
    finally {
        $Sha.Dispose()
    }
    return ([BitConverter]::ToString($Digest) -replace '-', '').ToUpperInvariant()
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

    $BuildMode = Get-StringOrNull $Json 'buildMode'
    $FirmwareFamily = Get-StringOrNull $Json 'firmwareFamily'
    $PcBiosVersion = Get-StringOrNull $Json 'pcBiosVersion'
    $OvmfVersion = Get-StringOrNull $Json 'ovmfVersion'
    $DsdtHash = Get-StringOrNull $Json 'dsdtHash'
    $VgaBiosHash = Get-StringOrNull $Json 'vgaBiosHash'
    $BiosRomHash = Get-StringOrNull $Json 'biosRomHash'
    $SourceRevision = Get-StringOrNull $Json 'sourceRevision'
    $BuildHash = Get-StringOrNull $Json 'buildHash'

    $ChipsetProperty = $Json.PSObject.Properties['supportedChipsets']
    if (-not $ChipsetProperty) {
        throw "missing property 'supportedChipsets'"
    }
    $ChipsetMask = Get-ChipsetMask $ChipsetProperty.Value

    $VmmDevVendorId = Get-UInt16Property $Json 'vmmDevVendorId'
    $VmmDevDeviceId = Get-UInt16Property $Json 'vmmDevDeviceId'
    $VgaVendorId = Get-UInt16Property $Json 'vgaVendorId'
    $VgaDeviceId = Get-UInt16Property $Json 'vgaDeviceId'
    $VirtioVendorId = Get-UInt16Property $Json 'virtioVendorId'

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
        $ExpectedMask = Get-ChipsetMask $ExpectedChipsets
        if ($ChipsetMask -ne $ExpectedMask) {
            Add-Failure "supportedChipsets mismatch: expected mask $ExpectedMask, got $ChipsetMask"
        }
    }

    $ComputedHash = Get-BuildHash `
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
