#requires -Version 5.1
<#
  Pure S3 lifecycle regression: compare redacted reports across cold boots
  and powered-off snapshot lifecycles without touching a real VM.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force
function Assert-Lifecycle([bool]$ok,[string]$name) {
    if (-not $ok) { throw ('S3 B3 lifecycle test failed: '+$name) }
}
function Clone-S3($x) { return ($x | ConvertTo-Json -Depth 10 | ConvertFrom-Json) }
$baseline = [pscustomobject]@{
    SchemaVersion=1;Audit='Storage-S3-C5'
    Disks=@([pscustomobject]@{
        Index=0;Model='LAB ATA DISK';Firmware='LAB1'
        SerialSha256='REDACTED_FIXTURE_HASH'
        PnpVendorProduct='VEN_LAB_ATA&PROD_DISK';BusType='SATA'
        HostDiscard=$false;HostNonRotational=$false
        Raw=[pscustomobject]@{
            Protocol='ATA';Model='LAB ATA DISK';Firmware='LAB1'
            SerialSha256='REDACTED_FIXTURE_HASH'
            SmartAvailable=$false;SmartEnabled=$false;TrimSupported=$false
            RotationWord217=0
        }
    })
    OpticalDevices=@([pscustomobject]@{
        Index=0;PnpVendorProduct='VEN_VBOX&PROD_CD-ROM'
        RawInquiry=[pscustomobject]@{Vendor='VBOX';Product='CD-ROM';Revision='1.0'}
    })
}
$current = Clone-S3 $baseline
$ok = Compare-CloakStorageS3Evidence -Baseline $baseline -Current $current
Assert-Lifecycle ($ok.Overall -eq 'PASS' -and $ok.Failed -eq 0) 'stable snapshot identity'
Write-Host 'PASS: stable ATA/optical identity and host flags across lifecycle'
# Script release can change between baseline and comparison; S3 lifecycle
# compares fields instead of requiring byte-for-byte collector versions.
$oldVersion = Clone-S3 $baseline
$oldVersion | Add-Member -NotePropertyName AuditRevision -NotePropertyValue 'S3-C5-2026-11-B2'
$newVersion = Clone-S3 $current
$newVersion | Add-Member -NotePropertyName AuditRevision -NotePropertyValue 'S3-C5-2026-11-B3'
$crossVersion = Compare-CloakStorageS3Evidence -Baseline $oldVersion -Current $newVersion
Assert-Lifecycle ($crossVersion.Overall -eq 'PASS' -and $crossVersion.Failed -eq 0) 'compatible baseline from earlier B2 release'
Write-Host 'PASS: compatible B2-to-B3 lifecycle report comparison'

foreach ($case in @(
    @{Name='serial';Change={param($x) $x.Disks[0].SerialSha256='DIFFERENT'};Id='LIFECYCLE_SERIALSHA256'},
    @{Name='raw serial';Change={param($x) $x.Disks[0].Raw.SerialSha256='DIFFERENT'};Id='LIFECYCLE_RAW_SERIALSHA256'},
    @{Name='firmware';Change={param($x) $x.Disks[0].Firmware='LAB2'};Id='LIFECYCLE_FIRMWARE'},
    @{Name='TRIM';Change={param($x) $x.Disks[0].Raw.TrimSupported=$true};Id='LIFECYCLE_RAW_TRIMSUPPORTED'},
    @{Name='rotation';Change={param($x) $x.Disks[0].Raw.RotationWord217=1};Id='LIFECYCLE_RAW_ROTATIONWORD217'},
    @{Name='host flag';Change={param($x) $x.Disks[0].HostDiscard=$true};Id='LIFECYCLE_HOSTDISCARD'},
    @{Name='optical';Change={param($x) $x.OpticalDevices[0].RawInquiry.Product='OTHER'};Id='LIFECYCLE_OPTICAL_PRODUCT'}
)) {
    $changed = Clone-S3 $baseline
    & $case.Change $changed
    $r = Compare-CloakStorageS3Evidence -Baseline $baseline -Current $changed
    Assert-Lifecycle ($r.Overall -eq 'FAIL') ('drift not flagged: '+$case.Name)
    Assert-Lifecycle (@($r.Checks | Where-Object { $_.Id -eq $case.Id -and $_.Status -eq 'FAIL' }).Count -eq 1) $case.Id
}
Write-Host 'PASS: serial/firmware/TRIM/rotation/host/optical drift negative fixtures'

$missing = Clone-S3 $baseline
$missing.Disks[0].Raw=$null
$partial = Compare-CloakStorageS3Evidence -Baseline $baseline -Current $missing
Assert-Lifecycle ($partial.Overall -eq 'PARTIAL' -and $partial.Failed -eq 0) 'missing raw remains PARTIAL'
$optGone = Clone-S3 $baseline
$optGone.OpticalDevices=@()
$r = Compare-CloakStorageS3Evidence -Baseline $baseline -Current $optGone
Assert-Lifecycle ($r.Overall -eq 'FAIL') 'optical attachment count drift'
Write-Host 'PASS: unavailable raw is PARTIAL, missing optical attachment is FAIL'

$bad=Clone-S3 $baseline
$bad.SchemaVersion=999
$caught=$false
try { Compare-CloakStorageS3Evidence -Baseline $bad -Current $baseline | Out-Null } catch {
    $caught=$_.Exception.Message -like '*schema invalid*'
}
Assert-Lifecycle $caught 'invalid baseline schema rejected'
Write-Host 'PASS: schema rejection and pure lifecycle regression suite'
