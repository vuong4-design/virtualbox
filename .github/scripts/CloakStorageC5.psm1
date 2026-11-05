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
            $checks.Add((New-C5Check $index 'SCSI_VPD83' 'NOT_VERIFIED' 'Raw VPD 0x83 page not read; logical_unit_id is not full VPD proof'))
        } else {
            $checks.Add((New-C5Check $index 'SCSI_INQUIRY' 'NOT_APPLICABLE' 'No direct SCSI INQUIRY evidence'))
            $checks.Add((New-C5Check $index 'SCSI_VPD83' 'NOT_APPLICABLE' 'No direct SCSI VPD evidence'))
        }
    }
    foreach ($optical in $OpticalDevices) {
        $checks.Add((New-C5Check -1 'ATAPI_OPTICAL' 'NOT_VERIFIED' 'Optical device present; raw ATAPI INQUIRY not collected'))
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
Export-ModuleMember -Function Test-CloakStorageC5
