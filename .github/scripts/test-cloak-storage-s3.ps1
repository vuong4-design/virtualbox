#requires -Version 5.1
<#
  Offline Storage S3/C5 regression tests. No VM, no disk writes.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force

function Assert-C5([bool]$Condition,[string]$What) {
    if (-not $Condition) { throw ('FAIL S3/C5: ' + $What) }
}
function Copy-C5($Value) { return ($Value | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
function Has-C5($Report,[string]$Id,[string]$Status) {
    return @($Report.Checks | Where-Object { $_.Id -eq $Id -and $_.Status -eq $Status }).Count -gt 0
}

$rawAta = [pscustomobject]@{
    Protocol = 'ATA';Model = 'LAB ATA DISK';Firmware = 'LAB1';SerialSha256 = 'ABC123'
    SmartAvailable = $true;SmartEnabled = $false;TrimSupported = $false
    RotationRate = 1;RotationWord217 = 1
}
$disk = [pscustomobject]@{
    Index = 0;Model = 'LAB ATA DISK';Firmware = 'LAB1';SerialSha256 = 'ABC123'
    PnpVendorProduct = 'VEN_LAB_ATA&PROD_DISK';BusType = 'SATA';WindowsMediaType = 'SSD'
    Raw = $rawAta
}
$pass = Test-CloakStorageC5 -Disks @($disk) -RequireRaw
Assert-C5 ($pass.Overall -eq 'PASS') 'fully observed ATA fixture'
foreach ($id in @('RAW_MODEL','RAW_FIRMWARE','RAW_SERIAL','SMART','TRIM','ROTATION','TRANSPORT')) {
    Assert-C5 (Has-C5 $pass $id 'PASS') ('ATA gate: ' + $id)
}
Write-Host 'PASS: fully observed ATA path, SMART-disabled supported, TRIM false, nonrotation'
$withHost = Copy-C5 $disk
$withHost | Add-Member -NotePropertyName HostNonRotational -NotePropertyValue $true
$withHost | Add-Member -NotePropertyName HostDiscard -NotePropertyValue $false
$hostPass = Test-CloakStorageC5 -Disks @($withHost) -RequireRaw
Assert-C5 (Has-C5 $hostPass 'HOST_ROTATION' 'PASS') 'host/guest rotation agreement'
Assert-C5 (Has-C5 $hostPass 'HOST_TRIM' 'PASS') 'host/guest TRIM agreement'
$hostTrimMismatch = Copy-C5 $withHost
$hostTrimMismatch.HostDiscard = $true
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($hostTrimMismatch)) 'HOST_TRIM' 'FAIL') 'host TRIM contradiction'
$hostRotationMismatch = Copy-C5 $withHost
$hostRotationMismatch.HostNonRotational = $false
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($hostRotationMismatch)) 'HOST_ROTATION' 'FAIL') 'host rotation contradiction'
$hostMissingRaw = Copy-C5 $withHost
$hostMissingRaw.Raw = $null
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($hostMissingRaw)) 'HOST_TRIM' 'NOT_VERIFIED') 'host TRIM but raw unavailable'
Write-Host 'PASS: explicit host attachment flags cross-checked with raw TRIM/rotation'



$osObserved = Copy-C5 $disk
$osObserved | Add-Member -NotePropertyName WindowsQuery -NotePropertyValue ([pscustomobject]@{
    DeviceType=0;BusTypeCode=11;Vendor='LAB ATA';Product='DISK';Revision='LAB1'
    TrimEnabled=$false;IncursSeekPenalty=$false
})
$osResult=Test-CloakStorageC5 -Disks @($osObserved) -RequireRaw
Assert-C5 (Has-C5 $osResult 'OS_DEVICE_DESC' 'PASS') 'Windows direct access descriptor'
Assert-C5 (Has-C5 $osResult 'ATA_WORD217' 'PASS') 'ATA word 217 has a declared valid nonrotating value'
Assert-C5 (Has-C5 $osResult 'OS_PNP_IDENTITY' 'NOT_APPLICABLE') 'ATA PnP names are not literal descriptor fields'
Assert-C5 (Has-C5 $osResult 'OS_ATA_IDENTITY' 'PASS') 'ATA OS descriptor model/firmware align with ATA raw and WMI'
Assert-C5 (Has-C5 $osResult 'OS_TRIM' 'PASS') 'Windows trim property observed'
Assert-C5 (Has-C5 $osResult 'OS_SEEK' 'PASS') 'Windows seek penalty observed'
Assert-C5 (Has-C5 $osResult 'OS_RAW_TRIM' 'PASS') 'Windows/raw TRIM agree'
Assert-C5 (Has-C5 $osResult 'OS_RAW_ROTATION' 'PASS') 'Windows/raw rotation agree'
$osBadVendor = Copy-C5 $osObserved
$osBadVendor.WindowsQuery.Vendor = 'OTHER'
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($osBadVendor)) 'OS_ATA_IDENTITY' 'FAIL') 'ATA descriptor model mismatch'
$osBlankVendor = Copy-C5 $osObserved
$osBlankVendor.WindowsQuery.Vendor = ''
$osBlankVendor.WindowsQuery.Product = 'LAB ATA DISK'
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($osBlankVendor)) 'OS_ATA_IDENTITY' 'PASS') 'empty Vendor with full ATA product model is valid'
$osBadFirmware = Copy-C5 $osBlankVendor
$osBadFirmware.WindowsQuery.Revision = 'WRONG'
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($osBadFirmware)) 'OS_ATA_IDENTITY' 'FAIL') 'ATA descriptor firmware mismatch'
$osBadTrim = Copy-C5 $osObserved
$osBadTrim.WindowsQuery.TrimEnabled=$true
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($osBadTrim)) 'OS_RAW_TRIM' 'FAIL') 'OS TRIM contradicts raw'
$osBadSeek = Copy-C5 $osObserved
$osBadSeek.WindowsQuery.IncursSeekPenalty=$true
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($osBadSeek)) 'OS_RAW_ROTATION' 'FAIL') 'OS seek contradicts raw'
Write-Host 'PASS: ATA descriptor identity with blank Vendor, firmware mismatch, TRIM/Seek consistency'

$unreported = Copy-C5 $disk
$unreported.Raw.RotationWord217 = 0
$unreported.Raw.RotationRate = $null
$unreported.WindowsMediaType = 'Unspecified'
$rotationReport = Test-CloakStorageC5 -Disks @($unreported)
Assert-C5 (Has-C5 $rotationReport 'ATA_WORD217' 'NOT_VERIFIED') 'ATA word 217 zero must remain unverified'
Assert-C5 (Has-C5 $rotationReport 'ROTATION' 'NOT_VERIFIED') 'No fabricated RPM from ATA word zero'
Write-Host 'PASS: word 217=0 and unknown MediaType do not imply HDD/SSD'

$missing = Copy-C5 $disk
$missing.Raw = $null
$partial = Test-CloakStorageC5 -Disks @($missing)
$strictMissing = Test-CloakStorageC5 -Disks @($missing) -RequireRaw
Assert-C5 ($partial.Overall -eq 'PARTIAL') 'missing smartctl must not yield PASS'
Assert-C5 ($strictMissing.Overall -eq 'INCOMPLETE') 'RequireRaw rejects unavailable evidence'
Assert-C5 (Has-C5 $partial 'TRIM' 'NOT_VERIFIED') 'missing TRIM evidence'
Write-Host 'PASS: unavailable raw evidence => PARTIAL/INCOMPLETE'

foreach ($scenario in @(
    @{Name='model';Field='Model';Where='Raw';Value='WRONG';Expected='RAW_MODEL'},
    @{Name='firmware';Field='Firmware';Where='Raw';Value='WRONG';Expected='RAW_FIRMWARE'},
    @{Name='serial';Field='SerialSha256';Where='Raw';Value='DIFFERENT';Expected='RAW_SERIAL'},
    @{Name='smart';Field='SmartAvailable';Where='Raw';Value=$false;Expected='SMART'},
    @{Name='rotation';Field='WindowsMediaType';Where='Disk';Value='HDD';Expected='ROTATION'},
    @{Name='transport';Field='Protocol';Where='Raw';Value='NVMe';Expected='TRANSPORT'},
    @{Name='pnp';Field='PnpVendorProduct';Where='Disk';Value='VEN_VBOX&PROD_HARDDISK';Expected='PROFILE_LAB'}
)) {
    $case = Copy-C5 $disk
    if ($scenario.Where -eq 'Raw') { $case.Raw.($scenario.Field) = $scenario.Value }
    else { $case.($scenario.Field) = $scenario.Value }
    if ($scenario.Name -eq 'smart') { $case.Raw.SmartEnabled = $true }
    $result = Test-CloakStorageC5 -Disks @($case)
    Assert-C5 ($result.Overall -eq 'FAIL') $scenario.Name
    Assert-C5 (Has-C5 $result $scenario.Expected 'FAIL') ($scenario.Name + ' check ID')
}
Write-Host 'PASS: model/firmware/serial/SMART/rotation/transport/PnP contradictions fail C5'

$scsi = [pscustomobject]@{
    Index=1;Model='VBOX HARDDISK';Firmware='1.0';SerialSha256='SCSIHASH'
    PnpVendorProduct='VEN_VBOX&PROD_HARDDISK';BusType='SCSI';WindowsMediaType='Unspecified'
    Raw=[pscustomobject]@{
        Protocol='SCSI';Model='VBOX HARDDISK';Firmware='1.0';SerialSha256='SCSIHASH'
        SmartAvailable=$null;SmartEnabled=$null;TrimSupported=$null;RotationRate=$null
        ScsiVendor='VBOX';ScsiProduct='HARDDISK';ScsiRevision='1.0'
    }
}
$scsiResult = Test-CloakStorageC5 -Disks @($scsi)
Assert-C5 (Has-C5 $scsiResult 'SCSI_INQUIRY' 'PASS') 'SCSI INQUIRY identity'
Assert-C5 (Has-C5 $scsiResult 'SCSI_VPD83' 'NOT_VERIFIED') 'VPD83 not assumed proven'
Assert-C5 ($scsiResult.Overall -eq 'PARTIAL') 'SCSI fixture incomplete'
$scsiWithVpd = Copy-C5 $scsi
$scsiWithVpd.Raw | Add-Member -NotePropertyName Vpd83 -NotePropertyValue ([pscustomobject]@{
    Source='SCSI_PASS_THROUGH_INQUIRY_EVPD83';DeviceType=0;IdentifierCount=1;HasDesignators=$true
}) -Force
$scsiVpdResult = Test-CloakStorageC5 -Disks @($scsiWithVpd)
Assert-C5 (Has-C5 $scsiVpdResult 'SCSI_VPD83' 'PASS') 'SCSI VPD83 positive designator fixture'
$scsiMismatch = Copy-C5 $scsi
$scsiMismatch.Raw.ScsiProduct = 'OTHER'
$scsiBad = Test-CloakStorageC5 -Disks @($scsiMismatch)
Assert-C5 (Has-C5 $scsiBad 'SCSI_INQUIRY' 'FAIL') 'SCSI INQUIRY mismatch'
$withOptical = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @([pscustomobject]@{Name='CD-ROM'})
Assert-C5 (Has-C5 $withOptical 'ATAPI_OPTICAL' 'NOT_VERIFIED') 'optical not silently pass'
Write-Host 'PASS: SCSI INQUIRY, VPD83 absent/positive-designator fixtures, optical coverage gap'

$opticalFixture = [pscustomobject]@{
    Index=0; PnpVendorProduct='VEN_VBOX&PROD_CD-ROM'
    WindowsQuery=[pscustomobject]@{
        DeviceType=5;Vendor='VBOX';Product='CD-ROM';Revision='1.0'
    }
    RawInquiry=[pscustomobject]@{
        DeviceType=5;Vendor='VBOX';Product='CD-ROM';Revision='1.0'
        Source='SCSI_PASS_THROUGH_INQUIRY_0x12'
    }
    RawVpd83=[pscustomobject]@{Source='SCSI_PASS_THROUGH_INQUIRY_EVPD83';DeviceType=5;IdentifierCount=1;HasDesignators=$true}
}
$opticalOkay = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($opticalFixture)
Assert-C5 (Has-C5 $opticalOkay 'OPTICAL_OS_DESCRIPTOR' 'PASS') 'optical Windows descriptor matches PnP'
Assert-C5 (Has-C5 $opticalOkay 'ATAPI_OPTICAL' 'PASS') 'optical raw INQUIRY matches descriptor'
Assert-C5 (Has-C5 $opticalOkay 'OPTICAL_VPD83' 'PASS') 'optical VPD 0x83 parsed with designator count'
Assert-C5 ($opticalOkay.Overall -eq 'PASS') 'full observed optical fixture'
$opticalWrong = Copy-C5 $opticalFixture
$opticalWrong.RawInquiry.Product = 'OTHER DVD'
$opticalBad = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($opticalWrong)
Assert-C5 (Has-C5 $opticalBad 'ATAPI_OPTICAL' 'FAIL') 'optical raw mismatch rejected'
$opticalWrongOs = Copy-C5 $opticalFixture
$opticalWrongOs.WindowsQuery.DeviceType = 0
$opticalBadType = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($opticalWrongOs)
Assert-C5 (Has-C5 $opticalBadType 'OPTICAL_OS_DESCRIPTOR' 'FAIL') 'optical OS descriptor type rejected'
$opticalMissing = Copy-C5 $opticalFixture
$opticalMissing.RawInquiry = $null
$opticalMissing.RawVpd83 = $null
$opticalNotVerified = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($opticalMissing)
Assert-C5 (Has-C5 $opticalNotVerified 'ATAPI_OPTICAL' 'NOT_VERIFIED') 'missing raw INQUIRY never PASS'
Assert-C5 (Has-C5 $opticalOkay 'OPTICAL_LAB_SCOPE' 'NOT_APPLICABLE') 'Unmodified VBOX optical remains out of lab profile'

$optLab = Copy-C5 $opticalFixture
$optLab.PnpVendorProduct = 'VEN_LAB&PROD_CD-ROM'
$optLab.WindowsQuery.Vendor = 'LAB'
$optLab.WindowsQuery.Revision = 'LAB1'
$optLab.RawInquiry.Vendor = 'LAB'
$optLab.RawInquiry.Revision = 'LAB1'
$optLabOkay = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($optLab)
Assert-C5 (Has-C5 $optLabOkay 'OPTICAL_LAB_SCOPE' 'PASS') 'opt-in synthetic LAB optical identity matches all three independent layers'
Assert-C5 (Has-C5 $optLabOkay 'ATAPI_OPTICAL' 'PASS') 'opt-in LAB optical direct INQUIRY matches Windows descriptor and PnP'
Assert-C5 (Has-C5 $optLabOkay 'OPTICAL_OS_DESCRIPTOR' 'PASS') 'LAB optical OS descriptor type and identity valid'
$optLabBad = Copy-C5 $optLab
$optLabBad.RawInquiry.Revision = 'BAD'
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($optLabBad)) 'OPTICAL_LAB_SCOPE' 'FAIL') 'LAB optical firmware/revision drift must FAIL'
$optLabBad = Copy-C5 $optLab
$optLabBad.PnpVendorProduct = 'VEN_LAB&PROD_OTHER'
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($optLabBad)) 'OPTICAL_LAB_SCOPE' 'FAIL') 'LAB optical wrong PnP product rejected'
$optLabMissing = Copy-C5 $optLab
$optLabMissing.RawInquiry = $null
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($optLabMissing)) 'OPTICAL_LAB_SCOPE' 'NOT_VERIFIED') 'LAB optical cannot PASS without direct INQUIRY'
Write-Host 'PASS: opt-in LAB optical PnP/OS/INQUIRY parity and mismatch/absence negative cases'
Write-Host 'PASS: optical OS descriptor, direct INQUIRY, mismatch and fallback'

$many = Test-CloakStorageC5 -Disks @($disk,$scsi)
Assert-C5 ($many.Overall -eq 'PARTIAL') 'multi-disk aggregation'
Assert-C5 ($many.Failed -eq 0) 'no false failures for mixed backends'
Write-Host 'PASS: multi-disk aggregate and no raw-capability inference'
Write-Host 'PASS: Storage S3 capability audit + C5 offline regression suite'
