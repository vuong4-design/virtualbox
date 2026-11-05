#requires -Version 5.1
<#
  Offline VBoxManage host capability exporter fixture. No VM or device I/O.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$exporter = Join-Path $PSScriptRoot 'Export-CloakStorageC5Host.ps1'
$mock = [IO.Path]::GetTempFileName() + '.ps1'
$out = [IO.Path]::GetTempFileName()
try {
    $mockCode = @'
if ($args[0] -ne 'showvminfo') { throw 'Unexpected VBoxManage operation' }
Write-Output '"VMState"="poweroff"'
Write-Output '"SATA-0-0"="D:\PRIVATE\secret.vdi"'
Write-Output '"SATA-ImageUUID-0-0"="11111111-2222-3333-4444-555555555555"'
Write-Output '"SATA-nonrotational-0-0"="off"'
Write-Output '"SATA-discard-0-0"="off"'
Write-Output '"SATA-1-0"="D:\PRIVATE\second.vdi"'
Write-Output '"SATA-nonrotational-1-0"="on"'
Write-Output '"SATA-discard-1-0"="on"'
exit 0
'@
    [IO.File]::WriteAllText($mock,$mockCode,[Text.Encoding]::UTF8)
    & $exporter -VM test -VBoxManage $mock -OutputPath $out -Controller SATA -Port 0 -Device 0 -GuestDiskIndex 0
    $text = [IO.File]::ReadAllText($out)
    if ($text.Contains('secret.vdi') -or $text.Contains('second.vdi') -or
        $text.Contains('11111111-2222')) { throw 'Host exporter leaked paths or UUIDs' }
    $data = $text | ConvertFrom-Json
    if ($data.SchemaVersion -ne 1 -or @($data.Bindings).Count -ne 2) {
        throw 'Host exporter lost or duplicated attachments'
    }
    $first = @($data.Bindings | Where-Object { $_.Port -eq 0 })
    $second = @($data.Bindings | Where-Object { $_.Port -eq 1 })
    if ($first.Count -ne 1 -or $first[0].GuestDiskIndex -ne 0 -or
        $first[0].Discard -ne $false -or $first[0].NonRotational -ne $false) {
        throw 'Explicit host binding incorrect'
    }
    if ($second.Count -ne 1 -or $null -ne $second[0].GuestDiskIndex) {
        throw 'Unmapped host disk was guessed'
    }
    $rejected = $false
    try { & $exporter -VM test -VBoxManage $mock -OutputPath $out -GuestDiskIndex 1 } catch {
        $rejected = $_.Exception.Message -match 'explicit'
    }
    if (-not $rejected) { throw 'Missing controller/port selection was not rejected' }
    Write-Host 'PASS: host S3 capability exporter, 2 attachments, redaction and explicit disk mapping'
}
finally {
    [IO.File]::Delete($mock)
    [IO.File]::Delete($out)
}
