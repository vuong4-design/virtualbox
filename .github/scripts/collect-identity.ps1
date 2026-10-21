<#
.SYNOPSIS
    Thu thập "guest-visible identity" của một VirtualBox VM để kiểm chứng lớp cloak.

.DESCRIPTION
    Script chạy headless một VM không có đĩa boot được (BIOS dừng ở "no bootable
    device" nhưng VMM vẫn sống), rồi dùng `VBoxManage debugvm <vm> info <item>` để
    đọc identity mà guest sẽ nhìn thấy:

        pci      -> VID/DID/SVID/SID + 256 byte config space của mọi PCI function
        acpi     -> header/bảng ACPI (OEM ID, Creator ID, OEM Table ID)
        vga / vbe-> GPU identity + VBE presentation
        hda      -> audio codec identity
        ohci / xhci -> USB controller identity
        vmsvga   -> capability bits của VMSVGA
        lpc / hpet -> chipset identity

    Sau đó chạy lại lần thứ hai với CÙNG hardware UUID để chứng minh identity
    ổn định giữa các lần mở VM (yêu cầu: random nhưng không đổi).

    Kết quả:
        <OutDir>\run1\*.txt   capture lần 1
        <OutDir>\run2\*.txt   capture lần 2
        <OutDir>\identity.txt fingerprint đã chuẩn hoá của lần 1
        <OutDir>\stability.txt so sánh run1 vs run2
        exit code 0 = ổn định, 1 = không ổn định, 2 = lỗi thực thi

.EXAMPLE
    .\collect-identity.ps1 -VBoxDir ..\vbox -OutDir ..\identity-out
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $VBoxDir,

    [Parameter(Mandatory = $true)]
    [string] $OutDir,

    [string] $VmName      = 'cloak-smoke',
    [string] $HardwareUuid = '9f2c1d40-7a51-4c62-9b8e-0d3a5e6f7c81',
    [string] $Chipset     = '',
    [string] $Firmware    = '',
    [int]    $BootWaitSeconds = 20,
    [switch] $RequireRuntime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Các info item đã đăng ký qua PDMDevHlpDBGFInfoRegister() ---
$script:InfoItems = @('pci', 'acpi', 'vga', 'vbe', 'hda', 'ohci', 'xhci', 'vmsvga', 'lpc', 'hpet')

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message"
}

function Invoke-VBoxManage {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)

    # Native command + 2>&1 + $ErrorActionPreference='Stop' -> PowerShell 5.1
    # coi stderr của lệnh native là terminating error. Tạm tắt EAP trong lúc gọi.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        $output = & $script:VBoxManage @Arguments 2>&1 |
            ForEach-Object { "$_" } |
            Out-String
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    return $output
}

function Get-IdentityFingerprint {
    <#
        Chuẩn hoá output để so sánh được giữa 2 lần chạy:
          - bỏ dòng trống
          - bỏ các dòng chứa dấu thời gian / session / uuid ngẫu nhiên
          - mask địa chỉ hex dài (RAM address, không phải identity)
          - cắt khoảng trắng thừa
    #>
    param([string] $Text)

    $lines = $Text -split "`r?`n" |
        Where-Object { $_ -match '\S' } |
        Where-Object { $_ -notmatch '(?i)(timestamp|elapsed|session[ _-]?id|^\s*uuid\s*:)' } |
        ForEach-Object {
            $s = $_.Trim()
            $s = $s -replace '0x[0-9a-fA-F]{8,16}', '0xADDR'
            $s = $s -replace '\s+', ' '
            $s
        }

    return ($lines -join "`n")
}

# ---------------------------------------------------------------------------
# Kiểm tra môi trường
# ---------------------------------------------------------------------------
$script:VBoxManage = Join-Path $VBoxDir 'VBoxManage.exe'
if (-not (Test-Path -LiteralPath $script:VBoxManage)) {
    Write-Host "ERROR: VBoxManage.exe not found: $script:VBoxManage" -ForegroundColor Red
    exit 2
}

$null = New-Item -ItemType Directory -Force -Path $OutDir

Write-Step "Using VBoxManage: $script:VBoxManage"

# ---------------------------------------------------------------------------
# 0. Kiem tra co the chay VM that khong
#
# VirtualBox tren Windows can VBoxDrv (kernel driver) + nested virtualization
# (VT-x) de chay may ao. GitHub-hosted runner KHONG co ca hai:
#   - VBoxDrv chua duoc cai -> "VERR_VM_DRIVER_NOT_INSTALLED"
#   - Azure runner khong expose nested virtualization
# => Phase 1 (capture runtime) chi chay khi co runtime target.
# ---------------------------------------------------------------------------
function Test-RuntimeAvailable {
    $driver = Join-Path $env:SystemRoot 'System32\drivers\VBoxDrv.sys'
    if (Test-Path -LiteralPath $driver) { return $true }

    # Da dang ky service?
    $svc = Get-Service -Name 'VBoxDrv' -ErrorAction SilentlyContinue
    if ($svc) { return $true }

    return $false
}

$runtimeAvailable = Test-RuntimeAvailable
if (-not $runtimeAvailable) {
    Write-Host 'RUNTIME_TARGET_UNAVAILABLE' -ForegroundColor Yellow
    Write-Host '  - VBoxDrv (kernel driver) chua duoc cai tren may nay' -ForegroundColor Yellow
    Write-Host '  - runner nay cung khong co nested virtualization' -ForegroundColor Yellow
    if ($RequireRuntime) {
        Write-Host 'ERROR: -RequireRuntime duoc dat nhung khong co runtime target.' -ForegroundColor Red
        exit 3
    }
    Write-Host '  -> BO QUA phase capture runtime (khong phai loi).' -ForegroundColor Yellow
    Write-Host '  -> De verify identity that runtime, hay chay script nay tren may co VBoxDrv' -ForegroundColor Yellow
    Write-Host '     (hoac tren self-hosted runner / VM local).' -ForegroundColor Yellow
}
else {
    Write-Step 'Runtime target available (VBoxDrv present).'
}

# ---------------------------------------------------------------------------
# 1. Tao VM (xoa neu da co) voi hardware UUID co dinh
# ---------------------------------------------------------------------------
Write-Step "Preparing VM '$VmName' (hardwareuuid=$HardwareUuid, chipset='$Chipset', firmware='$Firmware')"

$existing = Invoke-VBoxManage 'list' 'vms'
if ($existing -match [regex]::Escape($VmName)) {
    Write-Step "VM already exists - unregistering"
    $null = Invoke-VBoxManage 'unregistervm' $VmName '--delete'
}

$null = Invoke-VBoxManage 'createvm' '--name' $VmName '--ostype' 'Other_64' '--register'
if ($LASTEXITCODE -ne 0) {
    # Fallback: một số build không có "Other_64" -> tạo VM không chỉ định OS type.
    Write-Step 'createvm with --ostype Other_64 failed - retrying without --ostype'
    $null = Invoke-VBoxManage 'unregistervm' $VmName '--delete'
    $null = Invoke-VBoxManage 'createvm' '--name' $VmName '--register'
}
$null = Invoke-VBoxManage 'modifyvm' $VmName '--hardwareuuid' $HardwareUuid
if ($Chipset)  { $null = Invoke-VBoxManage 'modifyvm' $VmName '--chipset'  $Chipset  }
if ($Firmware) { $null = Invoke-VBoxManage 'modifyvm' $VmName '--firmware' $Firmware }

$null = Invoke-VBoxManage 'showvminfo' $VmName '--machinereadable' |
    Set-Content -Path (Join-Path $OutDir 'vminfo.txt') -Encoding utf8

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------
function Wait-VmRunning {
    <#
        Chờ VM chuyển sang trạng thái running. Trả về $false nếu VM bị dừng
        (aborted/saved/poweroff) hoặc hết thời gian chờ.
    #>
    param(
        [string] $Name,
        [int]    $TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $info = Invoke-VBoxManage 'showvminfo' $Name '--machinereadable'
        if ($info -match '(?m)^VMState="running"') { return $true }
        if ($info -match '(?m)^VMState="(aborted|saved|poweroff|stopped)"') { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-Capture {
    param([string] $RunDir)

    Write-Step "Capture -> $RunDir"
    $null = New-Item -ItemType Directory -Force -Path $RunDir

    # Start headless. Không có đĩa boot được nên BIOS dừng ở "no bootable
    # device" nhưng VMM vẫn chạy -> các info item của debugger hoạt động.
    Write-Step "Starting VM (headless)"
    $startOut = Invoke-VBoxManage 'startvm' $VmName '--type' 'headless'
    $startOut | Set-Content -Path (Join-Path $RunDir 'startvm.txt') -Encoding utf8

    if ($LASTEXITCODE -ne 0) {
        throw "VBoxManage startvm failed (exit $LASTEXITCODE):`n$startOut"
    }

    if (-not (Wait-VmRunning -Name $VmName -TimeoutSeconds 90)) {
        $state = Invoke-VBoxManage 'showvminfo' $VmName '--machinereadable'
        throw "VM '$VmName' did not reach the 'running' state:`n$state"
    }

    Start-Sleep -Seconds $script:BootWaitSeconds

    try {
        foreach ($item in $script:InfoItems) {
            $args = @('debugvm', $VmName, 'info', $item)
            if ($item -eq 'pci') { $args += 'verbose' }

            $text = Invoke-VBoxManage @args
            $text | Set-Content -Path (Join-Path $RunDir "info-$item.txt") -Encoding utf8
        }
    }
    finally {
        Write-Step "Powering off VM"
        $null = Invoke-VBoxManage 'controlvm' $VmName 'poweroff'
        Start-Sleep -Seconds 5
    }
}

# ---------------------------------------------------------------------------
# 2. Capture runtime (chi khi co runtime target)
# ---------------------------------------------------------------------------
if (-not $runtimeAvailable) {
    Write-Step 'Skipping runtime capture (no runtime target).'
    @(
        "RUNTIME_TARGET_UNAVAILABLE",
        "vm=$VmName",
        "hardwareuuid=$HardwareUuid",
        "chipset=$Chipset",
        "firmware=$Firmware",
        "created=$(Get-Date -Format o)"
    ) | Set-Content -Path (Join-Path $OutDir 'identity.txt') -Encoding utf8
    'RUNTIME_TARGET_UNAVAILABLE' | Set-Content -Path (Join-Path $OutDir 'stability.txt') -Encoding utf8
    Write-Step 'Done (config-only verification).'
    exit 0
}

Invoke-Capture -RunDir (Join-Path $OutDir 'run1')
Invoke-Capture -RunDir (Join-Path $OutDir 'run2')

# ---------------------------------------------------------------------------
# Fingerprint + so sánh
# ---------------------------------------------------------------------------
$fingerprints = [ordered]@{}
foreach ($item in $script:InfoItems) {
    $f1 = Get-IdentityFingerprint (Get-Content -Raw -Path (Join-Path $OutDir "run1\info-$item.txt"))
    $f2 = Get-IdentityFingerprint (Get-Content -Raw -Path (Join-Path $OutDir "run2\info-$item.txt"))
    $fingerprints[$item] = $f1
}

$fingerprints.GetEnumerator() | ForEach-Object {
    "### $($_.Key)`n$($_.Value)`n" | Out-File -FilePath (Join-Path $OutDir 'identity.txt') -Append -Encoding utf8
}

$report = [System.Collections.Generic.List[string]]::new()
$stable = $true
foreach ($item in $script:InfoItems) {
    $f1 = Get-IdentityFingerprint (Get-Content -Raw -Path (Join-Path $OutDir "run1\info-$item.txt"))
    $f2 = Get-IdentityFingerprint (Get-Content -Raw -Path (Join-Path $OutDir "run2\info-$item.txt"))
    if ($f1 -ceq $f2) {
        $report.Add("STABLE   : $item")
    }
    else {
        $stable = $false
        $report.Add("UNSTABLE : $item")
        $report.Add("--- run1 ---")
        $report.Add($f1)
        $report.Add("--- run2 ---")
        $report.Add($f2)
    }
}

$report | Set-Content -Path (Join-Path $OutDir 'stability.txt') -Encoding utf8
Write-Host ($report -join "`n")

if (-not $stable) {
    Write-Host 'ERROR: Identity is NOT stable between two runs of the same VM.' -ForegroundColor Red
    exit 1
}

Write-Step 'Identity is stable across two runs of the same VM.'
exit 0
