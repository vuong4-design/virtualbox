# Cloak lab-only DMI/ACPI runtime test

This is an **opt-in developer test of the self-built VirtualBox host**.
It is NOT a full production Cloak profile and it does NOT try to hide VirtualBox.
Use the official, signed Oracle Guest Additions already installed in the guest;
do not rebuild or test-sign Guest Additions for this experiment.

## Scope

- Windows host binary: `VBoxC.dll` built with `VBOX_WITH_CLOAK_LAB_PROFILE=1`.
- Lab profile ID: `lab-dmi-v1`; expected guest SMBIOS system maker
  `LabVendor`, system product `LabDesktop-01`, BIOS maker `LabFirmware`.
- The lab profile supplies `LAB` as the ACPI OEM ID, `LAB0` as the
  four-character table-ID prefix, and sets `CloakLabPatchHeaders=1`.
  This opts in to patching the copied DSDT and generated CPU/TPM SSDT
  header fields. The ACPI table length and signature are validated, and
  the checksum is regenerated; the AML method bytecode is left intact.
  Without the lab switch, the normal VirtualBox table bytes are unchanged.
  Conflicting pre-existing ACPI OEM overrides cause VM startup to fail closed
  instead of producing mixed OEM identifiers. Changing headers does NOT
  replace hardware identifiers inside AML methods.
- The profile is *DRAFT*, intentionally separate from the empty production
  profile registry and the `VBOX_WITH_CLOAK_BUILD` manifest checks. Only an
  explicitly compiled **lab** host can select this profile.
- Does **not** modify storage model (`VBOX HARDDISK`), graphics name,
  CPU brand/CPUID, PCI IDs, guest kernel drivers, VMMDev or virtual NIC.
  `PCI\\VEN_80EE&DEV_CAFE` is intentionally unchanged for the official
  `VBoxGuest` driver.

## CI build

The host `build` job writes `VBOX_WITH_CLOAK_LAB_PROFILE = 1` to its
`LocalConfig.kmk`; `src/VBox/Main/Makefile.kmk` passes the preprocessor
symbol to `VBoxC`. After building, CI checks `VBoxC.dll` for the exact lab
profile markers and `VBoxDD.dll` for the ACPI header-patching code.
JSON tests alone do not verify that runtime code was compiled.

The **production** `VBOX_WITH_CLOAK_BUILD` path still requires an authentic,
verified build identity manifest and compatible production profiles. This
lab path deliberately does not use the synthetic build-identity fixture or
misrepresent it as a production firmware provenance record.

## Apply on the Windows HOST, not in the guest

1. Use the new host artifact **`virtualbox-7.2-windows-amd64-binaries`**
   from a successful `build` job after this source change. Ensure that the
   `VBoxManage.exe` and `VBoxC.dll` invoked are from that same self-built
   VirtualBox host installation. Do not mix program files from two builds.
2. Create a VM snapshot or backup and **shut down guest completely**. Verify
   VM state is `poweroff`, not `saved`.
3. From PowerShell on the host, using this repository:

   ```powershell
   cd D:\virtualbox
   $vbm = 'C:\path\to\your\self-built\VBoxManage.exe'

   .\.github\scripts\Set-CloakLabProfile.ps1 -Action Status -VM test -VBoxManage $vbm
   .\.github\scripts\Set-CloakLabProfile.ps1 -Action Enable -VM test -VBoxManage $vbm -WhatIf
   .\.github\scripts\Set-CloakLabProfile.ps1 -Action Enable -VM test -VBoxManage $vbm
   ```

   The script creates/verifies the existing `VBoxInternal/Cloak/Seed` and
   `SeedHash`, then sets `VBoxInternal/Cloak/Profile` to `lab-dmi-v1` and
   `VBoxInternal/Cloak/Enabled` to `integer:1`. It refuses to modify
   VMs that are running or saved. The seed value is not printed.

4. Cold-start `test` using the **new self-built VirtualBox host**.
   Look at the VM's `Logs\VBox.log` for:

   ```text
   Cloak: LAB DMI/ACPI profile selected (not a production cloak build)
   Cloak: profile 'lab-dmi-v1' materialized
   ```

5. In the **Windows guest**, use PowerShell (no JSON retest needed):

   ```powershell
   Get-CimInstance Win32_ComputerSystem |
     Select-Object Manufacturer,Model

   Get-CimInstance Win32_BIOS |
     Select-Object Manufacturer,SMBIOSBIOSVersion

   Get-CimInstance Win32_PnPEntity |
     Where-Object { $_.PNPDeviceID -like 'PCI\\VEN_80EE&DEV_CAFE*' } |
     Select-Object Name,Status,ConfigManagerErrorCode,Service
   Get-Service VBoxService
   ```

   Expected: `LabVendor` / `LabDesktop-01`, BIOS `LabFirmware`,
   `VBoxGuest` reports `ConfigManagerErrorCode = 0`, and `VBoxService`
   runs. GPU and disk names may still show VirtualBox: that is expected.

6. **ACPI header verification after the new host build**, using a full
   cold boot of the same VM. Copy `Test-CloakAcpiGuest.ps1` from `.github/scripts`
   into the Windows guest and run it in PowerShell as administrator:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CloakAcpiGuest.ps1
   ```

   Expected registry identity (shown without the final revision subkey):

   ```text
   HKLM\HARDWARE\ACPI\DSDT\LAB___\LAB0DSDT
   HKLM\HARDWARE\ACPI\SSDT\LAB___\LAB0CPUT
   HKLM\HARDWARE\ACPI\FADT\LAB___\LAB0FACP
   HKLM\HARDWARE\ACPI\RSDT\LAB___\LAB0XSDT
   ```

   If TPM ACPI tables are present, an additional SSDT with Table ID
   `LAB0TPM0` may appear. The script also checks DMI, the unchanged
   `80EE:CAFE` device, and the official Guest Additions service.

   These keys show header metadata, not a proof of a full AML identity
   rewrite. **Do not claim ACPI full-pass until Windows guest results
   confirm it.** The build CI only verifies code presence/compilation.



## Optional lab Storage Identity (S0/S1)

Storage lab is **OFF by default**, even if the VM already uses `lab-dmi-v1`.
It does not change device PCI IDs, Guest Additions or disk contents. It may
change guest-visible ATA model/firmware/serial after the next cold boot, which
can cause Windows to re-enumerate the disk. Always take a VM snapshot/backup.

- S0 enumerates **actual** VM storage controllers and medium attachments via
  `IMachine` COM (controller type/instance, port/device, hard-disk type).
  It does not infer the bus from Windows `SCSI\\DISK` or `InterfaceType`.
- S1 is a **lab-only limited implementation**: hard-disk attachments on
  PIIX3/PIIX4/ICH6 IDE and AHCI are routed to `PrimaryMaster` /
  `PrimarySlave` / `SecondaryMaster` / `SecondarySlave` or `PortN`
  CFGM nodes. Optical, USB, SCSI, SAS, VirtIO and NVMe are not modified.
- Every eligible HDD receives generic `ModelNumber=LAB ATA DISK`,
  `FirmwareRevision=LAB1`, and an 18-character lab serial derived from
  the VM seed stream and (by default) the **attached medium UUID**, preserving
  the serial derivation of earlier lab builds. An **independent opt-in S2 flag**
  `StorageLabRootSerialEnabled` switches to the **root medium UUID** obtained
  by traversing `IMedium::Parent`; snapshot differencing leaves then share the
  root identity. With a base medium (no parent), the result is unchanged.
  The serial and medium UUID are never logged.
- User ExtraData overrides are not overwritten, but the effective
  `ModelNumber` (max 40), `FirmwareRevision` (max 8), and `SerialNumber`
  (max 20) must be valid and nonempty, otherwise VM startup fails.
- **Limit:** root-medium traversal is enabled **only** after explicitly
  selecting `EnableRootSerial` on a powered-off VM, and is intended to survive
  ordinary differencing snapshots. If an existing attached medium already has
  a parent, switching this mode may change its serial once; record a fresh
  baseline **after enabling**. It is not yet verified on real snapshot/restore.
  Media replacement, image merge/rebase, imported images, linked/full clones,
  and changed root media may still alter serial identity. A production-grade
  persisted logical drive ID and extended saved-state guard remain **pending**.
  C5 checks for INQUIRY/SMART/TRIM/nonrotation and cross-platform S3/S4 testing
  are pending. Do not mark Storage Identity production-complete.

On the **host**, shut down VM `test` entirely (state `poweroff`). Run:

```powershell
cd D:\virtualbox
$vbm = 'C:\path\to\same-custom-build\VBoxManage.exe'
.\.github\scripts\Set-CloakLabStorage.ps1 -Action Status -VM test -VBoxManage $vbm
.\.github\scripts\Set-CloakLabStorage.ps1 -Action Enable -VM test -VBoxManage $vbm -WhatIf
.\.github\scripts\Set-CloakLabStorage.ps1 -Action Enable -VM test -VBoxManage $vbm
```

Use a **new host artifact** after CI confirms `tstCloakConfig` and that
`VBoxC.dll` contains `StorageLabEnabled` and `LAB ATA DISK`.
Cold-boot the guest. Then run `Test-CloakLabStorageGuest.ps1` as Administrator
inside the Windows guest. You should see `LAB ATA DISK` / `LAB1` for IDE/AHCI
HDDs, and `VBoxService`/official `VBoxGuest` should still work. Disk serials,
raw medium UUIDs and seeds are deliberately not printed.

### S2: independent read-only identity audit and snapshot regression

The previous user-provided Windows guest results confirmed one HDD with model
`LAB ATA DISK`, firmware `LAB1`, serial and PnP vendor/product, with serial
stable across three restarts. That is **not** a snapshot test or raw ATA
IDENTIFY/SMART/TRIM evidence.

Rebuild the host after the root-medium traversal change. By default,
`StorageLabRootSerialEnabled` is off and the previous serial algorithm remains
active. After making a backup, fully power off VM `test` and explicitly enable
root-medium serial mode on the **host** if you want to test snapshot behavior:

```powershell
.\.github\scripts\Set-CloakLabStorage.ps1 -Action EnableRootSerial -VM test -VBoxManage $vbm
```

Copy
`.github/scripts/Test-CloakStorageS2Guest.ps1` into the guest and record a
sanitized baseline (choose a path that will survive snapshot restore):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CloakStorageS2Guest.ps1 -Mode Record -Path "$env:TEMP\cloak-storage-s2.json"
```

Cold boot, then compare from the **same guest**:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CloakStorageS2Guest.ps1 -Mode Compare -Path "$env:TEMP\cloak-storage-s2.json"
```

To test snapshot semantics, take a **powered-off snapshot**, start the VM on
its differencing medium, and run the compare command. If you restore a snapshot
created before recording the baseline, restore the baseline JSON separately
from a safe host-side copy. The audit deliberately writes no raw serial, PnP
instance suffix or `CloakSeed` into the JSON. It rejects changes to disk
count/index, model, firmware, serial hash or PnP vendor/product. Matching disk
indexes is a conservative fixture requirement; reordering drives is an
independent test and may need a different matcher.

The script also shows optional Windows storage metadata; if `smartctl.exe`
is already installed, it performs read-only `--info --json` queries. No SMART,
TRIM, rotational or raw ATA capability is assumed supported merely because
WMI reports model/firmware. Unavailable ATA passthrough is recorded as
**NOT VERIFIED**, not automatically PASS.

To disable the root-medium serial experiment without turning off Storage Lab,
fully power off VM `test` and run:

```powershell
.\.github\scripts\Set-CloakLabStorage.ps1 -Action DisableRootSerial -VM test -VBoxManage $vbm
```

**Rollback:** power off VM `test` completely and run:

```powershell
.\.github\scripts\Set-CloakLabStorage.ps1 -Action Disable -VM test -VBoxManage $vbm
```

Cold-boot again. The original VirtualBox ATA defaults are restored if no user
ExtraData overrides exist. Do not resume a saved VM across changes of storage
identity. This S1 test is **separate** from the full S0–S4 PR-3 plan in
`doc/cloak-plan/CLOAK-PLAN.md`.

### S3 capability audit and C5 cross-surface checks (read-only)

S3 adds a **collector** `.github/scripts/Test-CloakStorageS3Guest.ps1`,
a pure C5 evaluator `.github/scripts/CloakStorageC5.psm1`, and an optional
**host evidence exporter** `.github/scripts/Export-CloakStorageC5Host.ps1`.
No host device code, driver, ATA IDENTIFY word, SMART state or TRIM bit is
modified. A rebuild of VirtualBox is **not needed** merely to use these
scripts; the corresponding CI tests run on the fork workflow after push.

S3 checks WMI model/firmware/serial hash, PnP vendor/product, and Windows
Storage BusType and MediaType. If `smartctl.exe` already exists and can reach
the drive, S3 reads only `--info --json` and compares independent model,
firmware, serial hash, SMART support/enabled, TRIM support and rotation. For
**direct SCSI** results only, it also compares INQUIRY vendor/product/revision
against the reported Windows identity. The SCSI PnP prefix
`SCSI\\DISK` on an ATA/SATA disk is **not** direct SCSI INQUIRY evidence.
Raw SCSI VPD page 0x83 is now attempted only on appropriate direct SCSI
and optical devices (S3.2); missing or empty pages remain NOT_VERIFIED.
ATAPI optical INQUIRY is attempted through fixed read-only pass-through;
if the guest driver blocks either request it remains NOT_VERIFIED.

On the host, inspect the controller name, port and device before mapping:

```powershell
cd D:\virtualbox
$vbm = 'C:\path\to\same-custom-build\VBoxManage.exe'
& $vbm showvminfo test --machinereadable |
    Select-String 'nonrotational|discard|SATA-|IDE-'
```

For the example **only if** the *actual* guest disk 0 is attached to a
controller named `SATA`, port 0, device 0, export a host capability policy:

```powershell
.\.github\scripts\Export-CloakStorageC5Host.ps1 -VM test -VBoxManage $vbm -OutputPath .\cloak-c5-host.json -Controller SATA -Port 0 -Device 0 -GuestDiskIndex 0
```

With multiple disks, leave unmatched host attachments unmapped and provision
explicit mappings in a controlled fixture; never infer a guest disk index
from port order. The host policy JSON contains only controller, port/device,
explicitly mapped guest index, `NonRotational` and `Discard` booleans. It
**does not** contain VDI location, image UUID, serial or seed.

Copy **all three** `Test-CloakStorageS3Guest.ps1`, `CloakStorageC5.psm1` and `CloakStorageWindowsQuery.psm1`
from `.github/scripts` next to each other inside the Windows guest; also
copy the optional `cloak-c5-host.json` from the host. Execute:

```powershell
.\Test-CloakStorageS3Guest.ps1 -HostCapabilitiesPath .\cloak-c5-host.json -OutputPath "$env:TEMP\cloak-storage-s3.json"
```

If `smartctl.exe` is installed but not on PATH, specify the full location
with `-SmartctlPath`. With no smartctl or unsupported guest pass-through, omit
`-HostCapabilitiesPath` if unavailable and expect **PARTIAL**, not PASS.
Use `-RequireRaw` to fail the command when independent raw device data
is missing. This is observational only, not a SMART self-test or a TRIM write.

The C5 evaluator reports a status per check:

- `PASS`: evidence observed and consistent for the named check.
- `FAIL`: contradiction (e.g. ATA model/firmware/serial differs from WMI,
  SMART enabled but unsupported, host discard contradicts raw TRIM, or
  host nonrotational contradicts raw rotation).
- `NOT_VERIFIED`: relevant evidence unavailable or not independently linked.
- `NOT_APPLICABLE`: backend/feature absent, or no explicit host mapping.

`Overall=PARTIAL` means no observed contradiction but some required
evidence missing. `Overall=INCOMPLETE` under `-RequireRaw` is an
**expected failing exit** if raw evidence is not available. `FAIL` always
exits with an error. `Get-PhysicalDisk MediaType=Unspecified` is not evidence
of HDD or SSD; an OS-level TRIM setting is not proof of ATA word 169, and
`HealthStatus=Healthy` does not prove SMART support. C5 never turns on
SMART, TRIM, rotation or USB/SCSI identity spoofing.

Offline CI runs `test-cloak-storage-s3.ps1` (pure C5 contradictions),
`test-cloak-storage-s3-host.ps1` (VBoxManage host evidence/redaction), and
`test-cloak-storage-s3-collector.ps1` (guest collector, synthetic smartctl
JSON, host pairing, fail cases and report redaction). **CI fixture PASS is
not actual guest hardware C5 PASS.**

#### S3.1 Native Windows storage query and optical INQUIRY (2026-11-04)

S3 now includes `CloakStorageWindowsQuery.psm1`. Copy this module beside
`Test-CloakStorageS3Guest.ps1` and `CloakStorageC5.psm1` in Windows guest.

- Default: read-only `IOCTL_STORAGE_QUERY_PROPERTY` for device descriptor,
  `StorageDeviceTrimProperty` and `StorageDeviceSeekPenaltyProperty`.
  These observations are OS-mediated, **not** raw ATA IDENTIFY.
- Optional `-NativeAtaIdentify`: fixed, read-only `ATA IDENTIFY DEVICE 0xEC`
  via `IOCTL_ATA_PASS_THROUGH`; parses model, firmware, hashed serial,
  SMART bits 82/85, TRIM word 169 and rotation word 217. Driver denial
  returns NOT_VERIFIED (or falls back to smartctl if installed).
- Optical: Windows descriptor plus fixed, read-only SCSI `INQUIRY 0x12`
  via `IOCTL_SCSI_PASS_THROUGH` when the optical drive has a letter.
  C5 compares vendor/product/revision with descriptor/PnP. Device drivers
  may reject this read. Optical is not mapped to Win32_DiskDrive index.
- New checks: `OS_DEVICE_DESC`, `OS_TRIM`, `OS_SEEK`, `OS_RAW_TRIM`,
  `OS_RAW_ROTATION`, `OPTICAL_OS_DESCRIPTOR` and `ATAPI_OPTICAL`.

Inside Windows guest, Administrator PowerShell:

```powershell
.\Test-CloakStorageS3Guest.ps1 `
    -NativeAtaIdentify `
    -HostCapabilitiesPath ".\cloak-c5-host.json" `
    -OutputPath "$env:TEMP\cloak-storage-s3-native.json"
```

Use `-SkipWindowsIoctl` to disable Windows device queries, or
`-SkipOpticalInquiry` to skip direct optical SCSI INQUIRY. Only fixed
DATA_IN commands are available; no SMART enable, no TRIM write, no driver
change. No raw ATA 512-byte block, serial, full PnP instance or optical
device path is written to the sanitized report. `-RequireRaw` fails with
`INCOMPLETE` if required raw evidence remains missing (such as VPD 0x83).
Windows TrimEnabled is never treated as proof that ATA TRIM executes.

CI runs `test-cloak-storage-s3-winquery.ps1` and
`test-cloak-storage-s3-ata.ps1` with synthetic bytes and no real devices.
Native query success and optical pass-through require separate VM runtime
evidence; do not label S3 fully PASS from the offline fixtures.

#### S3.2 Versioned guest audit release (one copy, no VirtualBox rebuild)

Release `S3-C5-2026-11-B1` bundles the **three** guest files with a SHA-256
manifest. It is designed to prevent the observed mismatch where `RawInquiry`
contained a valid optical INQUIRY but the old C5 module still reported
`ATAPI_OPTICAL=NOT_VERIFIED` with the obsolete note `not collected`.

On the Windows host:

```powershell
cd D:\virtualbox
.\.github\scripts\New-CloakStorageS3Bundle.ps1 `
    -OutputPath "$env:TEMP\CloakStorageS3-B1.zip" -Force
```

Copy that ZIP (not individual scripts) into the guest. In PowerShell:

```powershell
cd C:\Users\admin\Documents\scripts
Expand-Archive .\CloakStorageS3-B1.zip -DestinationPath .\S3-C5-B1 -Force
Copy-Item .\cloak-c5-host.json .\S3-C5-B1\cloak-c5-host.json
cd .\S3-C5-B1
.\Test-CloakStorageS3Guest.ps1 `
    -NativeAtaIdentify `
    -HostCapabilitiesPath .\cloak-c5-host.json `
    -OutputPath "$env:TEMP\cloak-storage-s3-B1.json"
```

The collector checks all three SHA-256 entries **before module import**.
If no manifest exists (manual copying), the collector still refuses older
or mixed module release contracts, but does not claim SHA-256 verification.
JSON now includes `AuditRevision`, `BundleIntegrity`, and SHA-256 source
hashes. Hashes detect accidental corruption/mixing, **not** malicious
tampering or authorship (the manifest is not signed). No VMware/VirtualBox
binary, guest driver, Oracle Guest Additions or storage capability is modified.

**Updated Windows property diagnostics:** WindowsQuery is now a sanitized
object even when IOCTL_STORAGE_QUERY_PROPERTY fails; its `QueryStatus`
contains a reason such as `UNSUPPORTED`, `ACCESS_DENIED`, `DEVICE_NOT_FOUND`,
or `DRIVER_OR_STORAGE_ERROR`. The collector retries with a read-only handle
if metadata-only access fails. OS descriptors are not raw ATA evidence.

**Extended optical/SCSI checks:** fixed read-only SCSI `INQUIRY 0x12` EVPD
page `0x83` is attempted for applicable optical devices and direct SCSI
disks. Only a designator count and peripheral type are recorded, not
device ID bytes. An empty/unavailable VPD 0x83 is NOT_VERIFIED. On a SATA
ATA disk, `SCSI\DISK` in PnP remains **not** proof of direct SCSI protocol.

**Observed lab evidence (from Windows guest JSON):** ATA IDENTIFY 0xEC
matched `LAB ATA DISK`, firmware `LAB1`, and serial SHA-256. SMART was
reported unsupported/disabled, TRIM unsupported, rotation unreported;
WindowsQuery was null. Optical direct INQUIRY returned `VBOX / CD-ROM / 1.0`,
matching optical PnP. This is an **identity coherence result**, not proof
of SMART functionality, SSD/HDD rotation, or every SCSI VPD page. The
new B1 code and VPD query have not yet been run on that real guest.

Offline test: `.github/scripts/test-cloak-storage-s3-bundle.ps1` creates,
expands, audits, intentionally tampers, and tests release mismatch on a
synthetic guest. CI runs it with the other S3/C5 fixtures before build.

#### S3.3 B2 Windows IOCTL diagnostics, rotation policy, optical scope, lifecycle

Release `S3-C5-2026-11-B2` supersedes the B1 guest ZIP. All changes here
are **Windows guest audit scripts only**, not VirtualBox binaries or
Oracle Guest Additions. A host build is NOT required to evaluate B2.

**WindowsQuery repair and diagnostics:** B1 sent just 8 bytes for
`STORAGE_PROPERTY_QUERY`; B2 sends 12 bytes including
`AdditionalParameters[1]` and padding. B2 keeps the metadata-only and
GENERIC_READ fallback handles, both read-only. Each of the three queries
has a sanitized `QueryDiagnostics` entry: `Win32Error`, `FailureStage`,
`HandleMode`, `MetadataWin32Error`, `MetadataStage`,
`ReadOnlyWin32Error`, `ReadOnlyStage`, `ReturnedBytes`. Driver errors
are now separated from invalid/truncated replies; paths/serials remain
excluded from these diagnostics. A failing query is NOT_VERIFIED and
does not silently become a PASS. See Microsoft `STORAGE_PROPERTY_QUERY`
and `IOCTL_STORAGE_QUERY_PROPERTY` documentation.

**Rotation/optical:** `ATA_WORD217` reports PASS only when ATA IDENTIFY
word 217 contains a recognized value (1 = nonrotating; 100..65534 RPM).
Values 0 and 65535 are **unreported**, not HDD or SSD proof. The host
`NonRotational=false` field alone cannot fill the missing guest evidence.
`OPTICAL_LAB_SCOPE` explicitly reports `NOT_APPLICABLE` for the current
lab-only ATA disk profile; `VBOX/CD-ROM/1.0` can have a coherent optical
INQUIRY PASS while remaining an expected, unprofiled optical identity.
Do not rebrand it without a separate tested optical profile and backend.

**S3 cold-boot/snapshot lifecycle compare:** `-CompareTo` reads an older
sanitized Storage-S3-C5 JSON baseline, compares stable HDD/optical identity,
ATA supported/capability fields and host flags, and emits
`LifecycleComparison` separately from C5 `Overall`. An observed drift
fails the command; missing raw evidence yields PARTIAL (not a false PASS).
Windows transient query status and HealthStatus are intentionally not
treated as stable drive identity. The script does not take snapshots.

Build the B2 ZIP on the host, then copy the ZIP (and existing host
`cloak-c5-host.json`) to Windows guest; do not mix B1 modules:

```powershell
cd D:\virtualbox
.\.github\scripts\New-CloakStorageS3Bundle.ps1 `
    -OutputPath "$env:USERPROFILE\Downloads\CloakStorageS3-B2.zip" -Force
```

Guest PowerShell Administrator, initial baseline before the snapshot:

```powershell
cd C:\Users\admin\Documents\scripts
Expand-Archive .\CloakStorageS3-B2.zip -DestinationPath .\S3-C5-B2 -Force
Copy-Item .\cloak-c5-host.json .\S3-C5-B2\cloak-c5-host.json
cd .\S3-C5-B2
.\Test-CloakStorageS3Guest.ps1 `
    -NativeAtaIdentify `
    -HostCapabilitiesPath .\cloak-c5-host.json `
    -OutputPath "$env:TEMP\cloak-S3-B2-baseline.json"
```

Copy the baseline JSON to a safe location **outside the VM** before a
snapshot/restore that could roll back the guest filesystem. After a real
powered-off snapshot/cold boot/restore, make the baseline available in
guest again and compare:

```powershell
.\Test-CloakStorageS3Guest.ps1 `
    -NativeAtaIdentify `
    -HostCapabilitiesPath .\cloak-c5-host.json `
    -CompareTo "$env:TEMP\cloak-S3-B2-baseline.json" `
    -OutputPath "$env:TEMP\cloak-S3-B2-after.json"
```

The ZIP has a SHA-256 manifest checked prior to module import. It detects
accidental file corruption/mixing but is **not digitally signed**.
Do not overwrite a baseline with its comparison output.

CI now includes `test-cloak-storage-s3-lifecycle.ps1` and the existing
bundle regression which tests CompareTo using synthetic changes. B2
has **not** yet been run on the user's real Windows guest; host build
and actual snapshot/restore remain separately unverified.

#### S3.4 — B3 ATA descriptor consistency and cold-boot acceptance

Release S3-C5-2026-11-B3 packages the same three guest scripts in a
SHA-256 verified ZIP. The changes are audit-only; no VirtualBox host
binary or Oracle Guest Additions change is needed.

Why B3: on VM test, the ATA Windows storage descriptor reported
Vendor empty, Product LAB ATA DISK, Revision LAB1, while PnP reported
VEN_LAB_ATA&PROD_DISK. These are different identity representations.
For ATA, OS_PNP_IDENTITY is explicitly NOT_APPLICABLE rather than a
false failure. The new OS_ATA_IDENTITY compares the complete descriptor
model and revision against WMI and independent ATA IDENTIFY, and FAILs
on any actual disagreement. PROFILE_LAB still verifies PnP separately.

SeekPenalty Win32 31 is ERROR_GEN_FAILURE, not conclusive proof of
unsupported property or rotating media. OS_SEEK remains NOT_VERIFIED
with that exact error; raw ATA word 217 = 0 is also unreported.
Do not change rotation, SMART, TRIM or host NonRotational flags merely
to satisfy the audit.

Host: bundle the B3 guest files once.

~~~powershell
cd D:\virtualbox
.\.github\scripts\New-CloakStorageS3Bundle.ps1 -OutputPath "$env:USERPROFILE\Downloads\CloakStorageS3-B3.zip" -Force
~~~

Copy ZIP to C:\Users\admin\Documents\scripts inside VM, alongside
cloak-c5-host.json. In Administrator PowerShell, prepare B3 and take a
baseline while the VM is still running:

~~~powershell
cd C:\Users\admin\Documents\scripts
Expand-Archive .\CloakStorageS3-B3.zip -DestinationPath .\S3-C5-B3 -Force
Copy-Item .\cloak-c5-host.json .\S3-C5-B3\cloak-c5-host.json
cd .\S3-C5-B3
.\Test-CloakStorageS3Guest.ps1 -NativeAtaIdentify -HostCapabilitiesPath .\cloak-c5-host.json -OutputPath "$env:USERPROFILE\Documents\cloak-S3-B3-baseline.json"
~~~

Keep this baseline unchanged. Before any snapshot/restore, copy the
baseline outside the VM: a restore may also roll back guest files.

For a true cold boot, SAVE your documents and run the following in
the guest. This is a full shutdown, not Restart-Computer or VM Reset.

~~~powershell
shutdown.exe /s /t 0
~~~

Host PowerShell: ensure VM state is poweroff BEFORE restarting. Point
$vbm to the VBoxManage.exe from the actual custom installation.

~~~powershell
$vbm = 'C:\path\to\your\current\VBoxManage.exe'
& $vbm showvminfo "test" --machinereadable | Select-String '^VMState='
# Require: VMState="poweroff"
& $vbm startvm "test" --type gui
~~~

After Windows boots and disk enumeration settles, in guest
Administrator PowerShell:

~~~powershell
cd C:\Users\admin\Documents\scripts\S3-C5-B3
.\Test-CloakStorageS3Guest.ps1 -NativeAtaIdentify -HostCapabilitiesPath .\cloak-c5-host.json -CompareTo "$env:USERPROFILE\Documents\cloak-S3-B3-baseline.json" -OutputPath "$env:USERPROFILE\Documents\cloak-S3-B3-after-coldboot.json"

$report = Get-Content "$env:USERPROFILE\Documents\cloak-S3-B3-after-coldboot.json" -Raw | ConvertFrom-Json
$report | Select-Object AuditRevision,BundleIntegrity,Overall
$report.LifecycleComparison | Select-Object Overall,Failed,NotVerified
$report.LifecycleComparison.Checks | Where-Object Status -ne 'PASS' | Format-Table Disk,Id,Status,Note -AutoSize
~~~

LifecycleComparison.Overall=PASS and Failed=0 means all compared
fields available across both runs remained unchanged. PARTIAL means
missing evidence on at least one side; FAIL means drift and is a
failing exit. The independent C5 Overall may still be PARTIAL because
rotation, SeekPenalty or VPD 0x83 remains unverified. A previously
recorded B2 baseline may be compared with B3 if its fields are
compatible; matched B3-before/B3-after is preferable.

CI tests simulate empty vendor, actual model/firmware disagreements,
SeekPenalty error 31, and B2-to-B3 lifecycle comparisons. Only a real
guest cold boot can confirm runtime stability.

### S3.5 — Powered-off snapshot/restore end-to-end acceptance (host guarded workflow)

This workflow uses existing S3-C5-2026-11-B3 guest scripts; no VirtualBox
rebuild or guest script update is required. Host helper
Invoke-CloakStorageS3SnapshotHost.ps1 has separate Check, Take, Ready,
Restore and CheckRestored actions. It NEVER shuts down or starts a VM.
Restore is an explicit, double-acknowledged action with an independently
verified pre-restore guest report. CI tests use mock VBoxManage only.

IMPORTANT: RESTORE REVERTS VM SETTINGS AND GUEST DISK FILES to the
snapshot time. Back up all changed guest files to the HOST first.
The baseline and before/after reports MUST live on HOST storage, not
on the VM disk that will be rolled back. Take the snapshot only with
VMState=poweroff; no live or saved-RAM snapshot.

A. Transfer the existing guest B3 baseline (from
C:\Users\admin\Documents\cloak-S3-B3-baseline.json) to a host directory
as baseline.json, using a shared folder or another file transfer method.
Guest Documents and HOST Documents are DIFFERENT paths.

B. Host PowerShell; substitute the exact VBoxManage.exe path from the
custom VirtualBox installation, never the old vbox2 or a PATH alias:

~~~powershell
cd D:\virtualbox
$vbm = "C:\path\to\your\current\VBoxManage.exe"
Test-Path -LiteralPath $vbm   # Must be True
$ev = Join-Path $env:USERPROFILE 'Documents\CloakS3-Snapshot-test'
New-Item -ItemType Directory -Path $ev -Force | Out-Null
# Put a host copy of the B3 guest baseline at $ev\baseline.json
$common = @{
    VM='test'
    VBoxManage=$vbm
    BaselinePath=(Join-Path $ev 'baseline.json')
    EvidenceDir=$ev
    SnapshotName='S3-C5-identity-restore'
}
& .\.github\scripts\Invoke-CloakStorageS3SnapshotHost.ps1 @common -Action Check
~~~

C. Guest: save all work and run shutdown.exe /s /t 0. Wait until
the VM is completely POWERED OFF. Then on HOST:

~~~powershell
& .\.github\scripts\Invoke-CloakStorageS3SnapshotHost.ps1 @common -Action Take
& $vbm startvm "test" --type gui
~~~

D. Guest after the powered-off snapshot, PowerShell Administrator:

~~~powershell
cd C:\Users\admin\Documents\scripts\S3-C5-B3
.\Test-CloakStorageS3Guest.ps1 -NativeAtaIdentify -HostCapabilitiesPath .\cloak-c5-host.json -CompareTo "$env:USERPROFILE\Documents\cloak-S3-B3-baseline.json" -OutputPath "$env:USERPROFILE\Documents\cloak-S3-B3-before-restore.json"
~~~

Require LifecycleComparison=PASS, Failed=0 and NotVerified=0. Transfer
this guest report to HOST $ev\before.json. Back up every changed guest
file you need to retain. Restoring will discard writes made after Take.

E. Guest: shutdown.exe /s /t 0 again. On HOST after VM poweroff:

~~~powershell
$common.BeforeRestorePath = Join-Path $ev 'before.json'
& .\.github\scripts\Invoke-CloakStorageS3SnapshotHost.ps1 @common -Action Ready
# DESTRUCTIVE: run only after you have saved all changes outside guest.
& .\.github\scripts\Invoke-CloakStorageS3SnapshotHost.ps1 @common -Action Restore -AllowRollback -ConfirmSnapshotName 'S3-C5-identity-restore'
& .\.github\scripts\Invoke-CloakStorageS3SnapshotHost.ps1 @common -Action CheckRestored
~~~

The helper refuses restore unless VMState=poweroff, the uniquely named
snapshot exists, baseline SHA256 is unchanged, before.json is a valid
fully verified B3 lifecycle PASS and passes independent host comparison,
and exact restoration confirmation is supplied. A host evidence file
tracks TAKEN/READY/RESTORED without guest file paths, serials or UUIDs.

F. Refresh the restored host storage binding BEFORE starting the VM.
Use this example ONLY if SATA port0/device0 still corresponds to guest
Disk0. Do not guess a changed mapping:

~~~powershell
& .\.github\scripts\Export-CloakStorageC5Host.ps1 -VM test -VBoxManage $vbm -Controller SATA -Port 0 -Device 0 -GuestDiskIndex 0 -OutputPath (Join-Path $ev 'cloak-c5-host-restored.json')
& $vbm startvm "test" --type gui
~~~

Copy the refreshed HOST manifest to the guest B3 folder as
cloak-c5-host.json. Guest B3 scripts and baseline should still exist
because they were installed BEFORE the powered-off snapshot. Otherwise
restore exact HOST copies, not a new baseline.

G. Guest after Windows boots, PowerShell Administrator:

~~~powershell
cd C:\Users\admin\Documents\scripts\S3-C5-B3
.\Test-CloakStorageS3Guest.ps1 -NativeAtaIdentify -HostCapabilitiesPath .\cloak-c5-host.json -CompareTo "$env:USERPROFILE\Documents\cloak-S3-B3-baseline.json" -OutputPath "$env:USERPROFILE\Documents\cloak-S3-B3-after-restore.json"
$post = Get-Content "$env:USERPROFILE\Documents\cloak-S3-B3-after-restore.json" -Raw | ConvertFrom-Json
$post.LifecycleComparison | Format-List Overall,Failed,NotVerified
~~~

Transfer this guest report to HOST $ev\after.json. On HOST:

~~~powershell
& .\.github\scripts\Test-CloakStorageS3SnapshotEvidence.ps1 -BaselinePath $common.BaselinePath -BeforeRestorePath $common.BeforeRestorePath -AfterRestorePath (Join-Path $ev 'after.json')
~~~

PASS means BASELINE, BEFORE and AFTER are independently compared on
HOST without observed identity/capability drift or lifecycle gaps.
The separate C5 Overall may remain PARTIAL because SeekPenalty Win32 31,
ATA word 217=0, and optical VPD83 are unverified; this does NOT negate a
LifecycleComparison PASS. An actual VM snapshot/restore is NOT claimed
until you have run these stages against VM test and retained evidence.
Do not delete the snapshot until you have reviewed the restored state
and any guest files that must be retained.

#### S3.6 — Lab storage hook wiring guard (snapshot runtime deferred)

Hook batch H1 (2026-11-07) is a C++ source change staged for a single
future host build. It does not update guest scripts and does not
rebrand any optical/VSCSI/USB vendor or product.

- ConsoleImplConfigCloakStorage.h adds CloakStorageValidateLabEffective:
  checks effective CFGM ModelNumber, FirmwareRevision and SerialNumber
  against the attachment's lab defaults after validating lengths.
  A conflicting ExtraData override is rejected with VERR_MISMATCH.
  Serial contents are never logged.
- CloakStorageValidateLabCoverage rejects an explicitly enabled lab HDD
  profile if no eligible IDE/AHCI HDD is attached, or if the materialized
  disk count differs from the eligible count. Disabled lab mode is unchanged.
- ConsoleImplConfigCloak.cpp calls this lab-only validation after CFGM
  materialization and BEFORE wiping the expected serial. It only applies
  when the lab storage identity is explicitly enabled.
- The host inventory now counts optical attachments independently
  as out of scope of the HDD lab profile, without changing optical IDs.
- tstCloakConfig.cpp has positive and negative model/firmware/serial
  override and missing/partial HDD coverage fixtures. These C++ tests
  must still be compiled and run in CI.
- Test-CloakLabHookWiring.ps1 is a fast, read-only source/order guard;
  test-cloak-lab-hook-wiring.ps1 has negative fixtures that remove each
  new guard to ensure the pre-build gate fails closed. This static PASS
  is NOT a C++ compile nor a runtime guest acceptance result.

Host-only source guard (no VM actions or VirtualBox build):

~~~powershell
cd D:\virtualbox
.\.github\scripts\Test-CloakLabHookWiring.ps1 -OutputPath "$env:TEMP\cloak-lab-hook-wiring.json"
~~~

Deferred hooks: ATAPI optical materializer, VSCSI/USB MSD/HostDVD lab
profiles, stable logical-drive ID independent of medium UUID, and
backed SMART/TRIM/rotation capability implementation. Other firmware,
PCI and graphics hooks require separate evidence and compatibility
review; none is claimed complete by the HDD-only source guard.

User requested that actual snapshot/restore work be postponed.
Do not run snapshot actions for this hook batch. Existing snapshot
scripts remain unchanged. A future host C++ build and tstCloakConfig
run are required before claiming the new validator works in a VM.

### S3.7 — H2 IDE/AHCI optical profile hook, B4 guest audit (build pending)

H2 stages a NEW, SYNTHETIC, LAB-ONLY optical identity path. It is
**not enabled by default** and is independent of StorageLabEnabled.
No real manufacturer identity is claimed, no VMware/VMMDev/VGA/USB/PCI
driver-binding IDs or Guest Additions are modified.

**C++ wiring:** ConsoleImplConfigCloak.cpp now enumerates true DVD
attachments from the VM controller/medium COM graph. When
`VBoxInternal/Cloak/StorageLabOpticalEnabled=integer:1` and only for
virtual IDE/PIIX3 or AHCI DVD attachments (not HostDrive or passthrough),
it uses the actual controller instance/slot CFGM node to populate
`ModelNumber=LAB CD-ROM`, `FirmwareRevision=LAB1`,
`ATAPIVendorId=LAB`, `ATAPIProductId=CD-ROM`,
`ATAPIRevision=LAB1`, plus a synthetic, deterministic, redacted
18-character serial derived from the VM serial stream and slot.
For PIIX3 IDE only, `OverwriteInquiry=1` must also be effective.
Any conflicting ExtraData override fails before device initialization.
Unsupported or physical/passthrough optical mixed with a requested
optical lab profile fails the coverage gate rather than silently
changing only some drives. Empty DVD tray (medium not mounted) is
permitted if its virtual optical controller attachment exists.

**Known identity limit:** optical serial is keyed to controller instance
and slot. Moving optical to another slot changes that synthetic serial.
This is NOT the planned stable logical optical drive ID. No change
to ATA SMART, TRIM, rotation, optical VPD83 or physical optical inquiry
behavior is implied by this hook.

**Host control:** `Set-CloakLabStorage.ps1` adds `EnableOptical` and
`DisableOptical`. Run only when VM is fully poweroff and an existing
enabled `lab-dmi-v1` profile is selected. Global `Disable` clears
the optical switch too; `Enable` (HDD) does not automatically enable
optical. With optical disabled, current VBOX/CD-ROM/1.0 remains as-is.

**Guest audit:** release `S3-C5-2026-11-B4` adds C5 LAB optical scope
assessment. It reports `OPTICAL_LAB_SCOPE=PASS` only when PnP, Windows
descriptor and direct read-only INQUIRY all show synthetic
`LAB/CD-ROM/LAB1`; incomplete evidence is `NOT_VERIFIED` and
disagreement is `FAIL`. Unmodified `VBOX/CD-ROM/1.0` stays an expected
`NOT_APPLICABLE` optical lab residual. B4 keeps HDD C5 semantics.
Some VPD83/rotation observations may remain NOT_VERIFIED even when
this optical identity path works.

**Pre-build checks** (source/PowerShell only; cannot prove C++ compiles):

~~~powershell
cd D:\virtualbox
.\.github\scripts\Test-CloakLabHookWiring.ps1
.\.github\scripts\test-cloak-lab-hook-wiring.ps1
.\.github\scripts\test-cloak-lab-optical-host.ps1
.\.github\scripts\test-cloak-storage-s3.ps1
~~~

**After successful host build and passing native tstCloakConfig:**
First verify your actual current VBoxManage.exe path (not old vbox2).
Use a disposable test VM and back up its important data because
changing optical PnP identity can re-enumerate a device in Windows.
Ensure a virtual IDE or SATA optical attachment is present; do not
enable this profile for HostDrive or passthrough optical.
With the guest fully SHUT DOWN, on HOST PowerShell:

~~~powershell
cd D:\virtualbox
$vbm='C:\path\to\current\VBoxManage.exe'  # replace with actual path
.\.github\scripts\Set-CloakLabStorage.ps1 -Action Status -VM test -VBoxManage $vbm
.\.github\scripts\Set-CloakLabStorage.ps1 -Action EnableOptical -VM test -VBoxManage $vbm -WhatIf
.\.github\scripts\Set-CloakLabStorage.ps1 -Action EnableOptical -VM test -VBoxManage $vbm
& $vbm startvm test --type gui
~~~

Create/transfer B4 guest bundle from the HOST:

~~~powershell
cd D:\virtualbox
.\.github\scripts\New-CloakStorageS3Bundle.ps1 `
    -OutputPath "$env:USERPROFILE\Downloads\CloakStorageS3-B4.zip" -Force
~~~

Copy the B4 ZIP and existing `cloak-c5-host.json` to the guest
`C:\Users\admin\Documents\scripts`. Guest Administrator PowerShell:

~~~powershell
cd C:\Users\admin\Documents\scripts
Expand-Archive .\CloakStorageS3-B4.zip -DestinationPath .\S3-C5-B4 -Force
Copy-Item .\cloak-c5-host.json .\S3-C5-B4\cloak-c5-host.json
cd .\S3-C5-B4
.\Test-CloakStorageS3Guest.ps1 `
    -NativeAtaIdentify `
    -HostCapabilitiesPath .\cloak-c5-host.json `
    -OutputPath "$env:USERPROFILE\Documents\cloak-S3-B4-optical.json"
~~~

Acceptance requires `bundle integrity=SHA256_VERIFIED`,
`OPTICAL_LAB_SCOPE=PASS`, `OPTICAL_OS_DESCRIPTOR=PASS`,
`ATAPI_OPTICAL=PASS`, and no new HDD identity contradictions.
If Windows refuses INQUIRY or VPD, record NOT_VERIFIED instead of
claiming full storage runtime PASS. In a failure case, shut down
the VM fully and run on HOST:

~~~powershell
.\.github\scripts\Set-CloakLabStorage.ps1 -Action DisableOptical -VM test -VBoxManage $vbm
~~~

**Deferred:** snapshot/restore runtime testing; VSCSI, USB MSD,
HostDVD profile materializers; persistent logical drive ID; full
SMART/TRIM/rotation capability implementations. CI runs static source
guards and PowerShell tests BEFORE building, then native `tstCloakConfig`
as a separate compiled test stage. Do not claim H2 runtime PASS until
the new host build boots and the B4 guest JSON is inspected.

## Roll back safely

Shut down the guest fully, then on the host:

```powershell
.\.github\scripts\Set-CloakLabProfile.ps1 -Action Disable -VM test -VBoxManage $vbm
```

Cold-start the VM again. `Disable` keeps the seed/provisioning data intact
for reproducible future lab tests. Reverting the VM snapshot is also valid.

If a cold boot fails, disable with the command above **before** attempting to
start the VM again. Do not enable a production profile or use saved-state
restore with different identity settings.

## Troubleshooting

- Still shows `innotek GmbH`: verify the new host artifact passed the
  `Verify lab-only DMI profile is embedded in VBoxC` CI step, check that the
  VM is running under the matching self-built host, and inspect `VBox.log`.
- `profile 'lab-dmi-v1' is not available in the production registry`:
  the running `VBoxC.dll` lacks the lab compilation flag or is from the
  previous artifact.
- `Cloak: runtime cloak disabled`: the VM extradata `Enabled` key was not
  set correctly or the guest was started before it was applied.
- ACPI OEM ID can differ across ACPI tables. Do not conclude all firmware
  surfaces are changed from the two WMI SMBIOS commands alone.
