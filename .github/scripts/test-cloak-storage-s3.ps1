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
    RotationRate = 1
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
Assert-C5 (Has-C5 $osResult 'OS_TRIM' 'PASS') 'Windows trim property observed'
Assert-C5 (Has-C5 $osResult 'OS_SEEK' 'PASS') 'Windows seek penalty observed'
Assert-C5 (Has-C5 $osResult 'OS_RAW_TRIM' 'PASS') 'Windows/raw TRIM agree'
Assert-C5 (Has-C5 $osResult 'OS_RAW_ROTATION' 'PASS') 'Windows/raw rotation agree'
$osBadTrim = Copy-C5 $osObserved
$osBadTrim.WindowsQuery.TrimEnabled=$true
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($osBadTrim)) 'OS_RAW_TRIM' 'FAIL') 'OS TRIM contradicts raw'
$osBadSeek = Copy-C5 $osObserved
$osBadSeek.WindowsQuery.IncursSeekPenalty=$true
Assert-C5 (Has-C5 (Test-CloakStorageC5 -Disks @($osBadSeek)) 'OS_RAW_ROTATION' 'FAIL') 'OS seek contradicts raw'
Write-Host 'PASS: Windows descriptor/Trim/Seek vs raw ATA positive and negative C5'

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
$scsiMismatch = Copy-C5 $scsi
$scsiMismatch.Raw.ScsiProduct = 'OTHER'
$scsiBad = Test-CloakStorageC5 -Disks @($scsiMismatch)
Assert-C5 (Has-C5 $scsiBad 'SCSI_INQUIRY' 'FAIL') 'SCSI INQUIRY mismatch'
$withOptical = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @([pscustomobject]@{Name='CD-ROM'})
Assert-C5 (Has-C5 $withOptical 'ATAPI_OPTICAL' 'NOT_VERIFIED') 'optical not silently pass'
Write-Host 'PASS: SCSI INQUIRY, VPD83 coverage gap, optical coverage gap'

$opticalFixture = [pscustomobject]@{
    Index=0; PnpVendorProduct='VEN_VBOX&PROD_CD-ROM'
    WindowsQuery=[pscustomobject]@{
        DeviceType=5;Vendor='VBOX';Product='CD-ROM';Revision='1.0'
    }
    RawInquiry=[pscustomobject]@{
        DeviceType=5;Vendor='VBOX';Product='CD-ROM';Revision='1.0'
        Source='SCSI_PASS_THROUGH_INQUIRY_0x12'
    }
}
$opticalOkay = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($opticalFixture)
Assert-C5 (Has-C5 $opticalOkay 'OPTICAL_OS_DESCRIPTOR' 'PASS') 'optical Windows descriptor matches PnP'
Assert-C5 (Has-C5 $opticalOkay 'ATAPI_OPTICAL' 'PASS') 'optical raw INQUIRY matches descriptor'
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
$opticalNotVerified = Test-CloakStorageC5 -Disks @($disk) -OpticalDevices @($opticalMissing)
Assert-C5 (Has-C5 $opticalNotVerified 'ATAPI_OPTICAL' 'NOT_VERIFIED') 'missing raw INQUIRY never PASS'
Write-Host 'PASS: optical OS descriptor, direct INQUIRY, mismatch and fallback'

$many = Test-CloakStorageC5 -Disks @($disk,$scsi)
Assert-C5 ($many.Overall -eq 'PARTIAL') 'multi-disk aggregation'
Assert-C5 ($many.Failed -eq 0) 'no false failures for mixed backends'
Write-Host 'PASS: multi-disk aggregate and no raw-capability inference'
Write-Host 'PASS: Storage S3 capability audit + C5 offline regression suite'
