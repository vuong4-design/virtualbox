#requires -Version 5.1
<#
  Hermetic negative tests for source-level storage hook wiring guard.
  Only copies source files into a temporary directory; no VM or build.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sourceRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$root=[IO.Path]::Combine([IO.Path]::GetTempPath(),'cloak-hook-test-'+[Guid]::NewGuid().ToString('N'))
$gate=Join-Path $PSScriptRoot 'Test-CloakLabHookWiring.ps1'
$paths=@(
    'src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp',
    'src/VBox/Main/src-client/ConsoleImplConfigCloakStorage.h',
    'src/VBox/Main/src-client/ConsoleImplConfigX86.cpp',
    'src/VBox/Main/testcase/tstCloakConfig.cpp',
    'src/VBox/Devices/Storage/DevATA.cpp',
    'src/VBox/Devices/Storage/DevAHCI.cpp',
    'src/VBox/Devices/Storage/DrvSCSI.cpp',
    'include/VBox/vscsi.h',
    'src/VBox/Devices/Storage/VSCSI/VSCSIInternal.h',
    'src/VBox/Devices/Storage/VSCSI/VSCSIVpdPages.h',
    'src/VBox/Devices/Storage/VSCSI/VSCSILunSbc.cpp',
    'src/VBox/Devices/Storage/VSCSI/VSCSILunMmc.cpp',
    'src/VBox/Devices/Storage/DrvHostDVD.cpp',
    'src/VBox/Devices/Storage/UsbMsd.cpp',
    '.github/scripts/Set-CloakLabStorage.ps1'
)
try {
    foreach($p in $paths) {
        $src=Join-Path $sourceRoot $p
        $dest=Join-Path $root $p
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))|Out-Null
        [IO.File]::Copy($src,$dest)
    }
    & $gate -SourceRoot $root -OutputPath (Join-Path $root 'report.json') | Out-Null
    $report=Get-Content (Join-Path $root 'report.json') -Raw|ConvertFrom-Json
    if(@($report.Hooks|Where-Object {$_.Status -eq 'WIRED_LAB'}).Count -ne 5) {
        throw 'Expected five implemented lab hook contracts'
    }
    if (@($report.Hooks | Where-Object { $_.Id -eq 'ATAPI_PROFILE_MATERIALIZER' -and $_.Status -eq 'WIRED_LAB_OPTIN' }).Count -ne 1) {
        throw 'Expected the separate opt-in IDE/AHCI optical hook'
    }
    if (@($report.Hooks | Where-Object { $_.Id -eq 'SCSI_STANDARD_INQUIRY_MATERIALIZER' -and $_.Status -eq 'WIRED_LAB_OPTIN' }).Count -ne 1) {
        throw 'Expected the separate opt-in generic SCSI Standard INQUIRY hook'
    }
    if (@($report.Hooks | Where-Object { $_.Id -eq 'SCSI_SBC_VPD_IDENTITY_MATERIALIZER' -and $_.Status -eq 'WIRED_LAB_OPTIN' }).Count -ne 1) {
        throw 'Expected SBC VPD 0x80/0x83 identity hook'
    }
    Write-Host 'PASS: source-only lab hook contract detects five HDD points plus optical, SCSI INQUIRY and SBC VPD opt-ins'

    $console=Join-Path $root $paths[0]
    $original=[IO.File]::ReadAllText($console)
    $broken=$original.Replace('vrc = CloakStorageValidateLabEffective(&Cfgm, pSlotCfg, &Identity);',
                              'vrc = CloakStorageValidateEffective(&Cfgm, pSlotCfg);')
    if($broken -ceq $original) { throw 'Could not inject negative validator fixture' }
    [IO.File]::WriteAllText($console,$broken,[Text.Encoding]::UTF8)
    $rejected=$false
    try {& $gate -SourceRoot $root|Out-Null} catch {
        $rejected=$_.Exception.Message -match 'Lab validation must run after materialization'
    }
    if(-not $rejected){throw 'Missing lab exact validator was not rejected'}
    Write-Host 'PASS: missing effective CFGM identity hook fails fast before build'

    $broken=$original.Replace('CloakStorageValidateLabCoverage(fLabStorageEnabled, cEligible, cApplied)',
                              'CloakStorageValidateEffective(&Cfgm, pSlotCfg)')
    if($broken -ceq $original) {throw 'Could not inject negative coverage fixture'}
    [IO.File]::WriteAllText($console,$broken,[Text.Encoding]::UTF8)
    $rejected=$false
    try {& $gate -SourceRoot $root|Out-Null} catch {
        $rejected=$_.Exception.Message -match 'Coverage guard in live config path'
    }
    if(-not $rejected){throw 'Missing eligible-drive gate was not rejected'}
    Write-Host 'PASS: missing eligible-drive coverage hook fails static gate'

    $broken=$original.Replace('vrc = CloakStorageValidateLabOpticalEffective(&Cfgm, pOpticalSlot,',
                              'vrc = CloakStorageValidateLabEffective(&Cfgm, pOpticalSlot,')
    if($broken -ceq $original){throw 'Could not inject negative optical validator fixture'}
    [IO.File]::WriteAllText($console,$broken,[Text.Encoding]::UTF8)
    $rejected=$false
    try {& $gate -SourceRoot $root|Out-Null} catch {
        $rejected=$_.Exception.Message -match 'Optical identity must be validated after materialization'
    }
    if(-not $rejected){throw 'Missing exact optical identity gate was not rejected'}
    Write-Host 'PASS: missing optical effective identity gate rejected'

    $broken=$original.Replace('if (fHostDrive || fPassThrough)','if (false)')
    if($broken -ceq $original){throw 'Could not inject host-drive safety negative fixture'}
    [IO.File]::WriteAllText($console,$broken,[Text.Encoding]::UTF8)
    $rejected=$false
    try {& $gate -SourceRoot $root|Out-Null} catch {
        $rejected=$_.Exception.Message -match 'Host optical/passthrough guard'
    }
    if(-not $rejected){throw 'Missing host passthrough guard was not rejected'}
    Write-Host 'PASS: missing host optical/passthrough safety gate rejected'

    [IO.File]::WriteAllText($console,$original,[Text.Encoding]::UTF8)
    $broken=$original.Replace('CloakStorageValidateLabScsiCoverage(fLabScsiEnabled, cScsiPresent,',
                              'CloakStorageValidateLabScsiCoverage(false, cScsiPresent,')
    if($broken -ceq $original){throw 'Could not inject SCSI coverage negative fixture'}
    [IO.File]::WriteAllText($console,$broken,[Text.Encoding]::UTF8)
    $rejected=$false
    try {& $gate -SourceRoot $root|Out-Null} catch {
        $rejected=$_.Exception.Message -match 'SCSI coverage gate in live path'
    }
    if(-not $rejected){throw 'Missing SCSI coverage gate was not rejected'}
    Write-Host 'PASS: missing SCSI coverage hook rejected'

    [IO.File]::WriteAllText($console,$original,[Text.Encoding]::UTF8)
    $sbc=Join-Path $root 'src/VBox/Devices/Storage/VSCSI/VSCSILunSbc.cpp'
    $sbcOriginal=[IO.File]::ReadAllText($sbc)
    $sbcBroken=$sbcOriginal.Replace('VSCSI_VPD_DEVID_IDENTIFIER_TYPE_T10_VENDOR','0')
    if($sbcBroken -ceq $sbcOriginal){throw 'Could not inject VPD83 designator negative fixture'}
    [IO.File]::WriteAllText($sbc,$sbcBroken,[Text.Encoding]::UTF8)
    $rejected=$false
    try {& $gate -SourceRoot $root|Out-Null} catch {
        $rejected=$_.Exception.Message -match 'SBC VPD 0x83 T10 designator materialization'
    }
    if(-not $rejected){throw 'Missing SBC VPD83 designator wiring was not rejected'}
    Write-Host 'PASS: missing SBC VPD83 designator hook rejected'
}
finally {
    if([IO.Directory]::Exists($root)){[IO.Directory]::Delete($root,$true)}
}
Write-Host 'PASS: Lab storage hook wiring positive and negative regression'
