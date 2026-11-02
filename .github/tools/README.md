# Windows Guest Additions NSIS build dependency

`nsProcess-1.7.zip` is vendored for the Windows Guest Additions installer build only.

- Upstream: https://nsis.sourceforge.io/NsProcess_plugin
- Archive: https://nsis.sourceforge.io/mediawiki/images/1/18/NsProcess.zip
- Version: 1.7
- SHA-256: `30D7B4188280A01DD227E07373723A1EC6B1B3206D305FC4A2EC2691046F04E3`
- Contents: NSIS include `Include/nsProcess.nsh`, plugin binaries `Plugin/nsProcess.dll` and `Plugin/x64/nsProcess.dll`, upstream source and README/license information.

The GitHub Actions Windows Guest Additions job checks the archive hash and stages the
x86 Unicode plugin with NSIS before invoking the NSIS packaging target.
The archive is not deployed separately to guest machines.

NSIS itself is set up by `nsis-dev/setup-nsis@v1`, pinned to NSIS 3.10
with advanced logging support, because VirtualBox's installer scripts use
`LogSet` / `LogText`.
