#requires -Version 5.1
<#
  Hermetic tests for Windows StorageProperty descriptor parsing and SCSI
  INQUIRY 0x12 parsing. Never opens a real disk/optical device.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageWindowsQuery.psm1') -Force

function Assert-WinQuery([bool]$Condition,[string]$Description) {
    if (-not $Condition) { throw ('FAILED S3 WinQuery: ' + $Description) }
}
function Set-Dword([byte[]]$b,[int]$offset,[uint32]$value) {
    [Array]::Copy([BitConverter]::GetBytes($value),0,$b,$offset,4)
}
function Set-Ascii([byte[]]$b,[int]$offset,[int]$length,[string]$text) {
    $bytes = [Text.Encoding]::ASCII.GetBytes($text)
    if ($bytes.Length -gt $length) { throw 'Test string longer than field' }
    [Array]::Copy($bytes,0,$b,$offset,$bytes.Length)
}
$dev = New-Object byte[] 128
Set-Dword $dev 0 36
Set-Dword $dev 4 128
$dev[8] = 5  # CD-ROM (SCSI peripheral device type)
Set-Dword $dev 12 48
Set-Dword $dev 16 60
Set-Dword $dev 20 80
Set-Dword $dev 28 11 # BusTypeSata, non-authoritative
Set-Ascii $dev 48 12 'VBOX'
Set-Ascii $dev 60 16 'CD-ROM'
Set-Ascii $dev 80 8 '1.0'
$trim = New-Object byte[] 12
$seek = New-Object byte[] 12
Set-Dword $trim 0 12; Set-Dword $trim 4 12; $trim[8] = 0
Set-Dword $seek 0 12; Set-Dword $seek 4 12; $seek[8] = 1
$parsed = ConvertFrom-CloakStorageDescriptor -Device $dev -Trim $trim -Seek $seek
Assert-WinQuery ($parsed.DeviceType -eq 5) 'DeviceType 5 optical'
Assert-WinQuery ($parsed.BusTypeCode -eq 11) 'SATA bus'
Assert-WinQuery ($parsed.Vendor -eq 'VBOX' -and $parsed.Product -eq 'CD-ROM' -and $parsed.Revision -eq '1.0') 'Vendor/product/revision'
Assert-WinQuery ($parsed.TrimEnabled -eq $false -and $parsed.IncursSeekPenalty -eq $true) 'Windows seek and TRIM flags'

$badDev = [byte[]]$dev.Clone()
Set-Dword $badDev 16 4096
$badDesc = ConvertFrom-CloakStorageDescriptor -Device $badDev
Assert-WinQuery (-not $badDesc.Product) 'Out-of-bounds product offset rejected'
$badTrim = [byte[]]$trim.Clone()
$badTrim[8] = 2
$badResponse = ConvertFrom-CloakStorageDescriptor -Trim $badTrim
Assert-WinQuery ($null -eq $badResponse.TrimEnabled) 'Invalid boolean rejected'
Write-Host 'PASS: Windows Device/Trim/Seek descriptor parsing and bounds checks'

$inq = [byte[]]::new(96)
for ($i=0;$i -lt $inq.Length;$i++) { $inq[$i] = 32 }
$inq[0] = 5
Set-Ascii $inq 8 8 'VBOX'
Set-Ascii $inq 16 16 'CD-ROM'
Set-Ascii $inq 32 4 '1.0'
$result = ConvertFrom-CloakScsiInquiry -Bytes $inq
Assert-WinQuery ($null -ne $result) 'Optical INQUIRY accepted'
Assert-WinQuery ($result.Source -eq 'SCSI_PASS_THROUGH_INQUIRY_0x12' -and $result.DeviceType -eq 5) 'INQUIRY provenance'
Assert-WinQuery ($result.Vendor -eq 'VBOX' -and $result.Product -eq 'CD-ROM' -and $result.Revision -eq '1.0') 'INQUIRY identity'
$inq[0] = 8
Assert-WinQuery ($null -eq (ConvertFrom-CloakScsiInquiry -Bytes $inq)) 'Unsupported peripheral rejected'
$inq[0] = 5
$inq[9] = 0
Assert-WinQuery ($null -eq (ConvertFrom-CloakScsiInquiry -Bytes $inq)) 'Control character rejected'
Assert-WinQuery ($null -eq (ConvertFrom-CloakScsiInquiry -Bytes ([byte[]](0,1,2)))) 'Truncated INQUIRY rejected'
Write-Host 'PASS: read-only SCSI INQUIRY byte parsing and invalid input rejection'

$vpd = New-Object byte[] 252
$vpd[0]=5      # optical peripheral type
$vpd[1]=0x83   # device identification VPD page
$vpd[2]=0
$vpd[3]=8      # 4 bytes header + a 4-byte synthetic designator
$vpd[4]=1      # binary code set
$vpd[5]=3      # NAA type
$vpd[6]=0
$vpd[7]=4
$vpd[8]=0xde; $vpd[9]=0xad; $vpd[10]=0xbe; $vpd[11]=0xef
$parsedVpd=ConvertFrom-CloakScsiVpd83 -Bytes $vpd
Assert-WinQuery ($parsedVpd.IdentifierCount -eq 1 -and $parsedVpd.DeviceType -eq 5) 'VPD 0x83 designator parsed'
Assert-WinQuery (-not (($parsedVpd | ConvertTo-Json) -match 'deadbeef')) 'VPD designator values must not appear in report'
$badVpd=[byte[]]$vpd.Clone()
$badVpd[3]=250
Assert-WinQuery ($null -eq (ConvertFrom-CloakScsiVpd83 -Bytes $badVpd)) 'VPD page exceeding buffer rejected'
$emptyVpd=[byte[]]$vpd.Clone()
$emptyVpd[3]=0
$empty=ConvertFrom-CloakScsiVpd83 -Bytes $emptyVpd
Assert-WinQuery ($null -ne $empty -and $empty.IdentifierCount -eq 0) 'Empty VPD page does not pretend to contain designators'
Write-Host 'PASS: SCSI VPD 0x83 bounded parsing, redaction, empty and malformed pages'

# On Windows only, verify that the P/Invoke assembly compiles. Never open a
# real device. The designated non-existent index exercises CreateFile failure.
if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
    $probe = Get-CloakStorageWindowsProperties -DiskIndex 1024
    Assert-WinQuery ($null -ne $probe -and $null -eq $probe.DeviceType) 'Nonexistent disk has no fabricated descriptor'
    Assert-WinQuery ($probe.QueryStatus.DeviceDescriptor -ne 'AVAILABLE' -and
        $probe.QueryStatus.Trim -ne 'AVAILABLE' -and
        $probe.QueryStatus.SeekPenalty -ne 'AVAILABLE') 'No fabricated storage capabilities'
    Assert-WinQuery ($probe.QueryStatus.DeviceDescriptor -in @('DEVICE_NOT_FOUND','ACCESS_DENIED','UNSUPPORTED','DRIVER_OR_STORAGE_ERROR')) 'Sanitized diagnostic without device path'
    $diag = $probe.QueryDiagnostics.DeviceDescriptor
    Assert-WinQuery ($null -ne $diag -and $diag.FailureStage -in @('CREATE_FILE','DEVICE_IO_CONTROL','INVALID_RESPONSE_SIZE')) 'Diagnostic exposes only controlled stages'
    Assert-WinQuery ([int]$diag.Win32Error -gt 0) 'Diagnostic includes numeric Win32 error code'
    Assert-WinQuery ($null -ne $probe.QueryDiagnostics.Trim -and $null -ne $probe.QueryDiagnostics.SeekPenalty) 'Each query independently diagnosed'
    $safe = $probe | ConvertTo-Json -Depth 7
    Assert-WinQuery (-not $safe.Contains('PhysicalDrive1024') -and -not $safe.Contains('\\.\')) 'No device path in diagnostic JSON'
    Assert-WinQuery ($null -ne ('CloakStorageS3ReadOnlyB3.DeviceProps' -as [type])) 'P/Invoke assembly compiled'
    Write-Host 'PASS: Windows Add-Type read-only IOCTL helper compiled'
}
Write-Host 'PASS: Storage S3 Windows query offline tests and B2 numeric IOCTL diagnostics'
