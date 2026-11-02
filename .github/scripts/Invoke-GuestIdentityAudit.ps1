<#
.SYNOPSIS
    Kiem thu identity Windows guest qua hai lan cold boot; khong sua identity.
.DESCRIPTION
    Chay script NAY ben trong Windows VM (guest), khong phai Windows host.
    Phase Baseline: luu boot1.json. Phase Verify: luu boot2.json va so sanh.
    Thu thap SMBIOS, CPU/WMI, PCI, ACPI, GPU, storage, NIC, EDID, TPM.
    Phan CPUID leaf va bit hypervisor phai kiem bang tool rieng.
    JSON co the chua serial, MAC va hardware identifiers; khong upload cong khai.
.EXAMPLE
    .\Invoke-GuestIdentityAudit.ps1 -Phase Baseline -ExpectedVendor LabVendor -ExpectedProduct LabDesktop-01
    # Shut down VM completely and start it again.
    .\Invoke-GuestIdentityAudit.ps1 -Phase Verify -ExpectedVendor LabVendor -ExpectedProduct LabDesktop-01
#>
[CmdletBinding()]
param(
    [ValidateSet('Baseline', 'Verify', 'SelfTest')]
    [string] $Phase = 'Baseline',

    [string] $OutputDir = (Join-Path $env:USERPROFILE 'IdentityAudit'),

    [string] $ExpectedVendor = '',

    [string] $ExpectedProduct = '',

    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-AuditDocument {
    param([string] $Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Show-AuditSummary {
    param($Document)
    Write-Host '--- Guest identity coverage (data available; not a cloak PASS) ---'
    foreach ($Name in @('smbios', 'cpuid', 'acpi', 'pci', 'gpu', 'storage', 'nic', 'edid', 'tpm')) {
        $Property = $Document.PSObject.Properties[$Name]
        $Status = 'UNAVAILABLE'
        if ($null -ne $Property -and $null -ne $Property.Value) {
            $Status = 'CAPTURED'
            if ($Name -eq 'tpm' -and -not $Property.Value.present) { $Status = 'NOT PRESENT' }
        }
        Write-Host ('  {0,-10} {1}' -f $Name, $Status)
    }
    if ($null -ne $Document.PSObject.Properties['smbios']) {
        $Info = $Document.smbios
        Write-Host ('  DMI Manufacturer: {0}; Model: {1}' -f $Info.systemManufacturer, $Info.systemProduct)
    }
    if ($null -ne $Document.PSObject.Properties['cpuid']) {
        Write-Host ('  CPU brand: {0}' -f $Document.cpuid.brand)
        Write-Host ('  HypervisorPresent (WMI, not raw CPUID): {0}' -f $Document.cpuid.hypervisorPresentFromWmi)
    }
    if (@($Document.unavailable).Count -gt 0) {
        Write-Warning ('Unavailable WMI sections/classes: ' + (@($Document.unavailable) -join ', '))
    }
}

function Assert-AuditExpectedDmi {
    param($Document)
    if (-not $ExpectedVendor -and -not $ExpectedProduct) { return }
    if ($null -eq $Document.PSObject.Properties['smbios']) {
        throw 'Expected DMI test requested but SMBIOS collector was unavailable'
    }
    if ($ExpectedVendor -and $Document.smbios.systemManufacturer -cne $ExpectedVendor) {
        throw "DMI vendor mismatch: expected '$ExpectedVendor', got '$($Document.smbios.systemManufacturer)'"
    }
    if ($ExpectedProduct -and $Document.smbios.systemProduct -cne $ExpectedProduct) {
        throw "DMI product mismatch: expected '$ExpectedProduct', got '$($Document.smbios.systemProduct)'"
    }
    Write-Host 'EXPECTED DMI VALUES: PASS'
}

try {
    $Folder = $PSScriptRoot
    $Collector = Join-Path $Folder 'collect-guest-identity.ps1'
    $Comparator = Join-Path $Folder 'compare-identity.ps1'
    foreach ($Script in @($Collector, $Comparator)) {
        if (-not (Test-Path -LiteralPath $Script -PathType Leaf)) {
            throw "Missing companion script: $Script"
        }
    }

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $OutputDir = (Resolve-Path -LiteralPath $OutputDir).Path

    if ($Phase -eq 'SelfTest') {
        $Example = Join-Path $OutputDir 'synthetic-identity.json'
        & $Collector -SelfTest -OutputPath $Example
        if ($LASTEXITCODE -ne 0) { throw "Collector self-test failed: $LASTEXITCODE" }
        & $Comparator -SelfTest
        if ($LASTEXITCODE -ne 0) { throw "Comparator self-test failed: $LASTEXITCODE" }
        $Doc = Read-AuditDocument -Path $Example
        if ($null -eq $Doc.PSObject.Properties['gpu']) {
            throw 'Collector self-test missing GPU section'
        }
        if ($null -eq $Doc.cpuid.PSObject.Properties['hypervisorPresentFromWmi']) {
            throw 'Collector self-test missing hypervisor WMI status'
        }
        Write-Host 'AUDIT SELF-TEST: PASS (synthetic data, not a guest runtime result)'
        exit 0
    }

    $Baseline = Join-Path $OutputDir 'boot1.json'
    $Candidate = Join-Path $OutputDir 'boot2.json'
    if ($Phase -eq 'Baseline') {
        if ((Test-Path -LiteralPath $Baseline) -and -not $Force) {
            throw "Baseline exists: $Baseline. Specify -Force to overwrite it."
        }
        & $Collector -OutputPath $Baseline
        if ($LASTEXITCODE -ne 0) { throw "Collector baseline failed: $LASTEXITCODE" }
        $Doc = Read-AuditDocument -Path $Baseline
        Show-AuditSummary -Document $Doc
        Assert-AuditExpectedDmi -Document $Doc
        Write-Host 'BASELINE SAVED. Shut down Windows guest, power off VM, start again, then run -Phase Verify.'
        Write-Host "File: $Baseline"
        exit 0
    }

    if (-not (Test-Path -LiteralPath $Baseline)) {
        throw "No baseline found at $Baseline. Run -Phase Baseline first."
    }
    & $Collector -OutputPath $Candidate
    if ($LASTEXITCODE -ne 0) { throw "Collector verification failed: $LASTEXITCODE" }
    $Doc = Read-AuditDocument -Path $Candidate
    Show-AuditSummary -Document $Doc
    Assert-AuditExpectedDmi -Document $Doc

    $Comparison = Join-Path $OutputDir 'comparison.json'
    & $Comparator -Reference $Baseline -Candidate @($Candidate) -ReportPath $Comparison
    $Code = $LASTEXITCODE
    if ($Code -eq 0) {
        Write-Host 'COLD-BOOT IDENTITY STABILITY: PASS (captured fields match)'
    }
    elseif ($Code -eq 1) {
        Write-Host 'COLD-BOOT IDENTITY STABILITY: FAIL (identity mismatch)'
    }
    else {
        throw "Comparator failed: exit code $Code"
    }
    Write-Host "Result: $Comparison"
    Write-Host 'Note: WMI HypervisorPresent is NOT the raw CPUID hypervisor bit; missing sections remain untested.'
    exit $Code
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
