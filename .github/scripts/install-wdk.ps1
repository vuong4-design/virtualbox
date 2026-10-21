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

    WDK >= 10.0.22621 KHÔNG còn lib win7/win8, và WDK >= 10.0.22000 KHÔNG còn
    lib KM x86.  WDK 10.0.19041 là bản duy nhất còn CẢ hai, nên ta ghim version này.

    Tham khảo:
      - https://learn.microsoft.com/en-us/windows-hardware/drivers/other-wdk-downloads
      - https://learn.microsoft.com/en-us/windows-hardware/drivers/download-the-wdk

    Cách cài: bootstrapper chính thức của Microsoft. Mỗi kit được thử theo 2 cách:
      1. cài trực tiếp (silent) với feature id
      2. tải layout rồi chạy layout.exe (fallback khi feature id cũ bị gỡ)

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

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Note {
    param([string] $Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Invoke-Bootstrapper {
    <#
        Chạy 1 bootstrapper với các tham số đã cho, trả về exit code.
    #>
    param(
        [string] $Exe,
        [string[]] $Arguments
    )
    $proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
    Write-Note "$([System.IO.Path]::GetFileName($Exe)) $($Arguments -join ' ') -> exit $($proc.ExitCode)"
    return $proc.ExitCode
}

function Install-Kit {
    <#
        Cài 1 kit (SDK hoặc WDK):
          1. tải bootstrapper
          2. thử cài trực tiếp
          3. nếu thất bại -> thử layout + layout.exe
        Trả về $true nếu có vẻ thành công.
    #>
    param(
        [string] $Url,
        [string] $ExeName,
        [string[]] $DirectArgs,
        [string] $LayoutFeature,
        [scriptblock] $Verify
    )

    $exe = Join-Path $env:RUNNER_TEMP $ExeName
    Write-Step "Downloading $ExeName ($Url)"
    Invoke-WebRequest -Uri $Url -OutFile $exe -UseBasicParsing

    Write-Step "Installing $ExeName (direct)"
    $rc = Invoke-Bootstrapper -Exe $exe -Arguments $DirectArgs
    if ((& $Verify)) {
        Write-Step "$ExeName installed."
        return $true
    }
    if ($rc -ne 0 -and $rc -ne 3010) {
        Write-Host "    direct install returned $rc, trying layout fallback" -ForegroundColor Yellow
    }

    Write-Step "Installing $ExeName (layout fallback)"
    $layoutDir = Join-Path $env:RUNNER_TEMP "$ExeName-layout"
    $null = New-Item -ItemType Directory -Force -Path $layoutDir

    $layoutArgs = @('/layout', $layoutDir, '/quiet', '/ceip', 'off')
    if ($LayoutFeature) { $layoutArgs = @('/features', $LayoutFeature, '/layout', $layoutDir, '/quiet', '/ceip', 'off') }
    $rc = Invoke-Bootstrapper -Exe $exe -Arguments $layoutArgs
    if ($rc -ne 0 -and $rc -ne 3010) {
        Write-Host "    layout download returned $rc" -ForegroundColor Yellow
        return $false
    }

    $layoutExe = Get-ChildItem -Path $layoutDir -Filter 'layout.exe' -Recurse -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $layoutExe) {
        Write-Host "    layout.exe not found under $layoutDir - layout incomplete" -ForegroundColor Yellow
        return $false
    }

    $rc = Invoke-Bootstrapper -Exe $layoutExe.FullName -Arguments @('/quiet', '/norestart', '/ceip', 'off')
    if ($rc -ne 0 -and $rc -ne 3010) {
        Write-Host "    layout.exe returned $rc" -ForegroundColor Yellow
        return $false
    }

    if ((& $Verify)) {
        Write-Step "$ExeName installed (via layout)."
        return $true
    }
    Write-Host "    ${ExeName}: verification still failing after layout install" -ForegroundColor Yellow
    return $false
}

# ---------------------------------------------------------------------------
# 1. Windows SDK
# ---------------------------------------------------------------------------
$sdkOk = $true
if (-not $SkipSdk) {
    $sdkOk = Install-Kit -Url $SdkUrl -ExeName 'winsdksetup.exe' `
        -DirectArgs @(
            '/features', "OptionId.WindowsDesktopSDK-$KitVersion", 'OptionId.DesktopCPPx64',
            '/q', '/ceip', 'off', '/norestart'
        ) `
        -LayoutFeature "OptionId.WindowsDesktopSDK-$KitVersion" `
        -Verify { Test-Path (Join-Path $KitsRoot "Include\$KitVersion\um\windows.h") }
}

# ---------------------------------------------------------------------------
# 2. Windows Driver Kit
# ---------------------------------------------------------------------------
$wdkOk = $true
if (-not $SkipWdk) {
    $wdkOk = Install-Kit -Url $WdkUrl -ExeName 'wdksetup.exe' `
        -DirectArgs @('/features', 'OptionId.WindowsDriverKitComplete', '/q', '/ceip', 'off', '/norestart') `
        -LayoutFeature '' `
        -Verify { Test-Path (Join-Path $KitsRoot "Lib\$KitVersion\km\x64\ntoskrnl.lib") }
}

# ---------------------------------------------------------------------------
# 3. Kiểm tra các thư mục mà VirtualBox cần
# ---------------------------------------------------------------------------
Write-Step "Verifying required kit directories under $KitsRoot"

$required = @(
    @{ Path = "Include\$KitVersion\km";            Desc = 'KM headers' },
    @{ Path = "Include\$KitVersion\um";            Desc = 'UM headers' },
    @{ Path = "Lib\$KitVersion\km\x64";            Desc = 'KM libs (amd64)  -> WINSDK10-KM' },
    @{ Path = "Lib\$KitVersion\km\x86";            Desc = 'KM libs (x86)    -> WINSDK10-KM' },
    @{ Path = 'Lib\win7\km\x64';                   Desc = 'Win7 KM libs      -> WINSDK10-KM-W7 / -WLH' },
    @{ Path = 'Lib\win8\km\x64';                   Desc = 'Win8 KM libs      -> WINSDK10-KM-W8' }
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

# Ghi lại cho workflow dùng.
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
    Write-Host '  * WDK >= 10.0.22621 khong ship lib win7/win8.' -ForegroundColor Yellow
    Write-Host '    -> can WDK <= 10.0.20348 (bo "Windows 10 2004" 19041.5738).' -ForegroundColor Yellow
    Write-Host '  * WDK >= 10.0.22000 khong ship lib KM x86.' -ForegroundColor Yellow
    Write-Host '    -> can WDK <= 10.0.20348.' -ForegroundColor Yellow
    Write-Host '  * Feature id cua Windows SDK 10.0.19041 co the da bi go khoi' -ForegroundColor Yellow
    Write-Host '    dich vu tai ve -> can dung layout fallback (script da thu).' -ForegroundColor Yellow
    exit 1
}

Write-Step 'All required kit directories are present.'
exit 0
