#requires -Version 5.1
<#
  Regression fixture shaped after the user-provided Windows guest S3 JSON.
  Values are synthetic/redacted. No VM or physical device access.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force
if ((Get-CloakStorageC5Contract).Release -ne 'S3-C5-2026-11-B4') {
    throw 'Incorrect S3 C5 module release for evidence regression'
}
$disks = @(
    [pscustomobject]@{
        Index=0;Model='LAB ATA DISK';Firmware='LAB1'
        SerialSha256='SYNTHETIC_HASH_NOT_A_REAL_SERIAL'
        PnpVendorProduct='VEN_LAB_ATA&PROD_DISK'
        BusType='SATA';WindowsMediaType='Unspecified'
        WindowsDiskHealth='Healthy';PartitionStyle='MBR'
        WindowsQueryAttempted=$true
        WindowsQuery=[pscustomobject]@{
            Source='Windows-IOCTL_STORAGE_QUERY_PROPERTY'
            DeviceType=0;BusTypeCode=11
            Vendor='';Product='LAB ATA DISK';Revision='LAB1'
            TrimEnabled=$false;IncursSeekPenalty=$null
            QueryStatus=[pscustomobject]@{
                DeviceDescriptor='AVAILABLE';Trim='AVAILABLE';SeekPenalty='DRIVER_OR_STORAGE_ERROR'
            }
            QueryDiagnostics=[pscustomobject]@{
                SeekPenalty=[pscustomobject]@{
                    Status='DRIVER_OR_STORAGE_ERROR';Win32Error=31;FailureStage='DEVICE_IO_CONTROL'
                    MetadataWin32Error=31;ReadOnlyWin32Error=31
                }
            }
        }
        HostNonRotational=$false;HostDiscard=$false
        Raw=[pscustomobject]@{
            Source='Windows-IOCTL_ATA_PASS_THROUGH_IDENTIFY_0xEC'
            Protocol='ATA';Model='LAB ATA DISK';Firmware='LAB1'
            SerialSha256='SYNTHETIC_HASH_NOT_A_REAL_SERIAL'
            SmartAvailable=$false;SmartEnabled=$false;TrimSupported=$false
            RotationRate=$null;RotationWord217=0
        }
    }
)
$optical = @(
    [pscustomobject]@{
        Index=0;PnpVendorProduct='VEN_VBOX&PROD_CD-ROM'
        WindowsQuery=[pscustomobject]@{
            DeviceType=5;BusTypeCode=11;Vendor='VBOX'
            Product='CD-ROM';Revision='1.0'
            TrimEnabled=$null;IncursSeekPenalty=$null
        }
        RawVpd83=$null
        RawInquiry=[pscustomobject]@{
            Source='SCSI_PASS_THROUGH_INQUIRY_0x12'
            DeviceType=5;Vendor='VBOX';Product='CD-ROM';Revision='1.0'
        }
    }
)
$result = Test-CloakStorageC5 -Disks $disks -OpticalDevices $optical
if ($result.Overall -ne 'PARTIAL' -or $result.Failed -ne 0) {
    throw ('Evidence fixture should remain partial with zero contradictions; actual='+$result.Overall)
}
$expected = @{
    IDENTITY_WMI='PASS';PROFILE_LAB='PASS'
    RAW_MODEL='PASS';RAW_FIRMWARE='PASS';RAW_SERIAL='PASS'
    SMART='PASS';TRIM='PASS';HOST_TRIM='PASS';TRANSPORT='PASS'
    ROTATION='NOT_VERIFIED';ATA_WORD217='NOT_VERIFIED';HOST_ROTATION='NOT_VERIFIED'
    OS_DEVICE_DESC='PASS';OS_ATA_IDENTITY='PASS';OS_PNP_IDENTITY='NOT_APPLICABLE'
    OS_TRIM='PASS';OS_SEEK='NOT_VERIFIED';OS_RAW_TRIM='PASS'
    OPTICAL_OS_DESCRIPTOR='PASS';OPTICAL_LAB_SCOPE='NOT_APPLICABLE';ATAPI_OPTICAL='PASS'
    OPTICAL_VPD83='NOT_VERIFIED'
}
foreach ($key in $expected.Keys) {
    $hits = @($result.Checks | Where-Object {
        $_.Id -eq $key -and $_.Status -eq $expected[$key]
    })
    if ($hits.Count -ne 1) { throw ('Evidence C5 regression: '+$key+' expected '+$expected[$key]) }
}
$opticalCheck = @($result.Checks | Where-Object Id -eq 'ATAPI_OPTICAL')[0]
$seekCheck = @($result.Checks | Where-Object Id -eq 'OS_SEEK')[0]
if ($seekCheck.Status -ne 'NOT_VERIFIED' -or $seekCheck.Note -notmatch 'ERROR_GEN_FAILURE.*31') {
    throw 'Win32 31 must be reported as an error, not unsupported or proven HDD/SSD'
}
if ($opticalCheck.Note -match 'not collected') {
    throw 'Obsolete optical checker incorrectly says INQUIRY was not collected'
}
Write-Host 'PASS: observed guest ATA identity and optical INQUIRY are recognized'
Write-Host 'PASS: B2 observed empty ATA vendor, model/firmware/raw parity; Win32 31 remains NOT_VERIFIED'
Write-Host 'PASS: overall PARTIAL with zero contradictions; no obsolete optical C5 result'
