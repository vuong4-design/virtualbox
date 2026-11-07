#requires -Version 5.1
<#
  Offline triple-report verifier fixture. Creates synthetic B3 identity
  reports; never invokes VBoxManage or touches a real VM.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force
$root=Join-Path ([IO.Path]::GetTempPath()) ('s3-snapshot-evidence-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$baselinePath=Join-Path $root 'baseline.json'
$beforePath=Join-Path $root 'before.json'
$afterPath=Join-Path $root 'after.json'
$script=Join-Path $PSScriptRoot 'Test-CloakStorageS3SnapshotEvidence.ps1'
function Copy-S3($x){return ($x|ConvertTo-Json -Depth 12|ConvertFrom-Json)}
function Write-S3([string]$path,$x) {
    [IO.File]::WriteAllText($path,($x|ConvertTo-Json -Depth 12),[Text.Encoding]::UTF8)
}
function ExpectReject([scriptblock]$call,[string]$match) {
    $caught=$false
    try{ & $call | Out-Null }catch{$caught=$_.Exception.Message -match $match}
    if(-not $caught){throw ('Expected snapshot evidence rejection: '+$match)}
}
try {
    $base=[pscustomobject]@{
        SchemaVersion=1;Audit='Storage-S3-C5';AuditRevision='S3-C5-2026-11-B3'
        BundleIntegrity='SHA256_VERIFIED';Overall='PARTIAL'
        LifecycleComparison=$null
        Disks=@([pscustomobject]@{
            Index=0;Model='LAB ATA DISK';Firmware='LAB1';SerialSha256=('A'*64)
            PnpVendorProduct='VEN_LAB_ATA&PROD_DISK';BusType='SATA'
            HostDiscard=$false;HostNonRotational=$false
            Raw=[pscustomobject]@{
                Model='LAB ATA DISK';Firmware='LAB1';SerialSha256=('A'*64)
                SmartAvailable=$false;SmartEnabled=$false;TrimSupported=$false
                RotationWord217=0
            }
        })
        OpticalDevices=@([pscustomobject]@{
            Index=0;PnpVendorProduct='VEN_VBOX&PROD_CD-ROM'
            RawInquiry=[pscustomobject]@{Vendor='VBOX';Product='CD-ROM';Revision='1.0'}
        })
    }
    Write-S3 $baselinePath $base
    $before=Copy-S3 $base
    $before.LifecycleComparison=Compare-CloakStorageS3Evidence -Baseline $base -Current $before
    $after=Copy-S3 $base
    $after.LifecycleComparison=Compare-CloakStorageS3Evidence -Baseline $base -Current $after
    Write-S3 $beforePath $before
    Write-S3 $afterPath $after
    & $script -BaselinePath $baselinePath -BeforeRestorePath $beforePath -AfterRestorePath $afterPath | Out-Null
    if(-not $?){throw 'Positive triple report verification failed'}
    Write-Host 'PASS: matching redacted B3 baseline/pre/post reports independently validated'

    $changed=Copy-S3 $after
    $changed.Disks[0].SerialSha256=('B'*64)
    # Simulate forged/stale PASS from guest; host must recompare actual fields.
    Write-S3 $afterPath $changed
    ExpectReject { & $script -BaselinePath $baselinePath -BeforeRestorePath $beforePath -AfterRestorePath $afterPath } 'post-restore host recheck failed'
    Write-Host 'PASS: serial drift rejected even if guest claims Lifecycle PASS'

    $changed=Copy-S3 $after
    $changed.Disks[0].Raw=$null
    Write-S3 $afterPath $changed
    ExpectReject { & $script -BaselinePath $baselinePath -BeforeRestorePath $beforePath -AfterRestorePath $afterPath } 'post-restore host recheck failed'
    Write-Host 'PASS: missing raw observation never accepted as full snapshot PASS'

    $changed=Copy-S3 $after
    $changed.LifecycleComparison=$null
    Write-S3 $afterPath $changed
    ExpectReject { & $script -BaselinePath $baselinePath -BeforeRestorePath $beforePath -AfterRestorePath $afterPath } 'fully verified PASS'
    Write-Host 'PASS: missing guest lifecycle proof rejected'

    $changed=Copy-S3 $after
    $changed.AuditRevision='S3-C5-2026-11-B2'
    Write-S3 $afterPath $changed
    ExpectReject { & $script -BaselinePath $baselinePath -BeforeRestorePath $beforePath -AfterRestorePath $afterPath } 'version'
    Write-Host 'PASS: wrong audit release rejected'
}
finally {
    if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
}
Write-Host 'PASS: Storage S3 snapshot host evidence suite'
