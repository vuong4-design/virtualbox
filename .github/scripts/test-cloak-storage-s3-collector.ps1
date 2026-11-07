#requires -Version 5.1
<#
  Hermetic integration test for S3 guest collector using simulated Windows APIs.
  Does not enumerate any actual disk; does not require smartctl.exe.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$guest = Join-Path $PSScriptRoot 'Test-CloakStorageS3Guest.ps1'
$global:C5FixtureSingle = $false
$global:C5FixtureOptical = $false

function global:Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position=0)][string]$ClassName)
    if ($ClassName -eq 'Win32_DiskDrive') {
        $entries = @(
            [pscustomobject]@{Index=0;Model='LAB ATA DISK';FirmwareRevision='LAB1';
                SerialNumber='LB-SECRET-ONE';PNPDeviceID='SCSI\DISK&VEN_LAB_ATA&PROD_DISK\4&PRIVATE'},
            [pscustomobject]@{Index=1;Model='LAB ATA DISK';FirmwareRevision='LAB1';
                SerialNumber='LB-SECRET-TWO';PNPDeviceID='SCSI\DISK&VEN_LAB_ATA&PROD_DISK\4&PRIVATE2'}
        )
        if ($global:C5FixtureSingle) { return $entries[0] }
        return $entries
    }
    if ($ClassName -eq 'Win32_CDROMDrive') {
        if ($global:C5FixtureOptical) {
            return [pscustomobject]@{Drive='Z:';Name='VBOX CD-ROM';PNPDeviceID='SCSI\CDROM&VEN_VBOX&PROD_CD-ROM\4&PRIVATEOPT'}
        }
        return @()
    }
    throw "Unexpected WMI class: $ClassName"
}
function global:Get-Disk {
    [CmdletBinding()] param()
    if ($global:C5FixtureSingle) { return [pscustomobject]@{Number=0;BusType='SATA'} }
    return @(
        [pscustomobject]@{Number=0;BusType='SATA'},
        [pscustomobject]@{Number=1;BusType='SATA'}
    )
}
function global:Get-PhysicalDisk {
    [CmdletBinding()] param()
    $media = if ($global:C5FixtureSingle) { 'SSD' } else { 'Unspecified' }
    return @([pscustomobject]@{MediaType=$media;BusType='SATA'})
}

$out = [IO.Path]::GetTempFileName()
$mockSmartctl = $out + '.ps1'
$hostReport = $out + '.host.json'
try {
    & $guest -SkipSmartctl -SkipWindowsIoctl -OutputPath $out
    $text = [IO.File]::ReadAllText($out)
    if ($text.Contains('LB-SECRET-ONE') -or $text.Contains('LB-SECRET-TWO') -or
        $text.Contains('4&PRIVATE')) { throw 'Unredacted disk identifiers in S3 report' }
    $report = $text | ConvertFrom-Json
    if ($report.Overall -ne 'PARTIAL' -or @($report.Disks).Count -ne 2) {
        throw 'Unexpected S3 collector result'
    }
    if (@($report.Checks | Where-Object { $_.Id -eq 'RAW_MODEL' -and $_.Status -eq 'NOT_VERIFIED' }).Count -ne 2) {
        throw 'Missing smartctl must not yield PASS'
    }
    $caught = $false
    try { & $guest -SkipSmartctl -SkipWindowsIoctl -RequireRaw } catch {
        if ($_.Exception.Message -match 'strict audit incomplete') { $caught = $true } else { throw }
    }
    if (-not $caught) { throw 'S3 -RequireRaw did not fail on missing smartctl' }
    Write-Host 'PASS: S3 guest collector 2-disk, no-raw PARTIAL, redaction and RequireRaw failure'
    $global:C5FixtureOptical = $true
    & $guest -SkipSmartctl -SkipWindowsIoctl -OutputPath $out
    $withOptical = [IO.File]::ReadAllText($out)
    if ($withOptical.Contains('PRIVATEOPT')) { throw 'Full optical PnP instance leaked' }
    $opticalReport = $withOptical | ConvertFrom-Json
    if (@($opticalReport.OpticalDevices).Count -ne 1 -or
        @($opticalReport.Checks | Where-Object { $_.Id -eq 'ATAPI_OPTICAL' -and $_.Status -eq 'NOT_VERIFIED' }).Count -ne 1) {
        throw 'Optical device must be inventoried and unverified without direct INQUIRY'
    }
    $global:C5FixtureOptical = $false
    Write-Host 'PASS: guest optical inventory and missing direct INQUIRY remain NOT_VERIFIED'

    # Mock smartctl JSON to exercise the actual S3 collector's parser and
    # reporter. The fixture contains fake identifiers only.
    $global:C5FixtureSingle = $true
    $mockBody = @'
[pscustomobject]@{
    device = [pscustomobject]@{protocol='ATA'}
    model_name = 'LAB ATA DISK'
    firmware_version = 'LAB1'
    serial_number = 'LB-SECRET-ONE'
    smart_support = [pscustomobject]@{available=$true;enabled=$false}
    trim = [pscustomobject]@{supported=$false}
    rotation_rate = 1
} | ConvertTo-Json -Depth 5
'@
    [IO.File]::WriteAllText($mockSmartctl,$mockBody,[Text.Encoding]::UTF8)
    $hostFixture = [pscustomobject]@{
        SchemaVersion=1; Source='VBoxManage-showvminfo-machine-readable'
        Bindings=@([pscustomobject]@{Controller='SATA';Port=0;Device=0;GuestDiskIndex=0;
            NonRotational=$true;Discard=$false})
    }
    [IO.File]::WriteAllText($hostReport,($hostFixture | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
    & $guest -SkipWindowsIoctl -SmartctlPath $mockSmartctl -HostCapabilitiesPath $hostReport -RequireRaw -OutputPath $out
    $rawJson = [IO.File]::ReadAllText($out)
    if ($rawJson.Contains('LB-SECRET-ONE') -or $rawJson.Contains('4&PRIVATE')) {
        throw 'smartctl raw serial/PnP suffix leaked to S3 JSON'
    }
    $rawReport = $rawJson | ConvertFrom-Json
    if ($rawReport.Overall -ne 'PASS') { throw 'Fully evidenced ATA fixture should PASS' }
    if (@($rawReport.Checks | Where-Object { $_.Id -eq 'HOST_TRIM' -and $_.Status -eq 'PASS' }).Count -ne 1 -or
        @($rawReport.Checks | Where-Object { $_.Id -eq 'HOST_ROTATION' -and $_.Status -eq 'PASS' }).Count -ne 1) {
        throw 'Host and guest capability agreement was not tested'
    }
    if (@($rawReport.Checks | Where-Object { $_.Id -eq 'SMART' -and $_.Status -eq 'PASS' }).Count -ne 1) {
        throw 'Raw SMART capability not collected'
    }

    $hostFixture.Bindings[0].Discard = $true
    [IO.File]::WriteAllText($hostReport,($hostFixture | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
    $hostMismatch = $false
    try { & $guest -SkipWindowsIoctl -SmartctlPath $mockSmartctl -HostCapabilitiesPath $hostReport -RequireRaw } catch {
        $hostMismatch = $_.Exception.Message -match 'C5 contradictions detected'
    }
    if (-not $hostMismatch) { throw 'Host discard mismatch was not rejected' }
    $hostFixture.Bindings[0].Discard = $false
    [IO.File]::WriteAllText($hostReport,($hostFixture | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)

    [IO.File]::WriteAllText($mockSmartctl,
        ($mockBody -replace "model_name = 'LAB ATA DISK'","model_name = 'WRONG MODEL'"),
        [Text.Encoding]::UTF8)
    $contradictionDetected = $false
    try { & $guest -SkipWindowsIoctl -SmartctlPath $mockSmartctl -HostCapabilitiesPath $hostReport -RequireRaw -OutputPath $out } catch {
        if ($_.Exception.Message -match 'C5 contradictions detected') {
            $contradictionDetected = $true
        } else { throw }
    }
    if (-not $contradictionDetected) { throw 'Raw model mismatch was not rejected' }
    Write-Host 'PASS: smartctl JSON parser, sanitization and raw model mismatch gate'

}
finally {
    $global:C5FixtureSingle = $false
    [IO.File]::Delete($out)
    [IO.File]::Delete($mockSmartctl)
    [IO.File]::Delete($hostReport)
    $global:C5FixtureOptical = $false
}
