# Windows Guest Additions NSIS build dependencies

Two external NSIS plugins are pinned in this repository for the Windows Guest
Additions NSIS *build* (not as separately installed guest components):

| Plugin | Upstream | Version | SHA-256 |
| --- | --- | --- | --- |
| nsProcess | https://nsis.sourceforge.io/NsProcess_plugin | 1.7 | `30D7B4188280A01DD227E07373723A1EC6B1B3206D305FC4A2EC2691046F04E3` |
| AccessControl | https://nsis.sourceforge.io/AccessControl_plug-in | 1.0.8.3 (20210224) | `9AA60F9C5C023FDA2808AF216514D8913D2673BC522D944EE771DA032A1BDC10` |

Original archives:

- `nsProcess-1.7.zip`: https://nsis.sourceforge.io/mediawiki/images/1/18/NsProcess.zip
  (NSIS `Include/nsProcess.nsh`, x86 `Plugin/nsProcess.dll`, x64 DLL, source and docs)
- `AccessControl-1.0.8.3.zip`: https://nsis.sourceforge.io/mediawiki/images/4/4a/AccessControl.zip
  (NSIS 3 x86 Unicode `Plugins/i386-unicode/AccessControl.dll`, ANSI and
  amd64 Unicode DLLs, source, and Docs/AccessControl/AccessControl.txt)

The CI pipeline checks SHA-256 and stages the *x86 Unicode* DLLs into
`Plugins/x86-unicode` because the Guest Additions installer is compiled in
Unicode mode with the 32-bit NSIS stub. The `nsProcess` include file is staged
into the NSIS include search path. NSIS explicitly receives `!addincludedir`
and `!addplugindir` directives. The build preflight compiles NSIS calls for
nsProcess and all three AccessControl APIs currently used by VirtualBox's
Windows Guest Additions installer.

NSIS itself is set up by `nsis-dev/setup-nsis@v1`, set to NSIS 3.10
with advanced logging (VirtualBox uses `LogSet` and `LogText`).
