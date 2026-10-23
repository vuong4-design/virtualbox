<#
.SYNOPSIS
    Collector identity chạy TRONG guest Windows cho T3 (kế hoạch §4.7.3/§4.7.4.1).

.DESCRIPTION
    Thu thập identity guest-visible và ghi JSON theo schema mà
    compare-identity.ps1 đọc (schemaVersion 1). Không mask giá trị identity;
    chỉ trường thật sự volatile (timestamp, session, address) mới nằm trong
    allowlist của comparator.

    Nguồn dữ liệu:
        smbios  -> Win32_BIOS / Win32_BaseBoard / Win32_ComputerSystem / Win32_SystemEnclosure
        acpi    -> registry HKLM\HARDWARE\ACPI (OEM ID / OEM Table ID)
        pci     -> Win32_PnPEntity (VEN/DEV/SUBSYS/REV + LocationInfo -> BDF)
        cpuid   -> registry CentralProcessor (vendor/brand/identifier)
        storage -> Win32_DiskDrive (model/serial/firmware/interface)
        nic     -> Win32_NetworkAdapter (MAC + PCI ID)
        edid    -> root\wmi WmiMonitorID (manufacturer/product/serial)
        tpm     -> root\cimv2\security\microsofttpm Win32_Tpm
        guest   -> Win32_OperatingSystem (caption/version/build/arch)

    Giới hạn: CPUID leaf/register cần tool riêng (WMI không cung cấp); script
    ghi vendor/brand/identifier từ registry.

    Exit code: 0 = ghi thành công, 2 = lỗi tham số/không ghi được JSON.

.PARAMETER OutputPath
    Đường dẫn file JSON đầu ra (mặc định .\guest-identity.json).

.PARAMETER SelfTest
    Ghi một document mẫu cố định (không truy vấn hệ thống) để kiểm tra schema.

.EXAMPLE
    .\collect-guest-identity.ps1 -OutputPath C:\cloak\guest-identity.json
#>
[CmdletBinding()]
param(
    [string] $OutputPath = '.\guest-identity.json',

    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Unavailable = New-Object System.Collections.Generic.List[string]

function Get-CloakTrimmedString {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return '' }
    $Text = [string] $Value
    $Text = $Text.TrimEnd([char] 0).Trim()
    return $Text
}

function Get-CloakWmiInstance {
    param(
        [string] $ClassName,
        [string] $Namespace = 'root\cimv2',
        [string] $Filter = ''
    )

    try {
        if ($Filter) {
            return @(Get-CimInstance -ClassName $ClassName -Namespace $Namespace -Filter $Filter -ErrorAction Stop)
        }
        return @(Get-CimInstance -ClassName $ClassName -Namespace $Namespace -ErrorAction Stop)
    }
    catch {
        try {
            if ($Filter) {
                return @(Get-WmiObject -ClassName $ClassName -Namespace $Namespace -Filter $Filter -ErrorAction Stop)
            }
            return @(Get-WmiObject -ClassName $ClassName -Namespace $Namespace -ErrorAction Stop)
        }
        catch {
            [void] $script:Unavailable.Add($ClassName)
            return @()
        }
    }
}

function ConvertFrom-CloakUInt16String {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return '' }
    $Builder = New-Object System.Text.StringBuilder
    foreach ($Code in @($Value)) {
        if ([int] $Code -eq 0) { break }
        [void] $Builder.Append([char] [int] $Code)
    }
    return $Builder.ToString().Trim()
}

function Get-CloakPciIds {
    param([AllowNull()] [string] $PnpDeviceId)

    if (-not $PnpDeviceId) { return $null }
    $Match = [regex]::Match($PnpDeviceId, '^(?i)PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})(?:&SUBSYS_([0-9A-F]{8}))?(?:&REV_([0-9A-F]{2}))?')
    if (-not $Match.Success) { return $null }
    $Subsystem = $Match.Groups[3].Value
    $SubsystemDeviceId = ''
    $SubsystemVendorId = ''
    if ($Subsystem.Length -eq 8) {
        $SubsystemDeviceId = $Subsystem.Substring(0, 4)
        $SubsystemVendorId = $Subsystem.Substring(4, 4)
    }
    return [pscustomobject] @{
        VendorId          = $Match.Groups[1].Value.ToLowerInvariant()
        DeviceId          = $Match.Groups[2].Value.ToLowerInvariant()
        SubsystemVendorId = $SubsystemVendorId.ToLowerInvariant()
        SubsystemDeviceId = $SubsystemDeviceId.ToLowerInvariant()
        Revision          = $Match.Groups[4].Value.ToLowerInvariant()
    }
}

function Get-CloakPciBdf {
    param([AllowNull()] [string] $InstanceId)

    if (-not $InstanceId) { return '' }
    try {
        $Location = (Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName 'DEVPKEY_Device_LocationInfo' -ErrorAction Stop).Data
    }
    catch {
        return ''
    }
    if (-not $Location) { return '' }
    $Match = [regex]::Match($Location, 'PCI bus (\d+), device (\d+), function (\d+)')
    if (-not $Match.Success) { return '' }
    $Bus = [int] $Match.Groups[1].Value
    $Device = [int] $Match.Groups[2].Value
    $Function = [int] $Match.Groups[3].Value
    return ('{0:x2}:{1:x2}.{2:x1}' -f $Bus, $Device, $Function)
}

function Get-CloakSmbiosSection {
    $Bios = @(Get-CloakWmiInstance -ClassName 'Win32_BIOS')
    $Board = @(Get-CloakWmiInstance -ClassName 'Win32_BaseBoard')
    $System = @(Get-CloakWmiInstance -ClassName 'Win32_ComputerSystem')
    $Enclosure = @(Get-CloakWmiInstance -ClassName 'Win32_SystemEnclosure')

    if ($Bios.Count -eq 0 -and $Board.Count -eq 0 -and $System.Count -eq 0) {
        [void] $script:Unavailable.Add('smbios')
        return $null
    }

    $ChassisType = ''
    if ($Enclosure.Count -gt 0 -and $Enclosure[0].ChassisTypes) {
        $ChassisType = [string] (@($Enclosure[0].ChassisTypes)[0])
    }

    return [ordered] @{
        biosVendor          = Get-CloakTrimmedString $Bios[0].Manufacturer
        biosVersion         = Get-CloakTrimmedString $Bios[0].SMBIOSBIOSVersion
        biosReleaseDate     = Get-CloakTrimmedString $Bios[0].ReleaseDate
        biosSerial          = Get-CloakTrimmedString $Bios[0].SerialNumber
        systemManufacturer  = Get-CloakTrimmedString $System[0].Manufacturer
        systemProduct       = Get-CloakTrimmedString $System[0].Model
        baseboardManufacturer = Get-CloakTrimmedString $Board[0].Manufacturer
        baseboardProduct    = Get-CloakTrimmedString $Board[0].Product
        baseboardSerial     = Get-CloakTrimmedString $Board[0].SerialNumber
        chassisType         = $ChassisType
    }
}

function Get-CloakCpuidSection {
    $Path = 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
    if (-not (Test-Path -LiteralPath $Path)) {
        [void] $script:Unavailable.Add('cpuid')
        return $null
    }
    try {
        $Properties = Get-ItemProperty -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        [void] $script:Unavailable.Add('cpuid')
        return $null
    }
    return [ordered] @{
        vendor     = Get-CloakTrimmedString $Properties.VendorIdentifier
        brand      = Get-CloakTrimmedString $Properties.ProcessorNameString
        identifier = Get-CloakTrimmedString $Properties.Identifier
        featureSet = Get-CloakTrimmedString $Properties.FeatureSet
    }
}

function Get-CloakAcpiSection {
    $Root = 'HKLM:\HARDWARE\ACPI'
    if (-not (Test-Path -LiteralPath $Root)) {
        [void] $script:Unavailable.Add('acpi')
        return $null
    }
    $Tables = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($Signature in (Get-ChildItem -LiteralPath $Root -ErrorAction Stop)) {
            foreach ($OemId in (Get-ChildItem -LiteralPath $Signature.PSPath -ErrorAction Stop)) {
                foreach ($OemTableId in (Get-ChildItem -LiteralPath $OemId.PSPath -ErrorAction Stop)) {
                    foreach ($Revision in (Get-ChildItem -LiteralPath $OemTableId.PSPath -ErrorAction Stop)) {
                        $Tables.Add([ordered] @{
                            table     = Get-CloakTrimmedString $Signature.PSChildName
                            oemId     = Get-CloakTrimmedString $OemId.PSChildName
                            oemTableId = Get-CloakTrimmedString $OemTableId.PSChildName
                            revision  = Get-CloakTrimmedString $Revision.PSChildName
                        })
                    }
                }
            }
        }
    }
    catch {
        [void] $script:Unavailable.Add('acpi')
        return $null
    }
    $Sorted = @($Tables | Sort-Object -Property table, oemId, oemTableId, revision)
    return [ordered] @{ tables = $Sorted }
}

function Get-CloakPciSection {
    $Entities = @(Get-CloakWmiInstance -ClassName 'Win32_PnPEntity' -Filter "PNPDeviceID LIKE 'PCI\\%'")
    if ($Entities.Count -eq 0) {
        [void] $script:Unavailable.Add('pci')
        return $null
    }
    $Devices = New-Object System.Collections.Generic.List[object]
    foreach ($Entity in $Entities) {
        $Ids = Get-CloakPciIds $Entity.PNPDeviceID
        if (-not $Ids) { continue }
        $Devices.Add([ordered] @{
            bdf               = Get-CloakPciBdf $Entity.PNPDeviceID
            vendorId          = $Ids.VendorId
            deviceId          = $Ids.DeviceId
            subsystemVendorId = $Ids.SubsystemVendorId
            subsystemDeviceId = $Ids.SubsystemDeviceId
            revision          = $Ids.Revision
        })
    }
    $Sorted = @($Devices | Sort-Object -Property bdf, vendorId, deviceId, subsystemVendorId, subsystemDeviceId, revision)
    return [ordered] @{ devices = $Sorted }
}

function Get-CloakStorageSection {
    $Disks = @(Get-CloakWmiInstance -ClassName 'Win32_DiskDrive')
    if ($Disks.Count -eq 0) {
        [void] $script:Unavailable.Add('storage')
        return $null
    }
    $Devices = New-Object System.Collections.Generic.List[object]
    foreach ($Disk in $Disks) {
        $Devices.Add([ordered] @{
            model      = Get-CloakTrimmedString $Disk.Model
            serial     = Get-CloakTrimmedString $Disk.SerialNumber
            firmware   = Get-CloakTrimmedString $Disk.FirmwareRevision
            interface  = Get-CloakTrimmedString $Disk.InterfaceType
            mediaType  = Get-CloakTrimmedString $Disk.MediaType
        })
    }
    $Sorted = @($Devices | Sort-Object -Property model, serial, firmware, interface, mediaType)
    return [ordered] @{ devices = $Sorted }
}

function Get-CloakNicSection {
    $Adapters = @(Get-CloakWmiInstance -ClassName 'Win32_NetworkAdapter' -Filter 'PhysicalAdapter = True')
    if ($Adapters.Count -eq 0) {
        [void] $script:Unavailable.Add('nic')
        return $null
    }
    $Devices = New-Object System.Collections.Generic.List[object]
    foreach ($Adapter in $Adapters) {
        $Ids = Get-CloakPciIds $Adapter.PNPDeviceID
        if (-not $Ids) { continue }
        $Devices.Add([ordered] @{
            mac               = (Get-CloakTrimmedString $Adapter.MACAddress).ToLowerInvariant()
            vendorId          = $Ids.VendorId
            deviceId          = $Ids.DeviceId
            subsystemVendorId = $Ids.SubsystemVendorId
            subsystemDeviceId = $Ids.SubsystemDeviceId
            revision          = $Ids.Revision
            adapterType       = Get-CloakTrimmedString $Adapter.AdapterType
        })
    }
    $Sorted = @($Devices | Sort-Object -Property mac, vendorId, deviceId)
    return [ordered] @{ devices = $Sorted }
}

function Get-CloakEdidSection {
    $Monitors = @(Get-CloakWmiInstance -ClassName 'WmiMonitorID' -Namespace 'root\wmi')
    if ($Monitors.Count -eq 0) {
        [void] $script:Unavailable.Add('edid')
        return $null
    }
    $Displays = New-Object System.Collections.Generic.List[object]
    foreach ($Monitor in $Monitors) {
        $Displays.Add([ordered] @{
            manufacturerId = ConvertFrom-CloakUInt16String $Monitor.ManufacturerName
            productCode    = ConvertFrom-CloakUInt16String $Monitor.ProductCodeID
            serial         = ConvertFrom-CloakUInt16String $Monitor.SerialNumberID
            friendlyName   = ConvertFrom-CloakUInt16String $Monitor.UserFriendlyName
            week           = [string] $Monitor.WeekOfManufacture
            year           = [string] $Monitor.YearOfManufacture
        })
    }
    $Sorted = @($Displays | Sort-Object -Property manufacturerId, productCode, serial, friendlyName, week, year)
    return [ordered] @{ displays = $Sorted }
}

function Get-CloakTpmSection {
    $Tpm = @(Get-CloakWmiInstance -ClassName 'Win32_Tpm' -Namespace 'root\cimv2\security\microsofttpm')
    if ($Tpm.Count -eq 0) {
        return [ordered] @{ present = $false }
    }
    return [ordered] @{
        present             = $true
        specVersion         = Get-CloakTrimmedString $Tpm[0].SpecVersion
        manufacturerId      = Get-CloakTrimmedString $Tpm[0].ManufacturerIdTxt
        manufacturerVersion = Get-CloakTrimmedString $Tpm[0].ManufacturerVersion
    }
}

function Get-CloakGuestSection {
    $Os = @(Get-CloakWmiInstance -ClassName 'Win32_OperatingSystem')
    if ($Os.Count -eq 0) {
        [void] $script:Unavailable.Add('guest')
        return $null
    }
    return [ordered] @{
        caption      = Get-CloakTrimmedString $Os[0].Caption
        version      = Get-CloakTrimmedString $Os[0].Version
        buildNumber  = Get-CloakTrimmedString $Os[0].BuildNumber
        architecture = Get-CloakTrimmedString $Os[0].OSArchitecture
    }
}

function Get-CloakGuestDocument {
    $Document = [ordered] @{
        schemaVersion = 1
        source        = 'guest-windows'
        collector     = [ordered] @{
            tool      = 'collect-guest-identity.ps1'
            version   = '1'
            timestamp = (Get-Date).ToUniversalTime().ToString('o')
        }
        guest         = Get-CloakGuestSection
        smbios        = Get-CloakSmbiosSection
        cpuid         = Get-CloakCpuidSection
        acpi          = Get-CloakAcpiSection
        pci           = Get-CloakPciSection
        storage       = Get-CloakStorageSection
        nic           = Get-CloakNicSection
        edid          = Get-CloakEdidSection
        tpm           = Get-CloakTpmSection
    }

    foreach ($Name in @('guest', 'smbios', 'cpuid', 'acpi', 'pci', 'storage', 'nic', 'edid')) {
        if ($null -eq $Document[$Name]) {
            $Document.Remove($Name)
        }
    }

    $Unavailable = @($script:Unavailable | Sort-Object -Unique)
    $Document['unavailable'] = $Unavailable

    return [pscustomobject] $Document
}

function Get-CloakSelfTestDocument {
    return [pscustomobject] @{
        schemaVersion = 1
        source        = 'guest-windows'
        selfTest      = $true
        collector     = [ordered] @{
            tool      = 'collect-guest-identity.ps1'
            version   = '1'
            timestamp = '2026-01-01T00:00:00.0000000Z'
        }
        guest         = [ordered] @{
            caption      = 'Microsoft Windows 10 Pro'
            version      = '10.0.19045'
            buildNumber  = '19045'
            architecture = '64-bit'
        }
        smbios        = [ordered] @{
            biosVendor            = 'innotek GmbH'
            biosVersion           = 'VirtualBox'
            biosReleaseDate       = '20061201'
            biosSerial            = '0'
            systemManufacturer    = 'innotek GmbH'
            systemProduct         = 'VirtualBox'
            baseboardManufacturer = 'Oracle Corporation'
            baseboardProduct      = 'VirtualBox'
            baseboardSerial       = '0'
            chassisType           = '1'
        }
        cpuid         = [ordered] @{
            vendor     = 'GenuineIntel'
            brand      = 'Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz'
            identifier = 'Intel64 Family 6 Model 158 Stepping 10'
            featureSet = '2113669627'
        }
        acpi          = [ordered] @{
            tables = @(
                [ordered] @{ table = 'DSDT'; oemId = 'VBOX__'; oemTableId = 'VBOXBIOS'; revision = '00001000' },
                [ordered] @{ table = 'FACP'; oemId = 'VBOX__'; oemTableId = 'VBOXBIOS'; revision = '00000002' }
            )
        }
        pci           = [ordered] @{
            devices = @(
                [ordered] @{ bdf = '00:02.0'; vendorId = '80ee'; deviceId = 'beef'; subsystemVendorId = '80ee'; subsystemDeviceId = 'beef'; revision = '00' },
                [ordered] @{ bdf = '00:03.0'; vendorId = '80ee'; deviceId = 'cafe'; subsystemVendorId = '80ee'; subsystemDeviceId = 'cafe'; revision = '00' }
            )
        }
        storage       = [ordered] @{
            devices = @(
                [ordered] @{ model = 'VBOX HARDDISK'; serial = 'VB00000000000000'; firmware = '1.0'; interface = 'SCSI'; mediaType = 'Fixed hard disk media' }
            )
        }
        nic           = [ordered] @{
            devices = @(
                [ordered] @{ mac = '08:00:27:12:34:56'; vendorId = '8086'; deviceId = '100e'; subsystemVendorId = '8086'; subsystemDeviceId = '001e'; revision = '00'; adapterType = 'Ethernet 802.3' }
            )
        }
        edid          = [ordered] @{
            displays = @(
                [ordered] @{ manufacturerId = 'VBOX'; productCode = '0000'; serial = '0'; friendlyName = 'VBOX monitor'; week = '1'; year = '2026' }
            )
        }
        tpm           = [ordered] @{
            present             = $true
            specVersion         = '2.0'
            manufacturerId      = 'IBM'
            manufacturerVersion = '1.0'
        }
        unavailable   = @()
    }
}

function Write-CloakGuestDocument {
    param($Document, [string] $Path)

    $Resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $Directory = Split-Path -Parent $Resolved
    if ($Directory -and -not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Resolved, ($Document | ConvertTo-Json -Depth 12), [System.Text.UTF8Encoding]::new($false))
    return $Resolved
}

try {
    if ($SelfTest) {
        $Document = Get-CloakSelfTestDocument
    }
    else {
        $Document = Get-CloakGuestDocument
    }
    $Resolved = Write-CloakGuestDocument -Document $Document -Path $OutputPath
    Write-Host "Guest identity written: $Resolved"
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
