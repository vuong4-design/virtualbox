#requires -Version 5.1
<#
  Windows Storage S3 read-only IOCTL_STORAGE_QUERY_PROPERTY collector.
  Windows storage-stack descriptors are NOT raw ATA IDENTIFY/SCSI INQUIRY.
  The module returns sanitized properties only, never serials or device paths.
#>
Set-StrictMode -Version Latest

function Read-C5Ascii([byte[]]$Bytes, [uint32]$Offset) {
    if ($Offset -eq 0 -or $Offset -ge $Bytes.Length) { return '' }
    $start = [int]$Offset
    $length = 0
    while ($start + $length -lt $Bytes.Length -and $length -lt 64 -and
           $Bytes[$start + $length] -ne 0) { $length++ }
    if ($length -eq 0 -or $length -ge 64) { return '' }
    $raw = [Text.Encoding]::ASCII.GetString($Bytes, $start, $length)
    if ($raw -match '[^\x20-\x7e]') { return '' }
    return $raw.Trim()
}

function ConvertFrom-CloakStorageDescriptor {
    [CmdletBinding()]
    param([byte[]]$Device, [byte[]]$Trim, [byte[]]$Seek)
    $result = [pscustomobject][ordered]@{
        Source = 'Windows-IOCTL_STORAGE_QUERY_PROPERTY'
        DeviceType = $null
        BusTypeCode = $null
        Vendor = ''
        Product = ''
        Revision = ''
        TrimEnabled = $null
        IncursSeekPenalty = $null
    }
    # STORAGE_DEVICE_DESCRIPTOR: Version/Size at 0/4, DeviceType at 8,
    # vendor/product/revision offsets at 12/16/20, BusType at 28.
    if ($null -ne $Device -and $Device.Length -ge 36) {
        $version = [BitConverter]::ToUInt32($Device, 0)
        $declared = [BitConverter]::ToUInt32($Device, 4)
        if ($version -ge 36 -and $version -le $declared -and
            $declared -ge 36 -and $declared -le $Device.Length) {
            $deviceBytes = New-Object byte[] ([int]$declared)
            [Array]::Copy($Device, $deviceBytes, [int]$declared)
            $result.DeviceType = [int]$Device[8]
            $result.BusTypeCode = [int][BitConverter]::ToUInt32($Device, 28)
            $result.Vendor = Read-C5Ascii $deviceBytes ([BitConverter]::ToUInt32($Device,12))
            $result.Product = Read-C5Ascii $deviceBytes ([BitConverter]::ToUInt32($Device,16))
            $result.Revision = Read-C5Ascii $deviceBytes ([BitConverter]::ToUInt32($Device,20))
        }
    }
    foreach ($item in @(@{Bytes=$Trim;Field='TrimEnabled'},@{Bytes=$Seek;Field='IncursSeekPenalty'})) {
        $bytes = $item.Bytes
        if ($null -eq $bytes -or $bytes.Length -lt 9) { continue }
        $length = [BitConverter]::ToUInt32($bytes,4)
        if ($length -lt 9 -or $length -gt $bytes.Length -or $bytes[8] -notin @(0,1)) { continue }
        $result.($item.Field) = ($bytes[8] -eq 1)
    }
    return $result
}

function Initialize-CloakStorageWin32 {
    if ('CloakStorageS3ReadOnlyB4.DeviceProps' -as [type]) { return }
    $source = @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace CloakStorageS3ReadOnlyB4 {
    public static class DeviceProps {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(
            string name, uint access, uint share, IntPtr security, uint disposition,
            uint flags, IntPtr templateHandle);
        [DllImport("kernel32.dll", SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool DeviceIoControl(
            SafeFileHandle handle, uint code,
            byte[] input, int inputSize,
            byte[] output, int outputSize,
            out int bytesReturned, IntPtr overlapped);

        public static byte[] Inquiry(string path) {
            return InquiryInternal(path, false);
        }

        public static byte[] InquiryVpd83(string path) {
            return InquiryInternal(path, true);
        }

        static byte[] InquiryInternal(string path, bool evpd83) {
            // Only SCSI INQUIRY 0x12 (standard or EVPD page 0x83),
            // synchronously and DATA_IN. No other CDB or data-out allowed.
            using (SafeFileHandle h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (h == null || h.IsInvalid) return null;
                const int dataOffset = 64;
                int dataSize = evpd83 ? 252 : 96;
                int pointerOffset = IntPtr.Size == 8 ? 24 : 20;
                int cdbOffset = IntPtr.Size == 8 ? 36 : 28;
                ushort structSize = (ushort)(IntPtr.Size == 8 ? 56 : 44);
                byte[] buffer = new byte[dataOffset + dataSize];
                Buffer.BlockCopy(BitConverter.GetBytes(structSize), 0, buffer, 0, 2);
                buffer[6] = 6;
                buffer[8] = 1;  // SCSI_IOCTL_DATA_IN
                Buffer.BlockCopy(BitConverter.GetBytes((uint)dataSize),0,buffer,12,4);
                Buffer.BlockCopy(BitConverter.GetBytes((uint)10),0,buffer,16,4);
                if (IntPtr.Size == 8)
                    Buffer.BlockCopy(BitConverter.GetBytes((ulong)dataOffset),0,buffer,pointerOffset,8);
                else
                    Buffer.BlockCopy(BitConverter.GetBytes((uint)dataOffset),0,buffer,pointerOffset,4);
                buffer[cdbOffset] = 0x12;
                if (evpd83) {
                    buffer[cdbOffset+1] = 1;     // EVPD
                    buffer[cdbOffset+2] = 0x83;  // Device identification
                }
                buffer[cdbOffset+4] = (byte)dataSize;
                byte[] output = new byte[buffer.Length];
                int returned = 0;
                if (!DeviceIoControl(h, 0x0004d004, buffer, buffer.Length,
                                     output, output.Length, out returned, IntPtr.Zero)
                    || returned < dataOffset + (evpd83 ? 4 : 36) || output[2] != 0) return null;
                byte[] inquiry = new byte[dataSize];
                Buffer.BlockCopy(output, dataOffset, inquiry, 0, dataSize);
                return inquiry;
            }
        }

        public static byte[] AtaIdentify(string path) {
            // ATA IDENTIFY DEVICE (0xEC) only. No ATA write commands or SMART
            // enable/disable operations are exposed by this API.
            using (SafeFileHandle h = CreateFile(path, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (h == null || h.IsInvalid) return null;
                const int dataOffset = 64;
                const int dataSize = 512;
                ushort headerSize = (ushort)(IntPtr.Size == 8 ? 48 : 40);
                int pointerOffset = IntPtr.Size == 8 ? 24 : 20;
                int currentTaskFile = IntPtr.Size == 8 ? 40 : 32;
                byte[] input = new byte[dataOffset + dataSize];
                Buffer.BlockCopy(BitConverter.GetBytes(headerSize),0,input,0,2);
                Buffer.BlockCopy(BitConverter.GetBytes((ushort)2),0,input,2,2); // ATA_FLAGS_DATA_IN
                Buffer.BlockCopy(BitConverter.GetBytes((uint)dataSize),0,input,8,4);
                Buffer.BlockCopy(BitConverter.GetBytes((uint)10),0,input,12,4); // timeout sec
                if (IntPtr.Size == 8) {
                    Buffer.BlockCopy(BitConverter.GetBytes((ulong)dataOffset),0,input,pointerOffset,8);
                } else {
                    Buffer.BlockCopy(BitConverter.GetBytes((uint)dataOffset),0,input,pointerOffset,4);
                }
                input[currentTaskFile + 1] = 1;     // One ATA sector
                input[currentTaskFile + 6] = 0xEC;  // IDENTIFY DEVICE
                byte[] output = new byte[input.Length];
                int returned = 0;
                if (!DeviceIoControl(h, 0x0004d02c, input, headerSize,
                                     output, output.Length, out returned, IntPtr.Zero)
                    || returned < headerSize + dataSize) return null;
                // Error, device fault or busy in returned ATA status register.
                if ((output[currentTaskFile+6] & 0xA1) != 0) return null;
                byte[] identify = new byte[dataSize];
                Buffer.BlockCopy(output, dataOffset, identify, 0, dataSize);
                return identify;
            }
        }

        public sealed class PropertyQueryResult {
            public byte[] Data;
            public int Error;
            public string AccessMode;
            public string FailureStage;
            public int ReturnedBytes;
            public int MetadataError;
            public int ReadOnlyError;
            public string MetadataStage;
            public string ReadOnlyStage;
        }

        static PropertyQueryResult QueryWithAccess(string path, uint property, uint access) {
            PropertyQueryResult result = new PropertyQueryResult();
            result.AccessMode = access == 0 ? "METADATA" : "READ_ONLY";
            result.FailureStage = "CREATE_FILE";
            using (SafeFileHandle h = CreateFile(path, access, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
                if (h == null || h.IsInvalid) {
                    result.Error = Marshal.GetLastWin32Error();
                    return result;
                }
                // STORAGE_PROPERTY_QUERY: PropertyId + PropertyStandardQuery(0).
                // STORAGE_PROPERTY_QUERY contains PropertyId (4), QueryType
                // (4), and AdditionalParameters[1] plus native padding.
                // A previous 8-byte buffer omitted AdditionalParameters and
                // can be rejected as undersized by Windows storage drivers.
                byte[] input = new byte[12];
                Buffer.BlockCopy(BitConverter.GetBytes(property), 0, input, 0, 4);
                result.FailureStage = "DEVICE_IO_CONTROL";
                byte[] output = new byte[4096];
                int returned = 0;
                if (!DeviceIoControl(h, 0x002d1400, input, input.Length,
                                     output, output.Length, out returned, IntPtr.Zero)) {
                    result.Error = Marshal.GetLastWin32Error();
                    return result;
                }
                result.ReturnedBytes = returned;
                if (returned < 9 || returned > output.Length) {
                    result.Error = 13; // ERROR_INVALID_DATA
                    result.FailureStage = "INVALID_RESPONSE_SIZE";
                    return result;
                }
                result.Data = new byte[returned];
                Buffer.BlockCopy(output, 0, result.Data, 0, returned);
                result.Error = 0;
                result.FailureStage = "NONE";
                return result;
            }
        }

        public static PropertyQueryResult QueryDetailed(string path, uint property) {
            // Both attempts are read-only. Some storage stacks reject a
            // metadata-only handle but accept a GENERIC_READ handle.
            PropertyQueryResult first = QueryWithAccess(path, property, 0);
            if (first.Data != null) {
                first.MetadataError = first.Error;
                first.MetadataStage = first.FailureStage;
                first.ReadOnlyError = -1; // Not attempted.
                first.ReadOnlyStage = "NOT_ATTEMPTED";
                return first;
            }
            PropertyQueryResult read = QueryWithAccess(path, property, 0x80000000);
            PropertyQueryResult chosen = read;
            if (read.Data == null && read.Error == 5 && first.Error != 5)
                chosen = first;
            chosen.MetadataError = first.Error;
            chosen.MetadataStage = first.FailureStage;
            chosen.ReadOnlyError = read.Error;
            chosen.ReadOnlyStage = read.FailureStage;
            return chosen;
        }

        public static byte[] Query(string path, uint property) {
            return QueryDetailed(path, property).Data;
        }
    }
}
'@
    Add-Type -TypeDefinition $source -ErrorAction Stop
}

function Get-C5AtaText([byte[]]$Bytes,[int]$FirstWord,[int]$WordCount) {
    $ascii = New-Object byte[] ($WordCount*2)
    for ($i=0; $i -lt $WordCount; $i++) {
        $pos = ($FirstWord+$i)*2
        $ascii[$i*2] = $Bytes[$pos+1]
        $ascii[$i*2+1] = $Bytes[$pos]
    }
    $value = [Text.Encoding]::ASCII.GetString($ascii).Trim()
    if ($value -match '[^\x20-\x7e]') { return '' }
    return $value
}

function ConvertFrom-CloakAtaIdentify {
    [CmdletBinding()]
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -ne 512) { return $null }
    if (([BitConverter]::ToUInt16($Bytes,0) -band 0x8000) -ne 0) {
        return $null  # ATAPI Identify packet, not HDD IDENTIFY DEVICE
    }
    # ATA IDENTIFY word 255 may contain optional checksum signature 0xA5.
    # When present, reject a corrupted 512-byte block.
    if ($Bytes[510] -eq 0xA5) {
        $sum=0
        foreach ($b in $Bytes) { $sum=($sum + [int]$b) -band 255 }
        if ($sum -ne 0) { return $null }
    }
    $model = Get-C5AtaText $Bytes 27 20
    $firmware = Get-C5AtaText $Bytes 23 4
    $serial = Get-C5AtaText $Bytes 10 10
    if (-not $model -or -not $firmware -or -not $serial) { return $null }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $data = [Text.Encoding]::UTF8.GetBytes($serial.Trim())
        $serialHash = [BitConverter]::ToString($hash.ComputeHash($data)).Replace('-','')
    } finally { $hash.Dispose() }
    $word82 = [BitConverter]::ToUInt16($Bytes,82*2)
    $word85 = [BitConverter]::ToUInt16($Bytes,85*2)
    $word169 = [BitConverter]::ToUInt16($Bytes,169*2)
    $word217 = [int][BitConverter]::ToUInt16($Bytes,217*2)
    $rotation = if ($word217 -eq 1 -or ($word217 -ge 100 -and $word217 -lt 65535)) {
        $word217
    } else { $null }
    return [pscustomobject][ordered]@{
        Source = 'Windows-IOCTL_ATA_PASS_THROUGH_IDENTIFY_0xEC'
        Protocol = 'ATA'
        Model = $model
        Firmware = $firmware
        SerialSha256 = $serialHash
        SmartAvailable = (($word82 -band 1) -ne 0)
        SmartEnabled = (($word85 -band 1) -ne 0)
        TrimSupported = (($word169 -band 1) -ne 0)
        RotationRate = $rotation
        RotationWord217 = $word217
        RotationClassification = $(if ($word217 -eq 1) { 'NON_ROTATING' } elseif ($rotation) { 'ROTATING' } else { 'NOT_REPORTED' })
        ScsiVendor = ''
        ScsiProduct = ''
        ScsiRevision = ''
    }
}

function Get-CloakStorageAtaIdentify {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidateRange(0,1024)][int]$DiskIndex)
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { return $null }
    try {
        Initialize-CloakStorageWin32
        $bytes = [CloakStorageS3ReadOnlyB4.DeviceProps]::AtaIdentify(('\\.\PhysicalDrive'+$DiskIndex))
        return ConvertFrom-CloakAtaIdentify -Bytes $bytes
    } catch {
        return $null  # Drivers may reject ATA pass-through; never print paths.
    }
}

function ConvertFrom-CloakScsiInquiry {
    [CmdletBinding()]
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 36) { return $null }
    $deviceType = [int]($Bytes[0] -band 31)
    if ($deviceType -notin @(0,5)) { return $null }
    foreach ($item in @(@(8,8),@(16,16),@(32,4))) {
        for ($i=$item[0];$i -lt $item[0]+$item[1];$i++) {
            if ($Bytes[$i] -lt 32 -or $Bytes[$i] -gt 126) { return $null }
        }
    }
    return [pscustomobject][ordered]@{
        Source='SCSI_PASS_THROUGH_INQUIRY_0x12'
        DeviceType=$deviceType
        Vendor=([Text.Encoding]::ASCII.GetString($Bytes,8,8)).Trim()
        Product=([Text.Encoding]::ASCII.GetString($Bytes,16,16)).Trim()
        Revision=([Text.Encoding]::ASCII.GetString($Bytes,32,4)).Trim()
    }
}

function Get-CloakStorageOpticalInquiry {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z]:$')][string]$OpticalDrive)
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { return $null }
    try {
        Initialize-CloakStorageWin32
        $bytes = [CloakStorageS3ReadOnlyB4.DeviceProps]::Inquiry(('\\.\' + $OpticalDrive))
        return ConvertFrom-CloakScsiInquiry -Bytes $bytes
    } catch {
        return $null  # No device paths/driver errors disclosed.
    }
}

function Get-C5QueryStatus($Result) {
    if ($null -eq $Result) { return 'NOT_QUERIED' }
    if ($null -ne $Result.Data) { return 'AVAILABLE' }
    switch ([int]$Result.Error) {
        1    { return 'UNSUPPORTED' }
        2    { return 'DEVICE_NOT_FOUND' }
        3    { return 'DEVICE_NOT_FOUND' }
        5    { return 'ACCESS_DENIED' }
        13   { return 'INVALID_RESPONSE' }
        21   { return 'DEVICE_NOT_READY' }
        50   { return 'UNSUPPORTED' }
        87   { return 'INVALID_QUERY' }
        122  { return 'BUFFER_TOO_SMALL' }
        234  { return 'BUFFER_TOO_SMALL' }
        1167 { return 'DEVICE_NOT_FOUND' }
        default { return 'DRIVER_OR_STORAGE_ERROR' }
    }
}

function ConvertFrom-CloakScsiVpd83 {
    [CmdletBinding()]
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -lt 4 -or $Bytes[1] -ne 0x83) { return $null }
    $type = [int]($Bytes[0] -band 31)
    if ($type -notin @(0,5)) { return $null }
    $pageLength = ([int]$Bytes[2] -shl 8) -bor [int]$Bytes[3]
    if ($pageLength -gt $Bytes.Length - 4) { return $null }
    $end = 4 + $pageLength
    $position = 4
    $count = 0
    while ($position -lt $end) {
        if ($position + 4 -gt $end) { return $null }
        $identifierLength = [int]$Bytes[$position+3]
        if ($identifierLength -eq 0 -or $position+4+$identifierLength -gt $end) {
            return $null
        }
        $count++
        if ($count -gt 32) { return $null }
        $position += 4 + $identifierLength
    }
    # Preserve only count and page type, never VPD designator contents or IDs.
    return [pscustomobject][ordered]@{
        Source = 'SCSI_PASS_THROUGH_INQUIRY_EVPD83'
        DeviceType = $type
        IdentifierCount = $count
        HasDesignators = ($count -gt 0)
    }
}

function Get-CloakStorageScsiVpd83 {
    [CmdletBinding(DefaultParameterSetName='Disk')]
    param(
        [Parameter(ParameterSetName='Disk',Mandatory=$true)]
        [ValidateRange(0,1024)][int]$DiskIndex,
        [Parameter(ParameterSetName='Optical',Mandatory=$true)]
        [ValidatePattern('^[A-Za-z]:$')][string]$OpticalDrive
    )
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { return $null }
    $path = if ($PSCmdlet.ParameterSetName -eq 'Disk') {
        '\\.\PhysicalDrive' + $DiskIndex
    } else { '\\.' + '\' + $OpticalDrive }
    try {
        Initialize-CloakStorageWin32
        $bytes = [CloakStorageS3ReadOnlyB4.DeviceProps]::InquiryVpd83($path)
        return ConvertFrom-CloakScsiVpd83 -Bytes $bytes
    } catch {
        return $null
    }
}

function Get-C5QueryDiagnostic($Result) {
    if ($null -eq $Result) { return $null }
    # No device path or system error string: only stable categorical stage,
    # numeric Win32 codes and a response byte count.
    return [pscustomobject][ordered]@{
        Status = Get-C5QueryStatus $Result
        Win32Error = [int]$Result.Error
        FailureStage = [string]$Result.FailureStage
        HandleMode = [string]$Result.AccessMode
        MetadataWin32Error = [int]$Result.MetadataError
        MetadataStage = [string]$Result.MetadataStage
        ReadOnlyWin32Error = [int]$Result.ReadOnlyError
        ReadOnlyStage = [string]$Result.ReadOnlyStage
        ReturnedBytes = [int]$Result.ReturnedBytes
    }
}

function Get-CloakStorageWindowsProperties {
    [CmdletBinding(DefaultParameterSetName='Disk')]
    param(
        [Parameter(ParameterSetName='Disk',Mandatory=$true)]
        [ValidateRange(0,1024)][int]$DiskIndex,
        [Parameter(ParameterSetName='Optical',Mandatory=$true)]
        [ValidatePattern('^[A-Za-z]:$')][string]$OpticalDrive
    )
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { return $null }
    $path = if ($PSCmdlet.ParameterSetName -eq 'Disk') {
        '\\.\PhysicalDrive' + $DiskIndex
    } else { '\\.\' + $OpticalDrive }
    try {
        Initialize-CloakStorageWin32
        $descriptor = [CloakStorageS3ReadOnlyB4.DeviceProps]::QueryDetailed($path,0)
        $trim = [CloakStorageS3ReadOnlyB4.DeviceProps]::QueryDetailed($path,8)
        $seek = [CloakStorageS3ReadOnlyB4.DeviceProps]::QueryDetailed($path,7)
        $parsed = ConvertFrom-CloakStorageDescriptor -Device $descriptor.Data -Trim $trim.Data -Seek $seek.Data
        $parsed | Add-Member -NotePropertyName QueryStatus -NotePropertyValue ([pscustomobject][ordered]@{
            DeviceDescriptor = Get-C5QueryStatus $descriptor
            Trim = Get-C5QueryStatus $trim
            SeekPenalty = Get-C5QueryStatus $seek
        })
        $parsed | Add-Member -NotePropertyName QueryDiagnostics -NotePropertyValue ([pscustomobject][ordered]@{
            DeviceDescriptor = Get-C5QueryDiagnostic $descriptor
            Trim = Get-C5QueryDiagnostic $trim
            SeekPenalty = Get-C5QueryDiagnostic $seek
        })
        return $parsed
    } catch {
        # Never print raw device path or system error text.
        return $null
    }
}
function Get-CloakStorageWindowsQueryContract {
    return [pscustomobject]@{ Release='S3-C5-2026-11-B4'; SchemaVersion=1; IoctlPolicy='FixedReadOnlyQueries' }
}
Export-ModuleMember -Function ConvertFrom-CloakStorageDescriptor,Get-CloakStorageWindowsProperties,ConvertFrom-CloakScsiInquiry,Get-CloakStorageOpticalInquiry,ConvertFrom-CloakAtaIdentify,Get-CloakStorageAtaIdentify,ConvertFrom-CloakScsiVpd83,Get-CloakStorageScsiVpd83,Get-CloakStorageWindowsQueryContract
