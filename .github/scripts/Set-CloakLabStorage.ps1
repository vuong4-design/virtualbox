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
    [ValidateSet('Status','Enable','Disable')]
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

$key = 'VBoxInternal/Cloak/StorageLabEnabled'
if ($Action -ne 'Status') {
    if ($state -ne 'poweroff') { throw "Shut down VM completely before modifying Storage Identity (current: $state)" }
    if ($Action -eq 'Enable') {
        $enabled = Get-ExtraData 'VBoxInternal/Cloak/Enabled'
        $profile = Get-ExtraData 'VBoxInternal/Cloak/Profile'
        if ($enabled -notin @('integer:1','1') -or $profile -notin @('lab-dmi-v1','string:lab-dmi-v1')) {
            throw 'Storage Lab requires existing enabled lab-dmi-v1 profile; refusing to modify any other profile'
        }
    }
    if ($PSCmdlet.ShouldProcess($VM, "$Action lab storage identity")) {
        $value = if ($Action -eq 'Enable') { 'integer:1' } else { 'integer:0' }
        & $VBoxManage setextradata $VM $key $value
        if ($LASTEXITCODE -ne 0) { throw 'setextradata failed' }
    }
}

Write-Host "VM: $VM (power state: $state)"
$current = Get-ExtraData $key
Write-Host ("StorageLabEnabled: " + $(if ($current) { $current } else { '<not set> (OFF)' }))
Write-Host 'Changes take effect on cold boot only. No seeds or disk serials were printed.'
