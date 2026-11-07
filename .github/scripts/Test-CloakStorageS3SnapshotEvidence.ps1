#requires -Version 5.1
<#
.SYNOPSIS
  Independently validate powered-off S3 snapshot lifecycle from redacted
  B3 guest reports copied to a HOST directory.
.DESCRIPTION
  Read only. Does not call VBoxManage or mutate guest/host storage.
  Requires baseline, pre-restore and post-restore reports.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BaselinePath,
    [Parameter(Mandatory=$true)][string]$BeforeRestorePath,
    [Parameter(Mandatory=$true)][string]$AfterRestorePath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force
if ((Get-CloakStorageC5Contract).Release -ne 'S3-C5-2026-11-B3') {
    throw 'Host verifier requires S3-C5-2026-11-B3 module'
}
function Read-S3Report([string]$Path,[bool]$RequireLifecycle) {
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'S3 evidence file missing on host' }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -lt 100 -or $item.Length -gt 4194304) { throw 'S3 evidence JSON has unexpected size' }
    $data = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json
    if ([int]$data.SchemaVersion -ne 1 -or $data.Audit -ne 'Storage-S3-C5' -or
        $data.AuditRevision -ne 'S3-C5-2026-11-B3' -or
        $data.BundleIntegrity -ne 'SHA256_VERIFIED' -or
        $data.Overall -eq 'FAIL') {
        throw 'S3 report schema, version, integrity or C5 Overall invalid'
    }
    if ($RequireLifecycle -and
        ($null -eq $data.LifecycleComparison -or
         $data.LifecycleComparison.Overall -ne 'PASS' -or
         [int]$data.LifecycleComparison.Failed -ne 0 -or
         [int]$data.LifecycleComparison.NotVerified -ne 0)) {
        throw 'S3 lifecycle report did not record a fully verified PASS'
    }
    return $data
}
$baseFull=[IO.Path]::GetFullPath($BaselinePath)
$beforeFull=[IO.Path]::GetFullPath($BeforeRestorePath)
$afterFull=[IO.Path]::GetFullPath($AfterRestorePath)
if ($baseFull -ieq $beforeFull -or $baseFull -ieq $afterFull -or $beforeFull -ieq $afterFull) {
    throw 'Baseline, before-restore and after-restore must be three separate host files'
}
$baseline=Read-S3Report $BaselinePath $false
$before=Read-S3Report $BeforeRestorePath $true
$after=Read-S3Report $AfterRestorePath $true
$pre=Compare-CloakStorageS3Evidence -Baseline $baseline -Current $before
$post=Compare-CloakStorageS3Evidence -Baseline $baseline -Current $after
if ($pre.Overall -ne 'PASS' -or $pre.Failed -ne 0 -or $pre.NotVerified -ne 0) {
    throw ('S3 pre-restore host recheck failed: overall='+$pre.Overall+
        ' failed='+$pre.Failed+' notVerified='+$pre.NotVerified)
}
if ($post.Overall -ne 'PASS' -or $post.Failed -ne 0 -or $post.NotVerified -ne 0) {
    throw ('S3 post-restore host recheck failed: overall='+$post.Overall+
        ' failed='+$post.Failed+' notVerified='+$post.NotVerified)
}
Write-Host 'PASS: B3 snapshot restore identity is stable vs baseline BEFORE and AFTER restore'
Write-Host ('Pre-restore: PASS checks='+@($pre.Checks|Where-Object Status -eq 'PASS').Count)
Write-Host ('Post-restore: PASS checks='+@($post.Checks|Where-Object Status -eq 'PASS').Count)
Write-Host 'Note: a C5 Overall=PARTIAL is compatible with lifecycle PASS when ATA rotation/SeekPenalty/VPD were unverified both times.'
