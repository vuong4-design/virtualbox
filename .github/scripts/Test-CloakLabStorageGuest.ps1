#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Windows guest check for lab storage identity after a full cold boot.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$disks = @(Get-CimInstance Win32_DiskDrive)
if ($disks.Count -eq 0) { throw 'No guest disk was reported by WMI' }

$labDisks = @($disks | Where-Object { $_.Model -eq 'LAB ATA DISK' })
foreach ($disk in $disks) {
    $isLab = ($disk.Model -eq 'LAB ATA DISK' -and $disk.FirmwareRevision -eq 'LAB1')
    $status = if ($isLab) { 'LAB PASS' } else { 'UNMODIFIED / MISMATCH' }
    Write-Host ("Disk index={0}: model={1}; firmware={2}; {3}" -f $disk.Index, $disk.Model, $disk.FirmwareRevision, $status)
}
# Intentionally do not print raw drive serials, medium UUIDs or CloakSeed.
if ($labDisks.Count -eq 0) { throw 'No lab ATA/AHCI disk found: check StorageLabEnabled and host VBoxC.dll' }
foreach ($disk in $labDisks) {
    if ($disk.FirmwareRevision -ne 'LAB1') { throw ("Lab disk firmware mismatch at index " + $disk.Index) }
}
$guestDevice = Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.PNPDeviceID -like 'PCI\VEN_80EE&DEV_CAFE*' } |
    Select-Object -First 1
if (-not $guestDevice -or $guestDevice.ConfigManagerErrorCode -ne 0) {
    throw 'VBoxGuest PCI binding is missing or malfunctioning'
}
$service = Get-Service VBoxService -ErrorAction SilentlyContinue
if (-not $service -or $service.Status -ne 'Running') { throw 'VBoxService is not running' }
Write-Host 'PASS: lab storage model/firmware visible; Oracle Guest Additions compatible'
Write-Host 'NOT COVERED: ATA identify raw capabilities, SMART, TRIM, optical/SCSI/USB and boot-to-boot serial stability'
