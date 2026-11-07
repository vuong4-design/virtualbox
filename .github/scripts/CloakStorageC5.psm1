#requires -Version 5.1
<#
  Storage S3/C5 pure verifier. Takes normalized data; performs no system I/O.
  Missing raw capabilities => NOT_VERIFIED, never automatically PASS.
#>
Set-StrictMode -Version Latest

function Get-C5Field($Value, [string]$Name) {
    if ($null -eq $Value) { return $null }
    $prop = $Value.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}
function Get-C5Text($Value) {
    if ($null -eq $Value) { return '' }
    return (([string]$Value).Trim() -replace '\s+', ' ')
}
function Get-C5PnpPart([string]$Pnp, [string]$Kind) {
    if ($Pnp -match ('(?i)(?:^|&)' + $Kind + '_([^&]+)')) {
        return ($Matches[1].Trim('_') -replace '_+', ' ').ToUpperInvariant()
    }
    return ''
}
function New-C5Check([int]$Disk,[string]$Id,[string]$Status,[string]$Message) {
    return [pscustomobject][ordered]@{Disk=$Disk;Id=$Id;Status=$Status;Note=$Message}
}

function Test-CloakStorageC5 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Disks,
        [object[]]$OpticalDevices = @(),
        [switch]$RequireRaw
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    foreach ($disk in $Disks) {
        $index = [int](Get-C5Field $disk 'Index')
        $model = Get-C5Text (Get-C5Field $disk 'Model')
        $fw = Get-C5Text (Get-C5Field $disk 'Firmware')
        $serialHash = Get-C5Text (Get-C5Field $disk 'SerialSha256')
        $pnp = [string](Get-C5Field $disk 'PnpVendorProduct')
        $bus = (Get-C5Text (Get-C5Field $disk 'BusType')).ToUpperInvariant()
        $media = (Get-C5Text (Get-C5Field $disk 'WindowsMediaType')).ToUpperInvariant()
        $raw = Get-C5Field $disk 'Raw'
        $protocol = (Get-C5Text (Get-C5Field $raw 'Protocol')).ToUpperInvariant()
        $lab = $model -ceq 'LAB ATA DISK'
        $ataNamespace = $protocol -eq 'ATA' -or ($protocol -eq '' -and $bus -in @('SATA','ATA','IDE'))

        if (-not $model -or -not $fw -or ($lab -and -not $serialHash)) {
            if ($lab) {
                $checks.Add((New-C5Check $index 'IDENTITY_WMI' 'FAIL' 'Missing mandatory lab model, firmware or serial hash'))
            } else {
                $checks.Add((New-C5Check $index 'IDENTITY_WMI' 'NOT_VERIFIED' 'Non-lab device identity not fully exposed by Windows'))
            }
        } else {
            $checks.Add((New-C5Check $index 'IDENTITY_WMI' 'PASS' 'WMI identity observed'))
        }
        if ($lab) {
            if ($fw -cne 'LAB1' -or $pnp -cne 'VEN_LAB_ATA&PROD_DISK') {
                $checks.Add((New-C5Check $index 'PROFILE_LAB' 'FAIL' 'Lab firmware or PnP vendor/product differs from profile'))
            } else {
                $checks.Add((New-C5Check $index 'PROFILE_LAB' 'PASS' 'Lab model, firmware and PnP vendor/product agree'))
            }
        }
        # Windows class-driver storage properties are independent read-only
        # observations, NOT direct ATA IDENTIFY / SMART / SCSI INQUIRY.
        $winQuery = Get-C5Field $disk 'WindowsQuery'
        if ($null -eq $winQuery) {
            $osStatus = if (Get-C5Field $disk 'WindowsQueryAttempted') { 'NOT_VERIFIED' } else { 'NOT_APPLICABLE' }
            foreach ($id in @('OS_DEVICE_DESC','OS_PNP_IDENTITY','OS_ATA_IDENTITY','OS_TRIM','OS_SEEK')) {
                $checkStatus = if ($id -eq 'OS_PNP_IDENTITY' -and $ataNamespace) { 'NOT_APPLICABLE' } elseif ($id -eq 'OS_ATA_IDENTITY' -and -not $ataNamespace) { 'NOT_APPLICABLE' } else { $osStatus }
                $checks.Add((New-C5Check $index $id $checkStatus 'Windows storage-property query unavailable, skipped, or different identity namespace'))
            }
        } else {
            $devType = Get-C5Field $winQuery 'DeviceType'
            if ($null -eq $devType) {
                $checks.Add((New-C5Check $index 'OS_DEVICE_DESC' 'NOT_VERIFIED' 'Windows device descriptor unavailable'))
            } elseif ([int]$devType -ne 0) {
                $checks.Add((New-C5Check $index 'OS_DEVICE_DESC' 'FAIL' 'Windows disk descriptor is not direct-access device type'))
            } else {
                $checks.Add((New-C5Check $index 'OS_DEVICE_DESC' 'PASS' 'Windows descriptor reports direct-access device'))
            }
            $osVendor = (Get-C5Text (Get-C5Field $winQuery 'Vendor')).ToUpperInvariant()
            $osProduct = (Get-C5Text (Get-C5Field $winQuery 'Product')).ToUpperInvariant()
            $osRevision = (Get-C5Text (Get-C5Field $winQuery 'Revision')).ToUpperInvariant()
            $pnpVendor = Get-C5PnpPart $pnp 'VEN'
            $pnpProduct = Get-C5PnpPart $pnp 'PROD'
            if ($ataNamespace) {
                # SATA descriptors can legitimately have Vendor="" and
                # Product="LAB ATA DISK", unlike PnP VEN_LAB_ATA&PROD_DISK.
                # Never assume those are the same vendor/product namespace.
                $checks.Add((New-C5Check $index 'OS_PNP_IDENTITY' 'NOT_APPLICABLE' 'ATA PnP VEN/PROD fields cannot be directly equated to descriptor vendor/product; PnP checked independently'))
                $descriptorModel = (Get-C5Text (($osVendor + ' ' + $osProduct).Trim())).ToUpperInvariant()
                $rawModel = (Get-C5Text (Get-C5Field $raw 'Model')).ToUpperInvariant()
                $rawFw = (Get-C5Text (Get-C5Field $raw 'Firmware')).ToUpperInvariant()
                if ($null -eq $devType -or [int]$devType -ne 0 -or -not $descriptorModel -or -not $osRevision -or -not $model -or -not $fw -or -not $rawModel -or -not $rawFw) {
                    $checks.Add((New-C5Check $index 'OS_ATA_IDENTITY' 'NOT_VERIFIED' 'ATA descriptor/product/revision or independent WMI/ATA fields missing'))
                } elseif ($descriptorModel -ine $model -or $descriptorModel -ine $rawModel -or $osRevision -ine $fw -or $osRevision -ine $rawFw) {
                    $checks.Add((New-C5Check $index 'OS_ATA_IDENTITY' 'FAIL' 'ATA storage descriptor model/revision disagree with WMI or raw ATA IDENTIFY'))
                } else {
                    $checks.Add((New-C5Check $index 'OS_ATA_IDENTITY' 'PASS' 'ATA descriptor product/revision agree with WMI and raw ATA; vendor may be blank'))
                }
            } else {
                $checks.Add((New-C5Check $index 'OS_ATA_IDENTITY' 'NOT_APPLICABLE' 'Direct ATA evidence not present'))
                if (-not $osVendor -or -not $osProduct -or -not $pnpVendor -or -not $pnpProduct) {
                    $checks.Add((New-C5Check $index 'OS_PNP_IDENTITY' 'NOT_VERIFIED' 'OS descriptor or PnP vendor/product not available'))
                } elseif ($osVendor -eq $pnpVendor -and $osProduct -eq $pnpProduct) {
                    $checks.Add((New-C5Check $index 'OS_PNP_IDENTITY' 'PASS' 'Non-ATA descriptor and PnP vendor/product agree'))
                } else {
                    $checks.Add((New-C5Check $index 'OS_PNP_IDENTITY' 'FAIL' 'Non-ATA storage descriptor vendor/product conflict with PnP'))
                }
            }
            $osTrim = Get-C5Field $winQuery 'TrimEnabled'
            if ($null -eq $osTrim) {
                $checks.Add((New-C5Check $index 'OS_TRIM' 'NOT_VERIFIED' 'Windows trim property unavailable'))
            } else {
                $checks.Add((New-C5Check $index 'OS_TRIM' 'PASS' ('Windows storage stack TrimEnabled=' + [bool]$osTrim + '; not raw ATA word 169')))
            }
            $osSeek = Get-C5Field $winQuery 'IncursSeekPenalty'
            if ($null -eq $osSeek) {
                $seekDiag = Get-C5Field (Get-C5Field $winQuery 'QueryDiagnostics') 'SeekPenalty'
                $seekError = Get-C5Field $seekDiag 'Win32Error'
                if ($null -ne $seekError -and [int]$seekError -eq 31) {
                    $checks.Add((New-C5Check $index 'OS_SEEK' 'NOT_VERIFIED' 'Windows SeekPenalty returned ERROR_GEN_FAILURE (Win32 31); this is not proof of unsupported media or HDD/SSD'))
                } elseif ($null -ne $seekError -and [int]$seekError -in @(1,50)) {
                    $checks.Add((New-C5Check $index 'OS_SEEK' 'NOT_VERIFIED' ('SeekPenalty property request was rejected (Win32 '+[int]$seekError+'); no rotation inferred')))
                } else {
                    $checks.Add((New-C5Check $index 'OS_SEEK' 'NOT_VERIFIED' 'Windows seek-penalty property unavailable; no rotation inferred'))
                }
            } else {
                $checks.Add((New-C5Check $index 'OS_SEEK' 'PASS' ('Windows storage stack IncursSeekPenalty=' + [bool]$osSeek + '; not raw ATA word 217')))
            }
        }

        if ($null -eq $raw) {
            foreach ($id in @('RAW_MODEL','RAW_FIRMWARE','RAW_SERIAL','SMART','TRIM','ROTATION','TRANSPORT')) {
                $checks.Add((New-C5Check $index $id 'NOT_VERIFIED' 'Direct ATA/SCSI observation unavailable'))
            }
            if ($null -eq (Get-C5Field $disk 'HostDiscard')) {
                $checks.Add((New-C5Check $index 'HOST_TRIM' 'NOT_APPLICABLE' 'No mapped host attachment'))
            } else {
                $checks.Add((New-C5Check $index 'HOST_TRIM' 'NOT_VERIFIED' 'Host discard known, raw TRIM unavailable'))
            }
            if ($null -eq (Get-C5Field $disk 'HostNonRotational')) {
                $checks.Add((New-C5Check $index 'HOST_ROTATION' 'NOT_APPLICABLE' 'No mapped host attachment'))
            } else {
                $checks.Add((New-C5Check $index 'HOST_ROTATION' 'NOT_VERIFIED' 'Host rotation known, guest rotation unavailable'))
            }
            $checks.Add((New-C5Check $index 'SCSI_INQUIRY' 'NOT_APPLICABLE' 'No direct SCSI evidence'))
            $checks.Add((New-C5Check $index 'SCSI_VPD83' 'NOT_APPLICABLE' 'No direct SCSI evidence'))
            continue
        }
        foreach ($item in @(
            @{Id='RAW_MODEL'; Expected=$model; Actual=(Get-C5Text (Get-C5Field $raw 'Model'))},
            @{Id='RAW_FIRMWARE'; Expected=$fw; Actual=(Get-C5Text (Get-C5Field $raw 'Firmware'))},
            @{Id='RAW_SERIAL'; Expected=$serialHash; Actual=(Get-C5Text (Get-C5Field $raw 'SerialSha256'))}
        )) {
            if (-not $item.Expected -or -not $item.Actual) {
                $checks.Add((New-C5Check $index $item.Id 'NOT_VERIFIED' 'Independent value unavailable'))
            } elseif ($item.Expected -ieq $item.Actual) {
                $checks.Add((New-C5Check $index $item.Id 'PASS' 'Independent device identity agrees with WMI'))
            } else {
                $checks.Add((New-C5Check $index $item.Id 'FAIL' 'Independent device identity conflicts with WMI'))
            }
        }
        $smartAvailable = Get-C5Field $raw 'SmartAvailable'
        $smartEnabled = Get-C5Field $raw 'SmartEnabled'
        if ($null -eq $smartAvailable -or $null -eq $smartEnabled) {
            $checks.Add((New-C5Check $index 'SMART' 'NOT_VERIFIED' 'SMART support/enabled not both observed'))
        } elseif (-not [bool]$smartAvailable -and [bool]$smartEnabled) {
            $checks.Add((New-C5Check $index 'SMART' 'FAIL' 'SMART enabled but unsupported'))
        } else {
            $checks.Add((New-C5Check $index 'SMART' 'PASS' 'SMART support/enabled flags consistent; no SMART operation exercised'))
        }

        $trim = Get-C5Field $raw 'TrimSupported'
        if ($null -eq $trim) {
            $checks.Add((New-C5Check $index 'TRIM' 'NOT_VERIFIED' 'Raw TRIM capability not exposed; OS policy is not device support'))
        } else {
            $checks.Add((New-C5Check $index 'TRIM' 'PASS' ('Device reports TRIM supported=' + [bool]$trim + '; no command sent')))
        }

        $rotation = Get-C5Field $raw 'RotationRate'
        if ($null -eq $rotation -or "$rotation" -notmatch '^\d+$') {
            $checks.Add((New-C5Check $index 'ROTATION' 'NOT_VERIFIED' 'No raw rotation observation (ATA word 217 / SCSI VPD)'))
        } else {
            $rpm = [int]$rotation
            $kind = if ($rpm -in @(0,1)) {'SSD'} elseif ($rpm -ge 100) {'HDD'} else {'UNKNOWN'}
            if ($kind -eq 'UNKNOWN' -or $media -notin @('SSD','HDD')) {
                $checks.Add((New-C5Check $index 'ROTATION' 'NOT_VERIFIED' 'Rotation observed but matching Windows MediaType unknown'))
            } elseif ($kind -ne $media) {
                $checks.Add((New-C5Check $index 'ROTATION' 'FAIL' 'Rotation conflicts with Windows MediaType'))
            } else {
                $checks.Add((New-C5Check $index 'ROTATION' 'PASS' 'Raw rotation and Windows MediaType agree'))
            }
        }

        # ATA word 217: zero/0xffff means unreported; host rotation flags
        # must not be treated as a substitute for a valid ATA response.
        $rawWord217 = Get-C5Field $raw 'RotationWord217'
        if ($protocol -ne 'ATA') {
            $checks.Add((New-C5Check $index 'ATA_WORD217' 'NOT_APPLICABLE' 'Not a direct ATA IDENTIFY observation'))
        } elseif ($null -eq $rawWord217 -and (Get-C5Field $raw 'Source') -eq 'smartctl-json-info') {
            $checks.Add((New-C5Check $index 'ATA_WORD217' 'NOT_APPLICABLE' 'smartctl summary does not expose native ATA word 217 bytes'))
        } elseif ($null -eq $rawWord217) {
            $checks.Add((New-C5Check $index 'ATA_WORD217' 'NOT_VERIFIED' 'ATA word 217 not available from direct IDENTIFY source'))
        } elseif ([int]$rawWord217 -in @(0,65535)) {
            $checks.Add((New-C5Check $index 'ATA_WORD217' 'NOT_VERIFIED' 'ATA word 217 does not report a reliable rotation rate'))
        } elseif ([int]$rawWord217 -eq 1 -or ([int]$rawWord217 -ge 100 -and [int]$rawWord217 -le 65534)) {
            if ($null -ne $rotation -and [int]$rotation -ne [int]$rawWord217) {
                $checks.Add((New-C5Check $index 'ATA_WORD217' 'FAIL' 'Normalized rotation disagrees with ATA word 217'))
            } else {
                $checks.Add((New-C5Check $index 'ATA_WORD217' 'PASS' 'ATA rotation word is reported; no HDD/SSD inferred from host flag'))
            }
        } else {
            $checks.Add((New-C5Check $index 'ATA_WORD217' 'NOT_VERIFIED' 'ATA rotation word 217 is reserved or unknown'))
        }

        # Windows storage-class properties are OS-interpreted observations.
        # Compare them to raw ATA evidence only when both are present.
        $osTrimFlag = Get-C5Field $winQuery 'TrimEnabled'
        if ($null -eq $osTrimFlag -or $null -eq $trim) {
            $checks.Add((New-C5Check $index 'OS_RAW_TRIM' 'NOT_APPLICABLE' 'Windows trim or direct ATA support unavailable'))
        } elseif ([bool]$osTrimFlag -and -not [bool]$trim) {
            $checks.Add((New-C5Check $index 'OS_RAW_TRIM' 'FAIL' 'Windows reports TRIM enabled but raw ATA says unsupported'))
        } else {
            $checks.Add((New-C5Check $index 'OS_RAW_TRIM' 'PASS' 'Windows TRIM state is compatible with raw ATA support'))
        }
        $osSeekFlag = Get-C5Field $winQuery 'IncursSeekPenalty'
        if ($null -eq $osSeekFlag -or $null -eq $rotation -or "$rotation" -notmatch '^\d+$') {
            $checks.Add((New-C5Check $index 'OS_RAW_ROTATION' 'NOT_APPLICABLE' 'Windows seek or direct ATA rotation unavailable'))
        } elseif (([int]$rotation -eq 1 -and [bool]$osSeekFlag) -or
                  ([int]$rotation -ge 100 -and -not [bool]$osSeekFlag)) {
            $checks.Add((New-C5Check $index 'OS_RAW_ROTATION' 'FAIL' 'Windows seek penalty conflicts with raw rotation'))
        } elseif ([int]$rotation -eq 1 -or [int]$rotation -ge 100) {
            $checks.Add((New-C5Check $index 'OS_RAW_ROTATION' 'PASS' 'Windows seek penalty and raw rotation agree'))
        } else {
            $checks.Add((New-C5Check $index 'OS_RAW_ROTATION' 'NOT_APPLICABLE' 'Unclassified rotation value'))
        }

        # Cross-check host-side attachment flags only when a verified
        # controller/port/unit to Windows disk index binding is supplied.
        $hostDiscard = Get-C5Field $disk 'HostDiscard'
        if ($null -eq $hostDiscard) {
            $checks.Add((New-C5Check $index 'HOST_TRIM' 'NOT_APPLICABLE' 'No mapped host discard flag supplied'))
        } elseif ($null -eq $trim) {
            $checks.Add((New-C5Check $index 'HOST_TRIM' 'NOT_VERIFIED' 'Host discard flag known; raw ATA/SCSI TRIM unavailable'))
        } elseif ([bool]$hostDiscard -ne [bool]$trim) {
            $checks.Add((New-C5Check $index 'HOST_TRIM' 'FAIL' 'Host discard flag conflicts with guest TRIM capability'))
        } else {
            $checks.Add((New-C5Check $index 'HOST_TRIM' 'PASS' 'Host discard flag and guest TRIM capability agree'))
        }
        $hostNonRotational = Get-C5Field $disk 'HostNonRotational'
        if ($null -eq $hostNonRotational) {
            $checks.Add((New-C5Check $index 'HOST_ROTATION' 'NOT_APPLICABLE' 'No mapped host nonrotational flag supplied'))
        } elseif ($null -eq $rotation -or "$rotation" -notmatch '^\d+$') {
            $checks.Add((New-C5Check $index 'HOST_ROTATION' 'NOT_VERIFIED' 'Host rotation flag known; guest rotation not exposed'))
        } elseif ([int]$rotation -in @(0,1)) {
            if ([bool]$hostNonRotational) {
                $checks.Add((New-C5Check $index 'HOST_ROTATION' 'PASS' 'Host nonrotational and guest SSD rotation agree'))
            } else {
                $checks.Add((New-C5Check $index 'HOST_ROTATION' 'FAIL' 'Host marks rotating but guest says nonrotating'))
            }
        } elseif ([int]$rotation -ge 100) {
            if (-not [bool]$hostNonRotational) {
                $checks.Add((New-C5Check $index 'HOST_ROTATION' 'PASS' 'Host rotating and guest HDD rotation agree'))
            } else {
                $checks.Add((New-C5Check $index 'HOST_ROTATION' 'FAIL' 'Host marks nonrotating but guest reports RPM'))
            }
        } else {
            $checks.Add((New-C5Check $index 'HOST_ROTATION' 'NOT_VERIFIED' 'Rotation value is not classifiable'))
        }

        if (-not $bus -or -not $protocol) {
            $checks.Add((New-C5Check $index 'TRANSPORT' 'NOT_VERIFIED' 'Windows bus or raw protocol unknown'))
        } elseif (($protocol -eq 'NVME' -and $bus -in @('SATA','ATA','IDE','SCSI')) -or
                  ($bus -eq 'NVME' -and $protocol -in @('ATA','SCSI'))) {
            $checks.Add((New-C5Check $index 'TRANSPORT' 'FAIL' 'NVMe/non-NVMe protocol contradiction'))
        } elseif ($protocol -eq 'ATA' -and $bus -in @('SATA','ATA','IDE')) {
            $checks.Add((New-C5Check $index 'TRANSPORT' 'PASS' 'ATA and Windows transport compatible'))
        } else {
            $checks.Add((New-C5Check $index 'TRANSPORT' 'NOT_VERIFIED' 'SAT/USB/RAID translation may affect transport naming'))
        }

        if ($protocol -eq 'SCSI') {
            $ven = (Get-C5Text (Get-C5Field $raw 'ScsiVendor')).ToUpperInvariant()
            $prod = (Get-C5Text (Get-C5Field $raw 'ScsiProduct')).ToUpperInvariant()
            $rev = Get-C5Text (Get-C5Field $raw 'ScsiRevision')
            $winVen = Get-C5PnpPart $pnp 'VEN'
            $winProd = Get-C5PnpPart $pnp 'PROD'
            if (-not $ven -or -not $prod -or -not $winVen -or -not $winProd) {
                $checks.Add((New-C5Check $index 'SCSI_INQUIRY' 'NOT_VERIFIED' 'Direct SCSI vendor/product or PnP unavailable'))
            } elseif ($ven -ne $winVen -or $prod -ne $winProd) {
                $checks.Add((New-C5Check $index 'SCSI_INQUIRY' 'FAIL' 'Direct SCSI INQUIRY vendor/product conflicts with PnP'))
            } elseif ($rev -and $fw -and $rev -ine $fw) {
                $checks.Add((New-C5Check $index 'SCSI_INQUIRY' 'FAIL' 'INQUIRY revision conflicts with firmware'))
            } else {
                $checks.Add((New-C5Check $index 'SCSI_INQUIRY' 'PASS' 'Direct SCSI INQUIRY agrees with PnP identity'))
            }
            $vpd83 = Get-C5Field $raw 'Vpd83'
            $identifierCount = Get-C5Field $vpd83 'IdentifierCount'
            $vpdType = Get-C5Field $vpd83 'DeviceType'
            if ($null -eq $vpd83 -or $null -eq $identifierCount -or [int]$identifierCount -eq 0) {
                $checks.Add((New-C5Check $index 'SCSI_VPD83' 'NOT_VERIFIED' 'No complete direct VPD 0x83 designator observed'))
            } elseif ($null -eq $vpdType -or [int]$vpdType -ne 0) {
                $checks.Add((New-C5Check $index 'SCSI_VPD83' 'FAIL' 'VPD 0x83 peripheral type disagrees with direct-access disk'))
            } else {
                $checks.Add((New-C5Check $index 'SCSI_VPD83' 'PASS' 'Direct VPD 0x83 parsed with nonempty device identifiers; values redacted'))
            }
        } else {
            $checks.Add((New-C5Check $index 'SCSI_INQUIRY' 'NOT_APPLICABLE' 'No direct SCSI INQUIRY evidence'))
            $checks.Add((New-C5Check $index 'SCSI_VPD83' 'NOT_APPLICABLE' 'No direct SCSI VPD evidence'))
        }
    }
    foreach ($optical in $OpticalDevices) {
        $opticalIndex = Get-C5Field $optical 'Index'
        if ($null -eq $opticalIndex) { $opticalIndex = 0 }
        $slot = -1 - [int]$opticalIndex
        $pnp = [string](Get-C5Field $optical 'PnpVendorProduct')
        $pnVendor = Get-C5PnpPart $pnp 'VEN'
        $pnProduct = Get-C5PnpPart $pnp 'PROD'
        $desc = Get-C5Field $optical 'WindowsQuery'
        $inq = Get-C5Field $optical 'RawInquiry'
        # Optical lab is separately opt-in and must present a coherent
        # synthetic LAB/CD-ROM/LAB1 identity in all three guest layers.
        # An unmodified VBOX optical remains a documented, valid residual.
        if ($pnVendor -eq 'LAB') {
            $labInqVendor = (Get-C5Text (Get-C5Field $inq 'Vendor')).ToUpperInvariant()
            $labInqProduct = (Get-C5Text (Get-C5Field $inq 'Product')).ToUpperInvariant()
            $labInqRevision = (Get-C5Text (Get-C5Field $inq 'Revision')).ToUpperInvariant()
            $labOsVendor = (Get-C5Text (Get-C5Field $desc 'Vendor')).ToUpperInvariant()
            $labOsProduct = (Get-C5Text (Get-C5Field $desc 'Product')).ToUpperInvariant()
            $labOsRevision = (Get-C5Text (Get-C5Field $desc 'Revision')).ToUpperInvariant()
            if ($pnProduct -ne 'CD-ROM') {
                $checks.Add((New-C5Check $slot 'OPTICAL_LAB_SCOPE' 'FAIL' 'Unexpected PnP product for synthetic LAB optical profile'))
            } elseif (-not $labInqVendor -or -not $labInqProduct -or -not $labInqRevision -or -not $labOsVendor -or -not $labOsProduct -or -not $labOsRevision) {
                $checks.Add((New-C5Check $slot 'OPTICAL_LAB_SCOPE' 'NOT_VERIFIED' 'LAB optical PnP present, but direct INQUIRY or Windows descriptor incomplete'))
            } elseif ($labInqVendor -ne 'LAB' -or $labInqProduct -ne 'CD-ROM' -or $labInqRevision -ne 'LAB1' -or
                    $labOsVendor -ne 'LAB' -or $labOsProduct -ne 'CD-ROM' -or $labOsRevision -ne 'LAB1') {
                $checks.Add((New-C5Check $slot 'OPTICAL_LAB_SCOPE' 'FAIL' 'LAB optical identity conflicts with the synthetic lab optical contract'))
            } else {
                $checks.Add((New-C5Check $slot 'OPTICAL_LAB_SCOPE' 'PASS' 'Synthetic LAB optical profile matches PnP, OS descriptor and direct INQUIRY'))
            }
        } elseif ($pnVendor -eq 'VBOX') {
            $checks.Add((New-C5Check $slot 'OPTICAL_LAB_SCOPE' 'NOT_APPLICABLE' 'Unmodified VBOX CD-ROM remains outside opt-in optical lab profile'))
        } else {
            $checks.Add((New-C5Check $slot 'OPTICAL_LAB_SCOPE' 'NOT_APPLICABLE' 'Optical identity does not claim the synthetic LAB profile'))
        }
        $descVen = (Get-C5Text (Get-C5Field $desc 'Vendor')).ToUpperInvariant()
        $descProd = (Get-C5Text (Get-C5Field $desc 'Product')).ToUpperInvariant()
        $descRev = Get-C5Text (Get-C5Field $desc 'Revision')
        $type = Get-C5Field $desc 'DeviceType'
        if ($null -eq $desc -or $null -eq $type -or -not $descVen -or -not $descProd) {
            $checks.Add((New-C5Check $slot 'OPTICAL_OS_DESCRIPTOR' 'NOT_VERIFIED' 'Windows optical storage descriptor missing'))
        } elseif ([int]$type -ne 5) {
            $checks.Add((New-C5Check $slot 'OPTICAL_OS_DESCRIPTOR' 'FAIL' 'Optical descriptor is not SCSI peripheral type 5'))
        } elseif ($pnVendor -and $pnProduct -and ($descVen -ne $pnVendor -or $descProd -ne $pnProduct)) {
            $checks.Add((New-C5Check $slot 'OPTICAL_OS_DESCRIPTOR' 'FAIL' 'Optical descriptor conflicts with PnP vendor/product'))
        } else {
            $checks.Add((New-C5Check $slot 'OPTICAL_OS_DESCRIPTOR' 'PASS' 'Windows optical descriptor valid; OS-mediated, not direct INQUIRY'))
        }

        $inqVen = (Get-C5Text (Get-C5Field $inq 'Vendor')).ToUpperInvariant()
        $inqProd = (Get-C5Text (Get-C5Field $inq 'Product')).ToUpperInvariant()
        $inqRev = Get-C5Text (Get-C5Field $inq 'Revision')
        $inqType = Get-C5Field $inq 'DeviceType'
        if ($null -eq $inq -or $null -eq $inqType -or -not $inqVen -or -not $inqProd) {
            $checks.Add((New-C5Check $slot 'ATAPI_OPTICAL' 'NOT_VERIFIED' 'Direct read-only SCSI INQUIRY unavailable'))
        } elseif ([int]$inqType -ne 5) {
            $checks.Add((New-C5Check $slot 'ATAPI_OPTICAL' 'FAIL' 'Direct SCSI INQUIRY peripheral type is not CD/DVD'))
        } elseif ($descVen -and $descProd -and ($inqVen -ne $descVen -or $inqProd -ne $descProd)) {
            $checks.Add((New-C5Check $slot 'ATAPI_OPTICAL' 'FAIL' 'Direct optical INQUIRY disagrees with Windows storage descriptor'))
        } elseif ($pnVendor -and $pnProduct -and ($inqVen -ne $pnVendor -or $inqProd -ne $pnProduct)) {
            $checks.Add((New-C5Check $slot 'ATAPI_OPTICAL' 'FAIL' 'Direct optical INQUIRY disagrees with PnP'))
        } elseif ($descRev -and $inqRev -and $inqRev -ine $descRev) {
            $checks.Add((New-C5Check $slot 'ATAPI_OPTICAL' 'FAIL' 'Direct optical INQUIRY revision disagrees with descriptor'))
        } elseif (($pnVendor -and $pnProduct) -or ($descVen -and $descProd)) {
            $checks.Add((New-C5Check $slot 'ATAPI_OPTICAL' 'PASS' 'Direct read-only SCSI INQUIRY agrees with available Windows identity'))
        } else {
            $checks.Add((New-C5Check $slot 'ATAPI_OPTICAL' 'NOT_VERIFIED' 'Raw INQUIRY read but no independent vendor/product to compare'))
        }
        $optVpd = Get-C5Field $optical 'RawVpd83'
        $optVpdType = Get-C5Field $optVpd 'DeviceType'
        $optCount = Get-C5Field $optVpd 'IdentifierCount'
        if ($null -eq $optVpd -or $null -eq $optCount -or [int]$optCount -eq 0) {
            $checks.Add((New-C5Check $slot 'OPTICAL_VPD83' 'NOT_VERIFIED' 'No complete optical VPD 0x83 designator reported'))
        } elseif ($null -eq $optVpdType -or [int]$optVpdType -ne 5) {
            $checks.Add((New-C5Check $slot 'OPTICAL_VPD83' 'FAIL' 'Optical VPD 0x83 peripheral type disagrees with CD/DVD'))
        } else {
            $checks.Add((New-C5Check $slot 'OPTICAL_VPD83' 'PASS' 'Optical VPD 0x83 contains designators; identifiers redacted'))
        }
    }
    $failed = @($checks | Where-Object Status -eq 'FAIL').Count
    $missing = @($checks | Where-Object Status -eq 'NOT_VERIFIED').Count
    $passed = @($checks | Where-Object Status -eq 'PASS').Count
    $status = if ($failed) { 'FAIL' } elseif ($missing) { if ($RequireRaw) { 'INCOMPLETE' } else { 'PARTIAL' } } else { 'PASS' }
    return [pscustomobject][ordered]@{
        SchemaVersion=1; Audit='Storage-S3-C5'; Overall=$status
        Passed=$passed; Failed=$failed; NotVerified=$missing
        Checks=@($checks.ToArray())
    }
}
function Compare-CloakStorageS3Evidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$Baseline,
        [Parameter(Mandatory=$true)]$Current
    )
    if ([int](Get-C5Field $Baseline 'SchemaVersion') -ne 1 -or
        [int](Get-C5Field $Current 'SchemaVersion') -ne 1 -or
        [string](Get-C5Field $Baseline 'Audit') -ne 'Storage-S3-C5' -or
        [string](Get-C5Field $Current 'Audit') -ne 'Storage-S3-C5') {
        throw 'S3 lifecycle baseline/current report schema invalid'
    }
    $checks = [System.Collections.Generic.List[object]]::new()
    $baseDisks = @(Get-C5Field $Baseline 'Disks')
    $newDisks = @(Get-C5Field $Current 'Disks')
    if ($baseDisks.Count -ne $newDisks.Count) {
        $checks.Add((New-C5Check -1 'LIFECYCLE_DISK_COUNT' 'FAIL' 'Disk count changed after cold boot/snapshot'))
    } else {
        $checks.Add((New-C5Check -1 'LIFECYCLE_DISK_COUNT' 'PASS' 'Disk count unchanged'))
    }
    foreach ($b in $baseDisks) {
        $index = [int](Get-C5Field $b 'Index')
        $matched = @($newDisks | Where-Object { [int]$_.Index -eq $index })
        if ($matched.Count -ne 1) {
            $checks.Add((New-C5Check $index 'LIFECYCLE_DISK_INDEX' 'FAIL' 'Disk index no longer maps uniquely'))
            continue
        }
        $c = $matched[0]
        foreach ($field in @('Model','Firmware','SerialSha256','PnpVendorProduct','BusType')) {
            $old = Get-C5Text (Get-C5Field $b $field)
            $now = Get-C5Text (Get-C5Field $c $field)
            if (-not $old -or -not $now) {
                $checks.Add((New-C5Check $index ('LIFECYCLE_'+$field.ToUpperInvariant()) 'NOT_VERIFIED' 'Identity field missing in one audit'))
            } elseif ($old -cne $now) {
                $checks.Add((New-C5Check $index ('LIFECYCLE_'+$field.ToUpperInvariant()) 'FAIL' 'Identity drift detected after cold boot/snapshot'))
            } else {
                $checks.Add((New-C5Check $index ('LIFECYCLE_'+$field.ToUpperInvariant()) 'PASS' 'Identity unchanged'))
            }
        }
        $bRaw = Get-C5Field $b 'Raw'
        $cRaw = Get-C5Field $c 'Raw'
        foreach ($field in @('Model','Firmware','SerialSha256','SmartAvailable','SmartEnabled','TrimSupported','RotationWord217')) {
            $old = Get-C5Field $bRaw $field
            $now = Get-C5Field $cRaw $field
            $id = 'LIFECYCLE_RAW_'+$field.ToUpperInvariant()
            if ($null -eq $old -or $null -eq $now) {
                $checks.Add((New-C5Check $index $id 'NOT_VERIFIED' 'Direct ATA evidence missing on one side'))
            } elseif ([string]$old -cne [string]$now) {
                $checks.Add((New-C5Check $index $id 'FAIL' 'Raw device field changed after cold boot/snapshot'))
            } else {
                $checks.Add((New-C5Check $index $id 'PASS' 'Raw ATA capability/identity unchanged'))
            }
        }
        foreach ($field in @('HostNonRotational','HostDiscard')) {
            $old = Get-C5Field $b $field
            $now = Get-C5Field $c $field
            $id = 'LIFECYCLE_'+$field.ToUpperInvariant()
            if ($null -eq $old -or $null -eq $now) {
                $checks.Add((New-C5Check $index $id 'NOT_APPLICABLE' 'Host attachment flag not mapped in both runs'))
            } elseif ([string]$old -cne [string]$now) {
                $checks.Add((New-C5Check $index $id 'FAIL' 'Host attachment flag changed between audits'))
            } else {
                $checks.Add((New-C5Check $index $id 'PASS' 'Mapped host attachment flag unchanged'))
            }
        }
    }
    $baseOpt = @(Get-C5Field $Baseline 'OpticalDevices')
    $newOpt = @(Get-C5Field $Current 'OpticalDevices')
    if ($baseOpt.Count -ne $newOpt.Count) {
        $checks.Add((New-C5Check -1 'LIFECYCLE_OPTICAL_COUNT' 'FAIL' 'Optical device count changed'))
    } else {
        $checks.Add((New-C5Check -1 'LIFECYCLE_OPTICAL_COUNT' 'PASS' 'Optical device count unchanged'))
    }
    foreach ($b in $baseOpt) {
        $index = [int](Get-C5Field $b 'Index')
        $slot = -1 - $index
        $matched = @($newOpt | Where-Object { [int]$_.Index -eq $index })
        if ($matched.Count -ne 1) {
            $checks.Add((New-C5Check $slot 'LIFECYCLE_OPTICAL_INDEX' 'FAIL' 'Optical index mapping changed'))
            continue
        }
        $c = $matched[0]
        $bPnp = Get-C5Text (Get-C5Field $b 'PnpVendorProduct')
        $cPnp = Get-C5Text (Get-C5Field $c 'PnpVendorProduct')
        if (-not $bPnp -or -not $cPnp) {
            $checks.Add((New-C5Check $slot 'LIFECYCLE_OPTICAL_PNP' 'NOT_VERIFIED' 'Optical PnP missing'))
        } elseif ($bPnp -cne $cPnp) {
            $checks.Add((New-C5Check $slot 'LIFECYCLE_OPTICAL_PNP' 'FAIL' 'Optical PnP vendor/product drift'))
        } else {
            $checks.Add((New-C5Check $slot 'LIFECYCLE_OPTICAL_PNP' 'PASS' 'Optical PnP stable'))
        }
        $bInquiry = Get-C5Field $b 'RawInquiry'
        $cInquiry = Get-C5Field $c 'RawInquiry'
        foreach ($field in @('Vendor','Product','Revision')) {
            $old = Get-C5Text (Get-C5Field $bInquiry $field)
            $now = Get-C5Text (Get-C5Field $cInquiry $field)
            $id = 'LIFECYCLE_OPTICAL_'+$field.ToUpperInvariant()
            if (-not $old -or -not $now) {
                $checks.Add((New-C5Check $slot $id 'NOT_VERIFIED' 'Direct optical INQUIRY not available on both runs'))
            } elseif ($old -cne $now) {
                $checks.Add((New-C5Check $slot $id 'FAIL' 'Optical direct INQUIRY identity drift'))
            } else {
                $checks.Add((New-C5Check $slot $id 'PASS' 'Optical direct INQUIRY stable'))
            }
        }
    }
    $failed = @($checks | Where-Object Status -eq 'FAIL').Count
    $unverified = @($checks | Where-Object Status -eq 'NOT_VERIFIED').Count
    return [pscustomobject][ordered]@{
        Audit='Storage-S3-Lifecycle'
        Overall=$(if ($failed -gt 0) {'FAIL'} elseif ($unverified -gt 0) {'PARTIAL'} else {'PASS'})
        Failed=$failed
        NotVerified=$unverified
        Checks=@($checks.ToArray())
    }
}

function Get-CloakStorageC5Contract {
    return [pscustomobject]@{ Release='S3-C5-2026-11-B4'; SchemaVersion=1; CapabilityChecks='S3-C5-B4' }
}
Export-ModuleMember -Function Test-CloakStorageC5,Compare-CloakStorageS3Evidence,Get-CloakStorageC5Contract
