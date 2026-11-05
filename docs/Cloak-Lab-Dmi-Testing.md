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
