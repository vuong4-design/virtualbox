#requires -Version 5.1
<#
.SYNOPSIS
  Export read-only, redacted host storage attachment capability flags.
.DESCRIPTION
  Parses VBoxManage showvminfo --machinereadable flags emitted by
  VBoxManageInfo.cpp: <controller>-nonrotational-<port>-<device> and
  <controller>-discard-<port>-<device>. Does not save image paths, UUIDs,
  seeds or serial numbers. Guest index mapping must be explicit.
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()][string]$VM = 'test',
    [ValidateNotNullOrEmpty()][string]$VBoxManage = 'VBoxManage',
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [string]$Controller = '',
    [int]$Port = -1,
    [int]$Device = -1,
    [int]$GuestDiskIndex = -1
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not (Get-Command $VBoxManage -ErrorAction SilentlyContinue)) { throw 'VBoxManage not found' }
if ($GuestDiskIndex -ge 0 -and (-not $Controller -or $Port -lt 0 -or $Device -lt 0)) {
    throw 'Guest disk mapping requires explicit -Controller, -Port and -Device'
}
if ($GuestDiskIndex -lt -1 -or $Port -lt -1 -or $Device -lt -1) {
    throw 'Invalid guest disk index or attachment port/device'
}
$info = @(& $VBoxManage showvminfo $VM --machinereadable 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'VBoxManage showvminfo failed' }

$flags = @{}
foreach ($line in $info) {
    if ([string]$line -notmatch '^"(?<key>[^"]+)"="(?<value>[^"]*)"$') { continue }
    $key = [string]$Matches['key']
    $value = [string]$Matches['value']
    if ($key -notmatch '^(?<controller>.+)-(?<flag>nonrotational|discard)-(?<port>\d+)-(?<device>\d+)$') { continue }
    if ($value -notin @('on','off')) { throw 'Invalid host storage capability flag value' }
    $ctl = [string]$Matches['controller']
    $flag = [string]$Matches['flag']
    $portNum = [int]$Matches['port']
    $devNum = [int]$Matches['device']
    $bindingId = ('{0}|{1}|{2}' -f $ctl,$portNum,$devNum)
    if (-not $flags.ContainsKey($bindingId)) {
        $flags[$bindingId] = @{
            Controller=$ctl;Port=$portNum;Device=$devNum
            NonRotational=$null;Discard=$null;GuestDiskIndex=$null
        }
    }
    if ($flag -eq 'nonrotational') { $flags[$bindingId].NonRotational = ($value -eq 'on') }
    else { $flags[$bindingId].Discard = ($value -eq 'on') }
}

$bindings = @()
foreach ($binding in $flags.Values) {
    if ($null -eq $binding.NonRotational -or $null -eq $binding.Discard) {
        throw 'Host attachment has incomplete discard/nonrotational flags'
    }
    if ($GuestDiskIndex -ge 0 -and $binding.Controller -ieq $Controller -and
        $binding.Port -eq $Port -and $binding.Device -eq $Device) {
        $binding.GuestDiskIndex = $GuestDiskIndex
    }
    $bindings += [pscustomobject][ordered]@{
        Controller=$binding.Controller;Port=$binding.Port;Device=$binding.Device
        GuestDiskIndex=$binding.GuestDiskIndex
        NonRotational=$binding.NonRotational;Discard=$binding.Discard
    }
}
if ($bindings.Count -eq 0) { throw 'No attached storage capability flags found in VBoxManage output' }
if ($GuestDiskIndex -ge 0 -and
    @($bindings | Where-Object { $null -ne $_.GuestDiskIndex }).Count -ne 1) {
    throw 'Explicit controller/port/device mapping did not resolve uniquely'
}
$bindings = @($bindings | Sort-Object Controller,Port,Device)
$report = [pscustomobject][ordered]@{
    SchemaVersion=1
    Source='VBoxManage-showvminfo-machine-readable'
    Bindings=@($bindings)
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),
    ($report | ConvertTo-Json -Depth 5),[Text.Encoding]::UTF8)
Write-Host ("PASS: exported {0} host attachment flags, {1} explicitly bound guest disk(s); no image paths/UUIDs/serials" -f
    $bindings.Count,@($bindings | Where-Object { $null -ne $_.GuestDiskIndex }).Count)
