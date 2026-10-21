<#
.SYNOPSIS
    Quet cac chuoi identity trong binary da build, lam "baseline" de so sanh giua 2 commit.

.DESCRIPTION
    Khong the chay VM (GitHub runner khong co VBoxDrv / nested virtualization),
    nen phan capture runtime duoc bo qua. Phan nay quet truc tiep cac file da
    build xem co chuoi identity nao xuat hien - dung de:
      * xac nhan patch da bien dich vao binary
      * tao baseline de so sanh khi trien khai lop cloak

.PARAMETER VBoxDir
    Thu muc chua binary (out\win.amd64\release\bin).

.PARAMETER OutFile
    File bao cao.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $VBoxDir,
    [string] $OutFile = 'binary-identity.txt'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Cac chuoi can tim: khoa -> mo ta
$needles = [ordered]@{
    'VBOX HARDDISK'          = 'storage model PIIX3 (stock)'
    'VBOX CD-ROM'            = 'storage model optical (stock)'
    'Samsung PRO 970'        = 'storage model PIIX3 (cloak target)'
    'SanDisc Extreme Pro'    = 'storage model AHCI (cloak target)'
    'Seagate'                = 'USB MSD manufacturer (cloak target)'
    'Logitech'               = 'USB webcam vendor (cloak target)'
    'HD Webcam C270'         = 'USB webcam product (cloak target)'
    'VirtualBox Webcam'      = 'USB webcam product (stock)'
    'VBoxVBoxVBox'           = 'CPUID hypervisor vendor (stock)'
    'Microsoft   '           = 'CPUID hypervisor vendor (cloak target)'
    'ACRSYS'                 = 'DSDT OEM ID (cloak target)'
    'ACRPRDCT'               = 'DSDT OEM table ID (cloak target)'
    'VBOXBIOS'               = 'DSDT OEM table ID (stock)'
    'INTELCPU'               = 'MPS OEM ID (cloak target)'
    'VBOXCPU'                = 'MPS OEM ID (stock)'
    'A M I '                 = 'ACPI generated OEM table ID (cloak target)'
    'American Megatrends'    = 'PC BIOS branding (cloak target)'
    'NVIDIA VESA BIOS'       = 'VGA BIOS VBE branding (cloak target)'
    'VirtualBox VESA BIOS'   = 'VGA BIOS VBE branding (stock)'
    'IntelFirmwareInterface' = 'GA driver rename (cloak target)'
    'NetMonitor'             = 'GA service rename (cloak target)'
    'VBoxGuestPropSvc'       = 'GA HGCM service (stock / residue)'
    'innotek'                = 'SMBIOS vendor (stock)'
    'GenuineIntel'           = 'SMBIOS CPU vendor'
    'INTEL'                  = 'TPM/ACPI vendor (cloak target)'
    'IBM'                    = 'TPM manufacturer (stock)'
    'CSME'                   = 'TPM vendor string (cloak target)'
    '10EC'                   = 'VirtIO PCI vendor (cloak target)'
    '1AF4'                   = 'VirtIO PCI vendor (stock)'
    '80EE'                   = 'PCI vendor VirtualBox (stock)'
    '3938'                   = 'USB vendor (cloak target)'
    '046D'                   = 'USB webcam vendor Logitech (cloak target)'
    'CAFEBABE'               = 'placeholder'
}

# Cac file can quet
$files = @(
    'VBoxDD.dll', 'VBoxVMM.dll', 'VBoxC.dll', 'VBoxSVC.exe',
    'VirtualBox.exe', 'VirtualBoxVM.dll', 'VBoxRT.dll'
) | Where-Object { Test-Path (Join-Path $VBoxDir $_) }

if ($files.Count -eq 0) {
    Write-Host "ERROR: no VirtualBox binaries found in $VBoxDir" -ForegroundColor Red
    exit 2
}

function Get-AsciiStrings {
    param([string] $Path, [int] $MinLength = 4)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $sb = New-Object System.Text.StringBuilder
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($b in $bytes) {
        if ($b -ge 0x20 -and $b -le 0x7E) {
            [void]$sb.Append([char]$b)
        }
        else {
            if ($sb.Length -ge $MinLength) { $out.Add($sb.ToString()) }
            [void]$sb.Clear()
        }
    }
    if ($sb.Length -ge $MinLength) { $out.Add($sb.ToString()) }
    return $out
}

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("# Binary identity scan")
$report.Add("# generated: $(Get-Date -Format o)")
$report.Add("# vboxdir  : $VBoxDir")
$report.Add("")

# 1. Tim trong tat ca file
$found = [ordered]@{}
foreach ($k in $needles.Keys) { $found[$k] = [System.Collections.Generic.List[string]]::new() }

foreach ($f in $files) {
    $path = Join-Path $VBoxDir $f
    $strings = Get-AsciiStrings -Path $path
    foreach ($k in $needles.Keys) {
        foreach ($s in $strings) {
            if ($s.Contains($k)) {
                $found[$k].Add("$f")
                break
            }
        }
    }
}

$report.Add("| needle | meaning | found in |")
$report.Add("|---|---|---|")
foreach ($k in $needles.Keys) {
    $where = if ($found[$k].Count -gt 0) { ($found[$k] | Sort-Object -Unique) -join ', ' } else { '-' }
    $report.Add("| ``$k`` | $($needles[$k]) | $where |")
}
$report.Add("")

# 2. Danh sach chuoi identity cu the trong VBoxDD.dll (de doi voi baseline)
$dd = Join-Path $VBoxDir 'VBoxDD.dll'
if (Test-Path $dd) {
    $report.Add("## Interesting strings in VBoxDD.dll")
    $strings = Get-AsciiStrings -Path $dd
    $interesting = $strings | Where-Object {
        $_ -match '(?i)(VBOX|Samsung|SanDisk|Seagate|Logitech|Webcam|HARDDISK|CD-ROM|innotek|ACRSYS|ACRPRDCT|INTELCPU|A M I|Megatrends|NVIDIA VESA)'
    } | Sort-Object -Unique
    foreach ($s in $interesting) { $report.Add("  $s") }
}

$report | Set-Content -Path $OutFile -Encoding utf8
Write-Host "Written $OutFile"
Write-Host ($report | Where-Object { $_ -match '^\| `' } | Select-Object -First 40 | Out-String)
exit 0
