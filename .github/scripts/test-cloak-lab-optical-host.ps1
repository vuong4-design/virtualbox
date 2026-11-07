#requires -Version 5.1
<#
  Host-side offline test for separately opted-in ATAPI and SCSI lab switches.
  Uses a mock VBoxManage.ps1 in temp; never contacts a real VM.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('cloak-optical-host-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$statePath=Join-Path $root 'state.json'
$mock=Join-Path $root 'MockVBoxManage.ps1'
$controller=Join-Path $PSScriptRoot 'Set-CloakLabStorage.ps1'
function Write-State($st) { [IO.File]::WriteAllText($statePath,($st|ConvertTo-Json -Depth 6),[Text.Encoding]::UTF8) }
function Read-State { return (Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json) }
function Assert-Test([bool]$ok,[string]$what) { if(-not $ok){throw ('Optical host test failed: '+$what)} }
function Expect-Rejection([scriptblock]$code,[string]$pattern) {
    $caught=$false
    try{ & $code | Out-Null }catch{$caught=$_.Exception.Message -match $pattern}
    Assert-Test $caught ('Expected rejection: '+$pattern)
}
try {
    $state=[pscustomobject]@{
        VMState='poweroff';Enabled='integer:1';Profile='lab-dmi-v1'
        StorageLabEnabled='integer:1';StorageLabRootSerialEnabled='integer:1'
        StorageLabOpticalEnabled='integer:0';StorageLabScsiEnabled='integer:0';SetCount=0
    }
    Write-State $state
    $mockText=@'
$ErrorActionPreference='Stop'
$statePath=$env:CLOAK_OPTICAL_HOST_TEST_STATE
$s=Get-Content -LiteralPath $statePath -Raw|ConvertFrom-Json
if ($args[0] -eq 'showvminfo' -and $args[1] -eq 'test' -and $args[2] -eq '--machinereadable') {
    Write-Output ('VMState="'+$s.VMState+'"');exit 0
}
if ($args[0] -eq 'getextradata' -and $args[1] -eq 'test') {
    $name=([string]$args[2]).Replace('VBoxInternal/Cloak/','')
    if ($s.PSObject.Properties.Name -contains $name) {Write-Output ('Value: '+[string]$s.$name)}
    else {Write-Output 'No value set!'}
    exit 0
}
if ($args[0] -eq 'setextradata' -and $args[1] -eq 'test') {
    $name=([string]$args[2]).Replace('VBoxInternal/Cloak/','')
    if(-not ($s.PSObject.Properties.Name -contains $name)){exit 19}
    $s.$name=[string]$args[3]
    $s.SetCount=[int]$s.SetCount+1
    [IO.File]::WriteAllText($statePath,($s|ConvertTo-Json -Depth 6),[Text.Encoding]::UTF8)
    exit 0
}
exit 20
'@
    [IO.File]::WriteAllText($mock,$mockText,[Text.Encoding]::UTF8)
    $env:CLOAK_OPTICAL_HOST_TEST_STATE=$statePath
    & $controller -VM test -VBoxManage $mock -Action Status | Out-Null
    Assert-Test ((Read-State).SetCount -eq 0) 'Status does not set anything'
    & $controller -VM test -VBoxManage $mock -Action EnableOptical -WhatIf | Out-Null
    Assert-Test ((Read-State).SetCount -eq 0) 'WhatIf did not write ExtraData'
    & $controller -VM test -VBoxManage $mock -Action EnableOptical | Out-Null
    Assert-Test ((Read-State).StorageLabOpticalEnabled -eq 'integer:1') 'Optical lab explicitly enabled'
    & $controller -VM test -VBoxManage $mock -Action DisableOptical | Out-Null
    Assert-Test ((Read-State).StorageLabOpticalEnabled -eq 'integer:0') 'Optical lab explicitly disabled'
    & $controller -VM test -VBoxManage $mock -Action EnableScsi -WhatIf | Out-Null
    Assert-Test ((Read-State).StorageLabScsiEnabled -eq 'integer:0') 'SCSI WhatIf did not write ExtraData'
    & $controller -VM test -VBoxManage $mock -Action EnableScsi | Out-Null
    Assert-Test ((Read-State).StorageLabScsiEnabled -eq 'integer:1') 'SCSI lab explicitly enabled'
    & $controller -VM test -VBoxManage $mock -Action DisableScsi | Out-Null
    Assert-Test ((Read-State).StorageLabScsiEnabled -eq 'integer:0') 'SCSI lab explicitly disabled'
    Write-Host 'PASS: Status/WhatIf/Enable/Disable optical and SCSI only use mock VBoxManage'

    $st=Read-State;$st.VMState='running';Write-State $st
    Expect-Rejection { & $controller -VM test -VBoxManage $mock -Action EnableOptical } 'Shut down VM'
    Expect-Rejection { & $controller -VM test -VBoxManage $mock -Action EnableScsi } 'Shut down VM'
    $st=Read-State;$st.VMState='poweroff';$st.Profile='another-profile';Write-State $st
    Expect-Rejection { & $controller -VM test -VBoxManage $mock -Action EnableOptical } 'lab-dmi-v1'
    Expect-Rejection { & $controller -VM test -VBoxManage $mock -Action EnableScsi } 'lab-dmi-v1'
    $st=Read-State;$st.Profile='lab-dmi-v1';$st.StorageLabEnabled='integer:0';Write-State $st
    & $controller -VM test -VBoxManage $mock -Action EnableOptical | Out-Null
    Assert-Test ((Read-State).StorageLabOpticalEnabled -eq 'integer:1') 'Optical can be enabled independently of HDD lab mode'
    $st=Read-State;$st.StorageLabEnabled='integer:1';Write-State $st
    & $controller -VM test -VBoxManage $mock -Action Disable | Out-Null
    $st=Read-State
    Assert-Test ($st.StorageLabEnabled -eq 'integer:0' -and
                 $st.StorageLabRootSerialEnabled -eq 'integer:0' -and
                 $st.StorageLabOpticalEnabled -eq 'integer:0' -and
                 $st.StorageLabScsiEnabled -eq 'integer:0') 'Global Disable also clears optical and SCSI opt-ins'
    Write-Host 'PASS: running/wrong-profile rejected; global Disable clears all storage lab switches'
}
finally {
    Remove-Item Env:CLOAK_OPTICAL_HOST_TEST_STATE -ErrorAction SilentlyContinue
    if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
}
Write-Host 'PASS: lab optical/SCSI host switch regression (synthetic only)'
