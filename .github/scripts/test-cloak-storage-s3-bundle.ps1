#requires -Version 5.1
<#
  Offline bundle/version/integrity fixture. No actual VM or disk access.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('s3-bundle-fixture-' + [Guid]::NewGuid().ToString('N'))
$archive = Join-Path $root 'CloakStorageS3Bundle.zip'
$extracted = Join-Path $root 'guest'
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    & (Join-Path $PSScriptRoot 'New-CloakStorageS3Bundle.ps1') -OutputPath $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $extracted -ErrorAction Stop
    $manifest = Get-Content -LiteralPath (Join-Path $extracted 'CloakStorageS3Manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Release -ne 'S3-C5-2026-11-B4' -or @($manifest.Files).Count -ne 3) {
        throw 'Bad bundle version/contents'
    }
    foreach ($file in $manifest.Files) {
        $actual = (Get-FileHash -LiteralPath (Join-Path $extracted $file.Name) -Algorithm SHA256).Hash
        if ($actual -cne $file.Sha256) { throw ('Bundle file hash mismatch: '+$file.Name) }
    }
    Write-Host 'PASS: ZIP release and all three SHA256 hashes'

    $global:CloakBundleFixtureDrift = $false
    function global:Get-CimInstance {
        param([Parameter(Position=0)][string]$ClassName)
        if ($ClassName -eq 'Win32_DiskDrive') {
            return [pscustomobject]@{
                Index=0;Model='LAB ATA DISK';FirmwareRevision='LAB1'
                SerialNumber=$(if ($global:CloakBundleFixtureDrift) {'LB-CHANGED-ON-SNAPSHOT'}else{'LB-VERSION-FIXTURE'});PNPDeviceID='SCSI\DISK&VEN_LAB_ATA&PROD_DISK\hidden'
            }
        }
        if ($ClassName -eq 'Win32_CDROMDrive') { return @() }
        throw 'Unexpected CIM class requested'
    }
    function global:Get-Disk { return [pscustomobject]@{Number=0;BusType='SATA';HealthStatus='Healthy';PartitionStyle='MBR'} }
    function global:Get-PhysicalDisk { return [pscustomobject]@{MediaType='Unspecified';BusType='SATA'} }

    $script = Join-Path $extracted 'Test-CloakStorageS3Guest.ps1'
    $report = Join-Path $root 'report.json'
    & $script -SkipSmartctl -SkipWindowsIoctl -OutputPath $report
    $json = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($json.Overall -ne 'PARTIAL' -or $json.AuditRevision -ne 'S3-C5-2026-11-B4' -or
        $json.BundleIntegrity -ne 'SHA256_VERIFIED') {
        throw 'Bundle did not attest revision and integrity'
    }
    if (-not $json.CollectorSha256 -or -not $json.C5ModuleSha256 -or -not $json.WindowsQuerySha256) {
        throw 'Collector did not record script/module versions'
    }
    Write-Host 'PASS: versioned bundle audit on synthetic guest with SHA256 verified'
    $current = Join-Path $root 'after.json'
    & $script -SkipSmartctl -SkipWindowsIoctl -CompareTo $report -OutputPath $current | Out-Null
    $after = Get-Content -LiteralPath $current -Raw | ConvertFrom-Json
    if ($after.LifecycleComparison.Overall -ne 'PARTIAL' -or $after.LifecycleComparison.Failed -ne 0) {
        throw 'Collector lifecycle must report PARTIAL without raw, not a false PASS'
    }
    $global:CloakBundleFixtureDrift = $true
    $driftDetected = $false
    try { & $script -SkipSmartctl -SkipWindowsIoctl -CompareTo $report -OutputPath $current | Out-Null }
    catch { $driftDetected = $_.Exception.Message -match 'lifecycle snapshot/cold-boot identity drift' }
    if (-not $driftDetected) { throw 'Collector did not reject changed serial after snapshot' }
    $afterDrift = Get-Content -LiteralPath $current -Raw | ConvertFrom-Json
    if ($afterDrift.LifecycleComparison.Overall -ne 'FAIL') { throw 'Missing lifecycle FAIL in redacted report' }
    $global:CloakBundleFixtureDrift = $false
    Write-Host 'PASS: collector lifecycle CompareTo positive/negative integration'

    $module = Join-Path $extracted 'CloakStorageC5.psm1'
    [IO.File]::AppendAllText($module, "`n# deliberate drift fixture`n")
    $rejected = $false
    try { & $script -SkipSmartctl -SkipWindowsIoctl } catch {
        $rejected = $_.Exception.Message -match 'checksum mismatch'
    }
    if (-not $rejected) { throw 'Tampered C5 module did not fail before import' }
    Write-Host 'PASS: tampered guest module rejected before import'

    [IO.File]::Delete((Join-Path $extracted 'CloakStorageS3Manifest.json'))
    $oldText = [IO.File]::ReadAllText($module).Replace('S3-C5-2026-11-B4','S3-C5-OLD')
    [IO.File]::WriteAllText($module,$oldText,[Text.Encoding]::UTF8)
    $mismatch = $false
    try { & $script -SkipSmartctl -SkipWindowsIoctl } catch {
        $mismatch = $_.Exception.Message -match 'release mismatch'
    }
    if (-not $mismatch) { throw 'Old C5 module did not fail without manifest' }
    Write-Host 'PASS: mixed release modules rejected without manifest'
}
finally {
    $global:CloakBundleFixtureDrift = $false
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root,$true) }
}
