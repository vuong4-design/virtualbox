#requires -Version 5.1
<#
.SYNOPSIS
  Read-only Storage S2 identity/capability audit from inside a Windows guest.
.DESCRIPTION
  -Mode Record writes a redacted identity fingerprint to -Path.
  -Mode Compare checks a previous fingerprint across cold boots/snapshots.
  -Mode Audit only prints sanitized disk/capability summaries.
  No hardware settings, drivers, serials, full PnP IDs or seeds are changed
  or written. smartctl is used only when already installed and available.
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit','Record','Compare')]
    [string]$Mode = 'Audit',
    [string]$Path = '',
    [switch]$SkipSmartctl
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Mode -ne 'Audit' -and -not $Path) {
    throw '-Path is required for Record or Compare'
}

function Get-Sha256([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $raw = [Text.Encoding]::UTF8.GetBytes($Value.Trim())
        return [BitConverter]::ToString($hash.ComputeHash($raw)).Replace('-', '')
    } finally { $hash.Dispose() }
}

function Get-PnpVendorProduct([string]$Id) {
    # Return only the vendor/product pair, never the instance-specific suffix.
    if ($Id -match '(?i)VEN_([^&\\]+)&PROD_([^&\\]+)') {
        return ('VEN_{0}&PROD_{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    return 'NOT_REPORTED'
}

$disks = @(Get-CimInstance Win32_DiskDrive | Sort-Object Index)
if ($disks.Count -eq 0) { throw 'No Win32_DiskDrive entries' }

$rows = @()
foreach ($disk in $disks) {
    $index = [int]$disk.Index
    $model = ([string]$disk.Model).Trim()
    $fw = ([string]$disk.FirmwareRevision).Trim()
    $serialHash = Get-Sha256 ([string]$disk.SerialNumber)
    $pnp = Get-PnpVendorProduct ([string]$disk.PNPDeviceID)
    $row = [pscustomobject][ordered]@{
        Index = $index
        Model = $model
        Firmware = $fw
        SerialSha256 = $serialHash
        PnpVendorProduct = $pnp
    }
    $rows += $row
    Write-Host ("Disk {0}: Model={1}; Firmware={2}; PnP={3}; SerialHash={4}" -f
        $index, $model, $fw, $pnp,
        $(if ($serialHash) { $serialHash.Substring(0, 12) + '...' } else { 'UNAVAILABLE' }))

    if ($model -eq 'LAB ATA DISK') {
        if ($fw -ne 'LAB1') { throw "LAB disk ${index}: unexpected firmware" }
        if (-not $serialHash) { throw "LAB disk ${index}: serial unavailable" }
        if ($pnp -ne 'VEN_LAB_ATA&PROD_DISK') {
            Write-Warning "LAB disk ${index}: Windows PnP vendor/product differs from observed lab reference"
        }
    }
}

# Optional Windows storage information. Get-Disk BusType is informative only;
# it must not be treated as proof of ATA or SCSI wire protocol.
if (Get-Command Get-Disk -ErrorAction SilentlyContinue) {
    try {
        foreach ($sd in @(Get-Disk)) {
            Write-Host ("Storage API: disk={0}; BusType={1}; PartitionStyle={2}; HealthStatus={3}" -f
                $sd.Number, $sd.BusType, $sd.PartitionStyle, $sd.HealthStatus)
        }
    } catch {
        Write-Warning 'Get-Disk capability metadata not accessible'
    }
}
if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
    try {
        foreach ($pd in @(Get-PhysicalDisk)) {
            Write-Host ("PhysicalDisk API: MediaType={0}; BusType={1}; HealthStatus={2}" -f
                $pd.MediaType, $pd.BusType, $pd.HealthStatus)
        }
    } catch {
        Write-Warning 'Get-PhysicalDisk metadata not accessible'
    }
}

if (-not $SkipSmartctl) {
    $smart = Get-Command 'smartctl.exe' -ErrorAction SilentlyContinue
    if ($smart) {
        foreach ($disk in $disks) {
            $index = [int]$disk.Index
            $drive = "\\.\PhysicalDrive$index"
            try {
                $lines = @(& $smart.Source '--json' '--info' $drive 2>$null)
                $obj = ($lines -join [Environment]::NewLine) | ConvertFrom-Json -ErrorAction Stop
                if ($obj -and $obj.PSObject.Properties['model_name']) {
                    $rawModel = ([string]$obj.model_name).Trim()
                    Write-Host ("smartctl ATA/SCSI inquiry: disk={0}; Model={1}" -f $index, $rawModel)
                    if ($rawModel -ne ([string]$disk.Model).Trim()) {
                        Write-Warning "smartctl and WMI model differ on disk $index"
                    }
                } else {
                    Write-Host "smartctl: disk=$index raw identity not exposed by this controller"
                }
                if ($obj -and $obj.PSObject.Properties['smart_support']) {
                    Write-Host ("smartctl SMART: disk={0}; available={1}; enabled={2}" -f
                        $index, $obj.smart_support.available, $obj.smart_support.enabled)
                }
                if ($obj -and $obj.PSObject.Properties['rotation_rate']) {
                    Write-Host ("smartctl RotationRate: disk={0}; rate={1}" -f $index, $obj.rotation_rate)
                }
            } catch {
                Write-Host "smartctl: disk=$index unsupported/unavailable (not a test failure)"
            }
        }
    } else {
        Write-Host 'smartctl not installed; raw ATA IDENTIFY/SMART/TRIM not verified'
    }
}

if ($Mode -eq 'Record') {
    $snapshot = [pscustomobject][ordered]@{
        SchemaVersion = 1
        GuestTest = 'Cloak-Storage-S2'
        Disks = @($rows)
    }
    $json = $snapshot | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), $json, [Text.Encoding]::UTF8)
    Write-Host "Recorded redacted baseline: $Path"
}
elseif ($Mode -eq 'Compare') {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing baseline: $Path"
    }
    $baseline = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$baseline.SchemaVersion -ne 1) { throw 'Unsupported baseline version' }
    $previous = @($baseline.Disks)
    if ($previous.Count -ne $rows.Count) { throw 'Disk count changed since baseline' }
    foreach ($row in $rows) {
        $matches = @($previous | Where-Object { [int]$_.Index -eq $row.Index })
        if ($matches.Count -ne 1) { throw "Disk index $($row.Index): baseline ambiguity" }
        $b = $matches[0]
        foreach ($property in @('Model','Firmware','SerialSha256','PnpVendorProduct')) {
            if ([string]$row.$property -cne [string]$b.$property) {
                throw "S2 identity drift on disk $($row.Index): $property"
            }
        }
    }
    Write-Host 'PASS: Storage S2 identity unchanged relative to baseline'
}
Write-Host 'OBSERVATIONAL ONLY: raw ATA IDENTIFY, TRIM, SMART support may remain unavailable; no capability bits were changed.'
