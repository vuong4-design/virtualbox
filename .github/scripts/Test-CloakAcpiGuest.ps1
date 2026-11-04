#requires -Version 5.1
<#
.SYNOPSIS
  Verify lab-only ACPI OEM table IDs on an actual Windows guest after a cold boot.
.DESCRIPTION
  Read-only. Tests the tables seen by Windows in HKLM\HARDWARE\ACPI.
  Does not change VirtualBox, guest registry, drivers or credentials.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$base = 'HKLM:\HARDWARE\ACPI'
$expected = @(
    @{ Signature = 'DSDT'; OemId = 'LAB___'; TableId = 'LAB0DSDT' },
    @{ Signature = 'SSDT'; OemId = 'LAB___'; TableId = 'LAB0CPUT' },
    @{ Signature = 'FADT'; OemId = 'LAB___'; TableId = 'LAB0FACP' },
    @{ Signature = 'RSDT'; OemId = 'LAB___'; TableId = 'LAB0XSDT' }
)
$failures = @()
foreach ($item in $expected) {
    $path = Join-Path $base (Join-Path $item.Signature (Join-Path $item.OemId $item.TableId))
    if (Test-Path -LiteralPath $path) {
        Write-Host ("PASS: {0} {1} {2}" -f $item.Signature, $item.OemId, $item.TableId)
    } else {
        Write-Warning ("MISSING: {0} {1} {2}" -f $item.Signature, $item.OemId, $item.TableId)
        $failures += $item.Signature
    }
}

$residual = @()
foreach ($signature in @('DSDT','SSDT')) {
    $sig = Join-Path $base $signature
    if (Test-Path -LiteralPath $sig) {
        $residual += @(Get-ChildItem -LiteralPath $sig -ErrorAction Stop |
            Where-Object { $_.PSChildName -like 'VBOX*' } |
            ForEach-Object { "$signature/$($_.PSChildName)" })
    }
}
if ($residual.Count) {
    Write-Warning ('Other VBOX OEM ACPI tables remain: ' + ($residual -join ', '))
}

$system = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
if ($system.Manufacturer -ne 'LabVendor' -or $system.Model -ne 'LabDesktop-01') {
    $failures += 'SMBIOS system'
}
if ($bios.Manufacturer -ne 'LabFirmware' -or $bios.SMBIOSBIOSVersion -ne 'LAB-1.0') {
    $failures += 'SMBIOS BIOS'
}
$guestDevice = Get-CimInstance Win32_PnPEntity |
    Where-Object { $_.PNPDeviceID -like 'PCI\VEN_80EE&DEV_CAFE*' } |
    Select-Object -First 1
if (-not $guestDevice -or $guestDevice.ConfigManagerErrorCode -ne 0) {
    $failures += 'VBoxGuest PCI device'
}
$service = Get-Service VBoxService -ErrorAction SilentlyContinue
if (-not $service -or $service.Status -ne 'Running') {
    $failures += 'VBoxService'
}

if ($failures.Count -gt 0) {
    throw ('Lab ACPI/Guest Additions verification FAILED: ' + ($failures -join ', '))
}
Write-Host 'PASS: lab DMI, ACPI table IDs and official Guest Additions health'