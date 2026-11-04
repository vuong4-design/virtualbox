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
