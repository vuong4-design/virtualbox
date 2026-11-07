#requires -Version 5.1
<#
.SYNOPSIS
  Static, read-only inventory of hook wiring in the existing lab storage slice.
.DESCRIPTION
  Fails if critical source-level contracts disappear before expensive host
  compilation. Does NOT prove runtime behavior or VM-detection properties.
  Unsupported optical/VSCSI/USB/HostDVD paths are explicitly marked residual.
#>
[CmdletBinding()]
param(
    [string]$SourceRoot = (Join-Path $PSScriptRoot '..\..'),
    [string]$OutputPath = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($SourceRoot)
function Load-CloakSource([string]$RelativePath) {
    $p = Join-Path $root ($RelativePath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
        throw ('Missing hook source: ' + $RelativePath)
    }
    return [IO.File]::ReadAllText($p)
}
function Require-CloakPattern([string]$Text,[string]$Needle,[string]$Label) {
    if (-not $Text.Contains($Needle)) { throw ('Missing lab hook contract: '+$Label) }
}
$consolePath='src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp'
$storagePath='src/VBox/Main/src-client/ConsoleImplConfigCloakStorage.h'
$x86Path='src/VBox/Main/src-client/ConsoleImplConfigX86.cpp'
$testPath='src/VBox/Main/testcase/tstCloakConfig.cpp'
$console=Load-CloakSource $consolePath
$storage=Load-CloakSource $storagePath
$x86=Load-CloakSource $x86Path
$tests=Load-CloakSource $testPath
$rows = [System.Collections.Generic.List[object]]::new()
function Add-CloakRow([string]$Id,[string]$Status,[string]$Source,[string]$Note) {
    $rows.Add([pscustomobject][ordered]@{
        Id=$Id;Status=$Status;Source=$Source;Note=$Note
    })
}
Require-CloakPattern $console 'StorageLabEnabled' 'Storage lab must remain opt-in'
Require-CloakPattern $console 'if (fLabProfile && pProfile->pszAtaModel)' 'Lab-only materializer gate'
Add-CloakRow 'LAB_STORAGE_OPTIN' 'WIRED_LAB' $consolePath 'Requires explicit lab profile and opt-in; off by default'

Require-CloakPattern $console 'GetMediumAttachmentsOfController' 'COM medium graph enumeration'
Require-CloakPattern $console 'CloakStorageGetSlot(' 'Per-attachment CFGM slot resolver'
Require-CloakPattern $storage 'PrimarySlave' 'PIIX3 IDE slot support'
Require-CloakPattern $storage '"ahci"' 'AHCI slot support'
Add-CloakRow 'ATA_AHCI_ATTACHMENT_ROUTE' 'WIRED_LAB' $storagePath 'COM controller graph; IDE and SATA slot routing'

$cfgIndex=$x86.IndexOf('i_configStorageCtrls(')
$overlayIndex=$x86.IndexOf('i_configCfgmOverlay(')
$cloakIndex=$x86.IndexOf('i_configCloak(')
if ($cfgIndex -lt 0 -or $overlayIndex -le $cfgIndex -or $cloakIndex -le $overlayIndex) {
    throw 'Storage materialization must run after controller CFGM and ExtraData overlay'
}
Add-CloakRow 'MATERIALIZE_AFTER_OVERLAY' 'WIRED_LAB' $x86Path 'Storage graph exists; user overlay comes before lab materializer'

Require-CloakPattern $storage 'CloakStorageValidateLabEffective(' 'Exact effective lab identity validation'
Require-CloakPattern $storage 'VERR_MISMATCH' 'Fail-closed lab identity mismatches'
$materializeIndex=$console.IndexOf('vrc = CloakStorageMaterialize(&Cfgm, pSlotCfg, &Identity)')
$validateIndex=$console.IndexOf('vrc = CloakStorageValidateLabEffective(&Cfgm, pSlotCfg, &Identity)')
$wipeIndex=$console.IndexOf('RTMemWipeThoroughly(szSerial, sizeof(szSerial), 3)', $materializeIndex)
if ($materializeIndex -lt 0 -or $validateIndex -le $materializeIndex -or
    $wipeIndex -le $validateIndex) {
    throw 'Lab validation must run after materialization but before serial wipe'
}
Require-CloakPattern $tests 'CloakStorageValidateLabEffective(&VTable, pDiskA, &IdentityA)' 'Lab unit test wiring'
Add-CloakRow 'STORAGE_EFFECTIVE_PROFILE_GUARD' 'WIRED_LAB' $storagePath 'Rejects model/firmware/serial override mismatches before virtual-device initialization'

Require-CloakPattern $storage 'CloakStorageValidateLabCoverage(' 'Eligible HDD coverage validation helper'
Require-CloakPattern $storage 'if (!cEligible)' 'Enabled lab without eligible disk must fail'
Require-CloakPattern $console 'CloakStorageValidateLabCoverage(fLabStorageEnabled, cEligible, cApplied)' 'Coverage guard in live config path'
Require-CloakPattern $tests 'CloakStorageValidateLabCoverage(true, 0, 0)' 'Coverage guard negative unit fixture'
Add-CloakRow 'STORAGE_ELIGIBLE_COVERAGE_GUARD' 'WIRED_LAB' $storagePath 'Enabled HDD lab cannot silently succeed with no eligible/mapped disk'

Require-CloakPattern $console 'if (enmType == DeviceType_DVD)' 'Optical inventory hook'
Require-CloakPattern $console 'cOptical++' 'Explicit optical residual count'
Add-CloakRow 'OPTICAL_ATTACHMENT_INVENTORY' 'OBSERVED_ONLY' $consolePath 'Optical is counted without changing default descriptors; opt-in uses separate optical profile'

$ata=Load-CloakSource 'src/VBox/Devices/Storage/DevATA.cpp'
$ahci=Load-CloakSource 'src/VBox/Devices/Storage/DevAHCI.cpp'
Require-CloakPattern $ata '"ATAPIVendorId"' 'PIIX3 optical CFGM backend sink'
Require-CloakPattern $ahci '"ATAPIProductId"' 'AHCI optical CFGM backend sink'
Require-CloakPattern $ata '"ATAPIRevision"' 'PIIX3 optical revision backend'
Require-CloakPattern $ata '"OverwriteInquiry"' 'IDE direct INQUIRY overwrite backend'
Require-CloakPattern $ahci '"ATAPIVendorId"' 'AHCI optical vendor backend'
Require-CloakPattern $ahci '"ATAPIRevision"' 'AHCI optical revision backend'
Require-CloakPattern $console 'StorageLabOpticalEnabled' 'Independent opt-in must exist'
Require-CloakPattern $console 'if (!fLabOpticalEnabled)' 'Default optical identity must not change'
Require-CloakPattern $console 'if (fHostDrive || fPassThrough)' 'Host optical/passthrough guard'
Require-CloakPattern $console 'CloakStorageLabOpticalSerial(' 'Synthetic stable optical serial per attachment'
Require-CloakPattern $storage 'CloakStorageMaterializeOptical(' 'Optical CFGM materializer'
Require-CloakPattern $storage 'CloakStorageValidateLabOpticalEffective(' 'Optical effective identity validator'
Require-CloakPattern $storage 'CloakStorageValidateLabOpticalCoverage(' 'Optical coverage guard'
Require-CloakPattern $console 'CloakStorageValidateLabOpticalCoverage(fLabOpticalEnabled, cOptical,' 'Optical gate in config path'
Require-CloakPattern $tests 'testStorageLabOpticalMaterialization(hTest);' 'C++ native optical test registered'
$optMaterialize = $console.IndexOf('vrc = CloakStorageMaterializeOptical(&Cfgm, pOpticalSlot, &Optical, fIde)')
$optValidate = $console.IndexOf('vrc = CloakStorageValidateLabOpticalEffective(&Cfgm, pOpticalSlot,')
$optWipe = $console.IndexOf('RTMemWipeThoroughly(szOpticalSerial, sizeof(szOpticalSerial), 3)', $optMaterialize)
if ($optMaterialize -lt 0 -or $optValidate -le $optMaterialize -or $optWipe -le $optValidate) {
    throw 'Optical identity must be validated after materialization and before serial wipe'
}
$hostScriptContent = Load-CloakSource '.github/scripts/Set-CloakLabStorage.ps1'
Require-CloakPattern $hostScriptContent "'EnableOptical','DisableOptical'" 'Poweroff host optical switch'
Require-CloakPattern $hostScriptContent 'VBoxInternal/Cloak/StorageLabOpticalEnabled' 'Optical host ExtraData switch'
Add-CloakRow 'ATAPI_PROFILE_MATERIALIZER' 'WIRED_LAB_OPTIN' $storagePath 'Synthetic virtual IDE/AHCI optical identity, separate disabled-by-default switch, no host passthrough'

foreach ($relative in @(
    'src/VBox/Devices/Storage/VSCSI/VSCSILunSbc.cpp',
    'src/VBox/Devices/Storage/VSCSI/VSCSILunMmc.cpp',
    'src/VBox/Devices/Storage/DrvHostDVD.cpp',
    'src/VBox/Devices/Storage/UsbMsd.cpp'
)) {
    $null=Load-CloakSource $relative
}
Add-CloakRow 'VSCSI_USB_HOSTDVD_MATERIALIZER' 'NOT_WIRED_LAB' 'Storage/VSCSI;DrvHostDVD.cpp;UsbMsd.cpp' 'Backends exist; not provisioned by ATA HDD lab hook'
Add-CloakRow 'GENERAL_FIRMWARE_PCI_HOOKS' 'OUT_OF_SCOPE_FOR_THIS_GATE' 'doc/cloak-plan/CLOAK-PLAN.md' 'Requires independent source/runtime verification before any build'

$report=[pscustomobject][ordered]@{
    SchemaVersion=1
    Audit='Cloak-Lab-Hook-Wiring'
    GeneratedAtUtc=[DateTime]::UtcNow.ToString('o')
    Note='Source-level presence/order checks only; not compiler or VM runtime proof'
    Hooks=@($rows.ToArray())
}
if ($OutputPath) {
    $target=[IO.Path]::GetFullPath($OutputPath)
    [IO.File]::WriteAllText($target,($report|ConvertTo-Json -Depth 6),[Text.Encoding]::UTF8)
    Write-Host ('Hook wiring inventory saved: '+$target)
}
foreach ($item in $report.Hooks) {
    Write-Host ('HOOK [{0}] {1}: {2}' -f $item.Status,$item.Id,$item.Note)
}
Write-Host 'PASS: lab storage hook wiring, source order and explicit residual inventory'
