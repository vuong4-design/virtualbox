<#
.SYNOPSIS
    T3 — kiểm chứng runtime identity trên self-hosted runner (kế hoạch §4.7.4).

.DESCRIPTION
    Script chạy trên máy self-hosted Windows có VBoxDrv + VT-x. Với mỗi guest VM
    (Windows/Linux) trong file cấu hình:

        boot N lần (mặc định 3) trên cùng VM:
          - host: `VBoxManage debugvm <vm> info <item>` cho từng item đã đăng ký
          - guest: lấy JSON do guest collector ghi (collect-guest-identity.ps1/.sh)
            bằng lệnh `fetchCommand` do quản trị runner cấu hình

        So sánh boot 2..N với boot 1:
          - host: fingerprint text (chuẩn hoá; mask địa chỉ hex dài - volatile)
          - guest: schema comparator §4.7.4.1 (compare-identity.ps1)

    Không fallback sang hosted runner: thiếu VBoxDrv/VT-x -> exit 3 (fail).
    "No bootable device" không phải T3: collector phải chạy được trong guest.

    Nếu config bật `stateTest` (§4.6.5), sau các boot cold còn chạy thêm:
      - save state -> resume -> identity phải giống baseline
      - save state -> đổi seed -> resume phải bị từ chối (fail rõ)
      - snapshot -> restore -> identity phải giống baseline
      - snapshot -> đổi seed -> restore/start phải bị từ chối
    Negative test cần cloak build + seed đã provision (`provision-cloak.ps1`).

    Report chỉ chứa dữ liệu đã redact (comparator mặc định redact giá trị);
    raw dump giữ local trong WorkDir, không upload. Trước khi publish, script
    tự chạy audit redaction trên đúng tập file artifact (report + guest-compare);
    có seed/hash 64 hex, key ExtraData hay marker bí mật -> exit 2, không upload.

.PARAMETER VBoxDir
    Thư mục chứa VBoxManage.exe (ví dụ "vbox" — artifact của job build).

.PARAMETER WorkDir
    Thư mục làm việc: capture từng boot + report đã redact.

.PARAMETER ConfigPath
    File JSON cấu hình T3 (xem mẫu `.github/scripts/testdata/t3-config.sample.json`).

.PARAMETER SelfTest
    Kiểm tra logic so sánh/report bằng dữ liệu tổng hợp, không cần VM.

.PARAMETER ValidateConfig
    Chỉ đọc và kiểm tra ConfigPath rồi thoát (dùng được trên hosted runner).

.PARAMETER AuditArtifacts
    Chỉ audit redaction trên tập file artifact trong WorkDir rồi thoát
    (dùng trong job T3 trước bước upload; không cần VM).

.PARAMETER CheckRuntime
    Chỉ kiểm tra runner đã sẵn sàng chạy T3 rồi thoát: VBoxManage + VBoxDrv/VT-x,
    và nếu có ConfigPath thì thêm VM đã đăng ký + seed/hash đã provision đúng.
    Dùng khi bring-up runner self-hosted (O8); không boot VM.

.NOTES
    Exit code:
        0 = identity ổn định qua N boot (host + toàn bộ guest)
        1 = có khác biệt identity
        2 = lỗi cấu hình/thực thi
        3 = runtime target không khả dụng (VBoxDrv/VT-x)

    Khóa config tùy chọn:
        runs                   số boot cold (2..10, mặc định 3)
        bootTimeoutSeconds     chờ VM vào running (mặc định 180)
        captureDelaySeconds    chờ guest userspace trước khi capture (mặc định 20)
        stateTest              true -> bật test saved-state/snapshot (§4.6.5)
        stateTests             ghi đè từng test: saveStateRestore, saveStateSeedMismatch,
                               snapshotRestore, snapshotSeedMismatch
        snapshotName           tên snapshot tạm (mặc định cloak-t3-state)

    Placeholder trong `fetchCommand`:
        {vboxmanage}       đường dẫn VBoxManage.exe
        {name}             tên VM guest
        {platform}         windows|linux
        {run}              số thứ tự boot hiện tại
        {localPath}        file JSON đích trên host (bắt buộc ghi vào đây)
        {localDir}         thư mục chứa {localPath}
        {guestOutputPath}  đường dẫn JSON trong guest (theo cấu hình)
        {password}         lấy từ biến môi trường CLOAK_T3_GUEST_PASSWORD

    Guest VM phải được chuẩn bị trước trên runner (đĩa ảo, collector chạy lúc
    boot, ghi JSON vào `guestOutputPath`). Script KHÔNG tạo VM.

.EXAMPLE
    .\t3-runtime.ps1 -VBoxDir .\vbox -WorkDir .\t3-out -ConfigPath .\t3-config.json
#>
[CmdletBinding()]
param(
    [string] $VBoxDir,
    [string] $WorkDir,
    [string] $ConfigPath,
    [switch] $SelfTest,
    [switch] $ValidateConfig,
    [switch] $AuditArtifacts,
    [switch] $CheckRuntime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Các info item đã đăng ký qua PDMDevHlpDBGFInfoRegister() (giống collect-identity.ps1) ---
$script:T3InfoItems = @('pci', 'acpi', 'vga', 'vbe', 'hda', 'ohci', 'xhci', 'vmsvga', 'lpc', 'hpet')

$script:T3BootTimeoutDefault     = 180
$script:T3CaptureDelayDefault    = 20
$script:T3GuestWaitDefault       = 300

$script:T3SelfTestFailed = 0

function Write-Step {
    param([string] $Message)
    Write-Host "==> $Message"
}

function Write-ErrorLine {
    param([string] $Message)
    [Console]::Error.WriteLine("ERROR: $Message")
}

function Get-T3Property {
    param(
        $Object,
        [string] $Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-T3TextFingerprint {
    <#
        Chuẩn hoá output debugvm để so sánh giữa các boot:
          - bỏ dòng trống
          - bỏ dòng chứa timestamp/session id/uuid ngẫu nhiên
          - mask địa chỉ hex dài (RAM address — volatile theo §4.7.4.1)
          - gộp khoảng trắng
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

function Invoke-T3VBoxManage {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)

    # Native command + stderr + EAP 'Stop' -> PS 5.1 coi stderr la terminating error.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        $output = & $script:T3VBoxManage @Arguments 2>&1 |
            ForEach-Object { "$_" } |
            Out-String
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    return $output
}

function Wait-T3VmRunning {
    param(
        [string] $Name,
        [int]    $TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $info = Invoke-T3VBoxManage 'showvminfo' $Name '--machinereadable'
        if ($info -match '(?m)^VMState="running"') { return $true }
        if ($info -match '(?m)^VMState="(aborted|saved|poweroff|stopped)"') { return $false }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Expand-T3Arguments {
    param(
        [string[]] $Arguments,
        [hashtable] $Values
    )

    $result = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in $Arguments) {
        $text = $argument
        foreach ($key in $Values.Keys) {
            $text = $text.Replace("{$key}", [string] $Values[$key])
        }
        $result.Add($text)
    }
    return $result.ToArray()
}

# ---------------------------------------------------------------------------
# Preflight — thieu runtime phai fail (CI-14), khong duoc skip
# ---------------------------------------------------------------------------
function Assert-T3RuntimeAvailable {
    $driver = Join-Path $env:SystemRoot 'System32\drivers\VBoxDrv.sys'
    $hasDriver = (Test-Path -LiteralPath $driver)
    if (-not $hasDriver) {
        $service = Get-Service -Name 'VBoxDrv' -ErrorAction SilentlyContinue
        if ($null -ne $service) { $hasDriver = $true }
    }
    if (-not $hasDriver) {
        Write-ErrorLine 'RUNTIME_TARGET_UNAVAILABLE: VBoxDrv (kernel driver) not installed.'
        exit 3
    }

    $hasVtX = $false
    $cimError = ''
    try {
        $cpu = Get-CimInstance -ClassName 'Win32_Processor' -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $cpu) {
            if ($cpu.VMMonitorModeExtensions -eq $true) { $hasVtX = $true }
            if ($cpu.VirtualizationFirmwareEnabled -eq $true) { $hasVtX = $true }
        }
    }
    catch {
        $cimError = $_.Exception.Message
    }
    if (-not $hasVtX) {
        Write-ErrorLine "RUNTIME_TARGET_UNAVAILABLE: VT-x/AMD-V not detected (Win32_Processor). $cimError"
        exit 3
    }

    Write-Step 'Runtime target available (VBoxDrv + VT-x/AMD-V).'
}

# ---------------------------------------------------------------------------
# Cau hinh T3
# ---------------------------------------------------------------------------
function Read-T3Config {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-ErrorLine "config not found: $Path"
        exit 2
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $document = $raw | ConvertFrom-Json
    }
    catch {
        Write-ErrorLine "config is not valid JSON: $($_.Exception.Message)"
        exit 2
    }

    $runs = Get-T3Property -Object $document -Name 'runs' -Default 3
    if ($runs -isnot [int] -and $runs -isnot [long]) {
        Write-ErrorLine "config: 'runs' must be an integer."
        exit 2
    }
    if ($runs -lt 2 -or $runs -gt 10) {
        Write-ErrorLine "config: 'runs' must be 2..10 (T3 dung 3)."
        exit 2
    }

    $bootTimeout = Get-T3Property -Object $document -Name 'bootTimeoutSeconds' -Default $script:T3BootTimeoutDefault
    $captureDelay = Get-T3Property -Object $document -Name 'captureDelaySeconds' -Default $script:T3CaptureDelayDefault

    $stateTest = Get-T3Property -Object $document -Name 'stateTest' -Default $false
    if ($stateTest -isnot [bool]) {
        Write-ErrorLine "config: 'stateTest' must be a boolean."
        exit 2
    }
    $snapshotName = Get-T3Property -Object $document -Name 'snapshotName' -Default 'cloak-t3-state'
    if ([string] $snapshotName -notmatch '^[A-Za-z0-9._-]+$') {
        Write-ErrorLine "config: 'snapshotName' must match [A-Za-z0-9._-]+."
        exit 2
    }
    $stateTests = [ordered] @{
        SaveStateRestore      = [bool] $stateTest
        SaveStateSeedMismatch = [bool] $stateTest
        SnapshotRestore       = [bool] $stateTest
        SnapshotSeedMismatch  = [bool] $stateTest
    }
    $stateTestsRaw = Get-T3Property -Object $document -Name 'stateTests' -Default $null
    if ($null -ne $stateTestsRaw) {
        $stateTestKeys = @{
            SaveStateRestore      = 'saveStateRestore'
            SaveStateSeedMismatch = 'saveStateSeedMismatch'
            SnapshotRestore       = 'snapshotRestore'
            SnapshotSeedMismatch  = 'snapshotSeedMismatch'
        }
        foreach ($stateTestKey in $stateTestKeys.Keys) {
            $rawValue = Get-T3Property -Object $stateTestsRaw -Name $stateTestKeys[$stateTestKey] -Default $null
            if ($null -eq $rawValue) { continue }
            if ($rawValue -isnot [bool]) {
                Write-ErrorLine "config: stateTests.$($stateTestKeys[$stateTestKey]) must be a boolean."
                exit 2
            }
            $stateTests[$stateTestKey] = [bool] $rawValue
        }
    }

    $guests = Get-T3Property -Object $document -Name 'guests' -Default $null
    if ($null -eq $guests) {
        Write-ErrorLine "config: 'guests' is required."
        exit 2
    }

    $guestList = [System.Collections.Generic.List[object]]::new()
    $usesPassword = $false
    foreach ($guest in @($guests)) {
        $name = Get-T3Property -Object $guest -Name 'name' -Default ''
        $platform = Get-T3Property -Object $guest -Name 'platform' -Default ''
        $guestOutputPath = Get-T3Property -Object $guest -Name 'guestOutputPath' -Default ''
        $fetchCommand = Get-T3Property -Object $guest -Name 'fetchCommand' -Default $null
        $waitSeconds = Get-T3Property -Object $guest -Name 'waitSeconds' -Default $script:T3GuestWaitDefault

        if (-not $name) { Write-ErrorLine "config: guest 'name' is required."; exit 2 }
        if ($platform -notin @('windows', 'linux')) {
            Write-ErrorLine "config: guest '$name' has invalid platform '$platform' (windows|linux)."
            exit 2
        }
        if (-not $guestOutputPath) {
            Write-ErrorLine "config: guest '$name' requires 'guestOutputPath'."
            exit 2
        }
        if ($null -eq $fetchCommand -or @($fetchCommand).Count -eq 0) {
            Write-ErrorLine "config: guest '$name' requires non-empty 'fetchCommand'."
            exit 2
        }

        $commandList = [System.Collections.Generic.List[string]]::new()
        foreach ($part in @($fetchCommand)) {
            if ($part -isnot [string]) {
                Write-ErrorLine "config: guest '$name' fetchCommand entries must be strings."
                exit 2
            }
            $commandList.Add($part)
        }
        $expanded = $commandList.ToArray()
        if (-not ($expanded -match '\{localPath\}')) {
            Write-ErrorLine "config: guest '$name' fetchCommand must contain {localPath}."
            exit 2
        }
        if (@($expanded | Where-Object { $_ -match '\{password\}' }).Count -gt 0) {
            $usesPassword = $true
        }

        $guestList.Add([pscustomobject] @{
            Name             = $name
            Platform         = $platform
            GuestOutputPath  = $guestOutputPath
            FetchCommand     = $expanded
            WaitSeconds      = [int] $waitSeconds
        })
    }

    if ($guestList.Count -eq 0) {
        Write-ErrorLine "config: 'guests' must contain at least one entry."
        exit 2
    }

    return [pscustomobject] @{
        Runs                 = [int] $runs
        BootTimeoutSeconds   = [int] $bootTimeout
        CaptureDelaySeconds  = [int] $captureDelay
        StateTest            = [bool] $stateTest
        StateTests           = [pscustomobject] $stateTests
        SnapshotName         = [string] $snapshotName
        UsesPassword         = $usesPassword
        Guests               = $guestList.ToArray()
    }
}

# ---------------------------------------------------------------------------
# Guest collector fetch
# ---------------------------------------------------------------------------
function Test-T3GuestDocument {
    param([string] $Path)

    try {
        $document = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8) | ConvertFrom-Json
    }
    catch {
        return $false
    }
    if ($null -eq $document) { return $false }
    $schemaVersion = Get-T3Property -Object $document -Name 'schemaVersion' -Default $null
    if ($null -eq $schemaVersion) { return $false }
    return $true
}

function Invoke-T3GuestFetch {
    param(
        $Guest,
        [string] $LocalPath,
        [string] $LogPath
    )

    $deadline = (Get-Date).AddSeconds($Guest.WaitSeconds)
    $attempt = 0
    while ($true) {
        $attempt++

        if (Test-Path -LiteralPath $LocalPath) {
            Remove-Item -LiteralPath $LocalPath -Force
        }

        $values = @{
            'vboxmanage'      = $script:T3VBoxManage
            'name'            = $Guest.Name
            'platform'        = $Guest.Platform
            'localPath'       = $LocalPath
            'localDir'        = (Split-Path -Parent $LocalPath)
            'guestOutputPath' = $Guest.GuestOutputPath
            'password'        = [string] $env:CLOAK_T3_GUEST_PASSWORD
        }
        $arguments = Expand-T3Arguments -Arguments $Guest.FetchCommand -Values $values
        $program = $arguments[0]
        $programArguments = @()
        if ($arguments.Count -gt 1) { $programArguments = $arguments[1..($arguments.Count - 1)] }

        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 0
        try {
            $output = & $program @programArguments 2>&1 |
                ForEach-Object { "$_" } |
                Out-String
        }
        finally {
            $ErrorActionPreference = $oldEap
        }
        $fetchExit = $LASTEXITCODE

        "attempt $attempt : exit=$fetchExit" | Set-Content -LiteralPath $LogPath -Encoding utf8
        $output | Add-Content -LiteralPath $LogPath -Encoding utf8

        if ($fetchExit -eq 0 -and (Test-Path -LiteralPath $LocalPath) -and (Test-T3GuestDocument -Path $LocalPath)) {
            Write-Step "Guest '$($Guest.Name)': collector output captured (attempt $attempt)."
            return
        }

        if ((Get-Date) -ge $deadline) {
            throw "guest '$($Guest.Name)': collector output not available after $($Guest.WaitSeconds)s (last fetch exit=$fetchExit)."
        }
        Start-Sleep -Seconds 10
    }
}

# ---------------------------------------------------------------------------
# Saved state / snapshot tests (§4.6.5)
# ---------------------------------------------------------------------------
function Get-T3VmState {
    param([string] $Name)

    $info = Invoke-T3VBoxManage 'showvminfo' $Name '--machinereadable'
    if ($info -match '(?m)^VMState="([^"]+)"') { return $Matches[1] }
    return ''
}

function Wait-T3VmState {
    param(
        [string] $Name,
        [string[]] $States,
        [int] $TimeoutSeconds = 180
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $state = Get-T3VmState -Name $Name
        if ($States -contains $state) { return $true }
        if ($state -in @('poweroff', 'aborted', 'stopped') -and -not ($States -contains $state)) {
            return $false
        }
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 2
    }
}

function Get-T3ExtraData {
    param(
        [string] $Name,
        [string] $Key
    )

    $raw = Invoke-T3VBoxManage 'getextradata' $Name $Key
    if ($raw -match '(?m)^Value:\s*(.+?)\s*$') { return $Matches[1] }
    return ''
}

function Set-T3ExtraData {
    param(
        [string] $Name,
        [string] $Key,
        [string] $Value
    )

    if ([string]::IsNullOrEmpty($Value)) {
        $null = Invoke-T3VBoxManage 'setextradata' $Name $Key
    }
    else {
        $null = Invoke-T3VBoxManage 'setextradata' $Name $Key $Value
    }
    if ($LASTEXITCODE -ne 0) {
        throw "setextradata '$Key' failed (exit $LASTEXITCODE)."
    }
}

function Get-T3MutatedHex {
    param([string] $Hex)

    if ($Hex -notmatch '^[0-9a-fA-F]{64}$') { return '' }
    $normalized = $Hex.ToLowerInvariant()
    $first = '1'
    if ($normalized.Substring(0, 1) -eq '1') { $first = '0' }
    return $first + $normalized.Substring(1)
}

function Get-T3MutatedSeedValue {
    param([string] $Value)

    if ($Value -notmatch '^string:([0-9a-fA-F]{64})$') { return '' }
    $mutated = Get-T3MutatedHex -Hex $Matches[1]
    if ([string]::IsNullOrEmpty($mutated)) { return '' }
    return 'string:' + $mutated
}

function Clear-T3VmState {
    param([string] $Name)

    $state = Get-T3VmState -Name $Name
    if ($state -in @('running', 'paused', 'gurumeditation')) {
        $null = Invoke-T3VBoxManage 'controlvm' $Name 'poweroff'
        Start-Sleep -Seconds 5
        $state = Get-T3VmState -Name $Name
    }
    if ($state -eq 'saved' -or $state -eq 'aborted') {
        $null = Invoke-T3VBoxManage 'discardstate' $Name
        Start-Sleep -Seconds 3
    }
}

function Invoke-T3RunningCapture {
    param(
        $Guest,
        [string] $RunDir
    )

    $null = New-Item -ItemType Directory -Force -Path $RunDir

    $null = Invoke-T3VBoxManage 'showvminfo' $Guest.Name '--machinereadable' |
        Set-Content -LiteralPath (Join-Path $RunDir 'vminfo.txt') -Encoding utf8

    foreach ($item in $script:T3InfoItems) {
        $arguments = @('debugvm', $Guest.Name, 'info', $item)
        if ($item -eq 'pci') { $arguments += 'verbose' }
        $text = Invoke-T3VBoxManage @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "debugvm info $item failed (exit $LASTEXITCODE): $text"
        }
        $text | Set-Content -LiteralPath (Join-Path $RunDir "info-$item.txt") -Encoding utf8
    }

    Invoke-T3GuestFetch -Guest $Guest -LocalPath (Join-Path $RunDir 'guest-identity.json') -LogPath (Join-Path $RunDir 'guest-fetch.txt')
}

function New-T3StateResult {
    param(
        [string] $Status,
        [string] $Detail
    )

    return [pscustomobject] @{
        status = $Status
        detail = $Detail
    }
}

function Invoke-T3SeedMismatchProbe {
    param(
        [string] $Name,
        $Config
    )

    $startOutput = Invoke-T3VBoxManage 'startvm' $Name '--type' 'headless'
    $startExit = $LASTEXITCODE
    if ($startExit -ne 0) {
        return New-T3StateResult 'pass' "startvm refused (exit $startExit)"
    }

    $deadline = (Get-Date).AddSeconds($Config.BootTimeoutSeconds)
    $finalState = ''
    while ((Get-Date) -lt $deadline) {
        $state = Get-T3VmState -Name $Name
        if ($state -eq 'running') { $finalState = 'running'; break }
        if ($state -in @('poweroff', 'aborted', 'stopped')) { $finalState = $state; break }
        Start-Sleep -Seconds 2
    }

    if ($finalState -eq 'running') {
        $null = Invoke-T3VBoxManage 'controlvm' $Name 'poweroff'
        Start-Sleep -Seconds 5
        return New-T3StateResult 'fail' 'VM resumed with mismatched seed (identity would be mixed)'
    }
    if ($finalState -in @('poweroff', 'aborted', 'stopped')) {
        return New-T3StateResult 'pass' "VM refused to reach running (state=$finalState)"
    }
    return New-T3StateResult 'error' "VM state ambiguous after seed mismatch (state='$finalState')"
}

function Compare-T3StateCapture {
    param(
        $Guest,
        [string] $BaselineDir,
        [string] $StateDir,
        [string] $ComparatorPath
    )

    $hostComparison = Compare-T3HostRun -BaselineDir $BaselineDir -CandidateDir $StateDir
    if ($hostComparison.Status -eq 'error') {
        return [pscustomobject] @{
            Status = 'error'
            Detail = 'host capture incomplete: ' + ($hostComparison.Errors -join ',')
        }
    }
    if ($hostComparison.Status -eq 'fail') {
        return [pscustomobject] @{
            Status = 'fail'
            Detail = 'host diffs: ' + ($hostComparison.Diffs -join ',')
        }
    }

    $comparison = Invoke-T3GuestComparison -ComparatorPath $ComparatorPath `
        -BaselinePath (Join-Path $BaselineDir 'guest-identity.json') `
        -CandidatePath (Join-Path $StateDir 'guest-identity.json') `
        -ReportPath (Join-Path $StateDir 'guest-compare.json')

    if ($comparison.ExitCode -eq 1) {
        return [pscustomobject] @{
            Status = 'fail'
            Detail = 'guest diffs: ' + ($comparison.Differences -join ',')
        }
    }
    if ($comparison.ExitCode -ne 0) {
        return [pscustomobject] @{
            Status = 'error'
            Detail = "comparator exit $($comparison.ExitCode)"
        }
    }
    return [pscustomobject] @{
        Status = 'pass'
        Detail = 'identity identical to baseline'
    }
}

function Invoke-T3StateTests {
    param(
        $Guest,
        $Config,
        [string] $ComparatorPath,
        [string] $BaselineDir,
        [string] $StateRoot
    )

    $results = [ordered] @{}
    $seedKey = 'VBoxInternal/Cloak/Seed'
    $seedHashKey = 'VBoxInternal/Cloak/SeedHash'
    $snapshotName = $Config.SnapshotName

    if ($Config.StateTests.SaveStateRestore) {
        $dir = Join-Path $StateRoot 'save-restore'
        $status = 'error'
        $detail = ''
        try {
            Clear-T3VmState -Name $Guest.Name
            $startOutput = Invoke-T3VBoxManage 'startvm' $Guest.Name '--type' 'headless'
            if ($LASTEXITCODE -ne 0) { throw "startvm failed (exit $LASTEXITCODE): $startOutput" }
            if (-not (Wait-T3VmRunning -Name $Guest.Name -TimeoutSeconds $Config.BootTimeoutSeconds)) {
                throw 'VM did not reach running.'
            }
            Start-Sleep -Seconds $Config.CaptureDelaySeconds

            $null = Invoke-T3VBoxManage 'controlvm' $Guest.Name 'savestate'
            if (-not (Wait-T3VmState -Name $Guest.Name -States @('saved') -TimeoutSeconds 180)) {
                throw 'VM did not reach saved state.'
            }
            Start-Sleep -Seconds 3

            $startOutput = Invoke-T3VBoxManage 'startvm' $Guest.Name '--type' 'headless'
            if ($LASTEXITCODE -ne 0) { throw "resume failed (exit $LASTEXITCODE): $startOutput" }
            if (-not (Wait-T3VmRunning -Name $Guest.Name -TimeoutSeconds $Config.BootTimeoutSeconds)) {
                throw 'VM did not resume to running.'
            }
            Start-Sleep -Seconds $Config.CaptureDelaySeconds

            Invoke-T3RunningCapture -Guest $Guest -RunDir $dir
            $status = 'pass'
            $detail = 'resumed capture written'
        }
        catch {
            $status = 'error'
            $detail = $_.Exception.Message
        }
        finally {
            Clear-T3VmState -Name $Guest.Name
        }

        if ($status -eq 'pass') {
            $comparison = Compare-T3StateCapture -Guest $Guest -BaselineDir $BaselineDir -StateDir $dir -ComparatorPath $ComparatorPath
            $status = $comparison.Status
            $detail = $comparison.Detail
        }
        $results['saveStateRestore'] = New-T3StateResult $status $detail
    }

    if ($Config.StateTests.SaveStateSeedMismatch) {
        $status = 'error'
        $detail = ''
        $seedRaw = ''
        $seedHashRaw = ''
        try {
            Clear-T3VmState -Name $Guest.Name
            $seedRaw = Get-T3ExtraData -Name $Guest.Name -Key $seedKey
            $seedHashRaw = Get-T3ExtraData -Name $Guest.Name -Key $seedHashKey
            if ([string]::IsNullOrEmpty($seedRaw) -or [string]::IsNullOrEmpty($seedHashRaw)) {
                throw "seed not provisioned ('$seedKey'/'$seedHashKey' missing); run provision-cloak.ps1 first."
            }
            $mutatedSeed = Get-T3MutatedSeedValue -Value $seedRaw
            $mutatedHash = Get-T3MutatedHex -Hex $seedHashRaw
            if ([string]::IsNullOrEmpty($mutatedSeed) -or [string]::IsNullOrEmpty($mutatedHash)) {
                throw "unrecognized seed/seed-hash format ('$seedRaw' / '$seedHashRaw')."
            }

            $startOutput = Invoke-T3VBoxManage 'startvm' $Guest.Name '--type' 'headless'
            if ($LASTEXITCODE -ne 0) { throw "startvm failed (exit $LASTEXITCODE): $startOutput" }
            if (-not (Wait-T3VmRunning -Name $Guest.Name -TimeoutSeconds $Config.BootTimeoutSeconds)) {
                throw 'VM did not reach running.'
            }
            Start-Sleep -Seconds $Config.CaptureDelaySeconds

            $null = Invoke-T3VBoxManage 'controlvm' $Guest.Name 'savestate'
            if (-not (Wait-T3VmState -Name $Guest.Name -States @('saved') -TimeoutSeconds 180)) {
                throw 'VM did not reach saved state.'
            }
            Start-Sleep -Seconds 3

            Set-T3ExtraData -Name $Guest.Name -Key $seedKey -Value $mutatedSeed
            Set-T3ExtraData -Name $Guest.Name -Key $seedHashKey -Value $mutatedHash

            $probe = Invoke-T3SeedMismatchProbe -Name $Guest.Name -Config $Config
            $status = $probe.status
            $detail = $probe.detail
        }
        catch {
            $status = 'error'
            $detail = $_.Exception.Message
        }
        finally {
            if (-not [string]::IsNullOrEmpty($seedRaw)) {
                try { Set-T3ExtraData -Name $Guest.Name -Key $seedKey -Value $seedRaw } catch { }
            }
            if (-not [string]::IsNullOrEmpty($seedHashRaw)) {
                try { Set-T3ExtraData -Name $Guest.Name -Key $seedHashKey -Value $seedHashRaw } catch { }
            }
            Clear-T3VmState -Name $Guest.Name
        }
        $results['saveStateSeedMismatch'] = New-T3StateResult $status $detail
    }

    if ($Config.StateTests.SnapshotRestore) {
        $dir = Join-Path $StateRoot 'snapshot-restore'
        $status = 'error'
        $detail = ''
        try {
            Clear-T3VmState -Name $Guest.Name
            $null = Invoke-T3VBoxManage 'snapshot' $Guest.Name 'take' $snapshotName '--description' 't3 state test'
            if ($LASTEXITCODE -ne 0) { throw "snapshot take failed (exit $LASTEXITCODE)." }

            $startOutput = Invoke-T3VBoxManage 'startvm' $Guest.Name '--type' 'headless'
            if ($LASTEXITCODE -ne 0) { throw "startvm failed (exit $LASTEXITCODE): $startOutput" }
            if (-not (Wait-T3VmRunning -Name $Guest.Name -TimeoutSeconds $Config.BootTimeoutSeconds)) {
                throw 'VM did not reach running.'
            }
            Start-Sleep -Seconds $Config.CaptureDelaySeconds

            $null = Invoke-T3VBoxManage 'controlvm' $Guest.Name 'poweroff'
            Start-Sleep -Seconds 5

            $null = Invoke-T3VBoxManage 'snapshot' $Guest.Name 'restore' $snapshotName
            if ($LASTEXITCODE -ne 0) { throw "snapshot restore failed (exit $LASTEXITCODE)." }

            $startOutput = Invoke-T3VBoxManage 'startvm' $Guest.Name '--type' 'headless'
            if ($LASTEXITCODE -ne 0) { throw "startvm after restore failed (exit $LASTEXITCODE): $startOutput" }
            if (-not (Wait-T3VmRunning -Name $Guest.Name -TimeoutSeconds $Config.BootTimeoutSeconds)) {
                throw 'VM did not reach running after restore.'
            }
            Start-Sleep -Seconds $Config.CaptureDelaySeconds

            Invoke-T3RunningCapture -Guest $Guest -RunDir $dir
            $status = 'pass'
            $detail = 'restored capture written'
        }
        catch {
            $status = 'error'
            $detail = $_.Exception.Message
        }
        finally {
            Clear-T3VmState -Name $Guest.Name
            $null = Invoke-T3VBoxManage 'snapshot' $Guest.Name 'delete' $snapshotName
        }

        if ($status -eq 'pass') {
            $comparison = Compare-T3StateCapture -Guest $Guest -BaselineDir $BaselineDir -StateDir $dir -ComparatorPath $ComparatorPath
            $status = $comparison.Status
            $detail = $comparison.Detail
        }
        $results['snapshotRestore'] = New-T3StateResult $status $detail
    }

    if ($Config.StateTests.SnapshotSeedMismatch) {
        $status = 'error'
        $detail = ''
        $seedRaw = ''
        $seedHashRaw = ''
        try {
            Clear-T3VmState -Name $Guest.Name
            $seedRaw = Get-T3ExtraData -Name $Guest.Name -Key $seedKey
            $seedHashRaw = Get-T3ExtraData -Name $Guest.Name -Key $seedHashKey
            if ([string]::IsNullOrEmpty($seedRaw) -or [string]::IsNullOrEmpty($seedHashRaw)) {
                throw "seed not provisioned ('$seedKey'/'$seedHashKey' missing); run provision-cloak.ps1 first."
            }
            $mutatedSeed = Get-T3MutatedSeedValue -Value $seedRaw
            $mutatedHash = Get-T3MutatedHex -Hex $seedHashRaw
            if ([string]::IsNullOrEmpty($mutatedSeed) -or [string]::IsNullOrEmpty($mutatedHash)) {
                throw "unrecognized seed/seed-hash format ('$seedRaw' / '$seedHashRaw')."
            }

            $null = Invoke-T3VBoxManage 'snapshot' $Guest.Name 'take' $snapshotName '--description' 't3 state test'
            if ($LASTEXITCODE -ne 0) { throw "snapshot take failed (exit $LASTEXITCODE)." }

            Set-T3ExtraData -Name $Guest.Name -Key $seedKey -Value $mutatedSeed
            Set-T3ExtraData -Name $Guest.Name -Key $seedHashKey -Value $mutatedHash

            $restoreOutput = Invoke-T3VBoxManage 'snapshot' $Guest.Name 'restore' $snapshotName
            if ($LASTEXITCODE -ne 0) {
                $status = 'pass'
                $detail = "snapshot restore refused (exit $LASTEXITCODE)"
            }
            else {
                $probe = Invoke-T3SeedMismatchProbe -Name $Guest.Name -Config $Config
                $status = $probe.status
                $detail = 'after restore: ' + $probe.detail
            }
        }
        catch {
            $status = 'error'
            $detail = $_.Exception.Message
        }
        finally {
            if (-not [string]::IsNullOrEmpty($seedRaw)) {
                try { Set-T3ExtraData -Name $Guest.Name -Key $seedKey -Value $seedRaw } catch { }
            }
            if (-not [string]::IsNullOrEmpty($seedHashRaw)) {
                try { Set-T3ExtraData -Name $Guest.Name -Key $seedHashKey -Value $seedHashRaw } catch { }
            }
            Clear-T3VmState -Name $Guest.Name
            $null = Invoke-T3VBoxManage 'snapshot' $Guest.Name 'delete' $snapshotName
        }
        $results['snapshotSeedMismatch'] = New-T3StateResult $status $detail
    }

    return [pscustomobject] $results
}

# ---------------------------------------------------------------------------
# So sanh
# ---------------------------------------------------------------------------
function Compare-T3HostRun {
    param(
        [string] $BaselineDir,
        [string] $CandidateDir
    )

    $diffs = [System.Collections.Generic.List[string]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    foreach ($item in $script:T3InfoItems) {
        $baseline = Join-Path $BaselineDir "info-$item.txt"
        $candidate = Join-Path $CandidateDir "info-$item.txt"
        if (-not (Test-Path -LiteralPath $baseline) -or -not (Test-Path -LiteralPath $candidate)) {
            $errors.Add($item)
            continue
        }
        $baselineText = Get-Content -LiteralPath $baseline -Raw -Encoding UTF8
        $candidateText = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8
        if ((Get-T3TextFingerprint $baselineText) -cne (Get-T3TextFingerprint $candidateText)) {
            $diffs.Add($item)
        }
    }

    $status = 'pass'
    if ($errors.Count -gt 0) { $status = 'error' }
    elseif ($diffs.Count -gt 0) { $status = 'fail' }

    return [pscustomobject] @{
        Status = $status
        Diffs  = $diffs.ToArray()
        Errors = $errors.ToArray()
    }
}

function Get-T3ComparatorHost {
    $candidate = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    return 'powershell.exe'
}

function Invoke-T3GuestComparison {
    param(
        [string] $ComparatorPath,
        [string] $BaselinePath,
        [string] $CandidatePath,
        [string] $ReportPath
    )

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        $output = & (Get-T3ComparatorHost) -NoProfile -ExecutionPolicy Bypass -File $ComparatorPath `
            -Reference $BaselinePath -Candidate $CandidatePath -ReportPath $ReportPath 2>&1 |
            ForEach-Object { "$_" } |
            Out-String
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    $exitCode = $LASTEXITCODE

    $differences = 0
    $volatile = 0
    if (Test-Path -LiteralPath $ReportPath) {
        try {
            $report = (Get-Content -LiteralPath $ReportPath -Raw -Encoding UTF8) | ConvertFrom-Json
            $candidates = @(Get-T3Property -Object $report -Name 'candidates' -Default @())
            if ($candidates.Count -gt 0) {
                $differenceList = Get-T3Property -Object $candidates[0] -Name 'differences' -Default $null
                if ($null -ne $differenceList) { $differences = @($differenceList).Count }
                $volatileList = Get-T3Property -Object $candidates[0] -Name 'volatileDifferences' -Default $null
                if ($null -ne $volatileList) { $volatile = @($volatileList).Count }
            }
        }
        catch {
            # Report doc khong doc duoc -> coi nhu loi thuc thi ben duoi (exit != 0/1).
        }
    }

    return [pscustomobject] @{
        ExitCode    = $exitCode
        Differences = $differences
        Volatile    = $volatile
        Output      = $output
    }
}

# ---------------------------------------------------------------------------
# Report (redacted)
# ---------------------------------------------------------------------------
function Write-T3Report {
    param(
        [string] $Path,
        [string] $Status,
        $Guests,
        [int] $Runs
    )

    $document = [ordered] @{
        reportFormatVersion = 1
        tool                = 't3-runtime.ps1'
        version             = '1'
        timestamp           = (Get-Date).ToUniversalTime().ToString('o')
        runs                = $Runs
        status              = $Status
        guests              = @($Guests)
    }

    $json = ConvertTo-Json -InputObject $document -Depth 12
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $json, $encoding)
}

# ---------------------------------------------------------------------------
# Artifact redaction audit (0.4.5) - chi quet dung tap file se upload
# ---------------------------------------------------------------------------
function Get-T3ArtifactPaths {
    param([string] $Root)

    $paths = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Root)) { return $paths.ToArray() }
    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')

    $report = Join-Path $resolvedRoot 't3-report.json'
    if (Test-Path -LiteralPath $report) { $paths.Add($report) }

    foreach ($file in Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Filter 'guest-compare.json' -File -ErrorAction SilentlyContinue) {
        $relative = $file.FullName.Substring($resolvedRoot.Length).TrimStart('\')
        if ($relative -match '^run\d+\\[^\\]+\\guest-compare\.json$' -or
            $relative -match '^state\\[^\\]+\\[^\\]+\\guest-compare\.json$') {
            $paths.Add($file.FullName)
        }
    }
    return $paths.ToArray()
}

function Get-T3RedactionViolations {
    param([string] $Root)

    $rules = @(
        [pscustomobject] @{ Name = 'seed-or-sha256-hex'; Pattern = '(?i)\b[0-9a-f]{64}\b' }
        [pscustomobject] @{ Name = 'cloak-extradata-key'; Pattern = 'VBoxInternal/Cloak' }
        [pscustomobject] @{ Name = 'secret-marker'; Pattern = '(?i)(password\s*[:=]|-----BEGIN)' }
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    foreach ($path in Get-T3ArtifactPaths -Root $Root) {
        $text = ''
        try {
            $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        }
        catch {
            continue
        }
        foreach ($rule in $rules) {
            if ($text -match $rule.Pattern) {
                $violations.Add((Split-Path -Leaf $path) + ': ' + $rule.Name)
            }
        }
    }
    return $violations.ToArray()
}

# ---------------------------------------------------------------------------
# Self-test — khong can VM
# ---------------------------------------------------------------------------
function Assert-T3SelfTest {
    param(
        [string] $Name,
        [bool]   $Condition
    )

    if ($Condition) {
        Write-Host "PASS [$Name]"
    }
    else {
        Write-Host "FAIL [$Name]" -ForegroundColor Red
        $script:T3SelfTestFailed++
    }
}

function Invoke-T3SelfTest {
    $root = Join-Path $env:TEMP ("t3-selftest-" + $PID)
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $root -Force

    try {
        $guestJson = @'
{
  "schemaVersion": 1,
  "source": "guest-windows",
  "collector": { "tool": "collect-guest-identity.ps1", "version": "1", "timestamp": "TIMESTAMP" },
  "smbios": { "biosSerial": "0", "systemUuid": "9f2c1d40-7a51-4c62-9b8e-0d3a5e6f7c81" },
  "pci": { "devices": [ { "bdf": "00:02.0", "vendorId": "80ee", "deviceId": "beef" } ] }
}
'@

        foreach ($run in 1..3) {
            $runDir = Join-Path $root "run$run"
            $null = New-Item -ItemType Directory -Path $runDir -Force
            foreach ($item in $script:T3InfoItems) {
                $text = "item=$item`r`nvalue=80ee:beef`r`nbuffer=0xF0000000`r`ntime=timestamp 12:00:00"
                $text | Set-Content -LiteralPath (Join-Path $runDir "info-$item.txt") -Encoding utf8
            }
            ($guestJson -creplace 'TIMESTAMP', "2026-01-01T00:00:0$run Z") |
                Set-Content -LiteralPath (Join-Path $runDir 'guest-identity.json') -Encoding utf8
        }

        Write-Step 'Self-test: host fingerprint comparison'
        $hostPass = Compare-T3HostRun -BaselineDir (Join-Path $root 'run1') -CandidateDir (Join-Path $root 'run2')
        Assert-T3SelfTest -Name 'host text stable across runs' -Condition ($hostPass.Status -eq 'pass')

        $mutated = Get-Content -LiteralPath (Join-Path $root 'run2\info-pci.txt') -Raw -Encoding UTF8
        $mutated = $mutated -replace '80ee:beef', '80ee:beee'
        $mutated | Set-Content -LiteralPath (Join-Path $root 'run2\info-pci.txt') -Encoding utf8
        $hostFail = Compare-T3HostRun -BaselineDir (Join-Path $root 'run1') -CandidateDir (Join-Path $root 'run2')
        Assert-T3SelfTest -Name 'host pci change detected' -Condition ($hostFail.Status -eq 'fail' -and $hostFail.Diffs -contains 'pci')

        Write-Step 'Self-test: guest schema comparator integration'
        $comparator = Join-Path $PSScriptRoot 'compare-identity.ps1'
        Assert-T3SelfTest -Name 'comparator script exists' -Condition (Test-Path -LiteralPath $comparator)

        $matchReport = Join-Path $root 'match.compare.json'
        $match = Invoke-T3GuestComparison -ComparatorPath $comparator `
            -BaselinePath (Join-Path $root 'run1\guest-identity.json') `
            -CandidatePath (Join-Path $root 'run2\guest-identity.json') `
            -ReportPath $matchReport
        Assert-T3SelfTest -Name 'guest volatile-only change matches' -Condition ($match.ExitCode -eq 0 -and $match.Volatile -eq 1)

        $guestMutated = Get-Content -LiteralPath (Join-Path $root 'run3\guest-identity.json') -Raw -Encoding UTF8
        $guestMutated = $guestMutated -replace 'beef', 'bef0'
        $guestMutated | Set-Content -LiteralPath (Join-Path $root 'run3\guest-identity.json') -Encoding utf8
        $mismatchReport = Join-Path $root 'mismatch.compare.json'
        $mismatch = Invoke-T3GuestComparison -ComparatorPath $comparator `
            -BaselinePath (Join-Path $root 'run1\guest-identity.json') `
            -CandidatePath (Join-Path $root 'run3\guest-identity.json') `
            -ReportPath $mismatchReport
        Assert-T3SelfTest -Name 'guest device id change fails' -Condition ($mismatch.ExitCode -eq 1 -and $mismatch.Differences -ge 1)

        Write-Step 'Self-test: seed mutation helpers'
        $seedValue = 'string:' + '0' + ('a' * 63)
        $mutatedSeed = Get-T3MutatedSeedValue -Value $seedValue
        Assert-T3SelfTest -Name 'seed mutation flips first nibble' -Condition ($mutatedSeed -eq ('string:' + '1' + ('a' * 63)))
        Assert-T3SelfTest -Name 'seed mutation rejects malformed value' -Condition ((Get-T3MutatedSeedValue -Value 'nope') -eq '')
        $hashValue = '1' + ('b' * 63)
        $mutatedHash = Get-T3MutatedHex -Hex $hashValue
        Assert-T3SelfTest -Name 'hash mutation flips first nibble' -Condition ($mutatedHash -eq ('0' + ('b' * 63)))
        Assert-T3SelfTest -Name 'hash mutation rejects malformed value' -Condition ((Get-T3MutatedHex -Hex 'nothex') -eq '')

        Write-Step 'Self-test: report writing'
        $reportPath = Join-Path $root 't3-report.json'
        $guestReports = @(
            [pscustomobject] @{
                name = 'self-test-guest'
                platform = 'windows'
                status = 'pass'
                host = [pscustomobject] @{ status = 'pass'; diffs = @() }
                guest = @(
                    [pscustomobject] @{ run = 2; status = 'match'; differences = 0; volatile = 1; report = 'match.compare.json' }
                )
                state = [pscustomobject] @{
                    saveStateRestore = [pscustomobject] @{ status = 'pass'; detail = 'identity identical to baseline' }
                }
            }
        )
        Write-T3Report -Path $reportPath -Status 'pass' -Guests $guestReports -Runs 3
        $written = (Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8) | ConvertFrom-Json
        Assert-T3SelfTest -Name 'report is valid JSON with schema' -Condition ($written.reportFormatVersion -eq 1 -and $written.status -eq 'pass')
        Assert-T3SelfTest -Name 'report carries state test results' -Condition ($written.guests[0].state.saveStateRestore.status -eq 'pass')

        Write-Step 'Self-test: artifact redaction audit'
        $artifactRoot = Join-Path $root 'artifacts'
        $artifactRunDir = Join-Path $artifactRoot 'run1\self-test-guest'
        $null = New-Item -ItemType Directory -Force -Path $artifactRunDir
        $artifactFile = Join-Path $artifactRunDir 'guest-compare.json'
        Set-Content -LiteralPath $artifactFile -Value '{"reportFormatVersion":1,"status":"pass"}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $artifactRoot 't3-report.json') -Value '{"reportFormatVersion":1}' -Encoding utf8
        Assert-T3SelfTest -Name 'redaction audit accepts clean artifacts' -Condition ((@(Get-T3RedactionViolations -Root $artifactRoot)).Count -eq 0)
        Set-Content -LiteralPath $artifactFile -Value ('{"seed":"' + ('a' * 64) + '"}') -Encoding utf8
        Assert-T3SelfTest -Name 'redaction audit flags 64-hex token' -Condition ((@(Get-T3RedactionViolations -Root $artifactRoot)).Count -ge 1)
        Set-Content -LiteralPath $artifactFile -Value '{"note":"VBoxInternal/Cloak/SeedHash"}' -Encoding utf8
        Assert-T3SelfTest -Name 'redaction audit flags Cloak extradata key' -Condition ((@(Get-T3RedactionViolations -Root $artifactRoot)).Count -ge 1)
        Set-Content -LiteralPath $artifactFile -Value '{"reportFormatVersion":1}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $artifactRoot 'guest-identity.json') -Value ('{"serial":"' + ('a' * 64) + '"}') -Encoding utf8
        Assert-T3SelfTest -Name 'redaction audit ignores non-artifact names' -Condition ((@(Get-T3RedactionViolations -Root $artifactRoot)).Count -eq 0)
    }
    finally {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if ($script:T3SelfTestFailed -gt 0) {
        Write-Host "T3 self-test failed: $($script:T3SelfTestFailed) case(s)." -ForegroundColor Red
        exit 2
    }
    Write-Host 'T3 self-test passed'
    exit 0
}

if ($SelfTest) {
    Invoke-T3SelfTest
}

if ($ValidateConfig) {
    if (-not $ConfigPath) { Write-ErrorLine 'ValidateConfig requires ConfigPath.'; exit 2 }
    $validated = Read-T3Config -Path $ConfigPath
    Write-Step "Config OK: runs=$($validated.Runs)"
    foreach ($guest in $validated.Guests) {
        Write-Host "  guest=$($guest.Name) platform=$($guest.Platform) waitSeconds=$($guest.WaitSeconds)"
    }
    if ($validated.UsesPassword -and -not $env:CLOAK_T3_GUEST_PASSWORD) {
        Write-Host '  WARNING: config uses {password} but CLOAK_T3_GUEST_PASSWORD is not set in this environment.' -ForegroundColor Yellow
    }
    exit 0
}

if ($AuditArtifacts) {
    if (-not $WorkDir) { Write-ErrorLine 'AuditArtifacts requires WorkDir.'; exit 2 }
    $artifactPaths = @(Get-T3ArtifactPaths -Root $WorkDir)
    Write-Step "Artifact redaction audit: $($artifactPaths.Count) file(s) in $WorkDir"
    foreach ($artifactPath in $artifactPaths) { Write-Host "  $artifactPath" }
    $auditViolations = @(Get-T3RedactionViolations -Root $WorkDir)
    if ($auditViolations.Count -gt 0) {
        foreach ($auditViolation in $auditViolations) {
            Write-ErrorLine "artifact redaction violation: $auditViolation"
        }
        exit 2
    }
    Write-Host 'T3 artifacts clean.'
    exit 0
}

if ($CheckRuntime) {
    if (-not $VBoxDir) { Write-ErrorLine 'CheckRuntime requires VBoxDir.'; exit 2 }
    $script:T3VBoxManage = Join-Path $VBoxDir 'VBoxManage.exe'
    if (-not (Test-Path -LiteralPath $script:T3VBoxManage)) {
        Write-ErrorLine "VBoxManage.exe not found: $($script:T3VBoxManage)"
        exit 2
    }

    $versionOutput = Invoke-T3VBoxManage '--version'
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorLine "VBoxManage --version failed (exit $LASTEXITCODE): $versionOutput"
        exit 2
    }
    Write-Step "VBoxManage version: $($versionOutput.Trim())"

    Assert-T3RuntimeAvailable

    if ($ConfigPath) {
        $checkConfig = Read-T3Config -Path $ConfigPath
        $checkVmList = Invoke-T3VBoxManage 'list' 'vms'
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorLine "VBoxManage list vms failed (exit $LASTEXITCODE): $checkVmList"
            exit 2
        }
        $checkNeedsSeed = $checkConfig.StateTest -and ($checkConfig.StateTests.SaveStateSeedMismatch -or $checkConfig.StateTests.SnapshotSeedMismatch)
        foreach ($checkGuest in $checkConfig.Guests) {
            $quotedName = '"' + $checkGuest.Name + '"'
            if ($checkVmList -notmatch [regex]::Escape($quotedName)) {
                Write-ErrorLine "VM '$($checkGuest.Name)' is not registered on this runner."
                exit 2
            }

            $checkSeedRaw = Get-T3ExtraData -Name $checkGuest.Name -Key 'VBoxInternal/Cloak/Seed'
            $checkHashRaw = Get-T3ExtraData -Name $checkGuest.Name -Key 'VBoxInternal/Cloak/SeedHash'
            $checkProfileRaw = Get-T3ExtraData -Name $checkGuest.Name -Key 'VBoxInternal/Cloak/Profile'

            $checkSeedHex = ''
            if ($checkSeedRaw -match '^string:([0-9a-fA-F]{64})$') { $checkSeedHex = $Matches[1].ToLowerInvariant() }
            $checkHashStored = ''
            if ($checkHashRaw -match '^([0-9a-fA-F]{64})$') { $checkHashStored = $Matches[1].ToUpperInvariant() }

            $seedStatus = 'missing'
            if ($checkSeedHex) { $seedStatus = 'ok' }
            elseif ($checkSeedRaw) { $seedStatus = 'invalid' }

            $hashStatus = 'missing'
            if ($checkSeedHex -and $checkHashStored) {
                $checkBytes = New-Object byte[] 32
                for ($i = 0; $i -lt $checkBytes.Length; $i++) {
                    $checkBytes[$i] = [System.Convert]::ToByte($checkSeedHex.Substring($i * 2, 2), 16)
                }
                $sha = [System.Security.Cryptography.SHA256]::Create()
                try {
                    $checkComputed = ([BitConverter]::ToString($sha.ComputeHash($checkBytes))).Replace('-', '')
                }
                finally {
                    $sha.Dispose()
                    [System.Array]::Clear($checkBytes, 0, $checkBytes.Length)
                }
                if ($checkHashStored -eq $checkComputed) { $hashStatus = 'matches' } else { $hashStatus = 'MISMATCH' }
            }
            elseif ($checkHashRaw) { $hashStatus = 'invalid' }

            $profileStatus = 'unset'
            if ($checkProfileRaw) { $profileStatus = $checkProfileRaw }

            Write-Host "  guest=$($checkGuest.Name) vm=registered seed=$seedStatus seedHash=$hashStatus profile=$profileStatus"

            if ($hashStatus -eq 'MISMATCH' -or $hashStatus -eq 'invalid') {
                Write-ErrorLine "guest '$($checkGuest.Name)': stored seed hash does not match the seed; re-provision with provision-cloak.ps1 -Force."
                exit 2
            }
            if ($checkNeedsSeed -and -not $checkSeedHex) {
                Write-ErrorLine "guest '$($checkGuest.Name)': stateTest negative tests need a provisioned seed; run provision-cloak.ps1 first."
                exit 2
            }
        }
    }

    Write-Step 'Runner is ready for T3.'
    exit 0
}

# ---------------------------------------------------------------------------
# Main — T3 that
# ---------------------------------------------------------------------------
if (-not $VBoxDir)    { Write-ErrorLine 'VBoxDir is required.';    exit 2 }
if (-not $WorkDir)    { Write-ErrorLine 'WorkDir is required.';    exit 2 }
if (-not $ConfigPath) { Write-ErrorLine 'ConfigPath is required.'; exit 2 }

$script:T3VBoxManage = Join-Path $VBoxDir 'VBoxManage.exe'
if (-not (Test-Path -LiteralPath $script:T3VBoxManage)) {
    Write-ErrorLine "VBoxManage.exe not found: $($script:T3VBoxManage)"
    exit 2
}

$config = Read-T3Config -Path $ConfigPath
if ($config.UsesPassword -and -not $env:CLOAK_T3_GUEST_PASSWORD) {
    Write-ErrorLine 'config uses {password} but CLOAK_T3_GUEST_PASSWORD is not set.'
    exit 2
}

$comparatorPath = Join-Path $PSScriptRoot 'compare-identity.ps1'
if (-not (Test-Path -LiteralPath $comparatorPath)) {
    Write-ErrorLine "compare-identity.ps1 not found: $comparatorPath"
    exit 2
}

Write-Step 'T3 preflight'
Assert-T3RuntimeAvailable

$vmList = Invoke-T3VBoxManage 'list' 'vms'
foreach ($guest in $config.Guests) {
    $quotedName = '"' + $guest.Name + '"'
    if ($vmList -notmatch [regex]::Escape($quotedName)) {
        Write-ErrorLine "VM '$($guest.Name)' is not registered on this runner."
        exit 2
    }
}

$null = New-Item -ItemType Directory -Force -Path $WorkDir

$guestReports = [System.Collections.Generic.List[object]]::new()
$anyMismatch = $false
$anyError = $false
$exitCode = 0

foreach ($guest in $config.Guests) {
    Write-Step "Guest '$($guest.Name)' ($($guest.Platform)): $($config.Runs) boot"

    $capturedRuns = 0
    $guestError = ''
    for ($run = 1; $run -le $config.Runs; $run++) {
        $runDir = Join-Path $WorkDir (Join-Path "run$run" $guest.Name)
        $null = New-Item -ItemType Directory -Force -Path $runDir

        Write-Step "Boot $run/$($config.Runs) - $($guest.Name)"
        $started = $false
        $runError = $null
        try {
            $startOutput = Invoke-T3VBoxManage 'startvm' $guest.Name '--type' 'headless'
            if ($LASTEXITCODE -ne 0) {
                throw "startvm failed (exit $LASTEXITCODE): $startOutput"
            }
            $started = $true

            if (-not (Wait-T3VmRunning -Name $guest.Name -TimeoutSeconds $config.BootTimeoutSeconds)) {
                throw "VM '$($guest.Name)' did not reach the 'running' state."
            }

            Start-Sleep -Seconds $config.CaptureDelaySeconds

            Invoke-T3RunningCapture -Guest $guest -RunDir $runDir
            $capturedRuns++
        }
        catch {
            $runError = $_
        }
        finally {
            if ($started) {
                Write-Step "Powering off '$($guest.Name)'"
                $null = Invoke-T3VBoxManage 'controlvm' $guest.Name 'poweroff'
                Start-Sleep -Seconds 5
            }
        }

        if ($null -ne $runError) {
            $message = "$($runError.Exception.Message)"
            if ($message -match 'VERR_VM_DRIVER_NOT_INSTALLED') {
                Write-ErrorLine "RUNTIME_TARGET_UNAVAILABLE: $message"
                exit 3
            }
            $guestError = "run $run : $message"
            Write-ErrorLine "guest '$($guest.Name)' $guestError"
            break
        }
    }

    $guestStatus = 'pass'
    $hostReport = [pscustomobject] @{ status = 'skipped'; diffs = @() }
    $guestReportList = [System.Collections.Generic.List[object]]::new()

    if ($guestError) {
        $guestStatus = 'error'
        $anyError = $true
    }
    elseif ($capturedRuns -lt $config.Runs) {
        $guestStatus = 'error'
        $anyError = $true
        $guestError = "only $capturedRuns/$($config.Runs) boot captured"
    }
    else {
        for ($run = 2; $run -le $config.Runs; $run++) {
            $baselineDir = Join-Path $WorkDir (Join-Path 'run1' $guest.Name)
            $candidateDir = Join-Path $WorkDir (Join-Path "run$run" $guest.Name)

            $hostComparison = Compare-T3HostRun -BaselineDir $baselineDir -CandidateDir $candidateDir
            if ($hostComparison.Status -ne 'pass') {
                $guestStatus = 'fail'
                $anyMismatch = $true
            }
            if ($hostComparison.Status -eq 'error') {
                $anyError = $true
            }
            $hostReport = [pscustomobject] @{
                status = $hostComparison.Status
                diffs  = @($hostComparison.Diffs)
                errors = @($hostComparison.Errors)
            }

            $comparisonReport = Join-Path $candidateDir 'guest-compare.json'
            $comparison = Invoke-T3GuestComparison -ComparatorPath $comparatorPath `
                -BaselinePath (Join-Path $baselineDir 'guest-identity.json') `
                -CandidatePath (Join-Path $candidateDir 'guest-identity.json') `
                -ReportPath $comparisonReport

            $comparisonStatus = 'match'
            if ($comparison.ExitCode -eq 1) {
                $comparisonStatus = 'mismatch'
                $guestStatus = 'fail'
                $anyMismatch = $true
            }
            elseif ($comparison.ExitCode -ne 0) {
                $comparisonStatus = 'error'
                $guestStatus = 'error'
                $anyError = $true
            }

            $guestReportList.Add([pscustomobject] @{
                run         = $run
                status      = $comparisonStatus
                differences = $comparison.Differences
                volatile    = $comparison.Volatile
                report      = "run$run/$($guest.Name)/guest-compare.json"
            })
        }
    }

    $stateReport = $null
    if ($config.StateTest -and -not $guestError -and $capturedRuns -eq $config.Runs) {
        Write-Step "State tests (saved-state/snapshot) - $($guest.Name)"
        $stateReport = Invoke-T3StateTests -Guest $guest -Config $config -ComparatorPath $comparatorPath `
            -BaselineDir (Join-Path $WorkDir (Join-Path 'run1' $guest.Name)) `
            -StateRoot (Join-Path $WorkDir (Join-Path 'state' $guest.Name))
        foreach ($property in $stateReport.PSObject.Properties) {
            $testStatus = $property.Value.status
            Write-Host "    $($property.Name): $testStatus - $($property.Value.detail)"
            if ($testStatus -eq 'fail') {
                $guestStatus = 'fail'
                $anyMismatch = $true
            }
            elseif ($testStatus -eq 'error') {
                $guestStatus = 'error'
                $anyError = $true
            }
        }
    }

    $guestReports.Add([pscustomobject] @{
        name     = $guest.Name
        platform = $guest.Platform
        status   = $guestStatus
        error    = $guestError
        host     = $hostReport
        guest    = $guestReportList.ToArray()
        state    = $stateReport
    })
}

$overallStatus = 'pass'
if ($anyError)         { $overallStatus = 'error'; $exitCode = 2 }
elseif ($anyMismatch)  { $overallStatus = 'fail';  $exitCode = 1 }

$reportPath = Join-Path $WorkDir 't3-report.json'
Write-T3Report -Path $reportPath -Status $overallStatus -Guests $guestReports.ToArray() -Runs $config.Runs
Write-Step "Report: $reportPath (status=$overallStatus)"

$artifactViolations = @(Get-T3RedactionViolations -Root $WorkDir)
if ($artifactViolations.Count -gt 0) {
    foreach ($artifactViolation in $artifactViolations) {
        Write-ErrorLine "artifact redaction violation: $artifactViolation"
    }
    Write-ErrorLine 'Refusing to publish T3 artifacts: redaction audit failed.'
    exit 2
}

foreach ($guestReport in $guestReports) {
    Write-Host "  guest=$($guestReport.name) status=$($guestReport.status) host=$($guestReport.host.status)"
}

if ($exitCode -ne 0) {
    Write-ErrorLine "T3 identity verification failed (status=$overallStatus)."
    exit $exitCode
}
Write-Step 'T3 identity is stable across all boots.'
exit 0
