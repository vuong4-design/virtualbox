#requires -Version 5.1
<#
.SYNOPSIS
  Opt-in storage identity lab on a fully powered-off VirtualBox VM.
.DESCRIPTION
  Host-side only. Preserves the official Guest Additions and PCI device IDs.
  Does not read/log CloakSeed or disk serials.
#>
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [ValidateSet('Status','Enable','Disable','EnableRootSerial','DisableRootSerial','EnableOptical','DisableOptical','EnableScsi','DisableScsi')]
    [string]$Action = 'Status',
    [ValidateNotNullOrEmpty()]
    [string]$VM = 'test',
    [ValidateNotNullOrEmpty()]
    [string]$VBoxManage = 'VBoxManage'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tool = Get-Command $VBoxManage -ErrorAction SilentlyContinue
if (-not $tool) { throw "VBoxManage not found: $VBoxManage" }

function Get-ExtraData([string]$Key) {
    $result = @(& $VBoxManage getextradata $VM $Key 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "getextradata failed for $Key" }
    $row = @($result | Where-Object { $_ -match '^Value:\s*(.*)$' })
    if ($row.Count -gt 0) { return [regex]::Match([string]$row[0], '^Value:\s*(.*)$').Groups[1].Value }
    return ''
}

$info = @(& $VBoxManage showvminfo $VM --machinereadable 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Cannot access VM $VM" }
$stateLine = @($info | Where-Object { $_ -match '^VMState="([^"]+)"$' })
if ($stateLine.Count -ne 1) { throw 'Unable to determine VM power state' }
$state = [regex]::Match([string]$stateLine[0], '^VMState="([^"]+)"$').Groups[1].Value

$key = if ($Action -in @('EnableRootSerial','DisableRootSerial')) {
    'VBoxInternal/Cloak/StorageLabRootSerialEnabled'
} elseif ($Action -in @('EnableOptical','DisableOptical')) {
    'VBoxInternal/Cloak/StorageLabOpticalEnabled'
} elseif ($Action -in @('EnableScsi','DisableScsi')) {
    'VBoxInternal/Cloak/StorageLabScsiEnabled'
} else { 'VBoxInternal/Cloak/StorageLabEnabled' }
if ($Action -ne 'Status') {
    if ($state -ne 'poweroff') { throw "Shut down VM completely before modifying Storage Identity (current: $state)" }
    if ($Action -in @('Enable','EnableRootSerial','EnableOptical','EnableScsi')) {
        $enabled = Get-ExtraData 'VBoxInternal/Cloak/Enabled'
        $profile = Get-ExtraData 'VBoxInternal/Cloak/Profile'
        if ($enabled -notin @('integer:1','1') -or $profile -notin @('lab-dmi-v1','string:lab-dmi-v1')) {
            throw 'Storage Lab requires existing enabled lab-dmi-v1 profile; refusing to modify any other profile'
        }
    }
    if ($Action -eq 'EnableRootSerial') {
        $storageEnabled = Get-ExtraData 'VBoxInternal/Cloak/StorageLabEnabled'
        if ($storageEnabled -notin @('integer:1','1')) {
            throw 'Enable Storage Lab first; root-medium serial mode requires StorageLabEnabled=1'
        }
    }
    if ($PSCmdlet.ShouldProcess($VM, "$Action lab storage identity")) {
        $value = if ($Action -in @('Enable','EnableRootSerial','EnableOptical','EnableScsi')) { 'integer:1' } else { 'integer:0' }
        & $VBoxManage setextradata $VM $key $value
        if ($LASTEXITCODE -ne 0) { throw 'setextradata failed' }
        if ($Action -eq 'Disable') {
            # A future Enable must not silently reactivate a previous S2 mode.
            & $VBoxManage setextradata $VM 'VBoxInternal/Cloak/StorageLabRootSerialEnabled' 'integer:0'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to disable root-medium serial mode' }
            # Global storage-disable must clear the separate optical opt-in.
            & $VBoxManage setextradata $VM 'VBoxInternal/Cloak/StorageLabOpticalEnabled' 'integer:0'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to disable lab optical identity' }
            & $VBoxManage setextradata $VM 'VBoxInternal/Cloak/StorageLabScsiEnabled' 'integer:0'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to disable lab SCSI identity' }
        }
    }
}

Write-Host "VM: $VM (power state: $state)"
$current = Get-ExtraData 'VBoxInternal/Cloak/StorageLabEnabled'
$root = Get-ExtraData 'VBoxInternal/Cloak/StorageLabRootSerialEnabled'
$optical = Get-ExtraData 'VBoxInternal/Cloak/StorageLabOpticalEnabled'
$scsi = Get-ExtraData 'VBoxInternal/Cloak/StorageLabScsiEnabled'
Write-Host ("StorageLabEnabled: " + $(if ($current) { $current } else { '<not set> (OFF)' }))
Write-Host ("StorageLabRootSerialEnabled: " + $(if ($root) { $root } else { '<not set> (OFF)' }))
Write-Host ("StorageLabOpticalEnabled: " + $(if ($optical) { $optical } else { '<not set> (OFF)' }))
Write-Host ("StorageLabScsiEnabled: " + $(if ($scsi) { $scsi } else { '<not set> (OFF)' }))
Write-Host 'SCSI lab covers Standard INQUIRY on virtual SCSI/SAS/VirtioSCSI/USB MSD; SBC HDD also gets synthetic VPD 0x80/0x83 identity. MMC/DVD VPD remains unchanged.'
Write-Host 'Optical lab requires a virtual IDE/AHCI DVD; host-drive and passthrough optical are rejected at startup.'
Write-Host 'Changes take effect on cold boot only. No seeds or disk serials were printed.'
