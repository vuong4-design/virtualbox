# Windows Guest Identity Audit (read-only)

This kit measures guest-visible identity on a Windows VM. It does NOT modify VM
settings, enable Cloak profiles, or claim to hide the hypervisor.

## Prerequisites

- Power off the VM before changing its DMI settings.
- Use a **Windows guest** running PowerShell 5.1 or 7.
- Copy all three `.ps1` files from this directory together into the guest.
- If Guest Additions are installed, the host can share this directory:

  ```powershell
  $vbm = 'C:\Users\ADMIN\Downloads\virtualbox\VBoxManage.exe'
  & $vbm sharedfolder add 'test' --name IdentityAudit --hostpath 'C:\Users\ADMIN\Downloads\virtualbox\identity-audit' --automount
  ```

  After booting Windows guest, the scripts should be accessible via
  `\\VBOXSVR\IdentityAudit` (if shared folders / Guest Additions work).
  Copy the scripts to a LOCAL guest folder before running:

  ```powershell
  New-Item -ItemType Directory -Force "$env:USERPROFILE\IdentityAuditScripts" | Out-Null
  Copy-Item '\\VBOXSVR\IdentityAudit\*.ps1' "$env:USERPROFILE\IdentityAuditScripts" -Force
  ```

  Without Guest Additions, transfer the three scripts using a trusted file
  transfer method (for example, a USB device or private network share).
  The comparison happens **inside the guest**, so no guest-to-host clipboard
  or transfer is needed.

## Phase 1: baseline capture

From PowerShell INSIDE the guest:

```powershell
$kit = "$env:USERPROFILE\IdentityAuditScripts"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$kit\Invoke-GuestIdentityAudit.ps1" -Phase Baseline -ExpectedVendor LabVendor -ExpectedProduct LabDesktop-01
```

- If your test DMI strings differ, adjust `-ExpectedVendor` and
  `-ExpectedProduct` or omit them.
- JSON is saved in `$env:USERPROFILE\IdentityAudit\boot1.json`.
- Some sections can report `UNAVAILABLE`; those are NOT a pass.
- `cpuid.hypervisorPresentFromWmi` is a Windows WMI flag, **not** a raw CPUID
  leaf measurement.

## Phase 2: cold-boot comparison

Shut down Windows guest, make sure the VirtualBox VM is **Powered Off** (not
Saved), then start the VM again. In guest PowerShell:

```powershell
$kit = "$env:USERPROFILE\IdentityAuditScripts"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$kit\Invoke-GuestIdentityAudit.ps1" -Phase Verify -ExpectedVendor LabVendor -ExpectedProduct LabDesktop-01
```

- `COLD-BOOT IDENTITY STABILITY: PASS` means captured identity fields match.
- `FAIL` prints the changed field paths and writes `comparison.json`.
- Data collection alone does not demonstrate that Cloak Profile Engine is on.
- For a new baseline, `-Phase Baseline -Force` explicitly overwrites boot1.

## Additional observations

In guest PowerShell, inspect graphics, storage and adapter names:

```powershell
Get-CimInstance Win32_VideoController | Select-Object Name,VideoProcessor,DriverVersion,PNPDeviceID
Get-CimInstance Win32_DiskDrive | Select-Object Model,SerialNumber,FirmwareRevision,InterfaceType
Get-CimInstance Win32_NetworkAdapter | Where-Object PhysicalAdapter | Select-Object Name,MACAddress,PNPDeviceID
```

The audit script also inventories PCI and ACPI through WMI/registry.
A separate native CPU tool is needed for exact CPUID leaf/register measurements.

## Privacy

`boot1.json`, `boot2.json` contain hardware serial numbers, MAC addresses and
device identifiers. Do not upload them publicly. Sharing the comparator's
status and *field paths* (rather than raw values) is usually enough to debug.
