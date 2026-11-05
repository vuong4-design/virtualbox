#requires -Version 5.1
<#
.SYNOPSIS
  Offline, hermetic regression test for the read-only Windows Storage S2 auditor.
  Uses fabricated disk objects; never queries a real VM or its host disks.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$guestScript = Join-Path $PSScriptRoot 'Test-CloakStorageS2Guest.ps1'
$global:cloakAuditFixtureDrift = $false

function global:Get-CimInstance {
    param([string]$ClassName)
    if ($ClassName -ne 'Win32_DiskDrive') { throw "Unexpected CIM query: $ClassName" }
    $serial0 = if ($global:cloakAuditFixtureDrift) { 'LAB-SERIAL-MODIFIED' } else { 'LAB-SERIAL-BASE' }
    return @(
        [pscustomobject]@{
            Index = 0; Model = 'LAB ATA DISK'; FirmwareRevision = 'LAB1'
            SerialNumber = $serial0
            PNPDeviceID = 'SCSI\DISK&VEN_LAB_ATA&PROD_DISK\4&hidden'
        },
        [pscustomobject]@{
            Index = 1; Model = 'LAB ATA DISK'; FirmwareRevision = 'LAB1'
            SerialNumber = 'LAB-SERIAL-SECOND'
            PNPDeviceID = 'SCSI\DISK&VEN_LAB_ATA&PROD_DISK\4&other'
        }
    )
}
function global:Get-Disk { return @() }
function global:Get-PhysicalDisk { return @() }

$baseline = [IO.Path]::GetTempFileName()
try {
    & $guestScript -Mode Record -Path $baseline -SkipSmartctl
    $report = [IO.File]::ReadAllText($baseline)
    if (   $report.Contains('LAB-SERIAL-BASE') -or
           $report.Contains('LAB-SERIAL-SECOND') -or
           $report.Contains('4&hidden') -or
           $report.Contains('4&other')) {
        throw 'S2 audit contains unredacted per-device values'
    }

    & $guestScript -Mode Compare -Path $baseline -SkipSmartctl
    $global:cloakAuditFixtureDrift = $true
    $detected = $false
    try {
        & $guestScript -Mode Compare -Path $baseline -SkipSmartctl
    } catch {
        if ($_.Exception.Message -like '*identity drift*SerialSha256*') { $detected = $true }
        else { throw }
    }
    if (-not $detected) { throw 'S2 audit failed to reject serial drift' }
    Write-Host 'PASS: Storage S2 redaction, two-drive baseline, repeat compare and drift detection'
}
finally {
    $global:cloakAuditFixtureDrift = $false
    [IO.File]::Delete($baseline)
}
