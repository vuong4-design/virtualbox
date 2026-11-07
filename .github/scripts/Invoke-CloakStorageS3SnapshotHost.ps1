#requires -Version 5.1
<#
.SYNOPSIS
  Safely stage a powered-off VirtualBox S3/C5 snapshot restore test.
.DESCRIPTION
  Host only. Does not interact with guest files, shutdown/start the VM,
  run a build, modify storage flags, or perform a restore without an
  explicit, double-acknowledged Restore action. Evidence stays on host.
  B3 guest -CompareTo is still required for the final identity result.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Check','Take','Ready','Restore','CheckRestored')]
    [string]$Action,
    [ValidateNotNullOrEmpty()][string]$VM='test',
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$VBoxManage,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$BaselinePath,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$EvidenceDir,
    [string]$BeforeRestorePath = '',
    [ValidatePattern('^S3-C5-[A-Za-z0-9_-]+$')]
    [string]$SnapshotName='S3-C5-identity-restore',
    [switch]$AllowRollback,
    [string]$ConfirmSnapshotName = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-S3VBox([string[]]$Arguments) {
    # The caller supplies a full path to its intended fork VBoxManage.
    # Ignore stdout on mutating operations to avoid leaking paths/UUIDs.
    $response = @(& $VBoxManage @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw ('VBoxManage operation failed: ' + [string]$Arguments[0] +
            $(if ($Arguments.Count -gt 1) { '/' + [string]$Arguments[2] } else { '' }))
    }
    return $response
}

function Get-S3VMState {
    $info = @(Invoke-S3VBox -Arguments @('showvminfo',$VM,'--machinereadable'))
    $matchLines = @($info | Where-Object { $_ -match '^VMState="[^"]+"$' })
    if ($matchLines.Count -ne 1) { throw 'Could not verify unique VMState in VBoxManage machinereadable output' }
    if ($matchLines[0] -notmatch '^VMState="(?<state>[^"]+)"$') { throw 'Invalid VMState' }
    return [string]$Matches['state']
}
function Get-S3SnapshotCount {
    $lines = @(Invoke-S3VBox -Arguments @('snapshot',$VM,'list','--machinereadable'))
    $count=0
    foreach ($line in $lines) {
        if ($line -match '^SnapshotName(?:-\d+)?="(?<name>[^"]*)"$' -and
            $Matches['name'] -ceq $SnapshotName) { $count++ }
    }
    return $count
}
function Confirm-S3Baseline([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Host baseline JSON does not exist. Copy the guest B3 baseline outside the VM first.'
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -lt 100 -or $item.Length -gt 4194304) { throw 'Unexpected baseline JSON size' }
    $baseline = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$baseline.SchemaVersion -ne 1 -or $baseline.Audit -ne 'Storage-S3-C5' -or
        $baseline.AuditRevision -ne 'S3-C5-2026-11-B3' -or
        $baseline.BundleIntegrity -ne 'SHA256_VERIFIED' -or
        $baseline.Overall -eq 'FAIL') {
        throw 'Baseline must be a valid SHA256-verified Storage-S3-C5 B3 audit without C5 FAIL'
    }
    $disks = @($baseline.Disks | Where-Object { $_.Index -eq 0 })
    if ($disks.Count -ne 1 -or
        $disks[0].Raw.Protocol -ne 'ATA' -or
        $disks[0].Model -ne 'LAB ATA DISK' -or
        $disks[0].Firmware -ne 'LAB1' -or
        [string]$disks[0].SerialSha256 -notmatch '^[0-9A-Fa-f]{64}$' -or
        $disks[0].SerialSha256 -cne $disks[0].Raw.SerialSha256 -or
        $null -eq $disks[0].HostDiscard -or $null -eq $disks[0].HostNonRotational) {
        throw 'Baseline disk 0 is missing mapped ATA LAB identity / host flags'
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Confirm-S3BeforeRestore([string]$Path,[string]$Baseline) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Ready/Restore requires -BeforeRestorePath: copied B3 pre-restore audit JSON stored on host'
    }
    if ([IO.Path]::GetFullPath($Path) -ieq [IO.Path]::GetFullPath($Baseline)) {
        throw 'Pre-restore evidence must be a separate file from baseline'
    }
    $file=Get-Item -LiteralPath $Path
    if ($file.Length -lt 100 -or $file.Length -gt 4194304) {
        throw 'Invalid pre-restore report size'
    }
    $base=Get-Content -LiteralPath $Baseline -Raw | ConvertFrom-Json
    $before=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$before.SchemaVersion -ne 1 -or $before.Audit -ne 'Storage-S3-C5' -or
        $before.AuditRevision -ne 'S3-C5-2026-11-B3' -or
        $before.BundleIntegrity -ne 'SHA256_VERIFIED' -or
        $before.Overall -eq 'FAIL' -or
        $null -eq $before.LifecycleComparison -or
        $before.LifecycleComparison.Overall -ne 'PASS' -or
        [int]$before.LifecycleComparison.Failed -ne 0 -or
        [int]$before.LifecycleComparison.NotVerified -ne 0) {
        throw 'Pre-restore B3 guest audit must have a verified lifecycle PASS with zero unverified fields'
    }
    Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force
    if ((Get-CloakStorageC5Contract).Release -ne 'S3-C5-2026-11-B3') {
        throw 'Host snapshot verifier requires matching B3 C5 module'
    }
    $compared=Compare-CloakStorageS3Evidence -Baseline $base -Current $before
    if ($compared.Overall -ne 'PASS' -or $compared.Failed -gt 0 -or $compared.NotVerified -gt 0) {
        throw 'Pre-restore host independent identity recheck is not PASS'
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
function Read-S3State([string]$StatePath,[string]$Hash) {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw 'Missing host snapshot evidence. Use Action Take with this EvidenceDir before continuing.'
    }
    $record = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ([int]$record.SchemaVersion -ne 1 -or $record.Audit -ne 'Storage-S3-Snapshot-Host' -or
        $record.VM -cne $VM -or $record.SnapshotName -cne $SnapshotName -or
        $record.BaselineSha256 -cne $Hash -or
        $record.Phase -notin @('TAKEN','READY','RESTORED')) {
        throw 'Host evidence does not match VM/snapshot/current baseline. Refusing to continue.'
    }
    return $record
}
function Save-S3State([string]$StatePath,[string]$Hash,[string]$Phase,[string]$PreHash='') {
    $record = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Audit = 'Storage-S3-Snapshot-Host'
        VM = $VM
        SnapshotName = $SnapshotName
        BaselineSha256 = $Hash
        BeforeRestoreSha256 = $PreHash
        Phase = $Phase
        RecordedAtUtc = [DateTime]::UtcNow.ToString('o')
        Notes = 'Host-only state. Final acceptance requires separate guest S3 -CompareTo.'
    }
    [IO.File]::WriteAllText($StatePath,($record | ConvertTo-Json -Depth 4),[Text.Encoding]::UTF8)
}

if (-not [IO.Path]::IsPathRooted($VBoxManage) -or
    -not (Test-Path -LiteralPath $VBoxManage -PathType Leaf)) {
    throw 'Supply an existing FULL host path to the intended VBoxManage.exe (not an ambient PATH alias)'
}
if (-not (Get-Command $VBoxManage -ErrorAction SilentlyContinue)) {
    throw 'The selected VBoxManage executable cannot be invoked'
}
$baselineFull = [IO.Path]::GetFullPath($BaselinePath)
$evidenceFull = [IO.Path]::GetFullPath($EvidenceDir)
if ($evidenceFull -eq [IO.Path]::GetPathRoot($evidenceFull)) {
    throw 'Do not write S3 evidence at a drive root'
}
if (-not (Test-Path -LiteralPath $evidenceFull -PathType Container)) {
    [IO.Directory]::CreateDirectory($evidenceFull) | Out-Null
}
$hash = Confirm-S3Baseline $baselineFull
$statePath = Join-Path $evidenceFull 'cloak-s3-snapshot-host-state.json'
$vmState = Get-S3VMState
$count = Get-S3SnapshotCount

Write-Host ('S3 host preflight: VM={0}; VMState={1}; target snapshot matches={2}; baseline SHA256={3}' -f
    $VM,$vmState,$count,$hash)
if ($count -gt 1) { throw 'Snapshot name is ambiguous; provide an exact unique S3-C5 snapshot name' }

switch ($Action) {
    'Check' {
        Write-Host 'PASS: read-only VM/snapshot/baseline preflight; no snapshot or VM changes'
        break
    }
    'Take' {
        if ($vmState -cne 'poweroff') { throw 'Snapshot Take requires full guest shutdown (VMState=poweroff)' }
        if ($count -ne 0) { throw 'Target snapshot name already exists; no overwrite attempted' }
        if (Test-Path -LiteralPath $statePath) { throw 'Evidence already exists; choose a fresh EvidenceDir for a new snapshot test' }
        Invoke-S3VBox -Arguments @('snapshot',$VM,'take',$SnapshotName,'--description=S3/C5 powered-off identity lifecycle audit') | Out-Null
        if ((Get-S3SnapshotCount) -ne 1) { throw 'Snapshot take did not produce a unique named snapshot' }
        Save-S3State $statePath $hash 'TAKEN'
        Write-Host 'PASS: powered-off snapshot created; host evidence recorded. Start VM manually and collect pre-restore guest audit.'
        break
    }
    'Ready' {
        $old = Read-S3State $statePath $hash
        if ($old.Phase -ne 'TAKEN') { throw 'Ready requires previous Take phase' }
        if ($vmState -cne 'poweroff' -or $count -ne 1) {
            throw 'Before restore VM must be fully powered off and target snapshot must exist uniquely'
        }
        $preHash = Confirm-S3BeforeRestore $BeforeRestorePath $baselineFull
        Save-S3State $statePath $hash 'READY' $preHash
        Write-Host 'PASS: snapshot restore preflight READY; current guest changes WILL BE LOST if you restore.'
        break
    }
    'Restore' {
        $old = Read-S3State $statePath $hash
        if ($old.Phase -ne 'READY') { throw 'Restore refused: first complete Action Ready after guest shutdown' }
        if ($vmState -cne 'poweroff' -or $count -ne 1) { throw 'Restore requires poweroff and one matching snapshot' }
        $preHash = Confirm-S3BeforeRestore $BeforeRestorePath $baselineFull
        if ($old.BeforeRestoreSha256 -cne $preHash) { throw 'Pre-restore evidence changed after Ready; refusing rollback' }
        if (-not $AllowRollback -or $ConfirmSnapshotName -cne $SnapshotName) {
            throw 'Restore refused: supply -AllowRollback and -ConfirmSnapshotName equal to the target snapshot name'
        }
        Invoke-S3VBox -Arguments @('snapshot',$VM,'restore',$SnapshotName) | Out-Null
        if ((Get-S3VMState) -cne 'poweroff') {
            throw 'Snapshot restored, but VM state is not poweroff; inspect VBoxManage before starting guest'
        }
        Save-S3State $statePath $hash 'RESTORED' $preHash
        Write-Host 'PASS: snapshot restore completed to powered-off state. Start VM manually; run guest B3 -CompareTo after boot.'
        break
    }
    'CheckRestored' {
        $old = Read-S3State $statePath $hash
        if ($old.Phase -ne 'RESTORED') { throw 'CheckRestored requires a completed Restore action' }
        if ($count -ne 1) { throw 'Expected restored snapshot missing or ambiguous' }
        if ($vmState -notin @('poweroff','running')) { throw 'Unexpected VM state after restore' }
        Write-Host 'PASS: host snapshot state RESTORED verified. This is NOT a guest identity PASS: inspect LifecycleComparison after guest -CompareTo.'
        break
    }
}
