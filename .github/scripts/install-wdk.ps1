<#
.SYNOPSIS
    Cài Windows SDK + Windows Driver Kit (WDK) vào runner GitHub Actions.

.DESCRIPTION
    VirtualBox cần các thư viện kernel-mode (KM) cho Guest Additions:

        <Kits>\Include\<ver>\km\*.h        header KM
        <Kits>\Lib\<ver>\km\x64\*.lib      lib KM cho amd64
        <Kits>\Lib\<ver>\km\x86\*.lib      lib KM cho x86
        <Kits>\Lib\win7\km\x64\*.lib       lib nhắm Windows 7  (WINSDK10-KM-W7)
        <Kits>\Lib\win8\km\x64\*.lib       lib nhắm Windows 8  (WINSDK10-KM-W8)

    Về version:
      - WDK >= 10.0.22621 KHÔNG còn lib win7/win8.
      - WDK >= 10.0.22000 KHÔNG còn lib KM x86.
      - -> WDK 10.0.19041 là bản DUY NHẤT còn cả hai -> ghim version này.

    Về feature id của WDK (đã trích từ Burn manifest của wdksetup.exe):
      OptionId.WindowsDriverKitComplete   -> WDK chính (headers+libs 10.0.19041.0)
      OptionId.WdkDownlevelContent        -> 3 package Win7/Win8/Win8.1 WDK headers+libs
                                             (KHÔNG nằm trong feature "Complete"!)

    Tham khảo:
      - https://learn.microsoft.com/en-us/windows-hardware/drivers/other-wdk-downloads
      - https://learn.microsoft.com/en-us/windows-hardware/drivers/legacy-wdk-downloads

.PARAMETER KitVersion
    Phiên bản SDK/WDK cài đặt, ví dụ '10.0.19041.0'.

.EXAMPLE
    .\install-wdk.ps1 -KitVersion 10.0.19041.0
#>
[CmdletBinding()]
param(
    [string] $KitVersion = '10.0.19041.0',
    [string] $SdkUrl     = 'https://go.microsoft.com/fwlink/?linkid=2311805',
    [string] $WdkUrl     = 'https://go.microsoft.com/fwlink/?linkid=2342425',
    [string] $KitsRoot  = "${env:ProgramFiles(x86)}\Windows Kits\10",
    [switch] $SkipSdk,
    [switch] $SkipWdk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# URL thu muc payload cua WDK 10.0.19041.5738 (lay tu Burn manifest cua
# wdksetup.exe: <Payload ... FilePath="Installers\<ten file>" />).
# DOI GUID doi doi doi -> phai doi doi doi khi doi doi doi WDK khac.
$script:WdkBaseUrl = 'https://download.microsoft.com/download/1b122713-4a55-4a95-8848-279de832a4c9/wdk/'

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([string] $Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Invoke-Bootstrapper {
    param(
        [string] $Exe,
        [string[]] $Arguments,
        [int]    $TimeoutSeconds = 1800
    )
    $proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -PassThru -NoNewWindow
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Host "    TIMEOUT after $TimeoutSeconds s - killing $Exe" -ForegroundColor Red
        try { $proc.Kill() } catch { }
        Start-Sleep -Seconds 3
        return -1
    }
    Write-Note "$([System.IO.Path]::GetFileName($Exe)) $($Arguments -join ' ') -> exit $($proc.ExitCode)"
    return $proc.ExitCode
}

function Save-BurnLog {
    <#
        Luu log cua WiX Burn bootstrapper (de giup debug khi installer treo).
        Burn ghi log vao %TEMP%\<ten>\<WixBundleName>_<timestamp>.log
    #>
    $out = 'wdk-burn.log'
    $found = $false
    foreach ($dir in @($env:TEMP, (Join-Path $env:TEMP 'wdk'))) {
        if (-not (Test-Path $dir)) { continue }
        $logs = Get-ChildItem -Path $dir -Filter '*.log' -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Driver_Kit|SDK' -or $_.DirectoryName -match 'wdk' } |
            Sort-Object LastWriteTime -Descending
        if ($logs) {
            $logs | Select-Object -First 1 | ForEach-Object {
                Copy-Item $_.FullName $out -Force
                Write-Note "burn log: $($_.FullName)"
            }
            $found = $true
            break
        }
    }
    if (-not $found) { Write-Note 'no burn log found' }
}

function Install-Layout {
    <#
        Tai layout (chua toan bo MSI) roi cai layout.exe.
        Dung khi cai truc tiep that bai.
    #>
    param(
        [string] $Exe,
        [string] $LayoutDir,
        [string[]] $LayoutFeatures
    )
    $null = New-Item -ItemType Directory -Force -Path $LayoutDir
    $args = @('/layout', $LayoutDir, '/quiet', '/ceip', 'off')
    if ($LayoutFeatures) { $args = @('/features') + $LayoutFeatures + $args }
    $rc = Invoke-Bootstrapper -Exe $Exe -Arguments $args
    if ($rc -ne 0 -and $rc -ne 3010) {
        Write-Host "    layout download returned $rc" -ForegroundColor Yellow
        return $false
    }
    $layoutExe = Get-ChildItem -Path $LayoutDir -Filter 'layout.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $layoutExe) {
        Write-Host "    layout.exe not found under $LayoutDir - layout incomplete" -ForegroundColor Yellow
        return $false
    }
    $rc = Invoke-Bootstrapper -Exe $layoutExe.FullName -Arguments @('/quiet', '/norestart', '/ceip', 'off') -TimeoutSeconds 1500
    Save-BurnLog
    return ($rc -eq 0 -or $rc -eq 3010)
}

# ---------------------------------------------------------------------------
# 1. Windows SDK
#
# Runner image (windows-2022) da co san nhieu version SDK, gom 10.0.19041.0
# -> thuong da co, khong can cai.  Van thu cai neu thieu.
# ---------------------------------------------------------------------------
$sdkOk = $true
if (-not $SkipSdk) {
    $sdkPresent = Test-Path (Join-Path $KitsRoot "Include\$KitVersion\um\windows.h")
    if ($sdkPresent) {
        Write-Step "Windows SDK $KitVersion already installed - skip"
    }
    else {
        $sdkExe = Join-Path $env:RUNNER_TEMP 'winsdksetup.exe'
        Write-Step "Downloading Windows SDK bootstrapper ($SdkUrl)"
        Invoke-WebRequest -Uri $SdkUrl -OutFile $sdkExe -UseBasicParsing

        Write-Step "Installing Windows SDK $KitVersion"
        $rc = Invoke-Bootstrapper -Exe $sdkExe -ArgumentList @(
            '/features', "OptionId.WindowsDesktopSDK-$KitVersion", 'OptionId.DesktopCPPx64',
            '/q', '/ceip', 'off', '/norestart'
        )
        $sdkOk = Test-Path (Join-Path $KitsRoot "Include\$KitVersion\um\windows.h")
        if (-not $sdkOk) {
            Write-Host "    direct install did not produce the SDK - trying layout" -ForegroundColor Yellow
            $null = Install-Layout -Exe $sdkExe -LayoutDir (Join-Path $env:RUNNER_TEMP 'sdk-layout') `
                -LayoutFeatures @("OptionId.WindowsDesktopSDK-$KitVersion")
            $sdkOk = Test-Path (Join-Path $KitsRoot "Include\$KitVersion\um\windows.h")
        }
    }
}

# ---------------------------------------------------------------------------
# 2. Windows Driver Kit
#
# VAN DE GOC: runner windows-2022 da co san WDK 10.0.26100.7705.  Khi chay bundle
# WDK 19041 (ke ca /layout), Burn detect cac package cua no la "Obsolete" ->
# chuyen sang luong Modify/Repair -> hien UI
# "Microsoft.Bootstrapper.Presentation.LocationPage" va CHO MAI, du da co /q.
# (Da xac nhan trong Burn log cua run 39608128701 va 39623216928.)
#
# GIAI PHAI: BO QUA Burn hoan toan.
#   MSI cua WDK 19041 khong self-contained: noi dung (headers + .lib) nam trong
#   cac file CAB payload cung thu muc.  Danh sach lay tu Burn manifest cua
#   wdksetup.exe (PE section .wixburn -> UX container la file CAB), muc
#   <Payload ... FilePath="Installers\<ten file>"> cho tung <MsiPackage Id=...>.
#   Da test local: tai MSI + 3 CAB roi `msiexec /a` -> exit 0, ra dung
#   Windows Kits\10\Lib\win7\km\{x64,x86}\ntoskrnl.lib
#
#   -> Tai truc tiep MSI + CAB tu CDN Microsoft, roi msiexec /i tung nhom.
#   -> Tong tai ~77 MB. Khong Burn, khong layout, khong Modify UI.
#
# Danh sach payload: .github/scripts/wdk-payloads.txt
# ---------------------------------------------------------------------------
$wdkOk = $true
if (-not $SkipWdk) {
    # Don installer cu bi treo (giu global mutex).
    foreach ($procName in @('wdksetup', 'winsdksetup', 'msiexec')) {
        Get-Process -Name $procName -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Note "killing stale $($_.ProcessName) (pid $($_.Id))"; $_.Kill() }
    }
    Start-Sleep -Seconds 3

    $manifest = Join-Path $PSScriptRoot 'wdk-payloads.txt'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw "Missing payload manifest: $manifest"
    }

    $msiDir = Join-Path $env:RUNNER_TEMP 'wdk-msi'
    if (Test-Path $msiDir) { Remove-Item $msiDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -ItemType Directory -Force -Path $msiDir

    # Parse: "[<ten MSI>]" roi cac dong duong dan file.
    $groups = [System.Collections.Generic.List[object]]::new()
    $cur = $null
    foreach ($line in Get-Content -LiteralPath $manifest) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t.StartsWith('[') -and $t.EndsWith(']')) {
            $cur = [ordered]@{ Msi = $t.Substring(1, $t.Length - 2); Files = [System.Collections.Generic.List[string]]::new() }
            $groups.Add($cur)
        }
        elseif ($cur) {
            $cur.Files.Add($t)
        }
    }
    Write-Step "Payload manifest: $($groups.Count) package group(s)"

    foreach ($g in $groups) {
        Write-Step "Package: $($g.Msi)"
        foreach ($rel in $g.Files) {
            $name = Split-Path $rel -Leaf
            $out = Join-Path $msiDir $name
            if (Test-Path -LiteralPath $out) { continue }
            # Escape tung segment path: EscapeDataString se encode ca '/' thanh
            # %2F -> server download.microsoft.com tra 404.
            $encoded = ($rel.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
            $url = $script:WdkBaseUrl + $encoded
            try {
                Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 600
            }
            catch {
                Write-Host "    download failed: $rel -> $($_.Exception.Message)" -ForegroundColor Red
                continue
            }
        }

        $msiPath = Join-Path $msiDir $g.Msi
        if (-not (Test-Path -LiteralPath $msiPath)) {
            Write-Host "    MSI missing: $($g.Msi) - skip" -ForegroundColor Yellow
            continue
        }

        Write-Step "Installing $($g.Msi)"
        $rc2 = Invoke-Bootstrapper -Exe 'msiexec.exe' `
            -Arguments @('/i', "`"$msiPath`"", '/qn', '/norestart') -TimeoutSeconds 900
        if ($rc2 -ne 0 -and $rc2 -ne 3010) {
            Write-Host "    msiexec returned $rc2 for $($g.Msi)" -ForegroundColor Yellow
        }
    }

    $wdkOk = Test-Path (Join-Path $KitsRoot "Lib\$KitVersion\km\x64\ntoskrnl.lib")
}

# ---------------------------------------------------------------------------
# 3. Kiem tra cac thu muc ma VirtualBox can
# ---------------------------------------------------------------------------
Write-Step "Verifying required kit directories under $KitsRoot"

# Dump cay kit da cai -> artifact de debug khi co thay doi.
$treeFile = 'wdk-kit-tree.txt'
@(
    "=== Lib ==="
    (Get-ChildItem -Path (Join-Path $KitsRoot 'Lib') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    "=== Include ==="
    (Get-ChildItem -Path (Join-Path $KitsRoot 'Include') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Name })
    "=== Lib\*\km ==="
    (Get-ChildItem -Path (Join-Path $KitsRoot 'Lib') -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $km = Join-Path $_.FullName 'km'
            if (Test-Path $km) {
                $archs = (Get-ChildItem -Path $km -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ','
                "$($_.Name)\km -> $archs"
            }
        })
) | Set-Content -Path $treeFile -Encoding utf8
Write-Note "kit tree written to $treeFile"

$required = @(
    @{ Path = "Include\$KitVersion\km";            Desc = 'KM headers' },
    @{ Path = "Include\$KitVersion\um";            Desc = 'UM headers' },
    @{ Path = "Lib\$KitVersion\km\x64";            Desc = 'KM libs (amd64)  -> WINSDK10-KM' },
    @{ Path = "Lib\$KitVersion\km\x86";            Desc = 'KM libs (x86)    -> WINSDK10-KM' },
    @{ Path = 'Lib\win7\km\x64';                   Desc = 'Win7 KM libs      -> WINSDK10-KM-W7 / -WLH' },
    @{ Path = 'Lib\win8\km\x64';                   Desc = 'Win8 KM libs      -> WINSDK10-KM-W8' }
)

$optional = @(
    @{ Path = 'Lib\winv6.3\km\x64';                Desc = 'Win8.1 KM libs    -> WINSDK10-KM-W81' }
)

$missing = [System.Collections.Generic.List[string]]::new()
foreach ($r in $required) {
    $full = Join-Path $KitsRoot $r.Path
    if (Test-Path -LiteralPath $full) {
        Write-Host ("  OK   {0,-40} {1}" -f $r.Path, $r.Desc)
    }
    else {
        Write-Host ("  MISS {0,-40} {1}" -f $r.Path, $r.Desc) -ForegroundColor Red
        $missing.Add("$($r.Path) ($($r.Desc))")
    }
}

foreach ($r in $optional) {
    $full = Join-Path $KitsRoot $r.Path
    if (Test-Path -LiteralPath $full) {
        Write-Host ("  OK   {0,-40} {1}  (optional)" -f $r.Path, $r.Desc)
    }
    else {
        Write-Host ("  --   {0,-40} {1}  (optional, not installed)" -f $r.Path, $r.Desc) -ForegroundColor DarkGray
    }
}

$kitsInfo = [ordered]@{
    kits_root    = $KitsRoot
    kit_version  = $KitVersion
    sdk_ok       = $sdkOk
    wdk_ok       = $wdkOk
    km_incs      = (Join-Path $KitsRoot "Include\$KitVersion\km")
    km_lib_amd64 = (Join-Path $KitsRoot "Lib\$KitVersion\km\x64")
    km_lib_x86   = (Join-Path $KitsRoot "Lib\$KitVersion\km\x86")
    km_lib_w7    = (Join-Path $KitsRoot 'Lib\win7\km\x64')
    km_lib_w8    = (Join-Path $KitsRoot 'Lib\win8\km\x64')
}
$kitsInfo.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" } |
    Set-Content -Path 'wdk-layout-info.txt' -Encoding utf8

if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Host 'MISSING kit directories:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Nguyên nhân thường gặp:' -ForegroundColor Yellow
    Write-Host '  * Runner GH da co san WDK 10.0.26100 -> bundle 19041 bi Burn xep' -ForegroundColor Yellow
    Write-Host '    "Obsolete" -> vao luong Modify/Repair -> treo UI. Script da bypass' -ForegroundColor Yellow
    Write-Host '    Burn bang cach tai layout roi msiexec truc tiep.' -ForegroundColor Yellow
    Write-Host '  * Layout co MSI can dung (xem wdk-msi-inventory.txt) khong?' -ForegroundColor Yellow
    Write-Host '  * Bo lib downlevel (win7/win8/winv6.3) do feature "OptionId.WdkDownlevelContent"' -ForegroundColor Yellow
    Write-Host '    cung cap. Neu thieu -> can WDK <= 10.0.20348.' -ForegroundColor Yellow
    exit 1
}

Write-Step 'All required kit directories are present.'
exit 0
