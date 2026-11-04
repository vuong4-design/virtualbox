# Windows Guest Additions: isolated CI test signing (Windows 10 1809 x64)

**TEST ONLY.** This workflow is for the disposable Windows guest `test` (OS build 17763)
in the VirtualBox development project. It is **not** release signing, WHQL, Microsoft
attestation signing, or a way to run untrusted drivers on production systems.

## What the CI now does

1. Compile Windows Guest Additions normally.
2. Generate a new, **non-exportable**, self-signed code signing key in the hosted
   Windows runner's **CurrentUser\\My** store. This key is not committed or uploaded.
3. Do **not** import the CI test certificate into `Root` or `TrustedPublisher`
   on GitHub-hosted runners. This can cause an interactive trust prompt and
   stall the build. Signature verification confirms the signer thumbprint and
   tolerates only the expected untrusted test root; invalid hashes/signatures
   still fail. The CI signing step has a **15-minute timeout**, plus four
   phase markers to diagnose any subsequent stall. Sign staged `*.sys` driver
   binaries **before** creating catalog hashes.
4. Add `CatalogFile` to the four staged INF files (`VBoxGuest`, `VBoxMouse`,
   `VBoxVideo`, `VBoxWddm`), and build a separate catalog for each one with
   WDK `Inf2Cat /os:10_RS5_X64`. Use isolated directories so Inf2Cat only sees
   one INF at a time. Sign and verify these catalogs with `SignTool`.
5. Before `kmk packing`, verify SHA-256 for every file recorded in
   `VBoxGATestSigning.json` (including INF-referenced EXEs/DLLs such as
   `VBoxControl.exe`). Invoke kBuild with `-o FILE` for each protected input:
   this makes kBuild treat the signed output as already up to date, preventing
   its packing pass from replacing it with an unsigned build artifact.
   Re-create the installer using `VBOX_GA_CI_TESTSIGN=1` to embed four
   signed catalogs. The installer makefile explicitly declares these `.cat`
   files as prerequisites in CI test-signing mode.
6. Recompute SHA-256 for all protected files immediately after packing, then
   verify signed catalogs. If any input still changes, CI fails rather than
   shipping a mismatched package. **Never fix hash mismatches by skipping
   verification or editing the signing manifest.**

The downloadable GitHub Actions artifact `virtualbox-guest-additions` contains
`additions/VBoxWindowsAdditions-amd64.exe`, `additions/VBoxGATestSigner.cer` (PUBLIC
certificate only), and `additions/VBoxGATestSigning.json` (certificate fingerprint
and SHA-256 file hashes). **Do not use an artifact from a failing job**. The
test-signing certificate is unique to each run, so each new build requires
trusting its own public certificate on the disposable guest.

## Install on the disposable Windows guest (not the host)

1. Create a **snapshot** of the guest before attempting installation.
2. Confirm the guest is a dedicated test VM and not a production installation.
   If VirtualBox Secure Boot is enabled, turn it **off in the VM's firmware
   configuration**, using the host VirtualBox settings, while the VM is powered
   off. Do not alter Secure Boot on the physical host.
3. Copy `VBoxGATestSigner.cer` and `VBoxWindowsAdditions-amd64.exe` from the SAME
   successful CI run into the guest.
4. Open **PowerShell as Administrator inside the guest**. From the directory
   containing these two files, first inspect the certificate:

   ```powershell
   $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path .\VBoxGATestSigner.cer).Path)
   $cert | Format-List Subject,Thumbprint,NotAfter
   ```

   Optional: compare `$cert.Thumbprint` with
   `VBoxGATestSigning.json` -> `CertificateThumbprint`. Only proceed if
   the fingerprint matches the exact artifact you intended to test.

5. For this VM **only**, explicitly trust the public test certificate:

   ```powershell
   Import-Certificate -FilePath .\VBoxGATestSigner.cer -CertStoreLocation Cert:\LocalMachine\Root
   Import-Certificate -FilePath .\VBoxGATestSigner.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
   ```

6. Enable Windows test-signing mode in the **guest**, then reboot it:

   ```powershell
   bcdedit /set testsigning on
   Restart-Computer
   ```

   If BCD reports that Secure Boot protects the value, review the guest's
   firmware configuration. Do not try to bypass firmware policy on the host.
   Device Guard/HVCI or organization policy can impose additional restrictions.

7. After reboot, run the matching installer **as Administrator** inside the guest:

   ```powershell
   Start-Process -FilePath '.\VBoxWindowsAdditions-amd64.exe' -Verb RunAs -Wait -PassThru
   ```

   Restart the guest after installation, and verify:

   ```powershell
   Get-CimInstance Win32_PnPEntity |
     Where-Object { $_.PNPDeviceID -like 'PCI\VEN_80EE&DEV_CAFE*' } |
     Select-Object Name,Status,ConfigManagerErrorCode,Service
   Get-Service VBoxService -ErrorAction SilentlyContinue
   ```

If installing fails, check
`C:\Program Files\Oracle\VirtualBox Guest Additions\install_drivers.log`
and `C:\Windows\INF\setupapi.dev.log`. A signed test catalog does not
guarantee the driver is compatible with the guest.

## Restore the guest after testing

Revert to the VM snapshot, which restores trusted certificates, boot policy,
and installed driver state. If not reverting, disable test-signing in the
guest using `bcdedit /set testsigning off` and reboot, then remove only the
test certificate with the recorded thumbprint from the guest's LocalMachine
Root and TrustedPublisher stores. Be aware that disabling test-signing may
prevent the test driver from loading.

**Never import a CI test certificate onto a production host. Never upload a
private `.pfx` file or private key to GitHub artifacts.**

## Troubleshooting and limitations

* `ERROR_NO_CATALOG_FOR_OEM_INF (0xE000022F)`: expected when a driver lacks
  a signed catalog; verify `VBoxGuest.cat` is present next to `VBoxGuest.inf`
  in the extracted installer files.
* `SignTool` verification errors: the current CI runner's ephemeral
  certificate must be trusted there; on the guest, the matching public
  certificate must be installed in both stores.
* `Inf2Cat` signability errors: fix the specific driver INF/files reported
  by Inf2Cat, rather than suppressing signing checks.
* `VBoxSF.sys` is embedded-signed but the current NSIS package does not
  install a separate `VBoxSF.inf` through PnP. The four catalog targets
  reflect the driver INF files actually packed by NSIS for this x64 build.
* This path targets only Windows 10 1809 x64 (17763). Different guest
  OS versions/architectures require reviewing Inf2Cat OS targets and INF
  compatibility. For general production deployment, use Microsoft-approved
  driver signing.

Microsoft documentation:
- https://learn.microsoft.com/en-us/windows-hardware/drivers/install/test-signing
- https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/inf2cat
- https://learn.microsoft.com/en-us/windows-hardware/drivers/install/installing-test-certificates
