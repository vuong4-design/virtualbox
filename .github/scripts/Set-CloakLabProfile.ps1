#requires -Version 5.1
<#
.SYNOPSIS
  Inspect, enable, or disable the compiled lab-only Cloak DMI/ACPI profile.
.DESCRIPTION
  Runs on the HOST with the VBoxManage.exe from the custom VirtualBox build.
  Only works with a VM fully powered off for changes; it does not start a VM.
  Does not modify PCI identities, guest drivers, storage, graphics or CPU.
.EXAMPLE
  .\Set-CloakLabProfile.ps1 -Action Status -VM test -VBoxManage 'C:\path\to\custom\VBoxManage.exe'
.EXAMPLE
  .\Set-CloakLabProfile.ps1 -Action Enable -VM test -VBoxManage 'C:\path\to\custom\VBoxManage.exe'
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
if (-not $tool) { throw "Custom VirtualBox VBoxManage.exe not found: $VBoxManage" }

function Get-VBoxValue([string]$key) {
    $result = @(& $VBoxManage getextradata $VM $key 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage getextradata failed for key '$key'" }
    $matched = @($result | Where-Object { $_ -match '^Value:\s*(.*)$' })
    if ($matched.Count -gt 0) {
        return ([regex]::Match([string]$matched[0], '^Value:\s*(.*)$')).Groups[1].Value
    }
    return ''
}

$info = @(& $VBoxManage showvminfo $VM --machinereadable 2>&1)
if ($LASTEXITCODE -ne 0) { throw "Cannot read VM '$VM' from custom VBoxManage.exe" }
$stateLine = @($info | Where-Object { $_ -match '^VMState="([^"]+)"$' })
if ($stateLine.Count -ne 1) { throw "Cannot read power state for '$VM'" }
$state = [regex]::Match([string]$stateLine[0], '^VMState="([^"]+)"$').Groups[1].Value

$enabledKey = 'VBoxInternal/Cloak/Enabled'
$profileKey = 'VBoxInternal/Cloak/Profile'
$changed = $false

if ($Action -ne 'Status') {
    if ($state -ne 'poweroff') { throw "VM '$VM' must be fully powered off (not saved); current state: $state" }
    if ($PSCmdlet.ShouldProcess($VM, "$Action lab-only DMI/ACPI profile")) {
        if ($Action -eq 'Enable') {
            $provision = Join-Path $PSScriptRoot 'provision-cloak.ps1'
            if (-not (Test-Path -LiteralPath $provision -PathType Leaf)) {
                throw "Missing seed provisioner: $provision"
            }
            # Do not print, export, or change an existing seed.
            $existingSeed = Get-VBoxValue 'VBoxInternal/Cloak/Seed'
            if ($existingSeed) {
                & $provision -VM $VM -VBoxManage $VBoxManage -Verify
            } else {
                & $provision -VM $VM -VBoxManage $VBoxManage
            }

            & $VBoxManage setextradata $VM $profileKey 'string:lab-dmi-v1'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to write lab profile' }
            & $VBoxManage setextradata $VM $enabledKey 'integer:1'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to enable lab profile' }
            $changed = $true
        } else {
            & $VBoxManage setextradata $VM $enabledKey 'integer:0'
            if ($LASTEXITCODE -ne 0) { throw 'Failed to disable lab profile' }
            $changed = $true
        }
    }
}

$enabledValue = Get-VBoxValue $enabledKey
$profileValue = Get-VBoxValue $profileKey
Write-Host "VM: $VM (state=$state)"
Write-Host "Cloak Enabled: $(if ($enabledValue) { $enabledValue } else { '<not set>' })"
Write-Host "Cloak Profile: $(if ($profileValue) { $profileValue } else { '<not set>' })"
Write-Host 'No seed or serial number is printed.'
if ($Action -eq 'Enable' -and $changed) {
    Write-Host 'Cold-boot the VM, then inspect VBox.log for the lab-profile activation message.'
}
