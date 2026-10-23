Set-StrictMode -Version Latest

$script:ChipsetBits = @{
    'i440fx' = [uint32]1
    'piix3'  = [uint32]2
    'ich9'   = [uint32]4
}

function Get-CloakChipsetMask {
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
            if (-not $script:ChipsetBits.ContainsKey($Name)) {
                throw "unknown chipset '$Name'"
            }
            $Mask = $Mask -bor $script:ChipsetBits[$Name]
        }
    }
    return [uint32] $Mask
}

function Get-CloakStringOrNull {
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

function Get-CloakUInt16 {
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

function Get-CloakUInt16Property {
    param($Object, [string] $Name)
    $Property = $Object.PSObject.Properties[$Name]
    if (-not $Property) {
        throw "missing property '$Name'"
    }
    return Get-CloakUInt16 $Property.Value $Name
}

function Get-CloakLeUInt16Bytes {
    param([uint16] $Value)
    return [byte[]] @(($Value -band 0xFF), (($Value -shr 8) -band 0xFF))
}

function Get-CloakLeUInt32Bytes {
    param([uint32] $Value)
    return [byte[]] @(
        ($Value -band 0xFF),
        (($Value -shr 8) -band 0xFF),
        (($Value -shr 16) -band 0xFF),
        (($Value -shr 24) -band 0xFF)
    )
}

function Add-CloakHashString {
    param(
        [System.Collections.Generic.List[byte]] $Bytes,
        $Value
    )
    if ($null -eq $Value) {
        $Bytes.AddRange([byte[]] (Get-CloakLeUInt32Bytes ([uint32]::MaxValue)))
        return
    }
    $Text = [string] $Value
    $Encoded = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Bytes.AddRange([byte[]] (Get-CloakLeUInt32Bytes ([uint32] $Encoded.Length)))
    $Bytes.AddRange($Encoded)
}

function Get-CloakBuildHash {
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
    Add-CloakHashString $Bytes $BuildMode
    Add-CloakHashString $Bytes $FirmwareFamily
    Add-CloakHashString $Bytes $PcBiosVersion
    Add-CloakHashString $Bytes $OvmfVersion
    Add-CloakHashString $Bytes $DsdtHash
    Add-CloakHashString $Bytes $VgaBiosHash
    Add-CloakHashString $Bytes $BiosRomHash
    $Bytes.AddRange([byte[]] (Get-CloakLeUInt32Bytes $ChipsetMask))
    foreach ($Binding in @($VmmDevVendorId, $VmmDevDeviceId, $VgaVendorId, $VgaDeviceId, $VirtioVendorId)) {
        $Bytes.AddRange([byte[]] (Get-CloakLeUInt16Bytes $Binding))
    }
    Add-CloakHashString $Bytes $SourceRevision

    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash($Bytes.ToArray())
    }
    finally {
        $Sha.Dispose()
    }
    return ([BitConverter]::ToString($Digest) -replace '-', '').ToUpperInvariant()
}

Export-ModuleMember -Function Get-CloakChipsetMask, Get-CloakStringOrNull, Get-CloakUInt16, Get-CloakUInt16Property, Get-CloakBuildHash
