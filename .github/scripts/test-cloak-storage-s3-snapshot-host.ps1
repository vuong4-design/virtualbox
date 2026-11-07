#requires -Version 5.1
<#
  Hermetic host snapshot lifecycle tests.
  A mock VBoxManage.ps1 changes a temporary JSON state, never a real VM.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('cloak-s3-host-snapshot-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$baselinePath=Join-Path $root 'B3-baseline.json'
$beforePath=Join-Path $root 'B3-before-restore.json'
$evidenceDir=Join-Path $root 'host-evidence'
$statePath=Join-Path $root 'mock-vbox-state.json'
$mock=Join-Path $root 'MockVBoxManage.ps1'
$helper=Join-Path $PSScriptRoot 'Invoke-CloakStorageS3SnapshotHost.ps1'
$env:CLOAK_S3_MOCK_STATE=$statePath
function Assert-S3([bool]$Condition,[string]$What) {
    if(-not $Condition){throw ('FAILED snapshot fixture: '+$What)}
}
function PutMockState($state) {
    [IO.File]::WriteAllText($statePath,($state | ConvertTo-Json),[Text.Encoding]::UTF8)
}
function ReadMockState {
    return (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
}
function ExpectFailure([scriptblock]$Call,[string]$Pattern) {
    $failed=$false
    try { & $Call | Out-Null } catch {
        $failed=($_.Exception.Message -match $Pattern)
    }
    Assert-S3 $failed ('Expected rejection: '+$Pattern)
}
try {
    $baseline=[pscustomobject]@{
        SchemaVersion=1
        Audit='Storage-S3-C5'
        AuditRevision='S3-C5-2026-11-B3'
        BundleIntegrity='SHA256_VERIFIED'
        Overall='PARTIAL'
        Disks=@([pscustomobject]@{
            Index=0;Model='LAB ATA DISK';Firmware='LAB1'
            BusType='SATA';PnpVendorProduct='VEN_LAB_ATA&PROD_DISK'
            SerialSha256=('A'*64);HostDiscard=$false;HostNonRotational=$false
            Raw=[pscustomobject]@{
                Protocol='ATA';Model='LAB ATA DISK';Firmware='LAB1';SerialSha256=('A'*64)
                SmartAvailable=$false;SmartEnabled=$false;TrimSupported=$false
                RotationWord217=0
            }
        })
        OpticalDevices=@([pscustomobject]@{
            Index=0;PnpVendorProduct='VEN_VBOX&PROD_CD-ROM'
            RawInquiry=[pscustomobject]@{Vendor='VBOX';Product='CD-ROM';Revision='1.0'}
        })
    }
    [IO.File]::WriteAllText($baselinePath,($baseline|ConvertTo-Json -Depth 8),[Text.Encoding]::UTF8)
    PutMockState ([pscustomobject]@{VMState='running';SnapshotName='';Restored=$false})
    $mockCode=@'
$ErrorActionPreference='Stop'
$statePath=$env:CLOAK_S3_MOCK_STATE
$state=Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($args[0] -eq 'showvminfo' -and $args[1] -eq 'test' -and $args[2] -eq '--machinereadable') {
    Write-Output ('VMState="'+$state.VMState+'"')
    exit 0
}
if ($args[0] -eq 'snapshot' -and $args[1] -eq 'test') {
    if ($args[2] -eq 'list' -and $args[3] -eq '--machinereadable') {
        if ($state.SnapshotName) {
            Write-Output ('SnapshotName="'+$state.SnapshotName+'"')
            Write-Output 'SnapshotUUID="REDACTED-EXAMPLE-DO-NOT-STORE"'
        }
        exit 0
    }
    if ($args[2] -eq 'take' -and $state.VMState -eq 'poweroff' -and -not $state.SnapshotName) {
        $state.SnapshotName=$args[3]
        [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json),[Text.Encoding]::UTF8)
        exit 0
    }
    if ($args[2] -eq 'restore' -and $state.VMState -eq 'poweroff' -and $state.SnapshotName -eq $args[3]) {
        $state.Restored=$true
        [IO.File]::WriteAllText($statePath,($state|ConvertTo-Json),[Text.Encoding]::UTF8)
        exit 0
    }
}
exit 23
'@
    [IO.File]::WriteAllText($mock,$mockCode,[Text.Encoding]::UTF8)
    $props=@{
        VM='test'
        VBoxManage=$mock
        BaselinePath=$baselinePath
        EvidenceDir=$evidenceDir
        SnapshotName='S3-C5-snapshot-regression'
    }
    & $helper @props -Action Check | Out-Null
    ExpectFailure { & $helper @props -Action Take } 'poweroff'
    Write-Host 'PASS: read-only Check; Take rejects running VM'
    $state=ReadMockState
    $state.VMState='poweroff'
    PutMockState $state
    & $helper @props -Action Take | Out-Null
    $evidence=Join-Path $evidenceDir 'cloak-s3-snapshot-host-state.json'
    $record=Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
    Assert-S3 ($record.Phase -eq 'TAKEN') 'Take produced host-only evidence'
    Assert-S3 ((ReadMockState).SnapshotName -eq 'S3-C5-snapshot-regression') 'Take created expected named snapshot'
    Assert-S3 ((Get-Content -LiteralPath $evidence -Raw) -notmatch '(?i)(PhysicalDrive|SnapshotUUID|secret.vdi)') 'No UUID or device path in evidence'
    ExpectFailure { & $helper @props -Action Take } 'already exists'
    ExpectFailure { & $helper @props -Action Restore -AllowRollback -ConfirmSnapshotName 'S3-C5-snapshot-regression' } 'first complete Action Ready'
    Write-Host 'PASS: powered-off Take, snapshot uniqueness, cannot restore before Ready'
    Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force
    $before=$baseline | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $before | Add-Member -NotePropertyName LifecycleComparison -NotePropertyValue (
        Compare-CloakStorageS3Evidence -Baseline $baseline -Current $before
    )
    [IO.File]::WriteAllText($beforePath,($before|ConvertTo-Json -Depth 12),[Text.Encoding]::UTF8)
    $props.BeforeRestorePath=$beforePath
    $state=ReadMockState; $state.VMState='running'; PutMockState $state
    ExpectFailure { & $helper @props -Action Ready } 'powered off'
    $state=ReadMockState; $state.VMState='poweroff'; PutMockState $state
    & $helper @props -Action Ready | Out-Null
    $record=Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
    Assert-S3 ($record.BeforeRestoreSha256 -match '^[0-9A-F]{64}$') 'Before-restore evidence SHA256 recorded'
    $beforeAltered=Get-Content -LiteralPath $beforePath -Raw
    [IO.File]::AppendAllText($beforePath,[Environment]::NewLine)
    ExpectFailure { & $helper @props -Action Restore -AllowRollback -ConfirmSnapshotName 'S3-C5-snapshot-regression' } 'evidence changed after Ready'
    [IO.File]::WriteAllText($beforePath,$beforeAltered,[Text.Encoding]::UTF8)
    ExpectFailure { & $helper @props -Action Restore } 'supply -AllowRollback'
    ExpectFailure { & $helper @props -Action Restore -AllowRollback -ConfirmSnapshotName 'S3-C5-wrong' } 'supply -AllowRollback'
    Assert-S3 (-not (ReadMockState).Restored) 'No rollback without double confirmation'
    & $helper @props -Action Restore -AllowRollback -ConfirmSnapshotName 'S3-C5-snapshot-regression' | Out-Null
    Assert-S3 ((ReadMockState).Restored) 'Restore executed only after double confirmation'
    & $helper @props -Action CheckRestored | Out-Null
    $record=Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
    Assert-S3 ($record.Phase -eq 'RESTORED') 'Restore persisted host phase'
    Write-Host 'PASS: Ready requires off-VM verified pre-restore B3 report, SHA256 + double acknowledgment'
    $bad=Get-Content -LiteralPath $baselinePath -Raw | ConvertFrom-Json
    $bad.Disks[0].SerialSha256='B'*64
    [IO.File]::WriteAllText($baselinePath,($bad|ConvertTo-Json -Depth 8),[Text.Encoding]::UTF8)
    ExpectFailure { & $helper @props -Action CheckRestored } 'baseline'
    Write-Host 'PASS: changed baseline file rejected; no false snapshot identity PASS'
}
finally {
    Remove-Item Env:CLOAK_S3_MOCK_STATE -ErrorAction SilentlyContinue
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) }
}
Write-Host 'PASS: Storage S3 host snapshot safety regression suite'
