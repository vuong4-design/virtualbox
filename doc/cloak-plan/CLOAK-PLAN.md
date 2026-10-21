# Kế hoạch port "cloak" (identity presentation) từ fork AntiOS/Antidetect5 vào VirtualBox 7.2

> **Tài liệu này** là kết quả đọc toàn bộ tài liệu phân tích trong `cloak/` và đối chiếu với mã nguồn VirtualBox tại `D:\virtualbox\src` (branch `VBox-7.2`, `Version.kmk` → 7.2.23).
>
> **Mục tiêu:** xây dựng kế hoạch sửa mã nguồn VirtualBox để hiện thực hoá các lớp "cloak" (đổi identity mà guest nhìn thấy) đã được xác nhận trong tài liệu phân tích.
>
> **Trạng thái: KẾ HOẠCH — chưa triển khai code.** 4 quyết định thiết kế đã chốt tại [§10](#10-quyết-định-đã-chốt):
> (1) chia 4 PR, (2) identity phải **đồng bộ** → Machine Profile Engine, (3) selector **random nhưng ổn định** theo VM UUID, (4) build qua **GitHub Actions**.
>
> **Không nằm trong phạm vi:** các payload ở tầng ISO/script của bản fork (AutoKMS crack, hosts-blocklist chống anti-fraud, browser-profile forgery, driver test-signing). Đó là tài nguyên của `cloak/Iso/`, không phải mã nguồn VirtualBox.

---

## Mục lục

1. [Tóm tắt tài liệu phân tích](#1-tóm-tắt-tài-liệu-phân-tích)
2. [Kiến trúc cloak của fork](#2-kiến-trúc-cloak-của-fork)
3. [Inventory đầy đủ: hook → vị trí trong mã nguồn](#3-inventory-đầy-đủ-hook--vị-trí-trong-mã-nguồn)
4. [Nguyên tắc thiết kế: chọn cơ chế điều khiển](#4-nguyên-tắc-thiết-kế-chọn-cơ-chế-điều-khiển)
   - [4.5 Kiến trúc MPE — Machine Profile Engine](#45-kiến-trúc-mpe--machine-profile-engine-quyết-định-2-thông-tin-phải-đồng-bộ)
   - [4.6 Selector ổn định](#46-selector-ổn-định-quyết-định-3-random-nhưng-không-đổi-khi-mở-lại-vm)
   - [4.7 CI bằng GitHub Actions](#47-ci-bằng-github-actions-quyết-định-4)
5. [Kế hoạch triển khai theo phase](#5-kế-hoạch-triển-khai-theo-phase)
6. [Cross-layer coherence — phần cần thêm ngoài tài liệu](#6-cross-layer-coherence--phần-cần-thêm-ngoài-tài-liệu)
7. [Quy trình build](#7-quy-trình-build)
8. [Quy trình kiểm chứng](#8-quy-trình-kiểm-chứng)
9. [Rủi ro](#9-rủi-ro)
10. [Quyết định đã chốt](#10-quyết-định-đã-chốt)
11. [Trạng thái triển khai](#11-trạng-thái-triển-khai)

---

## 1. Tóm tắt tài liệu phân tích

### 1.1 Các tài liệu đã đọc

| Tài liệu | Vai trò |
|---|---|
| `cloak/ANTIOS-VIRTUALBOX-CLOAK-HOOK-INVENTORY-20260906.md` (2605 dòng) | **Inventory chính** — 46 mục, phân loại theo 16 part, kèm Tier 1/2/3 ranking |
| `cloak/ANTIOS-ANALYSIS-20260903.md` (767 dòng) | Báo cáo phân tích gốc, 20 slot `sltAntiOS*` |
| `cloak/ANTIOS-ISO-ANALYSIS-20260903.md` (469 dòng) | Phân tích cây ISO Guest Additions, 6 phân hệ giả mạo mới |
| `cloak/analysis_driverdiff/ANTIOS-COVERAGE-PROOF-MATRIX-20260908.md` (778 dòng) | Coverage matrix 61 row — trạng thái từng surface |
| `cloak/ChatGPT-20260902-0644.md` (12964 dòng) | Log RE so sánh 2 fork: GPM (GBoz*) và Antidetect5 |
| `cloak/A5TOOLKIT-UNPACK-20260903.md` (291 dòng) | NSIS Guest Additions unpack |
| `cloak/.catdesk/{project,current_plan,todo,session,decisions}.md` | Trạng thái dự án, stop-rule, 8 row runtime chưa đóng |
| `cloak/analysis_driverdiff/ANTIOS-HOOK-GAP-CROSSCHECK.md` (3774 dòng) | Cross-check đầy đủ 100+ pass |

### 1.2 Trạng thái coverage matrix (61 row)

| Trạng thái | Số row | Ý nghĩa |
|---|---:|---|
| `FORK_CHANGED_CONFIRMED` | 30 | Đã chứng minh fork khác Oracle, có sink guest-visible |
| `STOCK_REUSED_CONFIRMED` | 18 | Exact-pair bằng nhau, không có hook |
| `RUNTIME_UNVERIFIED` | 8 | Cần matched runtime capture mới để đóng |
| `ARTIFACT_BOUNDED` | 2 | Chỉ có artifact, chưa có runtime evidence |
| `REMOVED` | 1 | Feature bị gỡ khỏi fork |
| `INERT_OR_FILTERED` | 1 | Có producer nhưng bị lọc trước CFGM |
| `HISTORICAL_ONLY` | 1 | Chỉ có ở snapshot cũ |

8 row `RUNTIME_UNVERIFIED` (đóng bằng runtime, không mở lại static scan):

1. `CPU-TOPOLOGY-COHERENCE`
2. `PCI-CAPABILITY-GENERAL`
3. `HGCM-SHAREDFOLDERS-SEMANTICS`
4. `HGCM-CLIPBOARD-SEMANTICS`
5. `HGCM-DND-SEMANTICS`
6. `HGCM-HOSTCHANNEL-SEMANTICS`
7. `WHOLE-CERT-RESIDUE`
8. `UEFI-EFIGUARD-ACTIVATION` (chỉ phần downstream Windows patch realization)

### 1.3 Bối cảnh quan trọng cho kế hoạch

- **Oracle baseline:** VirtualBox 7.2.4 r170995.
- **Lineage của fork:** VirtualBox **7.1.6 r167084** (đã chứng minh qua exact-pair 3-way với official 7.1.6). Fork báo version `7.2.4` nhưng revision vẫn `167084`.
- **Repo hiện tại:** `VBox-7.2` = **7.2.23** (mới hơn baseline của fork ~19 bản build). Mọi line number trong tài liệu phải được re-map — tài liệu này đã map lại toàn bộ.

---

## 2. Kiến trúc cloak của fork

### 2.1 Mô hình

AntiOS **không** dựa vào một kernel hook duy nhất. Cloak là một hệ thống presentation đa lớp:

```
control plane  (ExtraData / CustomData / VBoxManage)
     │
     ├─► CFGM overlay ──► device constructors (VBoxDD)
     │                        ├─ PCI / USB identity
     │                        ├─ storage IDENTIFY / INQUIRY
     │                        └─ TPM capability backend
     │
     ├─► firmware generators (VBoxDD / OVMF)
     │        ├─ SMBIOS / DMI
     │        ├─ ACPI (generated + embedded DSDT)
     │        ├─ MPS
     │        ├─ legacy PC BIOS / VGA option ROM
     │        └─ UEFI (OVMF)
     │
     ├─► VMM CPU (VBoxVMM)
     │        ├─ CPUID hypervisor vendor + HVP bit
     │        └─ CPU DB profile selection
     │
     ├─► Guest Additions identity camouflage
     │        └─ VBoxGuest/VBoxService/VBoxSF/VBoxTray/VBoxControl/VBoxVideo
     │
     └─► Guest Control provisioning (guest-state mutation)
              ├─ TCP/IP stack randomization (M1D / M1D1)
              ├─ hop-limit compensation (VPN)
              ├─ hosts / firewall / privacy policy
              ├─ browser profile age/state
              └─ display topology / EDID
```

### 2.2 Hai kiểu fork được phân tích

| | **GPM** (`GPMRealBox`, `GBoz*`) | **Antidetect5** (`Vektor T13`) |
|---|---|---|
| Nguồn | `F:\products\GPMBox\vmachine\src\7.2.4\modified\` | `C:\Devel\Antidetect5\Personal\VirtualBox\` |
| Cơ chế điều khiển | COM property mới: `GPMCPUName`, `GPMGPUVendorId`, `GPMPCIVendorId`… | `ExtraData` key `VBoxInternal/...` + CFGM overlay |
| Số property lập trình được | 10 | ~53 `SetCustomData` call |
| Ảnh hưởng ABI | **Phá vỡ** — property mới chèn *trước* 8 `InternalAndReservedAttribute`, SDK build cũ không tương thích | **Không** — không đụng COM/TypeLib |
| License gate | AES-256-GCM, RSA key nhúng, endpoint `api.giaiphapmmo.vn` | `VBoxRT::CheckSerial()` → root CFGM `Flags` = `0x1337` (valid) / `0x337` (invalid) |

→ **Kế hoạch chọn kiểu Antidetect5**: không đụng COM ABI, đi qua đường `ExtraData` đã có sẵn trong VirtualBox stock.

### 2.3 Điểm yếu cốt lõi của bản cloak (phải sửa luôn)

Tài liệu §46 / §48.1 — **cross-layer inconsistency** là failure mode lớn nhất:

- AMI-looking BIOS nhưng F12 menu còn in `VirtualBox`
- NVIDIA-looking VBE nhưng raw ROM còn `Antidetect5` / `VirtualBox` / `VBoxVgaBios*.sym`
- Realtek-looking NIC nhưng driver internals còn `Red Hat` / `VirtIO` / `NetKVM` / `ParaNdis`
- Seagate USB descriptor nhưng VSCSI INQUIRY vẫn `VBOX`
- PIIX3 optical: IDENTIFY `Samsung` vs INQUIRY `VBOX`
- AHCI optical: IDENTIFY `Toshiba` vs INQUIRY `SanDisk`
- SSD-looking model nhưng TRIM / non-rotational / SMART không khớp
- VirtIO shared vendor rewrite `10EC` rò sang VirtIO-SCSI (`10EC:1048`)
- E1000 PCI subsystem vs EEPROM lệch thứ tự field
- Intel-looking TPM (`INTC/CSME/PTT`) nhưng libtpms cũ + PCR properties cũ
- NVIDIA-like graphics nhưng OBS IddCx EDID là `LNX / Linux FHD / Linux #0 / IddSample`

**Kết luận của tài liệu §57:** detector coherence-based mạnh hơn detector chỉ tìm literal `VBOX`. Vì vậy Phase 6 (coherence) được đưa vào kế hoạch, không phải làm sau cùng.

---

## 3. Inventory đầy đủ: hook → vị trí trong mã nguồn

> Cột "Nguồn" trỏ tới mục tương ứng trong `ANTIOS-VIRTUALBOX-CLOAK-HOOK-INVENTORY-20260906.md`.
> Mọi `file:line` đã được verify trực tiếp trên `D:\virtualbox\src` @ `edfe7955aa0`.

### 3.1 CPU / hypervisor / timing

| § | Hook | File:line | Ghi chú |
|---|---|---|---|
| 3.1 | Hyper-V vendor → `Microsoft   ` | `src/VBox/VMM/VMMR3/GIMR3Hv.cpp:245-248` | `CFGMR3QueryStringDef(pCfgHv, "VendorID", szVendor, sizeof(szVendor), "VBoxVBoxVBox")` — phải đúng 12 ký tự. Sink: leaf `0x40000000` EBX/ECX/EDX tại `GIMR3Hv.cpp:380-407` |
| 3.2 | **Suppress HVP bit** | `src/VBox/VMM/VMMR3/target-x86/CPUMR3CpuId-x86.cpp:4017-4026` | `case CPUMCPUIDFEATURE_HVP:` — bỏ `\|= X86_CPUID_FEATURE_ECX_HVP` (0x80000000) và `fHypervisorPresent = 1` → clear thay vì set. Const: `include/iprt/x86.h:521` |
| 3.2b | GIM provider dispatch | `src/VBox/VMM/VMMR3/GIMR3.cpp:156-184`; `GIMR3Hv.cpp:372-375`; `GIMR3Kvm.cpp:255-258`; `GIMR3Minimal.cpp:60-63` | Cả 3 provider đều gọi chung `CPUMR3SetGuestCpuIdFeature(..., HVP)` → phải xử lý cả 3 hoặc chỉ HyperV |
| 4.1 | CPU profile mới, `DmiCPU → GuestCpuName` | `src/VBox/VMM/VMMR3/CPUMR3Db.cpp:154` (`g_apCpumDbEntries`), `:272-275` (`CPUMR3DbGetEntries`); đọc key: `target-x86/CPUMR3CpuId-x86.cpp:2817-2821` | Fork có 61 entry, stock 27. Profile: `i9-9900K`, `i7-9700K`, `i7-9750H`, `i9-9980XE`, `Ryzen 7 1800X`… ⚠ xem cảnh báo §7.8 bên dưới |
| 4.1b | Producer `GuestCpuName` | `src/VBox/Main/src-client/ConsoleImplConfigX86.cpp:764` | `InsertConfigString(pCPUM, "GuestCpuName", bstrCpuProfile);` |
| 5.1 | `TM/TSCMode=RealTSCOffset` | `src/VBox/VMM/VMMR3/...` (stock) | Đã có sẵn ở stock — chỉ cần expose trong UI, **không cần sửa VMM** |

**Cảnh báo quan trọng (tài liệu §7.8 / Pass 116):** 4 profile Intel của fork **không phải** model CPUID độc lập — cùng family 6 / model 15 / stepping 6 (`CPUID.1 EAX = 0x000006f6`), `enmMicroarch=13` (= `kCpumMicroarch_Intel_Core2_Merom` trong enum VirtualBox). `i9-9900K` vs `i7-9700K` chỉ khác **1 trong 23** CPUID record (leaf `0x80000003`). Ngoài ra profile `i9-9900K` lộ brand string `i9-9700K`, `i7-9750H` lộ `i7-9700H`.
→ **Không được copy brand string từ fork.** Phải dựng lại CPUID blob từ CPU thật, hoặc bỏ hẳn khỏi scope.

Ngược lại, profile `AMD Ryzen 7 1800X Eight-Core` của fork **byte-for-byte giống** Oracle 7.1.6 và 7.2.4 → negative control tốt.

### 3.2 SMBIOS / DMI

| § | Hook | File:line | Ghi chú |
|---|---|---|---|
| 6.1 | Anti-detect gate `Flags & 0x1337` | `src/VBox/Devices/PC/DevFwCommon.cpp:487` (`FwCommonPlantDMITable`) | Đọc root CFGM `Flags`; gate type 17/19/8. Producer: `VBoxC` Console |
| 6.2 | SMBIOS Type 17 (Memory Device) + Type 19 (Memory Array Mapped Address) | `DevFwCommon.cpp:889-975` (Type 16 tại `:897-918`, Type 17 tại `:920-975`) | Stock có Type 16/17 nhưng bị gate bằng `DmiExposeMemoryTable` (`:630-633`, default 0). Cần thêm **Type 19** (chưa có trong stock) + key `DmiMemDev` (chưa có) |
| 6.3 | SMBIOS Type 8 (Port Connector) | chưa có trong stock | Cần code mới. Key `DmiPortConnectors` (chưa có). Chuỗi port connector mẫu của fork: `4 1;4 2;5 1;5 2;5 3;5 4;12;9;16;17;8 1;8 2;13 1;13 2;` (delimiter `;`) |
| 6.4 | **Type 11 OEM string suppression** | `DevFwCommon.cpp:977-999` | `RTStrPrintf(..., "vboxVer_%u.%u.%u", ...)` + `"vboxRev_%u"`. Đổi default `DmiOEMVBoxVer`/`DmiOEMVBoxRev` → `""` |
| 6.5 | Đổi default DMI vendor/product | `DevFwCommon.cpp:64-95` (`g_pszDefDmi*`) | `innotek GmbH`(:69,:73), `VirtualBox`(:70,:74), `Oracle Corporation`(:80,:88), `GenuineIntel`(:94), `Pentium(R) III`(:95) |
| 6.6 | Bảng key DMI mà stock đọc | `DevFwCommon.cpp:620-999` | Đầy đủ 30 key: `DmiUseHostInfo`, `DmiExposeMemoryTable`, `DmiExposeProcInf`, `DmiSystemUuid`, `DmiBIOS*`, `DmiSystem*`, `DmiBoard*`, `DmiChassis*`, `DmiProc*`, `DmiOEMVBoxVer/Rev` |

Macro đọc: `DMI_READ_CFG_STR_DEF` (`DevFwCommon.cpp:520-562`), `DMI_READ_CFG_STR` (`:564-565`), `DMI_READ_CFG_S32` (`:567-573`).
Lưu ý: `DmiREAD` hỗ trợ magic `"<EMPTY>"` → empty string và `"<DmiSystemUuid>"` → thay UUID (`:537-549`).

### 3.3 ACPI

| § | Hook | File:line | Ghi chú |
|---|---|---|---|
| 7.1 | UUID-derived ACPI OEM ID | `src/VBox/Devices/PC/DevACPI.cpp:4670-4678` | Stock default `"VBOX  "`. Fork: bảng 5 entry `HPQOEM` / `INTEL ` / `GBT   ` / `ASUS  ` / `IBMPDC`, index = `UUID.au32[3] % 5` |
| 7.2 | UUID-derived ACPI Creator ID | `DevACPI.cpp:4689-4697` | Stock default `"ASL "`. Fork: bảng 4 entry `HP  ` / `AMI ` / `INTL` / `ASUS`, index = `UUID.au32[3] & 3`. `AcpiCreatorRev` giữ `0x61` |
| 7.3 | Generated ACPI OEM Table ID cố định | `DevACPI.cpp:4680-4687` (`AcpiOemTabId` default `"VBOX"` → `"A M I "`), `:2918-2931` (`acpiR3PrepareHeader`) | OEM Table ID = `au8OemCustTabId` + signature → stock ra `VBOXAPIC`, `VBOXHPET`, `VBOXMCFG`. Đổi prefix thành `"A M I "` |
| 7.3b | SSDT CPU (`VBOXCPUT`) | `src/VBox/Devices/PC/ACPI/VBoxAcpi.cpp:91`, `:146` | `RTAcpiTblCreate(&hAcpiTbl, ACPI_TABLE_HDR_SIGNATURE_SSDT, 1, "VBOX  ", "VBOXCPUT", 2, "VBOX", RTBldCfgRevision());` |
| 7.4 | ACPI PM `VenDevId` override | `DevACPI.cpp:4881-4882` | Stock `8086:7113`; key `VenDevId` = (VID<<16)\|DID |
| 8.1 | Embedded DSDT rebrand | `src/VBox/Devices/PC/vbox.dsl:28` | `DefinitionBlock ("DSDT.aml", "DSDT", 2, "VBOX  ", "VBOXBIOS", 2)` → `"ACRSYS","ACRPRDCT"` |
| 8.2 | Battery `_BIF` debrand | `vbox.dsl:1491-1495` (`PBIF`), `:1505-1529` (`_BIF`) | `"VBOX","innotek"` → `"i2battery","INTEL"` |
| 8.3 | DSDT `\_PR.CPU0` | `vbox.dsl` (thêm mới) | `Processor (CPU0, 0, 0x410, 6)` |
| 8.4 | DSDT ThermalZone `CCD_` | `vbox.dsl` (thêm mới) | `_STR="CPU Thermal Zone"`, `_TMP=0x0C44` (3140 = 40.85 °C), `_CRT=0x0E92`, `_HOT=0x0E10`, `_PSV=0x0DC0`, `_STA=0x0F`, `_PSL -> \_PR.CPU0`, `_TC1=4`, `_TC2=3`, `_TSP=50`, `_TZP=0` |
| 8.5 | DSDT voltage device `\_SB.VLT0` | `vbox.dsl` (thêm mới) + `DevACPI.cpp` | `_HID="VDDCR"`, `_CID=PNP0C02`, `_UID=1`, `_STR="CPU Voltage Sensor"`, `_STA=0x0F`, I/O `0x4060..0x4067` |
| 8.5b | Host-side voltage handler | `DevACPI.cpp` (thêm mới) | **Stock chưa có** handler `0x4060`/`0x4064`. Map I/O hiện có: `DevACPI.cpp:96-261` (`PM_PORT_BASE 0x4000`, `BAT_INDEX 0x4040`, `SYSI_INDEX 0x4048`, `ACPI_RESET_BLK 0x4050`). Đăng ký: `:4847-4857` (pattern BAT/SYSI) |
| 8.5c | Behavior của voltage | `DevACPI.cpp` (thêm mới) | raw init = `1200`; timer cập nhật `(timer mod 701) + 800` → 800..1500; ~1 lần/giây |
| 8.6 | ACPI PM1 S2/S3 branch | `DevACPI.cpp` (edge delta) | Không phải cloak mặc định — **không ưu tiên** |

### 3.4 MPS / BIOS / VGA / UEFI

| § | Hook | File:line | Ghi chú |
|---|---|---|---|
| 9.1 | MPS rebrand | `src/VBox/Devices/PC/DevFwCommon.cpp:1128-1133` | `"VBOXCPU "` → `"INTELCPU"`, `"VirtualBox  "` → `"Intel       "` |
| 10.1 | PC BIOS AMI branding | `src/VBox/Devices/PC/BIOS/orgs.asm:86-87` (`BIOS_COPYRIGHT 'Oracle VirtualBox BIOS'`, `BIOS_BUILD_DATE '06/23/99'`); `BIOS/bios.c:74`; `BIOS/logo.c:477` | Target: `American Megatrends V3.10`, ROM tail `AMI BIOS` tại `0xFF00`, build date `23/08/22` tại `0xFFF5` |
| 10.2 | **Leak:** F12 boot menu | `BIOS/logo.c:477`; `BIOS/VBoxBiosAlternative8086.asm:1271`; `…386.asm:1537`; `…286.asm:1300` | `printf("\nVirtualBox temporary boot device selection\n\n…")` — residual fingerprint |
| 10.2b | Version banner trong ROM | `VBoxBiosAlternative8086.asm:1285`, `…386.asm:1568`, `…286.asm:1314` | `db 'VirtualBox 7.2.22', 000h` |
| 11.1 | VGA BIOS → NVIDIA VBE | `src/VBox/Devices/Graphics/BIOS/vbe.c:88-97`; `vgabios.c:99`, `:138` | `"VirtualBox VESA BIOS"` → `"NVIDIA VESA BIOS"`; `"VirtualBox VBE Display Adapter enabled"` → `"NVIDIA VBE Display Adapter enabled"`; `"Oracle VirtualBox VBE Adapter"` → `"NVIDIA Video Adapter"`. `VBOX_VENDOR`/`VBOX_PRODUCT` ở `Config.kmk:106-108` |
| 11.1b | VGA BIOS flattened | `Graphics/BIOS/VBoxVgaBiosAlternative{8086,386,286}.asm` | `8086.asm:9369, 9372, 9375, 8447`; `386.asm:8667, 8679`; `286.asm:9215, 9221, 9227, 8293` |
| 11.2 | **Leak:** raw VGA ROM build path | `Graphics/BIOS/VBoxVgaBiosAlternative*.asm` | `C:\Devel\Antidetect5\Personal\VirtualBox\...\VBoxVgaBios*.sym` — guest raw ROM scanner thấy được |
| 12.1 | `EfiGuardDxe` | `src/VBox/Devices/EFI/Firmware/` (module mới) | DXE driver patch bootmgfw/winload/ntoskrnl/CI.dll. **Không thuộc scope** — cần binary DXE mới, activation semantics chưa rõ |
| 12.4 | UEFI `FirmwareVendor=ASUS` | `src/VBox/Devices/EFI/Firmware/MdeModulePkg/MdeModulePkg.dec:1879-1881` (`PcdFirmwareVendor` = `L"EDK II"`) | Sink: `MdeModulePkg/Universal/BdsDxe/BdsEntry.c:710` → `gST->FirmwareVendor`; `OvmfPkg/SmbiosPlatformDxe/SmbiosPlatformDxe.c:146`. ⚠ Nên override trong `OvmfPkg/OvmfPkgX64.dsc` (pattern có sẵn: `OvmfPkg/Bhyve/BhyveX64.dsc:522` override `PcdFirmwareVendor` → `L"BHYVE"`) thay vì sửa `.dec` global |
| 12.5 | RamDisk SSDT creator debrand | `src/VBox/Devices/EFI/Firmware/OvmfPkg/RamDiskDxe/` | Stock `VBOX` / `170995` → fork `INTL` / `0x20200925` |
| 12.6 | Boot logo / BGRT image | `OvmfPkg/LogoDxe/` | BGRT **header** vẫn stock EDK2; chỉ image đổi |
| 12.2/12.3 | TcgMor / TdTcg2* removal | `OvmfPkg/` | Feature removal, không phải cloak. **Không thuộc scope** |

### 3.5 Device model

| § | Hook | File:line | Ghi trị đích |
|---|---|---|---|
| 13.1 | GPU `GpuModelId` full PCI tuple | `src/VBox/Devices/Graphics/DevVGA.cpp:6829-6843` | QWORD: VID<<48 \| DID<<32 \| SVID<<16 \| SID. Stock: `0x80ee`/`0xbeef` (2 nhánh), VMware `0x15AD` |
| 13.2 | VMSVGA `CMD_BUFFERS_2` suppression | `src/VBox/Devices/Graphics/DevVGA-SVGA.cpp:8074-8089` | Bỏ `SVGA_CAP_CMD_BUFFERS_2` (0x04000000) khỏi `*pu32DeviceCaps`. Const: `vmsvga_include/svga_reg.h:946` |
| 13.3/13.4 | `GpuFpSeed` / `GpuVendor` / `GpuModel` | — | **INERT** — không có consumer đã chứng minh. Không port |
| 14.1 | HDA codec + subsystem UUID-selected | `src/VBox/Devices/Audio/DevHdaCodec.cpp:801-804` (idVendor `0x8384` SigmaTel, idDevice `0x7680`); `src/VBox/Devices/Audio/DevHda.cpp:5138-5141` (subsystem = codec id) | Fork: `UUID` 2 hex cuối `& 0x1F` → bảng 32 entry VID:DID. Controller chính vẫn stock Intel `0x8086/0x2668` (`DevHda.cpp:4943-4946`) |
| 15.1 | PIIX3 ATA HDD model | `src/VBox/Devices/Storage/DevATA.cpp:8231-8232` | `VBOX HARDDISK` → `Samsung PRO 970` |
| 15.2 | PIIX3 optical model | `DevATA.cpp:8231-8232` | `VBOX CD-ROM` → `Samsung CD-ROM` |
| 15.3 | AHCI controller PCI identity | `src/VBox/Devices/Storage/DevAHCI.cpp:5769-5770` | `8086:2829` → `8086:8C82` + key override `VenDevId` |
| 15.4 | AHCI disk serial format | `DevAHCI.cpp` (serial generation) | `VB...` → `SD%xSSDE` / `SD%FSSDE%08x` |
| 15.5 | AHCI HDD / optical model | `DevAHCI.cpp:5414-5415` | `SanDisc Extreme Pro` / `Toshiba CD-ROM` |
| 15.6 | AHCI ATAPI INQUIRY | `DevAHCI.cpp:5436-5456` | vendor `SanDisk`, product `Extreme`, rev `1.0` |
| 15.7 | HostDVD inquiry fallback | `src/VBox/Devices/Storage/DrvHostDVD.cpp:366-368` | `VBOX/CD-ROM/1.0` → `Hitachi/CD-ROM/1.0` |
| 15.8 | VSCSI SBC/MMC vendor | `src/VBox/Devices/Storage/VSCSI/VSCSILunSbc.cpp:248-250`; `VSCSILunMmc.cpp:1146-1148`; `VSCSILunSsc.cpp:152-153` | **Fork giữ stock** `VBOX` — dùng làm Phase 6 coherence fix |
| 15.9 | VSCSI SBC MODE SENSE(6) | `VSCSILunSbc.cpp` | Stock `08 0A 04` → fork `08 12 04` |
| 16.1 | USB HID VID rebrand | `src/VBox/Devices/Input/UsbKbd.cpp:125-127`, `:326-329`, `:567-568`; `src/VBox/Devices/Input/UsbMouse.cpp:65-69`, `:351-355`, `:1194-1249` | `0x80EE` → `0x3938`, giữ PID `0010/0011/0020..0023` |
| 16.2 | USB HID descriptor override | `UsbKbd.cpp` / `UsbMouse.cpp` | Key mới `VenDevId` (VID<<16\|PID), `Manufacturer` (max 0x40), `Product` (max 0x40) |
| 16.3 | USB webcam Logitech C270 | `src/VBox/Devices/Video/UsbWebcamDesc.cpp:793-794`, `:925-927` | `80EE:0030 / VirtualBox / VirtualBox Webcam` → `046D:0825 / Logitech / HD Webcam C270`; serial giữ `00000011` |
| 16.4 | Webcam `StaticImagePath` | `UsbWebcamDesc.cpp` (thêm mới) | Nạp ảnh tĩnh, dùng kích thước trong webcam path |
| 16.5 | USB MSD rebrand | `src/VBox/Devices/Storage/UsbMsd.cpp:59-61`, `:282-284`, `:547-602` | VID `3938`, manufacturer `Seagate`, giữ PID `0030/0031`, product `USB Harddisk` / `USB CD-ROM` |
| 17.1 | OHCI `VenDevId` override | `src/VBox/Devices/USB/DevOHCI.cpp:6001-6005` | Stock `106B:003F` + key override |
| 17.2 | xHCI PantherPoint DID | `src/VBox/Devices/USB/DevXHCI.cpp:8052` | `8086:1E31` → `8086:8D31`. LynxPoint `:8050` (`0x8C31`) giữ stock, Renesas `:8041-8043` giữ stock |
| 17.3 | i440FX root bridge | `src/VBox/Devices/Bus/DevPCI.cpp:1353-1355` | `8086:1237` → `0400:1237` |
| 17.4 | PIIX3 ISA bridge | `DevPCI.cpp:1365-1366` | `8086:7000` → `8086:0484` |
| 17.5 | **VMMDev rebrand** | `src/VBox/Devices/VMMDev/VMMDev.cpp:4844-4847` | `80EE:CAFE` → `8086:1551`. High-signal: khớp GA driver rename |
| 17.6 | `PciDevId` | — | **INERT** — không port |
| 18.1 | VirtIO shared vendor rewrite | `src/VBox/Devices/VirtIO/VirtioCore.h:261` (`DEVICE_PCI_VENDOR_ID_VIRTIO 0x1AF4`); `VirtioCore.cpp:3073-3084` | `0x10EC` cho cả vendor **và** subsystem vendor |
| 18.2 | virtio-net Realtek DID selector | `src/VBox/Devices/Network/DevVirtioNet.cpp:3698-3705` | `u16_le(MAC[4], MAC[5]) % 11` → `8187, 8993, 7185, 7212, 5633, 7560, 7890, 6012, 6456, 7881, 5504` |
| 18.4 | VirtIO-SCSI leak | `VirtioCore.cpp:3073-3084` | Dùng chung core → `10EC:1048`. Sửa ở Phase 6 |
| 18.5 | E1000 index-0 subsystem spoof | `src/VBox/Devices/Network/DevE1000.cpp:267-281` (`g_aChips[]`) | 82540EM ss `8086:001E` → `85F0:1043` |
| 18.6 | E1000 EEPROM patch | `DevE1000.cpp:706-717` | `m_au16Data[0x0B]` (SID) / `[0x0C]` (SVID) → `1043` / `85F0`. ⚠ thứ tự field lệch với PCI config |
| 18.7 | E1000 82583V removal | `DevE1000.cpp:252-255`, `:280` | **Không port** (feature removal, tạo fingerprint riêng) |
| 19.2 | TPM2 manufacturer/vendor/firmware | `src/libs/libtpms-0.10.2/src/tpm2/VendorInfo.c:71-77` | `MANUFACTURER "IBM"`→`"INTC"`; `"SW  "/" TPM"`→`"CSME"/"PTT "`; `FIRMWARE_V1/V2` `0x20240125/0x00120000`→`0x01930001/0` |
| 19.3 | TPM failure-mode endian | `VendorInfo.c` + `PropertyCap.c:107-136` | `CTNI/EMSC/ TTP` — fork bug. **Cân nhắc sửa luôn** (coherence) |
| 19.4/19.5 | libtpms stale lineage + PCR properties | `src/libs/libtpms-0.10.2/src/tpm2/PCR.c:1205-1207`; `TpmTypes.h:650-669` | `TPM_PT_PCR_RESET_L3` bitmap `00 00 81` vs stock `00 00 F1`; `TPM_PT_PCR_POLICY`/`AUTH` `00 00 70` vs `00 00 00`. **Yêu cầu nâng libtpms** — scope lớn |

### 3.6 Guest Additions camouflage

| Fork name | VBox family | File cần sửa |
|---|---|---|
| `IntelFirmwareInterface.sys` | `VBoxGuest.sys` | `src/VBox/Additions/common/VBoxGuest/win/VBoxGuest.inf:63,69,85,100-103`; `VBoxGuestInst.cpp:61,88-89`; `include/VBox/VBoxGuest.h:104` (`VBOXGUEST_SERVICE_NAME`); `VBoxGuestEarlyNT.inf` |
| `NetMonitor.exe` | `VBoxService.exe` | `src/VBox/Additions/common/VBoxService/VBoxServiceInternal.h:189,193`; `src/VBox/Additions/win/Installer/VBoxAddInstallNt3x.cpp:90-91`; `src/VBox/Additions/win/Installer/Makefile.kmk:158` |
| `LANExp.sys` | `VBoxSF.sys` | `src/VBox/Additions/win/SharedFolders/driver/VBoxSF.inf:64,72` |
| `PCMonitor.exe` | `VBoxTray.exe` | `src/VBox/Additions/win/VBoxTray/VBoxTray.h:52`; `VBoxGuest.inf:70,93` |
| `SystemMonitor.exe` | `VBoxControl.exe` | `src/VBox/Additions/common/VBoxControl/VBoxControl.cpp`; installer |
| `BaseVideo.sys` / `GpuWddm.sys` | `VBoxVideo.sys` / `VBoxWddm.sys` | `src/VBox/Additions/win/Graphics/Video/mp/xpdm/VBoxVideo.inf:63,70`; `mp/wddm/VBoxWddm.inf:92,99` |
| `WhomNP.dll` | `VBoxMRXNP.dll` | `src/VBox/Additions/win/VBoxCredProv/` |
| — | `VBoxMouse.sys` | `src/VBox/Additions/win/Mouse/NT5/VBoxMouse.inf:55,76` (fork không đổi) |

**Cảnh báo tương thích:** đổi tên GA là **breaking change** cho:
- `VBoxGuest.inf` `PCI\VEN_80ee&DEV_cafe` — phải đổi theo VMMDev `8086:1551`
- Host `VBoxGuestPropSvc` / `VBoxGuestControlSvc` / `VBoxSharedFolders` / `VBoxSharedClipboard` / `VBoxDragAndDropSvc` / `VBoxHostChannel` — 6 service DLL, tên file giữ nguyên trong fork (xem §59.1 coverage matrix)
- `VBoxCertUtil` + certificate bundle

### 3.7 Control plane / provisioning

| § | Hạng mục | File:line | Ghi chú |
|---|---|---|---|
| 26 | `SetCustomData` / CFGM overlay | `src/VBox/Main/src-client/ConsoleImplConfigCommon.cpp:670-851` | **Đã có sẵn trong stock.** Không cần sửa cho phần lớn hạng mục |
| 26.1 | Active families | — | `DmiCPU→GuestCpuName`, `DmiPortConnectors`, `GpuModelId`, HID `VenDevId/Manufacturer/Product`, OHCI `VenDevId`, `TM/TSCMode`, `DmiMemDev` |
| 26.2 | Không có sink | — | `GpuVendor`, `GpuModel`, `GpuFpSeed`, `SlirpMac`, `DNSSuffix`, `DNSServer` — **không port** |
| 26.3 | Bị lọc trước CFGM | — | `DmiCPUVendor`, `DmiSocket`, `CustomValGpuCtMode`, `CustomValEthVen`, `CustomValNatVen` — **không port** |
| 22/23 | 20 slot `sltAntiOS*` | `src/VBox/Frontends/VirtualBox/src/runtime/UIMachineLogic.h` (slot mẫu: `sltTakeSnapshot:237`, `sltShowInformationDialog:238`) + `UIMachineLogic.cpp`; action pool: `src/VBox/Frontends/VirtualBox/src/globals/UIActionPoolRuntime.cpp` | Thực thi qua Guest Control stock: `CGuest::CreateSession` → `CGuestSession::ProcessCreate` → VMMDev/HGCM → `VBoxService` |
| — | 20 action ID | `UIActionPoolRuntime.cpp` | `AntiOSVPNHopTunerMinus1..Minus10` + `MinusD` (reset 128), `AntiOSIPv6Allow/Block`, `AntiOSStrictFirewallOn/Off`, `AntiOSTCPFingerprint1/2`, `AntiOSBrowserHardened`, `AntiOSActivateWindows`, `AntiOSAkamaiPumper` |

### 3.8 Feature removal — KHÔNG port

`NVMe` (backend đã bị gỡ), `UsbNet`, `82583V`, `ARMv8`, `TcgMor`, `TdTcg2Pei/Dxe`, `EfiGuardDxe`, `TPM 82583V`, `VMXNET3` (historical only).

Lý do (tài liệu §48.5): *feature removal tạo fingerprint thay vì che fingerprint* — thiếu capability tạo ra profile sản phẩm riêng, dễ bị detector nhận diện qua combination bất thường.

### 3.9 Behavioral regression — KHÔNG port

`VSCSI transfer-accounting regression` (§28), `TPM CRB normalization` (§29), `ACPI raw PM1 S2/S3` (§30). Đây là **bug** của fork, không phải cloak.

---

## 4. Nguyên tắc thiết kế: chọn cơ chế điều khiển

### 4.1 Quyết định

Dùng **ExtraData + CFGM overlay** (kiểu Antidetect5). Không thêm COM property.

### 4.2 Vì sao khả thi

`Console::i_configCfgmOverlay()` (`ConsoleImplConfigCommon.cpp:680-851`) đã map:

```
ExtraData key  "VBoxInternal/<node path>/<value name>"
        ↓
CFGM node      <node path>   value <value name>
```

Luồng đầy đủ:

| Bước | Vị trí |
|---|---|
| 1. Đọc ExtraData global + machine | `ConsoleImplConfigCommon.cpp:703-722` |
| 2. Lọc prefix `VBoxInternal/` | `:733-734` |
| 3. Tách node/value bằng `strrchr('/')` | `:761-767` |
| 4. Xoá value cũ, tạo node nếu chưa có | `:769-792` |
| 5. Chèn value (type prefix `string:` / `integer:` / `bytes:`, hoặc auto-detect) | `:799-842` |
| 6. Device đọc value qua `pfnCFGMQueryStringDef(pCfg, "<key>", …)` | mỗi device |

Gọi tại `ConsoleImplConfigX86.cpp:2055` — **trước** khi device được construct.

Quy ước path đã xác nhận (từ chính tài liệu fork):

```
VBoxInternal/Devices/pcbios/0/Config/DmiBIOSVendor
VBoxInternal/Devices/efi/0/Config/DmiBIOSVendor
VBoxInternal/Devices/vga/0/Config/GpuModelId
VBoxInternal/Devices/e1000/0/Config/VenDevId
VBoxInternal/USB/HidKeyboard/0/Config/VenDevId
VBoxInternal/USB/HidMouse/0/Config/Manufacturer
```

### 4.3 Ba hạng mục phải làm thêm so với fork

**(a) Whitelist CFGM.** Mỗi device có `PDMDEV_VALIDATE_CONFIG_RETURN` — key không có trong whitelist sẽ bị reject (device fail to construct).

| File | Dòng whitelist | Cần thêm |
|---|---|---|
| `src/VBox/Devices/PC/DevPcBios.cpp` | `1404-1468` | `DmiMemDev`, `DmiPortConnectors`, `Flags`, `VenDevId` |
| `src/VBox/Devices/EFI/DevEFI.cpp` | `1523-1574` | (mirror pcbios) |
| `src/VBox/Devices/PC/DevACPI.cpp` | `4360-4389` | `VenDevId` |
| `src/VBox/Devices/Graphics/DevVGA.cpp` | `s_szMscWorkaround[]` (`:6646-6693`) | `GpuModelId` |
| `src/VBox/Devices/Input/UsbKbd.cpp`, `UsbMouse.cpp` | (tương ứng) | `VenDevId`, `Manufacturer`, `Product` |
| `src/VBox/Devices/USB/DevOHCI.cpp` | | `VenDevId` |
| `src/VBox/Devices/Storage/DevAHCI.cpp` | | `VenDevId` |

**(b) Rewrite path pcbios ↔ efi.** `i_configCfgmOverlay` không biết VM dùng BIOS hay EFI. Fork có "firmware path map" (`/pcbios/` ↔ `/efi/`). Cần 1 bước trong `ConsoleImplConfigCommon.cpp:724-843`:

- nếu VM dùng EFI → `Devices/pcbios/0/Config/*` chuyển thành `Devices/efi/0/Config/*`
- nếu VM dùng BIOS → ngược lại

→ 1 profile DMI áp dụng cho cả 2 firmware mode.

**(c) Cổng `Flags` chống lạm dụng.** Fork dùng `Flags & 0x1337` như license gate. Nếu port nguyên xi thì bất kỳ ai cũng set được. Đề xuất: dùng một cờ riêng (ví dụ `CloakEnabled`) và **không** bật mặc định — để người dùng chủ động bật.

### 4.4 Những gì **không** đụng tới

| Không đụng | Lý do |
|---|---|
| `include/VBox/VBoxGuest.h` COM interface (trừ hằng tên service) | Giữ ABI |
| `src/VBox/Main/idl/*.idl` | Giữ TypeLib hash → SDK cũ vẫn chạy |
| `src/VBox/Main/src-client/ConsoleImplConfigX86.cpp` (trừ overlay rewrite) | Không cần `InsertConfigString` mới |
| `Config.kmk` `VBOX_VENDOR` / `VBOX_PRODUCT` | Đổi sẽ ảnh hưởng toàn bộ string sản phẩm + licensing. Sửa cục bộ trong `vbe.c` / `vgabios.c` |
| `VBoxC` HGCM service names | 6 service DLL giữ nguyên; đổi sẽ phá tương thích guest |

---

### 4.5 Kiến trúc MPE — Machine Profile Engine (quyết định #2: "thông tin phải đồng bộ")

#### 4.5.1 Vấn đề cần giải

Yêu cầu: **mọi thông tin identity phải đồng bộ với nhau**. Ví dụ một máy phải là "máy Intel đời 8xx, chipset Intel, firmware AMI, GPU NVIDIA, NIC Intel, storage Samsung" — không được trộn `0400:1237` (AMD) với xHCI Intel đời 9xx, không được có BIOS AMI nhưng ACPI OEM ID `ASUS`.

Cách fork làm: **vá từng literal riêng lẻ** → tạo ra chính những mâu thuẫn mà tài liệu §48.1 liệt kê.

Cách ta làm: **một nguồn sự thật duy nhất** — `MachineProfile`. Mọi giá trị đều do profile sinh ra, không có giá trị nào hard-code rời rạc.

#### 4.5.2 Vị trí đặt MPE

| Thành phần | Vị trí đề xuất | Lý do |
|---|---|---|
| Engine + profile registry | `src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp` / `.h` (file mới) | Chạy 1 lần, 1 nơi, trước khi device construct |
| Điểm gọi | `Console::i_configConstructorX86()` (`ConsoleImplConfigX86.cpp:383`), ngay **trước** `i_configCfgmOverlay()` (đang gọi ở `:2055`) | Overlay ghi đè giá trị sau → engine phải chạy trước, hoặc engine ghi sau overlay (xem 4.5.5) |
| Ghi kết quả | CFGM node, qua `InsertConfigString/Integer` vào node `Devices/<dev>/0/Config` | Device chỉ cần đọc key → không cần sửa logic device nhiều |
| Device | Đọc CFGM key như hiện tại | Tái dùng cơ chế stock, không thêm code path mới |

**Quyết định quan trọng:** MPE **không** sống trong VBoxDD. Nếu đặt ở VBoxDD thì mỗi device tự sinh giá trị → mất tính đồng bộ và mất tính ổn định (xem 4.6).

#### 4.5.3 Cấu trúc `MachineProfile`

```c
typedef struct MACHINEPROFILE
{
    /* --- Identity nhà sản xuất / hệ điều hành --- */
    const char *pszSystemVendor;      /* "LENOVO"                    */
    const char *pszSystemProduct;     /* "ThinkPad T14 Gen 2"       */
    const char *pszSystemVersion;     /* "1.0"                       */
    const char *pszSystemFamily;      /* "ThinkPad T14 Gen 2"       */
    const char *pszSystemSKU;
    const char *pszBiosVendor;        /* "LENOVO"                    */
    const char *pszBiosVersion;       /* "N2HET52W (1.50)"          */
    const char *pzszBiosReleaseDate;  /* "20230201"                 */
    const char *pszBoardVendor;       /* "LENOVO"                    */
    const char *pszBoardProduct;      /* "20XW004VGE"                */
    const char *pszChassisVendor;     /* "LENOVO"                    */
    const char *pszChassisType;       /* "Notebook"                 */
    const char *pszProcManufacturer;  /* "GenuineIntel"             */

    /* --- Firmware / ACPI --- */
    const char *pszAcpiOemId;         /* "LENOVO"                   */
    const char *pszAcpiCreatorId;     /* "AMI "                     */
    const char *pszAcpiOemTabId;      /* "A M I "                   */
    const char *pszMpsOemId;          /* "INTELCPU"                 */
    const char *pszMpsProductId;      /* "Intel       "             */
    const char *pszAcpiDmiOemId;      /* OEM ID của DSDT: "ACRSYS"   */
    const char *pszAcpiDmiOemTabId;   /* "ACRPRDCT"                 */
    const char *pszBiosRomVendor;     /* "American Megatrends..."   */

    /* --- CPU --- */
    const char *pszGuestCpuName;      /* "i7-9750H"                 */
    const char *pszCpuBrandString;    /* "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz" */

    /* --- Chipset (phải cùng đời với CPU) --- */
    uint16_t    uI440FxVendorId;      /* 0x8086                     */
    uint16_t    uI440FxDeviceId;      /* 0x1237                     */
    uint16_t    uPiix3IsaDeviceId;    /* 0x7000 → 0x0484            */
    uint16_t    uXhciDeviceId;        /* 0x8D31                     */
    uint16_t    uAhciDeviceId;        /* 0x8C82                     */
    uint16_t    uAcpiPmDeviceId;      /* 0x7113                     */
    uint16_t    uHdaDeviceId;         /* 0x2668                     */
    uint16_t    uOhciDeviceId;        /* 0x003F                     */

    /* --- GPU --- */
    uint64_t    uGpuModelId;          /* VID<<48|DID<<32|SVID<<16|SID */
    const char *pszVbeVendor;         /* "NVIDIA Corporation"       */
    const char *pszVbeProduct;        /* "NVIDIA Video Adapter"     */
    const char *pszEdidManufacturer;  /* "DEL" / "SAM" / "BNQ"      */
    const char *pszEdidModel;

    /* --- Storage --- */
    const char *pszAtaModel;          /* "Samsung PRO 970"          */
    const char *pszAtapiVendor;       /* "Samsung"                  */
    const char *pszAtapiProduct;      /* "CD-ROM"                   */
    const char *pszInquiryVendor;     /* "Samsung"                  */
    const char *pszInquiryProduct;    /* "Extreme"                  */
    uint8_t     uNonRotational;       /* 1 nếu SSD                  */
    uint8_t     fTrimSupported;       /* 1 nếu discard              */
    uint8_t     fSmartSupported;      /* 1 nếu SMART                */

    /* --- Network --- */
    uint16_t    uNicVendorId;         /* 0x8086                     */
    uint16_t    uNicDeviceId;         /* 0x100E                     */
    uint16_t    uNicSubVendorId;      /* 0x8086                     */
    uint16_t    uNicSubDeviceId;      /* 0x001E                     */
    const char *pszEepromSubVendor;   /* "8086" hex                 */
    const char *pszEepromSubDevice;

    /* --- TPM --- */
    const char *pszTpmManufacturer;   /* "INTC"                     */
    const char *pszTpmVendor1;        /* "CSME"                     */
    const char *pszTpmVendor2;        /* "PTT "                     */
    uint32_t    uTpmFirmwareV1;
    uint32_t    uTpmFirmwareV2;

    /* --- Battery (ACPI _BIF) --- */
    const char *pszBatteryType;       /* "i2battery"                */
    const char *pszBatteryOem;        /* "INTEL"                    */
} MACHINEPROFILE;
```

#### 4.5.4 Profile registry

Bắt đầu với **3 profile đầy đủ** (đủ để test cả 3 nhánh CPU Intel / CPU AMD / GPU NVIDIA):

| Profile | CPU | Chipset | Firmware | GPU | NIC | Storage | TPM |
|---|---|---|---|---|---|---|---|
| `profile-lenovo-t14` | i7-9750H (Cascade Lake) | Intel 8xx/Cannon Lake | AMI + ACPI `LENOVO` | NVIDIA GV100 | Intel I219-V | Samsung PM981 | Intel PTT |
| `profile-dell-latitude` | i5-10400 (Comet Lake) | Intel 4xx/Comet Lake | Phoenix | Intel UHD 630 | Intel I219-LM | SK Hynix PC801 | Intel PTT |
| `profile-amd-ryzen-t14` | Ryzen 7 PRO 6850U | AMD Zen 3 | Phoenix | AMD Raphael | Realtek RTL8168 | Micron 2450 | MSFT |

Mỗi profile là **một hàng dữ liệu literal** trong `ConsoleImplConfigCloak.cpp`. Thêm profile mới = thêm 1 hàng.

**Quy tắc bắt buộc khi thêm profile:** không được tự ý ghép giá trị. Mỗi profile phải là một cấu hình máy thật (hoặc mô phỏng sát 1 máy thật).

#### 4.5.5 Thứ tự materialize

```
i_configConstructorX86()
  │
  ├─ [A] i_configCfgmOverlay()            ← ExtraData của user ghi đè
  │      (ConsoleImplConfigCommon.cpp:680)
  │
  ├─ [B] MPE: đọc ExtraData "CloakProfile" / "CloakEnabled"
  │      ├─ nếu tắt → return (không đổi gì)
  │      ├─ seed = f(VM UUID)  (xem 4.6)
  │      ├─ profile = registry[ prng.pickProfile() ]
  │      └─ materialize từng field
  │
  └─ [C] MPE ghi đè CFGM: InsertConfigString/Integer vào node lưu trữ
         (CHỈ ghi đè field mà user KHÔNG chỉ định trong ExtraData)
```

**Thứ tự A → B → C** (không phải B → A): nếu MPE ghi trước overlay thì ExtraData của user bị MPE đè mất. Với thứ tự A → B → C, MPE phải **kiểm tra** xem user đã set key đó chưa, và nếu có thì **không** ghi đè → user vẫn override được.

Cơ chế: MPE đọc lại ExtraData (như `i_configCfgmOverlay` đang làm ở `:703-722`) và so sánh; hoặc đơn giản hơn — MPE ghi vào node riêng `Devices/cloak/0/Config/*`, còn device đọc `Devices/cloak/0/Config/X` trước, fallback sang `Devices/<dev>/0/Config/X`. Cách này **không cần** thứ tự A/B/C cụ thể, và sạch hơn.

→ **Khuyến nghị: node riêng `Devices/cloak/0/Config/*`**, device đọc theo thứ tự ưu tiên. Chi tiết ở Phase 1.0.

#### 4.5.6 Bộ luật coherence (validate lúc build-time hoặc run-time)

| # | Luật | Ví dụ vi phạm |
|---|---|---|
| C1 | CPU đời ↔ chipset đời | CPU Core2 (model 15) + chipset 8xx |
| C2 | chipset vendor ↔ i440FX vendor | `0400:1237` (AMD) + xHCI `8086:8D31` (Intel) |
| C3 | ACPI OEM ID ↔ SMBIOS vendor ↔ firmware vendor | ACPI `ASUS` + SMBIOS `LENOVO` |
| C4 | GPU vendor ↔ VBE vendor ↔ EDID manufacturer | PCI `10DE` + VBE `NVIDIA` + EDID `DEL` |
| C5 | Storage model family ↔ INQUIRY vendor ↔ nonrotational/TRIM/SMART | Model `Samsung PRO 970` + INQUIRY `VBOX` |
| C6 | NIC PCI subsystem ↔ EEPROM ↔ INF | PCI `85F0:1043` ↔ EEPROM `1043`/`85F0` |
| C7 | TPM manufacturer ↔ CPU vendor | TPM `INTC` + CPU AMD |
| C8 | HDA codec ↔ chipset đời | Codec 2003-era + chipset 8xx |
| C9 | Storage controller ↔ chipset | AHCI `8086:8C82` (8xx) nhưng CPU Haswell (6xx) |
| C10 | Monitor/EDID ↔ GPU | EDID panel manufacturer không khớp GPU |

Luật C1–C10 được implement dưới dạng **assertion trong MPE lúc khởi tạo** (fail sớm, log rõ profile nào vi phạm) + một **bộ test offline** để lint toàn bộ profile registry.

#### 4.5.7 Phạm vi của MPE so với plan ban đầu

MPE **thay thế** phần lớn giá trị đích cứng trong Phase 1-2. Cụ thể:

| Task cũ | Task mới |
|---|---|
| 1.7 đổi default DMI vendor/product | MPE `pszSystemVendor` / `pszBiosVendor` / … |
| 1.8 ACPI OEM/Creator theo UUID | MPE `pszAcpiOemId` / `pszAcpiCreatorId` |
| 1.9 ACPI OEM Table ID | MPE `pszAcpiOemTabId` |
| 1.13 MPS rebrand | MPE `pszMpsOemId` / `pszMpsProductId` |
| 2.4-2.6 storage model | MPE `pszAtaModel` / `pszInquiryVendor` / … |
| 2.13 i440FX + PIIX3 | MPE `uI440FxVendorId` / `uPiix3IsaDeviceId` |
| 2.14 VMMDev | MPE `uVmmDevVendorId/DeviceId` (thêm field) |
| 2.18 E1000 | MPE `uNicVendorId` / `uEepromSubVendor` / … |
| 2.19 TPM | MPE `pszTpmManufacturer` / `uTpmFirmwareV1` |

Các task **không** nằm trong MPE (vì phụ thuộc runtime device, không phải profile tĩnh): 2.1 (GPU `GpuModelId` — có thể đưa vào MPE), 2.2 (VMSVGA caps), 2.8-2.10 (USB), 2.17 (virtio-net DID — phụ thuộc MAC).

---

### 4.6 Selector ổn định (quyết định #3: random nhưng không đổi khi mở lại VM)

#### 4.6.1 Yêu cầu

- Mỗi VM có **bộ identity riêng**, trông ngẫu nhiên → không bị detector đoán theo profile cố định.
- **Mở lại VM → giá trị y hệt** → không "nhảy" giá trị mỗi lần boot.
- VM khác → bộ giá trị khác.

#### 4.6.2 Nguồn seed

| Ứng viên | Ổn định? | Nhận xét |
|---|---|---|
| **VM UUID** (`pMachine->getId()` / config `UUID`) | ✅ | Lưu trong `.vbox`, không đổi trừ khi user đổi. **Chọn làm seed gốc** |
| MAC address adapter | ✅ | Ổn định nếu user không đổi; nhưng user hay đổi → dùng làm *stream* phụ |
| Đường dẫn file `.vbox` | ❌ | Đổi khi move VM |
| Timestamp | ❌ | Đổi mỗi lần |
| `RTRandCreateSystem()` | ❌ | Không seedable → không tái lập được |

→ **Seed gốc = VM UUID.**

#### 4.6.3 Thuật toán

```
seed64 = FNV1a64( "VBoxCloakProfile" || VM_UUID_16_bytes )

// tách thành nhiều stream độc lập, mỗi stream 1 mục đích
stream_profile = splitmix64(seed64 + 0x01)
stream_serial  = splitmix64(seed64 + 0x02)
stream_macdid  = splitmix64(seed64 + 0x03)
stream_jitter  = splitmix64(seed64 + 0x04)
```

`splitmix64` là PRNG 64-bit tốt, tự implement được (~10 dòng), không cần thêm thư viện.

**Quy tắc bắt buộc:** chỉ materialize **một lần** trong MPE, rồi ghi kết quả vào CFGM. **Không** tính lại ở nhiều nơi — nếu device nào đó tự gọi PRNG với cùng seed thì vẫn ra cùng giá trị, nhưng nếu thứ tự gọi khác nhau (ví dụ thêm/bớt 1 lần gọi) thì các giá trị phía sau **đổi hết** → mất tính ổn định. Vì vậy:
- PRNG **chỉ** nằm trong MPE (VBoxC).
- Device chỉ đọc giá trị đã materialize từ CFGM.
- Ngoại lệ duy nhất: virtio-net DID — phụ thuộc MAC mà MAC chỉ biết ở device. → Dùng `stream_macdid` với seed = `FNV1a64(seed64 || MAC)`, vẫn deterministic vì MAC ổn định.

#### 4.6.4 Xác minh tính ổn định

Test bắt buộc:

| Test | Cách |
|---|---|
| Cùng VM, mở lại 3 lần | Giá trị identity giống hệt nhau (so `debugvm info pci verbose` + DMI dump) |
| Clone VM (copy `.vbox` + disk) | **Có thể khác** — vì UUID khác. Đây là hành vi mong muốn (mỗi "máy" là 1 máy khác) |
| 2 VM trong 1 lần build | Bộ giá trị khác nhau, không trùng lặp |
| Re-seed bằng UUID mới | Đổi toàn bộ bộ giá trị |

#### 4.6.5 Cách ép 1 profile cụ thể (cho test)

Cần cơ chế override, nếu không sẽ không test được từng profile:

```
ExtraData: VBoxInternal/cloak/0/Config/Profile = profile-lenovo-t14
```

Khi key này có mặt → MPE **bỏ qua** PRNG, dùng profile cố định. Giá trị random (serial, jitter) vẫn lấy từ PRNG → vẫn ổn định.

---

### 4.7 CI bằng GitHub Actions (quyết định #4)

> **Phát hiện quan trọng:** repo **đã có sẵn** một workflow build hoạt động:
> `.github/workflows/build.yml` (310 dòng, hiện **chưa commit** — `git status` → `?? .github/workflows/`).
> Bước 4.7.1-4.7.3 mô tả chính workflow đó; 4.7.4-4.7.6 nêu các **fix cần làm** trước khi dùng được.

#### 4.7.1 Workflow hiện có — `.github/workflows/build.yml`

| Thuộc tính | Giá trị |
|---|---|
| Tên | `Build VirtualBox 7.2 (Windows x64)` |
| Trigger | `workflow_dispatch`, `push` → `main`, `VBox-7.2` |
| Runner | `windows-2022`, timeout 360 phút |
| Quyền | `contents: read` |
| Env | `VBOX_WITHOUT_ADDITIONS=1`, `VBOX_WITH_ADDITIONS_PACKING=""` |
| Output | `out\win.amd64\release\bin` |
| Artifact | `virtualbox-7.2-windows-amd64-binaries` + `virtualbox-windows-build-diagnostics` |

Các bước (theo thứ tự trong file):

| # | Step | Nội dung |
|---|---|---|
| 1 | Checkout | `repository: VirtualBox/virtualbox`, `ref: VBox-7.2`, `submodules: recursive` |
| 2 | MSVC | `ilammy/msvc-dev-cmd@v1`, `arch: amd64` |
| 3 | Verify | Kiểm tra `kBuild\kBuild\bin\win.amd64\kmk.exe` (+ `kmk_ash.exe`, `win.x86\kmk.exe`) và `Windows Kits\10\Include` → **kBuild đã có sẵn binary trong repo, không cần build** |
| 4 | Patch DDK | Sửa `configure.vbs` để bỏ lệnh gọi `CheckForWinDDK` |
| 5 | Yasm | `choco install vcredist2010` + tải `yasm-1.3.0-win64.exe` → `GITHUB_PATH` |
| 6 | Qt | `jurplel/install-qt-action@v4`, Qt **6.8.0** `win64_msvc2022_64`, modules `qt5compat qtscxml`, cache |
| 7 | SDL | tải `SDL-devel-1.2.15-VC.zip` → `VBOX_SDL_PATH` (copy `lib\x64\*` lên `lib\`) |
| 8 | Configure | copy `Windows Kits\10\bin\<ver>\x64` → `bin\x64` (và x86), rồi `cscript configure.vbs --with-SDK10 --with-libSDL --with-Qt`; ghi `LocalConfig.kmk` |
| 9 | Build | `kmk.exe -j$([Environment]::ProcessorCount)` |
| 10 | Bundle | copy `SDL.dll`, chạy `windeployqt --release --no-translations --no-compiler-runtime` |
| 11 | Upload | diagnostics (`configure.log`, `AutoConfig.kmk`, `LocalConfig.kmk`, `env.bat`, `*.log`) + binaries |

`LocalConfig.kmk` do workflow ghi (dòng 216-230):

```
VBOX_WITH_QTGUI = 1
VBOX_GUI_USE_QGL = 1
PATH_SDK_QT6 = <qt>
PATH_TOOL_QT6 = <qt>
PATH_TOOL_QT6_BIN = <qt>/bin
VBOX_PATH_QT = <qt>
VBOX_WITH_HARDENING =
VBOX_WITHOUT_ADDITIONS = 1
VBOX_WITH_ADDITIONS_PACKING =
VBOX_WITH_WARNINGS_AS_ERRORS =
VBOX_WITH_TESTCASES =
VBOX_WITH_VALIDATIONKIT =
```

#### 4.7.2 Yêu cầu build — đánh giá lại theo workflow thực tế

`configure.vbs` chạy các check sau (`configure.vbs:2375-2404`):

| Check | Bắt buộc? | Workflow đã xử lý? |
|---|---|---|
| `CheckSourcePath` | ✅ | ✅ path runner `D:\a\virtualbox\virtualbox` — ASCII, không space |
| `CheckForkBuild` | ✅ | ✅ kBuild prebuilt trong repo (`kBuild/kBuild/bin/win.amd64/kmk.exe`) |
| `CheckForWinDDK` | ⚠ | ✅ **bỏ qua** bằng patch `configure.vbs` (step 4) |
| `CheckForVisualCPP` | ✅ | ✅ `msvc-dev-cmd` |
| `CheckForSDK10` | ✅ | ✅ có sẵn; workflow copy `bin\<ver>` → `bin\x64`/`bin\x86` |
| `CheckForMidl` | ✅ | ✅ theo SDK |
| `CheckForYasm` | ⚠ | ✅ step 5 (yasm 1.3.0) |
| `CheckForNasm` | ⚠ | ⚠ **chưa cài** — chưa rõ có cần; nếu build fail thì thêm `choco install nasm` |
| `CheckForOpenWatcom` | ❌ optional | ✅ **cố ý bỏ qua** — giữ `.asm` BIOS checked-in (xem §7.3) |
| `CheckForlibSDL` | ⚠ | ✅ step 7 (SDL **1.2.15**, không phải SDL2) |
| `CheckForXml2` | ✅ | ✅ `src/libs/libxml2-2.15.4` |
| `CheckForSsl` (64+32) | ✅ | ✅ `src/libs/openssl-3.5.8` — build cross 32-bit đã chạy được |
| `CheckForCurl` (64+32) | ✅ | ✅ `src/libs/curl-8.18.0` |
| `CheckForQt` | ⚠ | ✅ step 6 (Qt 6.8.0) |
| `CheckForPython` | ✅ | ⚠ **chưa cài** — hiện workflow chưa có `setup-python`; có thể runner đã có sẵn Python |
| `CheckForLibVpx/Ogg/Vorbis` | ✅ | ✅ `src/libs/` |

> `MsgFatal` chỉ dùng cho kBuild / VC version / shell sanity → thiếu tool chỉ ra warning ở `configure.vbs`, không chặn.

**Kết luận:** workflow hiện tại **đã build được VirtualBox đầy đủ (trừ Guest Additions)**. Việc cần làm không phải "dựng CI từ đầu" mà là **vá nó cho đúng mục đích cloak**.

#### 4.7.3 Lỗi nghiêm trọng cần sửa trước tiên

```yaml
- name: Checkout VirtualBox
  uses: actions/checkout@v4
  with:
    repository: VirtualBox/virtualbox     # ← ĐANG BUILD UPSTREAM, KHÔNG PHẢI REPO CỦA BẠN
    ref: VBox-7.2
    fetch-depth: 1
    submodules: recursive
```

→ Workflow hiện tại **build `VirtualBox/virtualbox`**, không build code của `vuong4-design/virtualbox`.
Mọi thay đổi cloak sẽ **không được compile** cho tới khi sửa.

**Fix:**

```yaml
      - name: Checkout VirtualBox
        uses: actions/checkout@v4
        with:
          repository: ${{ github.repository }}   # repo của bạn
          ref: ${{ github.ref_name }}             # branch đang push
          fetch-depth: 1
          submodules: recursive
```

Hoặc bỏ hẳn khối `with:` (checkout mặc định đã đúng repo/branch của event).

**Cũng cần sửa trigger** — hiện chỉ chạy cho `main` và `VBox-7.2`:

```yaml
on:
  workflow_dispatch:
  push:
    branches:
      - main
      - VBox-7.2
      - 'feature/cloak-*'
  pull_request:
    branches:
      - VBox-7.2
      - 'feature/cloak-*'
```

#### 4.7.4 Bổ sung: job `smoke` (kiểm chứng identity)

Cần một bước/job chạy sau build để **tự động** xác nhận cloak có hoạt động:

```yaml
  smoke:
    needs: build
    runs-on: windows-2022
    timeout-minutes: 30
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: virtualbox-7.2-windows-amd64-binaries
          path: vbox
      - name: Register COM server
        shell: cmd
        run: vbox\VBoxSVC.exe /RegServer
      - name: Collect identity
        shell: pwsh
        run: |
          $ErrorActionPreference = "Stop"
          & .\vbox\VBoxManage.exe list vms | Tee-Object vms.txt
          & .\vbox\VBoxManage.exe showvminfo "<vm>" --machinereadable | Out-File vminfo.txt
          & .\vbox\VBoxManage.exe debugvm "<vm>" info pci verbose | Out-File pci.txt
          # so sánh với artifact của run trước (baseline)
      - uses: actions/upload-artifact@v4
        with:
          name: cloak-identity-report
          path: |
            vms.txt
            vminfo.txt
            pci.txt
```

Yêu cầu: cần **một VM đã định nghĩa** trong CI. Có 2 lựa chọn:

| Lựa chọn | Cách | Đánh giá |
|---|---|---|
| A. VM do CI tạo | `VBoxManage createvm` + `VBoxManage storagectl` (disk rỗng) | Nhanh, không cần image. **Chỉ đọc được identity host-side** (`showvminfo`, `debugvm info pci` chạy được khi VM tắt) — đủ để verify phần lớn |
| B. VM có sẵn từ artifact | Upload `.vbox` + disk tối thiểu vào artifact, tải xuống ở job smoke | Chạy được guest thật → verify được cả ACPI/DMI trong guest. Cần disk image nhỏ (Linux live ~50 MB) |

→ **Khuyến nghị:** dùng **A** cho PR gating (nhanh, không cần image), **B** cho release/manual verification.

#### 4.7.5 Bổ sung: job `full-additions` (Guest Additions + WDK)

> **ĐÃ TRIỂN KHAI** — `.github/workflows/build.yml` (job `full-additions`) + `.github/scripts/install-wdk.ps1`

Job `build` đặt `VBOX_WITHOUT_ADDITIONS=1` → **không** build driver GA → PR-2 (đổi tên GA) không verify được. Job mới build lại toàn bộ với GA bật.

#### 4.7.5.1 Phát hiện quan trọng: DDK 7.1 vs WDK 10

`Config.kmk:2157-2199` quyết định bộ SDK cho driver GA:

| Biến | Giá trị mặc định (x86/amd64) | Cần gì |
|---|---|---|
| `VBOX_WINDDK_GST` | `WINSDK10-KM` | `Lib\<ver>\km\{x64,x86}` |
| `VBOX_WINDDK_GST_W7` | `WINSDK10-KM-W7` | `Lib\win7\km\{x64,x86}` |
| `VBOX_WINDDK_GST_W8` | `WINSDK10-KM-W8` | `Lib\win8\km\{x64,arm32}` |
| `VBOX_WINDDK_GST_WLH` | **`WINDDK71WLH`** | ❌ **DDK 7.1** (Vista) — dùng cho `VBoxSF.sys`, `VBoxDisp*` |
| `VBOX_WINDDK_GST_W2K3` | **`WINDDK71WNET`** | ❌ **DDK 7.1** — `VBoxSFW2K.sys` |
| `VBOX_WINDDK_GST_WXP` | **`WINDDK71WXP`** | ❌ **DDK 7.1** — `VBoxMRXNP.dll` |
| `VBOX_WINDDK_GST_NT4` | → `WXP` | ❌ **DDK 7.1** — `VBoxGuest.sys` (x86), `VBoxMouseNT.sys`, `VBoxVideo.sys` (xpdm) |

**DDK 7.1 (`7600.16385.1`) KHÔNG có trong git mirror** — nó chỉ nằm trong bản source drop chính thức của Oracle (`tools/win.x86/ddk/7600.16385.1`, xem `configure.vbs:1125`). Đây là lý do workflow gốc phải patch bỏ check `CheckForWinDDK` (`configure.vbs:1169-1172` → `MsgError` → configure trả exit code khác 0).

**Giải pháp:** thay bộ DDK 7.1 bằng bộ lib của WDK 10 qua `LocalConfig.kmk`:

```
VBOX_WINDDK_GST_WLH  = WINSDK10-KM-WLH    # kBuild: dùng lib Win7 thay lib Vista
VBOX_WINDDK_GST_W2K3 = WINSDK10-KM-W7
VBOX_WINDDK_GST_WXP  = WINSDK10-KM-W7
VBOX_WINDDK_GST_NT4  = WINSDK10-KM-W7
SDK_WINSDK10_VERSION = 10.0.19041.0      # header KM phai cung version voi WDK
```

`WINSDK10-KM-WLH` **đã có sẵn trong kBuild** (`kBuild/kBuild/sdks/WINSDK10-KM-WLH.kmk`) với comment: *"There are no Vista libraries shipping with the windows 10 WDK, so this is a bit hackish and uses the Windows 7 ones instead."*

#### 4.7.5.2 Chọn version WDK

Từ tài liệu Microsoft (`other-wdk-downloads` + blog *Building Drivers for Previous OS Releases Using the Latest WDK*):

| WDK | Có lib KM x86? | Có lib win7/win8? | Kết luận |
|---|---|---|---|
| 10.0.19041.5738 | ✅ (19041 < 22000) | ✅ | **Duy nhất thỏa cả hai** |
| 10.0.22621.x | ✅ | ❌ | Thiếu win7/win8 |
| 10.0.26100+ | ❌ | ❌ | Thiếu cả hai |

→ Job ghim **SDK + WDK 10.0.19041.0**.

Link tải (đã verify truy cập được):
- SDK: `https://go.microsoft.com/fwlink/?linkid=2311805` → `winsdksetup.exe`
- WDK: `https://go.microsoft.com/fwlink/?linkid=2342425` → `wdksetup.exe`

#### 4.7.5.3 Script `install-wdk.ps1`

`.github/scripts/install-wdk.ps1` — mỗi kit thử 2 cách:

1. **Cài trực tiếp** (silent) với feature id:
   - SDK: `/features OptionId.WindowsDesktopSDK-10.0.19041.0 OptionId.DesktopCPPx64 /q /ceip off`
   - WDK: `/features OptionId.WindowsDriverKitComplete /q /ceip off`
2. **Fallback layout**: `wdksetup.exe /layout <dir> /quiet` → chạy `layout.exe /quiet` (tránh phải đoán feature id của WDK, vốn đổi theo version).

Sau đó **verify** 6 thư mục bắt buộc và fail với thông báo chỉ rõ nguyên nhân:

```
Include\10.0.19041.0\km        Include\10.0.19041.0\um
Lib\10.0.19041.0\km\x64        Lib\10.0.19041.0\km\x86
Lib\win7\km\x64                Lib\win8\km\x64
```

#### 4.7.5.4 Nội dung job

| Step | Nội dung |
|---|---|
| Checkout | `repository: ${{ github.repository }}` (giống job `build`) |
| Record source revision | Ghi repo/ref/sha vào `source-revision.txt` |
| MSVC | `ilammy/msvc-dev-cmd@v1` |
| Verify kBuild + SDK | Kiểm tra `kmk.exe` + `Windows Kits\10\Include` |
| Patch DDK check | Bỏ `CheckForWinDDK` trong `configure.vbs` (vẫn cần — không có DDK 7.1) |
| **Install WDK** | `install-wdk.ps1 -KitVersion 10.0.19041.0` |
| Yasm / Qt 6 / SDL | Giống job `build` |
| Configure | `configure.vbs --with-SDK10 --with-libSDL --with-Qt` + `LocalConfig.kmk` (GA bật + override DDK) |
| Build | `kmk -j$(ProcessorCount)` |
| **Verify GA artifacts** | Check `VBoxGuest.sys`, `VBoxService.exe`, `VBoxTray.exe`, `VBoxControl.exe` (bắt buộc) + `VBoxSF.sys`, `VBoxMouse.sys`, `VBoxVideo.sys`, `VBoxWddm.sys`, `VBoxCertUtil.exe` (báo cáo) + `VBoxGuestAdditions.iso` |
| Upload | Artifact `virtualbox-guest-additions` + `virtualbox-additions-build-diagnostics` |

#### 4.7.5.5 Giới hạn đã biết

| Hạn chế | Hệ quả |
|---|---|
| Không có DDK 7.1 | Dùng lib Win7 thay cho Vista/XP. Driver x86 (`VBoxGuest` x86, `VBoxMouseNT`, `VBoxVideo` xpdm) có thể không link được vì thiếu `exsup.lib` (lib thời XP) |
| `VBOX_WINDDK_GST_NT4` → `WINSDK10-KM-W7` | `VBoxGuest.sys` x86 + `VBoxVideo.sys` (xpdm) + `VBoxMouseNT.sys` có thể fail link → có thể phải bỏ `VBOX_WITH_ADDITIONS_ISO.win.x86` |
| WDK 19041 không còn trên VS 2022 mới nhất | Đã xử lý bằng layout fallback; nếu Microsoft gỡ hẳn feature id thì job sẽ fail với thông báo rõ |
| Job build lại toàn bộ (~2-4h) | Chấp nhận được ở giai đoạn hiện tại; có thể tối ưu bằng `paths` filter khi PR-2 hoàn tất |

#### 4.7.6 Mapping PR → job

| PR | Job | Ghi chú |
|---|---|---|
| PR-1 `cloak-identity` | `build` (hiện có, sau khi sửa checkout) + `smoke` | Không đụng GUI/GA |
| PR-2 `cloak-ga-rename` | `full-additions` | Cần WDK |
| PR-3 `cloak-provisioning` | `build` | Đụng GUI (Qt) |
| PR-4 `cloak-coherence` | `build` + `smoke` | Có thể đụng libtpms |

#### 4.7.7 Danh sách task CI cụ thể (Phase 0)

| # | Task | File | Trạng thái | Nghiệm thu |
|---|---|---|---|---|
| 0.3.1 | Commit workflow hiện có vào git | `.github/workflows/build.yml` | ✅ **đã làm** (file tồn tại, chưa commit) | `git ls-files .github/workflows` có file |
| 0.3.2 | **Sửa checkout** sang repo của bạn + mở trigger `feature/cloak*` + `pull_request` | `.github/workflows/build.yml:3-14`, `:36-44` | ✅ **đã làm** | Push lên branch → workflow build đúng commit của bạn (kiểm tra `source-revision.txt` trong artifact) |
| 0.3.3 | Thêm `setup-python` nếu thiếu | — | ⛔ **bỏ qua** | Python chỉ dùng cho macOS bindings (`Makefile.kmk` của `src/VBox/Main`); Windows build không cần |
| 0.3.4 | Cache `out/` để tăng tốc | — | ⛔ **bỏ qua (có lý do)** | kBuild so sánh **timestamp**; restore cache làm timestamp mất thứ tự → có thể build sai. An toàn hơn là rebuild sạch |
| 0.3.5 | Ghi `source-revision.txt` (repo/ref/sha) vào artifact | `.github/workflows/build.yml` | ✅ **đã làm** | Artifact diagnostics chứa `source-revision.txt` |
| 0.3.6 | `concurrency` để huỷ run cũ | `.github/workflows/build.yml:19-22` | ✅ **đã làm** | Push liên tiếp chỉ giữ run mới |
| 0.4.1 | Thêm job `smoke` (3 kịch bản: ICH9+BIOS, PIIX3+BIOS, ICH9+EFI) | `.github/workflows/build.yml` + `.github/scripts/collect-identity.ps1` | ✅ **đã làm** | Artifact `cloak-identity-report` + `stability.txt` |
| 0.4.2 | Thêm job `full-additions` + WDK | `.github/workflows/build.yml` + `.github/scripts/install-wdk.ps1` | ✅ **đã làm** — xem [§4.7.5](#475-bổ-sung-job-full-additions-guest-additions--wdk) |
| 0.4.3 | Job `smoke` với VM thật (có disk) | — | ⬜ chưa làm | Verify được DMI/ACPI **trong guest** |

**Về script `collect-identity.ps1`** (`.github/scripts/collect-identity.ps1`):

| Đặc điểm | Chi tiết |
|---|---|
| Cơ chế | `VBoxManage debugvm <vm> info <item>` — 10 info item đã đăng ký qua `PDMDevHlpDBGFInfoRegister()`: `pci` (verbose), `acpi`, `vga`, `vbe`, `hda`, `ohci`, `xhci`, `vmsvga`, `lpc`, `hpet` |
| VM | Tạo headless **không có đĩa boot** → BIOS dừng ở "no bootable device" nhưng VMM vẫn sống → debugger info hoạt động |
| Hardware UUID | Cố định theo kịch bản → selector deterministic |
| Kiểm tra ổn định | Chạy **2 lần** trên cùng 1 VM, so fingerprint → fail nếu khác. Đây là test trực tiếp cho yêu cầu "random nhưng ổn định" |
| Chuẩn hoá fingerprint | Bỏ dòng trống, bỏ dòng chứa timestamp/session/uuid, mask địa chỉ hex dài (`0x[0-9a-f]{8,16}` → `0xADDR`) |
| Kịch bản | `ich9-bios` (mặc định), `piix3-bios` (`--chipset piix3`), `ich9-efi` (`--firmware efi`) — phủ cả 2 chipset và cả 2 đường DMI (pcbios/efi) |
| Exit code | 0 = ổn định, 1 = không ổn định, 2 = lỗi môi trường |

> Script được upload thành artifact `cloak-ci-scripts` từ job `build` → job `smoke` **không cần checkout repo** (tránh clone lại ~1.4 GB).


#### 4.7.8 Vấn đề kỹ thuật còn lại

| # | Vấn đề | Xử lý |
|---|---|---|
| CI-1 | `CheckSourcePath` — path phải ASCII, không space | OK với runner mặc định |
| CI-2 | kBuild | Đã prebuilt trong repo — **không cần build** (đã xác minh qua step "Verify kBuild") |
| CI-3 | 32-bit OpenSSL/curl | Đã chạy được (workflow hiện tại build thành công) |
| CI-4 | WDK cho GA driver | `choco install wdk` — version pin, có thể cần self-hosted runner |
| CI-5 | Qt 6.8.0 download ~1 GB | `install-qt-action` đã có `cache: true` |
| CI-6 | RAM/CPU | `windows-2022` = 4 vCPU / 16 GB; timeout 360 phút đã đặt rộng |
| CI-7 | `env.bat` chứa đường dẫn tuyệt đối | Chạy `configure.vbs` **trong** job, không cache `env.bat` |
| CI-8 | `kmk` song song | `-j$([Environment]::ProcessorCount)` — đã có |
| CI-9 | Artifacts lớn | `upload-artifact` mặc định nén; cân nhắc `compression-level: 0` |
| CI-10 | **Workflow build upstream thay vì repo mình** | 0.3.2 — **fix bắt buộc** |
| CI-11 | `VBOX_WITHOUT_ADDITIONS=1` chặn PR-2 | 0.4.2 |
| CI-12 | `LocalConfig.kmk` bị ghi đè mỗi run | OK — file nằm trong `.gitignore`, sinh lại mỗi job |

#### 4.7.9 Lỗi CI lần 1 (run `39571032952`) và cách sửa

> Run đầu tiên sau khi sửa checkout: `https://github.com/vuong4-design/virtualbox/actions/runs/39571032952`
> → `build` **fail**, `full-additions` **fail**, `smoke` skipped.

##### Lỗi A — `build` job: `error C2561: 'RTBldCfgRevision': function must return a value`

```
src\VBox\Runtime\common\misc\buildconfig.cpp(49,5): error C2561: 'RTBldCfgRevision': function must return a value
src\VBox\Runtime\common\misc\buildconfig.cpp(55,5): error C2561: 'RTBldCfgRevisionStr': function must return a value
```

**Nguyên nhân:** đây là bản **git**, không phải SVN. `Version.kmk:48` có
`VBOX_SVN_REV_VERSION_FALLBACK := $(patsubset %:,,  $Rev: 115387 $  )` — chỗ `$Rev: … $` chỉ được
expand trong SVN. `Config.kmk:9568-9607` xử lý git bằng cách đọc **commit message** HEAD tìm dòng
`svn:sync-xref-src-repo-rev: rNNNNN`:

```make
$(GIT) log -1 $(PATH_ROOT) | $(SED) … -e '/svn:sync-xref-src-repo-rev\: r/!d' …
```

Commit message của chúng ta không có dòng đó → `VBOX_SVN_REV` rỗng →
`IPRT_BLDCFG_SCM_REV` rỗng → `buildconfig.cpp` sinh ra `return ;` → **C2561**.

**Cách sửa (đã áp dụng):** `Config.kmk:9613-9622` hỗ trợ override từ bên ngoài
(*"allow to overwrite VBOX_SVN_REV externally"*). Workflow đọc revision từ `Version.kmk` rồi ghi vào
`LocalConfig.kmk`:

```powershell
$svnRev = (Select-String -Path "Version.kmk" -Pattern '\$Id: Version\.kmk (\d+)').Matches[0].Groups[1].Value
# -> "VBOX_SVN_REV = 115387"
```

> **Ghi chú:** cách "đúng" của upstream là thêm dòng `svn:sync-xref-src-repo-rev: r115387` vào commit
> message. Cách trên tự động và không phụ thuộc cách commit — nên dùng cách trên.

##### Lỗi B — `full-additions` job: thiếu `Lib\win7\km\x64` và `Lib\win8\km\x64`

Log cho thấy SDK + WDK 19041 **đã cài thành công**:

```
==> winsdksetup.exe /features OptionId.WindowsDesktopSDK-10.0.19041.0 … -> exit 1001
==> winsdksetup.exe installed.                       <- verify pass
==> wdksetup.exe /features OptionId.WindowsDriverKitComplete … -> exit 0
==> wdksetup.exe installed.                          <- verify pass
  OK   Include\10.0.19041.0\km          OK   Lib\10.0.19041.0\km\x64
  OK   Include\10.0.19041.0\um          OK   Lib\10.0.19041.0\km\x86
  MISS Lib\win7\km\x64                  MISS Lib\win8\km\x64
```

**Nguyên nhân (đã xác minh bằng log WiX Burn của chính installer):** WDK 19041 có **26 package**, trong đó
3 package cung cấp bộ lib "downlevel" — nhưng feature `OptionId.WindowsDriverKitComplete`
**không chọn** chúng:

```
i201: Planned package: package_Windows7WDKHeadersandLibs_x86_en_us,   … ba requested: None, execute: None
i201: Planned package: package_Windows8WDKHeadersandLibs_x86_en_us,   … ba requested: None, execute: None
i201: Planned package: package_Windows8.1WDKHeadersandLibs_x86_en_us, … ba requested: None, execute: None
```

Feature id của 3 package đó **không đoán được**: bootstrapper chỉ báo
`ERROR: The following features specified by the /features switch are not available: …` cho id sai,
**không** liệt kê id hợp lệ (đã thử 8 biến thể → tất cả invalid).

**Cách sửa (đã áp dụng):** bỏ qua feature id, dùng **layout + msiexec trực tiếp**:

1. `wdksetup.exe /layout <dir> /quiet` → tải toàn bộ MSI (khoảng 2 GB).
2. `layout.exe /quiet` → cài bộ mặc định.
3. `msiexec /i "<layout>\*Windows7WDKHeadersandLibs*.msi" /qn` (tương tự cho Win8 / Win8.1) →
   cài `Lib\win7\km\*`, `Lib\win8\km\*`, `Lib\winv6.3\km\*`.

Ngoài ra script giờ **dump cây kit đã cài** vào `wdk-kit-tree.txt` (uploaded artifact) để lần CI sau
có ground truth ngay cả khi vẫn còn thiếu.

> **Ghi chú:** WDK 19041 **có** các bộ lib này (đã xác minh qua listing hệ thống thật:
> `Windows Kits/10/Lib/win7/km/{x64,x86}/ntoskrnl.lib`, `…/win8/km/{x64,x86,arm}/…`,
> `…/winv6.3/km/…`) — chỉ là installer mặc định không chọn.

##### Sai lầm của tôi lúc thiết kế (đã ghi nhận)

Tôi đã khẳng định trong §4.7.5 rằng *"WDK 10.0.19041 là bản duy nhất còn cả lib x86 lẫn win7/win8"* và
*"script đã thử layout fallback"*. Thực tế:
- Bản 19041 **có** win7/win8 (đúng), nhưng installer không cài mặc định (sai ở chỗ tôi cho là đã xử lý).
- Layout fallback của script cũ **không** cài các package downlevel vì nó chạy `layout.exe` với bộ
  feature mặc định — tức cũng bỏ sót đúng cái cần cài.

Đã sửa lại bằng cách cài MSI trực tiếp như trên.



---

## 5. Kế hoạch triển khai theo phase

> Mỗi task có: file:line cụ thể đã verify, giá trị đích, và tiêu chí nghiệm thu.
> Ưu tiên theo Tier 1/2/3 của tài liệu §39.

### Phase 0 — Nền tảng (bắt buộc trước mọi thứ)

| # | Task | File | Nghiệm thu |
|---|---|---|---|
| 0.1 | Tạo branch `feature/cloak` từ `VBox-7.2` | — | `git branch` |
| 0.2 | Chứng minh build Windows **cục bộ** chạy được | `configure.vbs` → `env.bat` + `AutoConfig.kmk` | Build sạch không lỗi |
| 0.3 | **Sửa workflow CI** (checkout + trigger + revision log) | `.github/workflows/build.yml` | ✅ **đã làm** — xem [§4.7.7](#477-danh-sách-task-ci-cụ-thể-phase-0) |
| 0.4 | Thêm job `smoke` (verify identity + ổn định) | `.github/workflows/build.yml`, `.github/scripts/collect-identity.ps1` | ✅ **đã làm** (3 kịch bản) |
| 0.4b | Thêm job `full-additions` + WDK | `.github/workflows/build.yml`, `.github/scripts/install-wdk.ps1` | ✅ **đã làm** — xem [§4.7.5](#475-bổ-sung-job-full-additions-guest-additions--wdk) |
| 0.5 | Rewrite path pcbios ↔ efi trong CFGM overlay | `ConsoleImplConfigCommon.cpp:724-843` | Set `VBoxInternal/Devices/pcbios/0/Config/DmiBIOSVendor` → guest thấy ở cả BIOS và EFI mode |
| 0.6 | Hạ tầng test: script so sánh guest-visible identity giữa 2 build | `.github/scripts/collect-identity.ps1` ✅ (phần CI) | Chạy được trên VM Windows + Linux |
| 0.7 | Baseline identity để so sánh (artifact từ build stock) | artifact `cloak-identity-report` | Có 1 bộ giá trị reference cho VM mẫu |

**Ghi chú build:** repo **không có** `BUILDING-WIN32.md` (chỉ có `README.md`, `CONTRIBUTING.md`, `SECURITY.md`). Quy trình cục bộ:

```powershell
cd D:\virtualbox
cscript configure.vbs        # sinh AutoConfig.kmk + env.bat + configure.log
cmd /c "env.bat && kmk"      # build full
cmd /c "env.bat && kmk VBoxDD2_OBJECTS"   # build nhanh 1 module
```

Chi tiết CI: xem [§4.7](#47-ci-bằng-github-actions-quyết-định-4).

### Phase 1.0 — Machine Profile Engine (nền cho toàn bộ Phase 1-2)

> Phase này **bắt buộc phải đi trước** Phase 1 và Phase 2, vì các task sau chỉ là "đọc CFGM key thay vì hard-code literal".

| # | Task | File | Nghiệm thu |
|---|---|---|---|
| 1.0.1 | Khung `MACHINEPROFILE` + registry 3 profile | `src/VBox/Main/src-client/ConsoleImplConfigCloak.h` (mới) | Compile, không lỗi |
| 1.0.2 | PRNG `splitmix64` + FNV1a64 seed từ VM UUID | `ConsoleImplConfigCloak.cpp` (mới) | Unit test: cùng UUID → cùng output |
| 1.0.3 | `MPE::materialize()` → ghi CFGM vào node `Devices/cloak/0/Config/*` | `ConsoleImplConfigCloak.cpp` | `VBoxManage showvminfo` hiện đúng giá trị |
| 1.0.4 | Tích hợp vào `i_configConstructorX86` | `ConsoleImplConfigX86.cpp:383` (trước dòng 2055) | Giá trị tới được device |
| 1.0.5 | Bộ luật coherence C1–C10 (assertion lúc init) | `ConsoleImplConfigCloak.cpp` | Profile vi phạm → log rõ + fail sớm |
| 1.0.6 | Lint offline toàn bộ profile registry | script test | Không profile nào vi phạm C1–C10 |
| 1.0.7 | Cơ chế ép profile cụ thể (`Devices/cloak/0/Config/Profile`) | `ConsoleImplConfigCloak.cpp` | Set ExtraData → profile cố định |
| 1.0.8 | Cơ chế bật/tắt (`Devices/cloak/0/Config/Enabled`) — **mặc định tắt** | `ConsoleImplConfigCloak.cpp` | Không bật → VirtualBox y hệt stock |

### Phase 1 — Tier 1: CPU / firmware (giá trị cao nhất)

| # | Task | File:line | Giá trị đích | Rủi ro |
|---|---|---|---|---|
| 1.1 | Hyper-V vendor | `GIMR3Hv.cpp:245-248` | `"Microsoft   "` (12 ký tự) | Thấp |
| 1.2 | HVP suppression | `target-x86/CPUMR3CpuId-x86.cpp:4017-4026` | clear HVP thay vì set | **Cao** |
| 1.3 | CPU DB profile | `CPUMR3Db.cpp:154` | profile CPUID thật, **không** copy brand string của fork | Cao |
| 1.4 | SMBIOS Type 11 suppression | `DevFwCommon.cpp:977-999` | `DmiOEMVBoxVer/Rev` default `""` | Thấp |
| 1.5 | SMBIOS Type 17/19/8 | `DevFwCommon.cpp:889-975` + code mới | key `DmiMemDev`, `DmiPortConnectors` | Trung bình |
| 1.6 | Anti-detect gate | `DevFwCommon.cpp:487` | cờ `CloakEnabled` | Thấp |
| 1.7 | Default DMI vendor/product | `DevFwCommon.cpp:64-95` | (chốt ở §10) | Thấp |
| 1.8 | ACPI OEM/Creator theo UUID | `DevACPI.cpp:4670-4697` | bảng 5 + bảng 4 | Thấp |
| 1.9 | ACPI OEM Table ID | `DevACPI.cpp:4680-4687`, `:2918-2931` | `"A M I "` | Thấp |
| 1.10 | DSDT rebrand | `PC/vbox.dsl:28` | `ACRSYS` / `ACRPRDCT` | Thấp |
| 1.11 | Battery `_BIF` | `PC/vbox.dsl:1491-1495` | `i2battery` / `INTEL` | Thấp |
| 1.12 | DSDT CPU0 + thermal + voltage | `PC/vbox.dsl` + `DevACPI.cpp` | AML theo §8.3-8.5 | Trung bình |
| 1.13 | MPS rebrand | `DevFwCommon.cpp:1128-1133` | `INTELCPU` / `Intel` | Thấp |
| 1.14 | PC BIOS AMI | `PC/BIOS/orgs.asm:86-87`, `bios.c:74`, `logo.c:477` + 3 `.asm` | `American Megatrends V3.10` | Trung bình (`.asm` là generated) |
| 1.15 | **Fix leak F12** | `PC/BIOS/logo.c:477` + 3 `.asm` | bỏ `VirtualBox` | Thấp |
| 1.16 | VGA BIOS → NVIDIA | `Graphics/BIOS/vbe.c:88-97`, `vgabios.c:99` + 3 `.asm` | chuỗi NVIDIA | Trung bình |
| 1.17 | **Fix leak raw VGA ROM** | `Graphics/BIOS/VBoxVgaBiosAlternative*.asm` | bỏ `Antidetect5` / `VirtualBox` | Thấp |
| 1.18 | UEFI `FirmwareVendor` | `OvmfPkg/OvmfPkgX64.dsc` (override) | `L"ASUS"` | Trung bình (cần EDK2 build) |
| 1.19 | ACPI PM `VenDevId` | `DevACPI.cpp:4881-4882` | key override | Thấp |

**Ràng buộc kỹ thuật quan trọng:**

- **BIOS / VGA BIOS**: file `.asm` checked-in là **artifact sinh ra** từ nguồn gốc
  (`PC/BIOS/Makefile.kmk:136-165`, `Graphics/BIOS/Makefile.kmk:71-104`).
  → Phải sửa **cả** nguồu gốc (`.asm` gốc, `logo.c`, `vbe.c`, `vgabios.c`) **và** file `.asm` đã flatten, nếu không lần regenerate sẽ mất patch.
- **DSDT**: build được trong tree — `bldRTIasl` build từ `src/VBox/Runtime/tools/RTIasl.cpp` (`src/VBox/Runtime/tools/Makefile.kmk:82-88`), `Config.kmk:2532` (`VBOX_RTIASL`), `Devices/Makefile.kmk:917-919`.
- **UEFI**: build OVMF riêng (`Devices/EFI/Firmware/Makefile.kmk:435-453`, `ACTIVE_PLATFORM = OvmfPkg/OvmfPkgX64.dsc`).

### Phase 2 — Tier 2: device identity

| # | Task | File:line | Giá trị đích |
|---|---|---|---|
| 2.1 | GPU `GpuModelId` | `Graphics/DevVGA.cpp:6829-6843` | VID<<48\|DID<<32\|SVID<<16\|SID |
| 2.2 | VMSVGA `CMD_BUFFERS_2` | `Graphics/DevVGA-SVGA.cpp:8074-8089` | bỏ bit 0x04000000 |
| 2.3 | HDA codec/subsystem | `Audio/DevHdaCodec.cpp:801-804`, `Audio/DevHda.cpp:5138-5141` | bảng 32 VID:DID theo UUID |
| 2.4 | PIIX3 ATA model | `Storage/DevATA.cpp:8231-8232` | `Samsung PRO 970` / `Samsung CD-ROM` |
| 2.5 | AHCI controller | `Storage/DevAHCI.cpp:5769-5770` | `8086:8C82` |
| 2.6 | AHCI model/serial/INQUIRY | `Storage/DevAHCI.cpp:5414-5456` | `SanDisc Extreme Pro`, `SD%xSSDE`, `SanDisk/Extreme/1.0` |
| 2.7 | HostDVD inquiry | `Storage/DrvHostDVD.cpp:366-368` | `Hitachi/CD-ROM/1.0` |
| 2.8 | USB HID VID + override | `Input/UsbKbd.cpp:125-127,326-329`, `Input/UsbMouse.cpp:65-69,351-355` | `3938` + 3 key mới |
| 2.9 | USB webcam | `Video/UsbWebcamDesc.cpp:793-794,925-927` | `046D:0825 / Logitech / HD Webcam C270` |
| 2.10 | USB MSD | `Storage/UsbMsd.cpp:59-61,282-284` | `3938` / `Seagate` |
| 2.11 | OHCI `VenDevId` | `USB/DevOHCI.cpp:6001-6005` | key override |
| 2.12 | xHCI PantherPoint | `USB/DevXHCI.cpp:8052` | `8086:8D31` |
| 2.13 | i440FX + PIIX3 ISA | `Bus/DevPCI.cpp:1353-1355`, `:1365-1366` | `0400:1237`, `8086:0484` |
| 2.14 | **VMMDev** | `VMMDev/VMMDev.cpp:4844-4847` | `8086:1551` |
| 2.15 | ACPI PM `VenDevId` | `PC/DevACPI.cpp:4881-4882` | key override |
| 2.16 | VirtIO vendor | `VirtIO/VirtioCore.h:261`, `VirtioCore.cpp:3073-3084` | `0x10EC` |
| 2.17 | virtio-net Realtek DID | `Network/DevVirtioNet.cpp:3698-3705` | 11 DID theo MAC |
| 2.18 | E1000 subsystem + EEPROM | `Network/DevE1000.cpp:267-281`, `:706-717` | `85F0:1043` |
| 2.19 | TPM `INTC/CSME/PTT` | `src/libs/libtpms-0.10.2/src/tpm2/VendorInfo.c:71-77` | 4 hằng |

### Phase 3 — Guest Additions camouflage

Đổi tên trong: tên file, tên service, tên registry key, `FileDescription`/`ProductName` trong PE VersionInfo, và `PCI\VEN_...&DEV_...` trong INF.

Thứ tự: **đổi host trước, guest sau** (hoặc song song trong cùng build) — nếu đổi lệch, guest sẽ không load driver.

| Task | File chính |
|---|---|
| 3.1 | `Additions/common/VBoxGuest/win/VBoxGuest.inf`, `VBoxGuestInst.cpp`, `include/VBox/VBoxGuest.h:104` |
| 3.2 | `Additions/common/VBoxService/VBoxServiceInternal.h:189,193`, `Additions/win/Installer/VBoxAddInstallNt3x.cpp:90-91` |
| 3.3 | `Additions/win/SharedFolders/driver/VBoxSF.inf:64,72` |
| 3.4 | `Additions/win/VBoxTray/VBoxTray.h:52` |
| 3.5 | `Additions/common/VBoxControl/VBoxControl.cpp` + installer |
| 3.6 | `Additions/win/Graphics/Video/mp/{xpdm/VBoxVideo.inf, wddm/VBoxWddm.inf}` |
| 3.7 | `Additions/win/VBoxCredProv/` (WhomNP) |

### Phase 4 — Guest provisioning / UI runtime actions

| Task | File |
|---|---|
| 4.1 | Thêm slot `sltAntiOS*` vào `Frontends/VirtualBox/src/runtime/UIMachineLogic.h/.cpp` |
| 4.2 | Đăng ký action `AntiOS*` vào `Frontends/VirtualBox/src/globals/UIActionPoolRuntime.cpp` |
| 4.3 | Payload Guest Control: TCP fingerprint (M1D/M1D1), hop tuner, IPv6, firewall, browser hardened, GPS |

**Lưu ý phạm vi:** chỉ port các action **không** phụ thuộc payload bên ngoài đã bị AV quarantine hoặc chặn dịch vụ bên thứ ba (AutoKMS, hosts-blocklist anti-fraud). Các payload đó nằm ở `cloak/Iso/etc/`, không phải mã nguồn VirtualBox.

### Phase 5 — Cross-layer coherence

Sửa các mâu thuẫn §2.3. **Không để cuối** — càng sửa nhiều plane độc lập càng dễ tạo mâu thuẫn mới.

| Mâu thuẫn | File:line |
|---|---|
| F12 còn `VirtualBox` | `PC/BIOS/logo.c:477` + 3 `.asm` |
| Raw VGA ROM còn `Antidetect5` | `Graphics/BIOS/VBoxVgaBiosAlternative*.asm` |
| USB MSD `Seagate` vs VSCSI `VBOX` | `Storage/VSCSI/VSCSILunSbc.cpp:248-250`, `VSCSILunMmc.cpp:1146-1148` |
| PIIX3 optical IDENTIFY vs INQUIRY | `Storage/DevATA.cpp:2431-2433` |
| AHCI optical `Toshiba` vs `SanDisk` | `Storage/DevAHCI.cpp:5436-5456` |
| SSD model vs nonrotational/TRIM/SMART | `Storage/DevATA.cpp`, `Storage/DevAHCI.cpp` (word 217/169) |
| VirtIO-SCSI `10EC:1048` | `VirtIO/VirtioCore.cpp:3073-3084` (ngoại lệ theo device type) |
| E1000 PCI vs EEPROM thứ tự field | `Network/DevE1000.cpp:277` vs `:706-717` |
| TPM `INTC` vs libtpms cũ | `src/libs/libtpms-0.10.2/` — cần nâng version |
| HDA tuple vs chipset đời | cần bảng profile coherence |
| VMMDev `8086:1551` vs INF `PCI\VEN_80ee&DEV_cafe` | `Additions/common/VBoxGuest/win/VBoxGuest.inf:63` |

### Phase 6 — Verification

Reuse đúng các collector mà tài liệu đã viết và self-test sẵn (tất cả nằm trong `cloak/analysis_driverdiff/`):

| Collector | File | Kiểm tra |
|---|---|---|
| PCI final sink (Pass 118) | `pass118_pci_runtime_analyze.py` | `debugvm <vm> info pci verbose` → `10EC:*` + virtio cap chain; `8086:1551` + BAR0 size `0x20` |
| CPU topology (Pass 124) | `pass124_cpu_topology_*.py` | CPUID `0/1/4/0xb/0x80000000/0x80000002-04/0x80000008/0x8000001d/0x8000001e` + APIC/x2APIC + core/package |
| Cert residue (Pass 123) | `pass123_cert_store_*` | thumbprint `6FE993BC8729F84CF60684BB1D8BD1CC3CB2D004` |
| SHFL (Pass 125/128) | `pass125_*`, `pass128_sharedfolder_passive_log_analyze.py` | `uRootIdVer` |
| ACPI (Pass 103) | `pass103_acpi_runtime_harness.md` | DSDT/OEM ID |
| USB (Pass 107) | `pass107_usb_runtime_harness.md` | descriptor/string |
| E1000 (Pass 106) | `pass106_e1000_runtime_harness.md` | PCI vs EEPROM |
| Firmware (Pass 112) | `pass112_firmware_runtime_harness.md` | SMBIOS/ACPI/MPS |
| VMSVGA caps (Pass 111) | `pass111_vmsvga_caps_runtime_harness.md` | `CMD_BUFFERS_2` |
| EDID (Pass 110) | `pass110_monitor_edid_runtime_harness.md` | monitor identity |

**Tiêu chí nghiệm thu mỗi task:**

1. Build sạch.
2. VM boot được (Windows + Linux).
3. Collector tương ứng cho thấy giá trị mới.
4. Matrix row tương ứng chuyển `RUNTIME_UNVERIFIED` → `FORK_CHANGED_CONFIRMED` trong `antios_coverage_proof_matrix_v1.json`, hoặc có bằng chứng runtime cụ thể ghi vào evidence file.
5. Không sinh mâu thuẫn mới ở Phase 5.

---

## 6. Cross-layer coherence — phần cần thêm ngoài tài liệu

Tài liệu §56 đề xuất **machine-profile coherence model** như một tầng audit riêng. Đề xuất cụ thể cho bản port:

```
MachineProfile {
  cpu:      {family, model, stepping, cores, threads, avx, pcid}
  chipset:  {i440FX, LPC, xHCI, AHCI, ACPI_PM, HDA}
  firmware: {vendor, OEM_ID, creator, ACPI_OEM_TabId, SMBIOS_vendor}
  gpu:      {VID/DID/SVID/SID, VBE vendor, EDID}
  storage:  {controller, model family, INQUIRY vendor, nonrotational/TRIM/SMART}
  net:      {VID/DID/SVID/SID, EEPROM, INF, provider strings}
  tpm:      {manufacturer, firmware, PCR properties}
  guest:    {GA service names, file names, PnP provider, WMI}
}
```

Check tự động:
- chipset generation đồng nhất (e.g. `0400:1237` AMD + `8086:8D31` xHCI Intel = lệch đời)
- ACPI OEM ID (`AMI`/`INTEL`/`ASUS`/`HP`) khớp SMBIOS vendor và firmware vendor
- CPU generation khớp chipset (Core2-era CPUID + chipset đời 8xx)
- storage model family đồng nhất giữa IDENTIFY và INQUIRY
- SSD model ⟺ nonrotational + TRIM + SMART
- GPU vendor khớp VBE vendor khớp EDID manufacturer
- TPM manufacturer khớp firmware version

---

## 7. Quy trình build

```powershell
cd D:\virtualbox

# 1) cấu hình (một lần)
cscript configure.vbs
#    → sinh AutoConfig.kmk, env.bat, configure.log

# 2) build
cmd /c "env.bat && kmk"

# 3) build nhanh một module
cmd /c "env.bat && kmk VBoxDD2_OBJECTS"
cmd /c "env.bat && kmk VBoxVM_OBJECTS"

# 4) chỉ OVMF
cmd /c "env.bat && kmk VBoxEFI-amd64"
```

Yêu cầu môi trường: MSVC (Visual Studio), Windows SDK, WDK (cho driver GA), kBuild `>= 3256` (`src/VBox/Main/Makefile.kmk:360,540,1053`), và **OpenWatcom** cho legacy BIOS nếu muốn regenerate `.asm` từ nguồn.

Khoản cần thiết khác:
- `iasl` — build được trong tree (`bldRTIasl` ← `src/VBox/Runtime/tools/RTIasl.cpp`)
- EDK2 toolchain — cho OVMF

### 7.1 Build trên GitHub Actions (đường chính)

Theo quyết định #4, **CI là đường build chính**; local chỉ để debug nhanh.

Repo **đã có** workflow `.github/workflows/build.yml` (310 dòng, chưa commit) build VirtualBox 7.2 Windows x64 trên `windows-2022`:

| Job | Nội dung | Dependency cài thêm |
|---|---|---|
| `build` (hiện có) | Toàn bộ + GUI (Qt 6.8.0) — **trừ** Guest Additions (`VBOX_WITHOUT_ADDITIONS=1`) | yasm, Qt 6.8.0, SDL 1.2.15 |
| `smoke` (thêm) | Chạy `VBoxManage` / `debugvm info pci verbose` → artifact identity | — |
| `full-additions` (thêm) | Build kèm Guest Additions (cần WDK) | WDK |

**Fix bắt buộc trước khi dùng:** workflow đang checkout `repository: VirtualBox/virtualbox` → build upstream, **không** build code của bạn. Xem [§4.7.3](#473-lỗi-nghiêm-trọng-cần-sửa-trước-tiên).

Output: `out\win.amd64\release\bin` → artifact `virtualbox-7.2-windows-amd64-binaries`.

Chi tiết: [§4.7](#47-ci-bằng-github-actions-quyết-định-4).

### 7.2 Lưu ý khi build **không** có GUI

`Config.kmk:862` đặt `VBOX_WITH_QTGUI = 1` mặc định trên Windows. Job `core` ghi đè trong `LocalConfig.kmk` (file này đã nằm trong `.gitignore`):

```
VBOX_WITH_QTGUI=
```

Tương tự cho Guest Additions — cần xác minh tên flag chính xác trong `Config.kmk` / `src/VBox/Additions/Makefile.kmk` trước khi viết workflow.

### 7.3 Vì sao bỏ qua OpenWatcom

`PC/BIOS/Makefile.kmk:136-165` và `Graphics/BIOS/Makefile.kmk:71-104` **sinh lại** file `.asm` đã flatten từ nguồn gốc. Nếu CI có OpenWatcom và regenerate, các patch đã sửa trong `.asm` sẽ bị ghi đè.

→ **Quyết định: không regenerate BIOS trong CI.** Giữ `.asm` checked-in là nguồn build thực tế, sửa đồng thời cả `.asm` gốc lẫn `.asm` flatten. Ghi rõ trong commit message để không ai regenerate nhầm.

---

## 8. Quy trình kiểm chứng

### 8.1 Kiểm tra tĩnh (nhanh, mỗi task)

```powershell
# PCI inventory
VBoxManage debugvm "<vm>" info pci verbose

# DMI/ACPI
VBoxManage showvminfo "<vm>" --machinereadable
```

### 8.2 Kiểm tra runtime (theo collector)

Chạy collector trong guest Windows, so với giá trị mong đợi. Script có sẵn ở `cloak/analysis_driverdiff/`.

### 8.3 Kiểm tra differential

Cùng một cấu hình VM, chạy lần lượt dưới:
1. Build **stock** (baseline)
2. Build **cloak**

diff toàn bộ output collector. Mọi khác biệt phải map được về một task trong kế hoạch — khác biệt không giải thích được = regression.

### 8.4 Regression check bắt buộc

| Hệ | Check |
|---|---|
| Windows 10/11 | Boot, PnP không có device lỗi, driver GA load, GPU driver, audio, network, storage |
| Linux (Debian/Ubuntu) | Boot, `lspci`, `lsusb`, `dmesg` không có "unknown device" |
| VBoxManage | `showvminfo`, `list hdds`, `showvminfo --machinereadable` |
| Shared clipboard / DnD / shared folder | Hoạt động sau khi đổi GA |
| Guest Control | `VBoxControl` chạy được |

---

## 9. Rủi ro

| # | Rủi ro | Mức | Giảm thiểu |
|---|---|---|---|
| R1 | Suppress HVP làm Hyper-V/KVM provider lỗi | **Cao** | Chỉ suppress khi provider = HyperV; giữ `EnableHVP` bật lại được. Test cả 3 provider |
| R2 | Đổi CPUID leaf/ID → guest BSOD (đặc biệt driver MSI) | **Cao** | Test Windows + Linux sau **mỗi** task Tier 1 |
| R3 | Key CFGM mới không có trong whitelist → device không construct | Trung bình | Sửa whitelist **cùng lúc** với code đọc key |
| R4 | `VBOX_VENDOR`/`VBOX_PRODUCT` đổi → đụng licensing, toàn bộ string sản phẩm | Trung bình | Sửa cục bộ trong `vbe.c`/`vgabios.c`, **không** sửa `Config.kmk` |
| R5 | Tạo cross-layer mismatch mới (tệ hơn leak cũ) | **Cao** | Áp dụng Phase 5 cùng lúc, không để cuối |
| R6 | `.asm` BIOS bị regenerate mất patch | Trung bình | Commit cả nguồn + flatten; ghi rõ trong commit message |
| R7 | EFI build cần toolchain riêng, lâu, khó debug | Trung bình | Làm sau các phase khác; tách PR riêng |
| R8 | Đổi tên GA làm guest cũ không load được driver | Trung bình | Đồng bộ host+guest trong cùng build; version-gate |
| R9 | Port CPUDB sai → CPUID incoherent | Cao | Dựng CPUID blob từ CPU thật, validate bằng Pass 116/124 |
| R10 | Nâng libtpms lên version mới → hàng loạt diff | Trung bình | Tách PR riêng, không gộp Phase 1 |
| R11 | GPL/về pháp lý | Thấp | VirtualBox là GPL; fork đã redistribute. Chỉ dùng cho mục đích kiểm thử/nghiên cứu |
| R12 | **CI build nhầm repo** (upstream thay vì repo mình) | **Cao** | Đã xác định: `build.yml:25-31`. Fix bắt buộc ở task 0.3 — kiểm tra lại bằng artifact `configure.log`/`AutoConfig.kmk` sau khi sửa |
| R13 | **CI không build được Guest Additions** (thiếu WDK) | Trung bình | `VBOX_WITHOUT_ADDITIONS=1` → job `full-additions` (task 0.4.2); nếu WDK trên runner công cộng không ổn định → self-hosted runner |
| R14 | **MPE tạo giá trị không ổn định** (đổi mỗi lần mở VM) | **Cao** | Seed từ VM UUID + materialize đúng 1 lần; test "mở lại 3 lần" trong CI (task 0.6/0.7) |
| R15 | **MPE tạo mâu thuẫn chéo** (profile sai quy tắc) | Cao | Luật C1–C10 assert lúc init + lint offline (task 1.0.5, 1.0.6) |
| R16 | **`.asm` BIOS bị regenerate trong CI** → mất patch | Trung bình | §7.3 — không cài OpenWatcom, không regenerate |
| R17 | **PR lớn, khó review** | Trung bình | 4 PR theo §10.1; mỗi PR có 1 tầng kiểm chứng rõ ràng |
| R18 | **CI chạy lâu** (timeout 360 phút) | Thấp | Cache `out/` + `Qt` (đã có `cache: true`); job `smoke` dùng lại artifact của `build` |

---

## 10. Quyết định đã chốt

> Đã chốt với người yêu cầu. Kế hoạch dưới đây được cập nhật theo 4 quyết định này.
> **Chỉ lập kế hoạch — chưa triển khai code cho tới khi có chỉ thị "triển khai".**

| # | Câu hỏi | Quyết định | Ảnh hưởng lên kế hoạch |
|---|---|---|---|
| 1 | Chia PR thế nào? | **Theo đề xuất**: 4 PR | Mục 10.1 |
| 2 | Giá trị đích cho DMI vendor/product? | **Thông tin phải đồng bộ** | §4.5 — thay bằng Machine Profile Engine; thêm Phase 1.0 |
| 3 | Selector random hay cố định? | **Random, nhưng ổn định qua các lần mở VM** | §4.6 — PRNG seed từ VM UUID, materialize 1 lần |
| 4 | Môi trường build? | **GitHub Actions** | §4.7 — 3 job (`core` / `full` / `smoke`); thêm task 0.3, 0.4, 0.7 |

### 10.1 Chia PR (quyết định #1)

| PR | Branch | Nội dung | Phase | Job CI bắt buộc |
|---|---|---|---|---|
| **PR-1** | `feature/cloak-identity` | MPE + Tier 1 (CPU/firmware) + Tier 2 (device identity) | 1.0, 1, 2 | `core` |
| **PR-2** | `feature/cloak-ga-rename` | Đổi tên Guest Additions (driver/service/file/INF/PE version info) | 3 | `full` |
| **PR-3** | `feature/cloak-provisioning` | UI runtime actions + Guest Control provisioning | 4 | `full` |
| **PR-4** | `feature/cloak-coherence` | Sửa cross-layer mismatch + nâng libtpms | 5 | `core` (+ `full` nếu đụng GA) |

Quy tắc merge:
- PR-1 phải merge trước (MPE là nền của PR-4).
- PR-4 cần PR-1 + PR-2 đã merge (để so coherence trên bộ GA đã đổi tên).
- PR-2 và PR-3 độc lập với nhau.

### 10.2 Đồng bộ thông tin (quyết định #2)

→ Xem [§4.5](#45-kiến-trúc-mpe--machine-profile-engine-quyết-định-2-thông-tin-phải-đồng-bộ).

Tóm tắt thay đổi so với bản kế hoạch đầu:
- Thêm **Phase 1.0 — Machine Profile Engine** chạy trước Phase 1/2.
- MPE nằm ở **VBoxC** (`src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp/.h`), là nguồn sự thật duy nhất.
- Mọi giá trị identity được **materialize một lần** và ghi vào node CFGM `Devices/cloak/0/Config/*`; device đọc từ đó (fallback về `Devices/<dev>/0/Config/*` để user vẫn override được).
- Bộ luật coherence **C1–C10** kiểm tra lúc khởi tạo + lint offline.
- 3 profile mẫu: `profile-lenovo-t14` (Intel, NVIDIA), `profile-dell-latitude` (Intel, Intel GPU), `profile-amd-ryzen-t14` (AMD).
- Mặc định **tắt** — bật qua `Devices/cloak/0/Config/Enabled`.

### 10.3 Selector ổn định (quyết định #3)

→ Xem [§4.6](#46-selector-ổn-định-quyết-định-3-random-nhưng-không-đổi-khi-mở-lại-vm).

Tóm tắt:
- Seed gốc = **VM UUID** (lưu trong `.vbox`, ổn định qua mọi lần mở).
- PRNG = `splitmix64`, tách 4 stream độc lập (profile / serial / mac-did / jitter).
- **Materialize đúng một lần** trong MPE → ghi CFGM. Không tính lại ở device.
- Ngoại lệ: virtio-net DID dùng `FNV1a64(seed64 || MAC)` — MAC ổn định nên vẫn deterministic.
- Cơ chế ép profile cụ thể để test: `Devices/cloak/0/Config/Profile`.
- 4 test bắt buộc: mở lại 3 lần → giống hệt; clone VM → khác (UUID khác); 2 VM → khác nhau; re-seed UUID → đổi hết.

### 10.4 CI GitHub Actions (quyết định #4)

→ Xem [§4.7](#47-ci-bằng-github-actions-quyết-định-4).

Tóm tắt:
- **CI đã tồn tại**: `.github/workflows/build.yml` (310 dòng, **chưa commit**) build VirtualBox 7.2 Windows x64 trên `windows-2022` — Qt 6.8.0, SDL 1.2.15, yasm 1.3.0, kBuild prebuilt, patch bỏ DDK check.
- **Fix bắt buộc (CI-10)**: workflow checkout `repository: VirtualBox/virtualbox` → đang build **upstream**, không build code của bạn. Đổi thành `${{ github.repository }}` / `${{ github.ref_name }}`.
- Thêm trigger cho `feature/cloak-*` và `pull_request`.
- Thêm job `smoke` (verify identity) + job `full-additions` (cần WDK, vì `VBOX_WITHOUT_ADDITIONS=1` chặn PR-2).
- Output: `out\win.amd64\release\bin`.
- Không cần OpenWatcom → giữ `.asm` BIOS checked-in là nguồn build (không regenerate).
- Đã loại trừ: 32-bit OpenSSL/curl, kBuild, SDL, Qt, SDK — workflow hiện tại đã xử lý thành công.

### 10.5 Vẫn còn mở (không chặn triển khai)

| # | Mục | Xử lý |
|---|---|---|
| O1 | CPU profile nào port trước | Đề xuất: `i7-9750H` (Intel, có CPUID blob chuẩn) + `Ryzen 7 PRO 6850U` (AMD) — fork dùng `Ryzen 7 1800X` làm negative control (byte-for-byte giống Oracle) |
| O2 | Nội dung `EfiGuardDxe` | **Ngoài scope** — cần binary DXE mới, activation semantics chưa rõ |
| O3 | Nâng libtpms 0.10.2 | Tách PR riêng trong PR-4; diff lớn, cần test TPM |
| O4 | Profile đầy đủ cho 3 máy mẫu | Cần tra cứu spec thật của từng máy (SMBIOS, ACPI, PCI ID, EEPROM) trước khi viết profile |

---

## 11. Trạng thái triển khai

```
[x] Đọc tài liệu cloak/           → mục 1
[x] Đối chiếu với src/            → mục 3
[x] Lập kế hoạch                   → tài liệu này
[x] Chốt 4 quyết định thiết kế    → mục 10
[x] Phase 0.3 — sửa workflow CI    → .github/workflows/build.yml
[x] Phase 0.4 — job smoke + script → .github/scripts/collect-identity.ps1
[x] Phase 0.4b — job full-additions → .github/scripts/install-wdk.ps1
[ ] TRIỂN KHAI phần còn lại        ← chờ chỉ thị
```

**Trạng thái hiện tại:**

| Hạng mục | Trạng thái |
|---|---|
| Mã nguồn VirtualBox (`src/`) | **Chưa sửa gì** |
| `.github/workflows/build.yml` | 3 job: `build` (core), `full-additions` (GA + WDK), `smoke` (verify identity) |
| `.github/scripts/collect-identity.ps1` | Thu thập + kiểm tra ổn định identity (3 kịch bản) |
| `.github/scripts/install-wdk.ps1` | Cài SDK+WDK 10.0.19041 (direct → layout fallback) + verify 6 thư mục |
| `.gitignore` | Vẫn còn thay đổi chưa commit (`+cloak`) |
| Tài liệu | `doc/cloak-plan/CLOAK-PLAN.md` |

Khi nhận chỉ thị "triển khai", thứ tự đề xuất:

1. Phase 0.1-0.2 (branch + build local) — *chưa làm*
2. Phase 0.5 (rewrite path pcbios ↔ efi)
3. Phase 1.0 (MPE) — nền cho mọi thứ sau
4. Phase 1 (Tier 1) → Phase 2 (Tier 2) → PR-1
5. Phase 3 → PR-2
6. Phase 4 → PR-3
7. Phase 5 → PR-4

**Bước kiểm chứng đầu tiên sau khi có code:** push branch `feature/cloak` → workflow chạy →
- job `build` xanh → job `smoke` xanh → artifact `cloak-identity-report` cho thấy identity **đã đổi** so với baseline nhưng **ổn định giữa 2 lần chạy**.
- job `full-additions` xanh → artifact `virtualbox-guest-additions` có `VBoxGuest.sys` + `VBoxGuestAdditions.iso`.

---

## Phụ lục A — Bảng tra nhanh: hook → file

| Nhóm | File |
|---|---|
| CPUID / HVP | `src/VBox/VMM/VMMR3/target-x86/CPUMR3CpuId-x86.cpp` |
| Hyper-V vendor | `src/VBox/VMM/VMMR3/GIMR3Hv.cpp` |
| CPU DB | `src/VBox/VMM/VMMR3/CPUMR3Db.cpp` |
| SMBIOS / MPS | `src/VBox/Devices/PC/DevFwCommon.cpp` |
| PC BIOS | `src/VBox/Devices/PC/BIOS/` (`orgs.asm`, `logo.c`, `bios.c`, `VBoxBiosAlternative*.asm`) |
| DSDT / SSDT | `src/VBox/Devices/PC/vbox.dsl`, `src/VBox/Devices/PC/ACPI/VBoxAcpi.cpp` |
| ACPI | `src/VBox/Devices/PC/DevACPI.cpp` |
| EFI / OVMF | `src/VBox/Devices/EFI/Firmware/MdeModulePkg/`, `OvmfPkg/` |
| VGA / VMSVGA | `src/VBox/Devices/Graphics/DevVGA.cpp`, `DevVGA-SVGA.cpp`, `BIOS/` |
| Audio | `src/VBox/Devices/Audio/DevHda.cpp`, `DevHdaCodec.cpp` |
| Storage | `src/VBox/Devices/Storage/DevATA.cpp`, `DevAHCI.cpp`, `DrvHostDVD.cpp`, `VSCSI/` |
| USB | `src/VBox/Devices/Input/UsbKbd.cpp`, `UsbMouse.cpp`; `src/VBox/Devices/USB/DevOHCI.cpp`, `DevXHCI.cpp`; `src/VBox/Devices/Video/UsbWebcamDesc.cpp`; `src/VBox/Devices/Storage/UsbMsd.cpp` |
| Chipset | `src/VBox/Devices/Bus/DevPCI.cpp` |
| VMMDev | `src/VBox/Devices/VMMDev/VMMDev.cpp` |
| Network | `src/VBox/Devices/Network/DevE1000.cpp`, `DevVirtioNet.cpp`; `src/VBox/Devices/VirtIO/VirtioCore.cpp` |
| TPM | `src/libs/libtpms-0.10.2/src/tpm2/VendorInfo.c` |
| Guest Additions | `src/VBox/Additions/` |
| Control plane | `src/VBox/Main/src-client/ConsoleImplConfigCommon.cpp`, `ConsoleImplConfigX86.cpp` |

## Phụ lục B — Baseline đối chiếu

| Artifact | SHA-256 (fork, theo tài liệu) |
|---|---|
| `VBoxDD.dll` | `709fa7bfa317f449fdb75eaa358e67f9efa6ee5e3694b2f3c37c3fde5e99114a` |
| `VBoxVMM.dll` | `c5889e3cb082285c733fc9637e571bc9065b72ab5f6579be0b0ebc95000b6aa3` |
| `VBoxDD2.dll` | `cd97868a598f8d48f52f12b07d90805e9d126c53649877a5d749ae2dd139d790` |
| `VBoxDDU.dll` | `63c46d52ec685c25d8ee887293d9744a6331456bd39805cef48ecaae7c9057a0` |
| `VirtualBoxVM.dll` | `e268386d8123dd0573749f197d1601e6b3316499d7351d241b80d204dcfa6bc4` |
| `VBoxDDR0.r0` | `c3ceead4eda25c3df69492bc2abfa1bd2840dfc8bf47772ebfedac0fd13dd0b5` |

| Control | SHA-256 |
|---|---|
| Oracle 7.2.4 r170995 | (chính là baseline đối chiếu) |
| Oracle 7.1.6 r167084 (outer package, authoritative lineage control) | `35c42c98b784974a965c358a9bda63b6cb4edde80db83f87daa2fee83e6cfad6` |
