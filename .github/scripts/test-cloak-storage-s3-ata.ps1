#requires -Version 5.1
<#
  Hermetic parser test for Windows ATA PASS THROUGH IDENTIFY DEVICE 0xEC.
  The fixture is synthetic. No real disk is opened.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'CloakStorageWindowsQuery.psm1') -Force

function Assert-Ata([bool]$condition,[string]$name) {
    if (-not $condition) { throw ('FAIL native ATA S3: '+$name) }
}
function Set-AtaWord([byte[]]$buf,[int]$word,[uint16]$value) {
    [Array]::Copy([BitConverter]::GetBytes($value),0,$buf,$word*2,2)
}
function Set-AtaText([byte[]]$buf,[int]$word,[int]$maxWords,[string]$text) {
    $fixed = $text.PadRight($maxWords*2,' ')
    if ($fixed.Length -gt $maxWords*2) { throw 'Test string overflow' }
    for ($i=0;$i -lt $maxWords;$i++) {
        $buf[($word+$i)*2] = [byte][char]$fixed[$i*2+1]
        $buf[($word+$i)*2+1] = [byte][char]$fixed[$i*2]
    }
}
$identify = New-Object byte[] 512
Set-AtaWord $identify 0 0x0040
Set-AtaWord $identify 82 0x0001
Set-AtaWord $identify 85 0x0001
Set-AtaWord $identify 169 0x0001
Set-AtaWord $identify 217 0x0001
Set-AtaText $identify 10 10 'LB-AUDIT-TEST'
Set-AtaText $identify 23 4 'LAB1'
Set-AtaText $identify 27 20 'LAB ATA DISK'
$identify[510]=0xA5
$sum=0
foreach($byte in $identify) { $sum=($sum + [int]$byte) -band 0xff }
$identify[511] = [byte]((256-$sum) -band 0xff)

$raw = ConvertFrom-CloakAtaIdentify -Bytes $identify
Assert-Ata ($null -ne $raw) 'valid IDENTIFY accepted'
Assert-Ata ($raw.Protocol -eq 'ATA' -and $raw.Source -match 'IDENTIFY_0xEC') 'provenance and protocol'
Assert-Ata ($raw.Model -eq 'LAB ATA DISK' -and $raw.Firmware -eq 'LAB1') 'ATA swapped strings'
Assert-Ata ($raw.SerialSha256.Length -eq 64 -and $raw.SerialSha256 -notmatch 'LB-AUDIT') 'serial redacted'
Assert-Ata ($raw.SmartAvailable -eq $true -and $raw.SmartEnabled -eq $true) 'SMART supported/enabled word 82/85'
Assert-Ata ($raw.TrimSupported -eq $true) 'word 169 TRIM'
Assert-Ata ($raw.RotationRate -eq 1) 'word 217 nonrotational'
Write-Host 'PASS: raw ATA model, firmware, hashed serial, SMART, TRIM, nonrotational decoded'

$corrupt=[byte[]]$identify.Clone()
$corrupt[50] = $corrupt[50] -bxor 1
Assert-Ata ($null -eq (ConvertFrom-CloakAtaIdentify -Bytes $corrupt)) 'ATA integrity checksum'
$atapi=[byte[]]$identify.Clone()
$atapi[1] = $atapi[1] -bor 0x80
Assert-Ata ($null -eq (ConvertFrom-CloakAtaIdentify -Bytes $atapi)) 'ATAPI is not ATA disk'
Assert-Ata ($null -eq (ConvertFrom-CloakAtaIdentify -Bytes ([byte[]](0,1,2)))) 'truncated IDENTIFY'
$rotationUnknown=[byte[]]$identify.Clone()
Set-AtaWord $rotationUnknown 217 0
$rotationUnknown[510] = 0   # ATA integrity word not present
$rotationUnknown[511] = 0
$rotation = ConvertFrom-CloakAtaIdentify -Bytes $rotationUnknown
Assert-Ata ($null -ne $rotation -and $null -eq $rotation.RotationRate) 'unreported rotation remains null'
Write-Host 'PASS: ATA checksum, ATA vs ATAPI, truncation and unknown rotation checks'

if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) {
    $result = Get-CloakStorageAtaIdentify -DiskIndex 1024
    Assert-Ata ($null -eq $result) 'nonexistent disk safely returns null'
    Write-Host 'PASS: Windows native ATA read-only query compiles and fails closed on missing disk'
}
Write-Host 'PASS: Storage S3 native ATA offline tests'
