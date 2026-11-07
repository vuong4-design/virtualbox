#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Storage S3 capability audit and C5 cross-surface consistency gate.
.DESCRIPTION
  Run INSIDE a Windows guest. Optional smartctl.exe --info --json is read-only.
  Missing SMART/TRIM/rotation/INQUIRY/VPD evidence is NOT_VERIFIED.
  Never writes guest hardware settings, sends TRIM, enables SMART, or changes
  VirtualBox drivers. Report excludes raw serials, medium UUIDs, full PnP IDs.
  Copy CloakStorageC5.psm1 and CloakStorageWindowsQuery.psm1 beside this script.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = '',
    [switch]$SkipSmartctl,
    [switch]$RequireRaw,
    [string]$SmartctlPath = '',
    [string]$HostCapabilitiesPath = '',
    [switch]$SkipWindowsIoctl,
    [switch]$SkipOpticalInquiry,
    [switch]$NativeAtaIdentify
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageC5.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'CloakStorageWindowsQuery.psm1') -Force

function Get-S3Hash([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value.Trim())
        return [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-','')
    } finally { $hash.Dispose() }
}
function Get-S3Field($Obj,[string]$Key) {
    if ($null -eq $Obj) { return $null }
    $p = $Obj.PSObject.Properties[$Key]
    if ($null -eq $p) { return $null }
    return $p.Value
}
function Get-S3PnpPair([string]$Id) {
    if ($Id -match '(?i)VEN_([^&\\]+)&PROD_([^&\\]+)') {
        return ('VEN_{0}&PROD_{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    return 'NOT_REPORTED'
}
function Get-S3RawInfo($Smart,[int]$Index) {
    if ($null -eq $Smart) { return $null }
    $drive = '\\.\PhysicalDrive' + $Index
    try {
        # Smartctl can return a nonzero exit status for nonfatal SMART warnings:
        # parse valid JSON when available, never echo its raw text.
        $lines = @(& $Smart.Source '--info' '--json' $drive 2>$null)
        if ($lines.Count -eq 0) { return $null }
        $obj = ($lines -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $obj) { return $null }
        $device = Get-S3Field $obj 'device'
        $protocol = [string](Get-S3Field $device 'protocol')
        $model = [string](Get-S3Field $obj 'model_name')
        $scsiVendor = [string](Get-S3Field $obj 'vendor')
        $scsiProduct = [string](Get-S3Field $obj 'product')
        $revision = [string](Get-S3Field $obj 'revision')
        $firmware = [string](Get-S3Field $obj 'firmware_version')
        if (-not $model -and $scsiProduct) {
            # Direct SCSI model normally includes vendor plus product.
            # INQUIRY remains compared to PnP as two separate fields.
            $model = ($scsiVendor + ' ' + $scsiProduct).Trim()
        }
        if (-not $firmware -and $revision) { $firmware = $revision }

        $smart = Get-S3Field $obj 'smart_support'
        $trim = Get-S3Field $obj 'trim'
        $trimSupport = Get-S3Field $trim 'supported'
        $rpm = Get-S3Field $obj 'rotation_rate'
        $rawSerial = [string](Get-S3Field $obj 'serial_number')
        $rawHash = Get-S3Hash $rawSerial
        if (-not $protocol -and -not $model -and -not $scsiVendor) { return $null }
        return [pscustomobject][ordered]@{
            Source = 'smartctl-json-info'
            Protocol = $protocol
            Model = $model.Trim()
            Firmware = $firmware.Trim()
            SerialSha256 = $rawHash
            SmartAvailable = Get-S3Field $smart 'available'
            SmartEnabled = Get-S3Field $smart 'enabled'
            TrimSupported = $trimSupport
            RotationRate = $rpm
            ScsiVendor = $scsiVendor.Trim()
            ScsiProduct = $scsiProduct.Trim()
            ScsiRevision = $revision.Trim()
            Vpd83PresentHint = -not [string]::IsNullOrWhiteSpace([string](Get-S3Field $obj 'logical_unit_id'))
        }
    } catch {
        # Never print smartctl errors, which can contain full device identifiers.
        return $null
    }
}

$wmiDisks = @(Get-CimInstance Win32_DiskDrive | Sort-Object Index)
if ($wmiDisks.Count -eq 0) { throw 'S3: no disk reported by WMI' }

$storageDisks = @()
try { $storageDisks = @(Get-Disk -ErrorAction Stop) } catch { Write-Warning 'Get-Disk unavailable' }
$physicalDisks = @()
try { $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop) } catch { Write-Warning 'Get-PhysicalDisk unavailable' }
$optical = @()
try { $optical = @(Get-CimInstance Win32_CDROMDrive -ErrorAction Stop) } catch { Write-Warning 'Optical WMI inventory unavailable' }

$smartTool = $null
if (-not $SkipSmartctl) {
    if ($SmartctlPath) {
        if (-not (Test-Path -LiteralPath $SmartctlPath -PathType Leaf)) {
            throw 'Specified smartctl path does not exist'
        }
        $smartTool = [pscustomobject]@{Source=[IO.Path]::GetFullPath($SmartctlPath)}
    } else {
        $smartTool = Get-Command 'smartctl.exe' -ErrorAction SilentlyContinue
    }
}
if (-not $smartTool) {
    if ($NativeAtaIdentify) {
        Write-Host 'S3: smartctl unavailable or skipped; trying read-only native ATA IDENTIFY (0xEC)'
    } else {
        Write-Host 'S3: smartctl unavailable or skipped; raw ATA/SCSI identity and capabilities NOT_VERIFIED'
    }
}

$normalizedDisks = @()
foreach ($disk in $wmiDisks) {
    $index = [int]$disk.Index
    $systemDisk = @($storageDisks | Where-Object { [int]$_.Number -eq $index })
    $bus = if ($systemDisk.Count -eq 1) { [string]$systemDisk[0].BusType } else { '' }
    # PhysicalDisk ID is not a reliable Win32_DiskDrive Index. Only associate
    # MediaType if both Windows APIs observe exactly one drive.
    $mediaType = if ($wmiDisks.Count -eq 1 -and $physicalDisks.Count -eq 1) {
        [string]$physicalDisks[0].MediaType
    } else { 'Unspecified' }
    $raw = if ($NativeAtaIdentify) { Get-CloakStorageAtaIdentify -DiskIndex $index } else { $null }
    if (-not $raw -and $smartTool) { $raw = Get-S3RawInfo $smartTool $index }
    $windowsProps = if (-not $SkipWindowsIoctl) { Get-CloakStorageWindowsProperties -DiskIndex $index } else { $null }
    $row = [pscustomobject][ordered]@{
        Index = $index
        Model = ([string]$disk.Model).Trim()
        Firmware = ([string]$disk.FirmwareRevision).Trim()
        SerialSha256 = Get-S3Hash ([string]$disk.SerialNumber)
        PnpVendorProduct = Get-S3PnpPair ([string]$disk.PNPDeviceID)
        BusType = $bus
        WindowsMediaType = $mediaType
        WindowsDiskHealth = if ($systemDisk.Count -eq 1) { [string](Get-S3Field $systemDisk[0] 'HealthStatus') } else { '' }
        PartitionStyle = if ($systemDisk.Count -eq 1) { [string](Get-S3Field $systemDisk[0] 'PartitionStyle') } else { '' }
        WindowsQueryAttempted = (-not $SkipWindowsIoctl)
        WindowsQuery = $windowsProps
        Raw = $raw
    }
    $normalizedDisks += $row
    Write-Host ("S3 Disk {0}: Model={1}; Firmware={2}; Bus={3}; MediaType={4}; Health={5}; PnP={6}; Raw={7}" -f
        $index, $row.Model, $row.Firmware, $bus, $mediaType, $row.WindowsDiskHealth, $row.PnpVendorProduct,
        $(if ($raw) { $raw.Protocol } else { 'UNAVAILABLE' }))
}
$normalizedOptical = @()
for ($i=0; $i -lt $optical.Count; $i++) {
    $cd = $optical[$i]
    $drive = ([string](Get-S3Field $cd 'Drive')).Trim()
    $hasDrive = $drive -match '^[A-Za-z]:$'
    $descriptor = $null
    $inquiry = $null
    if (-not $SkipWindowsIoctl -and $hasDrive) {
        $descriptor = Get-CloakStorageWindowsProperties -OpticalDrive $drive
        if (-not $SkipOpticalInquiry) {
            $inquiry = Get-CloakStorageOpticalInquiry -OpticalDrive $drive
        }
    }
    $normalizedOptical += [pscustomobject][ordered]@{
        Index = $i
        PnpVendorProduct = Get-S3PnpPair ([string](Get-S3Field $cd 'PNPDeviceID'))
        WindowsQuery = $descriptor
        RawInquiry = $inquiry
    }
    Write-Host ("S3 Optical {0}: PnP={1}; OS descriptor={2}; direct INQUIRY={3}" -f
        $i,$normalizedOptical[-1].PnpVendorProduct,
        $(if ($descriptor) { 'AVAILABLE' } else { 'UNAVAILABLE' }),
        $(if ($inquiry) { 'AVAILABLE' } else { 'UNAVAILABLE' }))
}
Write-Host ("S3 Optical devices: {0}; raw INQUIRY requires a valid optical drive letter and pass-through support" -f $normalizedOptical.Count)

if ($HostCapabilitiesPath) {
    if (-not (Test-Path -LiteralPath $HostCapabilitiesPath -PathType Leaf)) {
        throw 'Host capabilities manifest not found'
    }
    $hostManifest = Get-Content -LiteralPath $HostCapabilitiesPath -Raw | ConvertFrom-Json
    if ([int]$hostManifest.SchemaVersion -ne 1 -or
        [string]$hostManifest.Source -ne 'VBoxManage-showvminfo-machine-readable') {
        throw 'Unsupported or untrusted host capability schema'
    }
    $mapped = @{}
    foreach ($binding in @($hostManifest.Bindings)) {
        if ($null -eq $binding.GuestDiskIndex) { continue }  # Unassigned host device.
        $diskIndex = [int]$binding.GuestDiskIndex
        if ($diskIndex -lt 0 -or $mapped.ContainsKey($diskIndex)) {
            throw 'Duplicate/invalid host-to-guest disk mapping'
        }
        if ($binding.NonRotational -isnot [bool] -or $binding.Discard -isnot [bool]) {
            throw 'Invalid host capability types'
        }
        $target = @($normalizedDisks | Where-Object Index -eq $diskIndex)
        if ($target.Count -ne 1) { throw 'Host capability mapping refers to absent guest disk' }
        $mapped[$diskIndex] = $true
        $target[0] | Add-Member -NotePropertyName HostNonRotational -NotePropertyValue $binding.NonRotational
        $target[0] | Add-Member -NotePropertyName HostDiscard -NotePropertyValue $binding.Discard
    }
    Write-Host ("S3 host C5: mapped {0} disk(s); unmatched attachments excluded, not guessed" -f $mapped.Count)
}

$report = Test-CloakStorageC5 -Disks $normalizedDisks -OpticalDevices $normalizedOptical -RequireRaw:$RequireRaw
foreach ($check in $report.Checks) {
    Write-Host ("C5 [{0}] Disk={1} {2}: {3}" -f $check.Status,$check.Disk,$check.Id,$check.Note)
}
Write-Host ("C5 Overall={0}; PASS={1}; FAIL={2}; NOT_VERIFIED={3}" -f
    $report.Overall,$report.Passed,$report.Failed,$report.NotVerified)

if ($OutputPath) {
    # Report contains no raw serial, device path/instance ID, logical_unit_id,
    # seed, unmodified smartctl output or stable medium UUID.
    $sanitized = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Audit = 'Storage-S3-C5'
        Overall = $report.Overall
        Disks = @($normalizedDisks)
        OpticalDevices = @($normalizedOptical)
        Checks = @($report.Checks)
    }
    # Raw fields are already normalized and redacted, including serial SHA256.
    $json = $sanitized | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),$json,[Text.Encoding]::UTF8)
    Write-Host ("S3 redacted report saved: {0}" -f $OutputPath)
}
if ($report.Overall -eq 'FAIL') { throw 'S3 C5 contradictions detected; see check IDs above' }
if ($report.Overall -eq 'INCOMPLETE') { throw 'S3 C5 strict audit incomplete; missing raw evidence' }
if ($report.Overall -eq 'PARTIAL') {
    Write-Host 'S3 PARTIAL: no observed C5 contradiction, but some capabilities remain NOT_VERIFIED'
}
