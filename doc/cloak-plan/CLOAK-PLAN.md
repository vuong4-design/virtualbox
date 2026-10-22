# Kế hoạch port "cloak" (identity presentation) từ fork AntiOS/Antidetect5 vào VirtualBox 7.2

> **Tài liệu này** là kết quả đọc toàn bộ tài liệu phân tích trong `cloak/` và đối chiếu với mã nguồn VirtualBox tại `D:\virtualbox\src` (branch `VBox-7.2`, `Version.kmk` → 7.2.23).
>
> **Mục tiêu:** xây dựng kế hoạch sửa mã nguồn VirtualBox để hiện thực hoá các lớp "cloak" (đổi identity mà guest nhìn thấy) đã được xác nhận trong tài liệu phân tích.
>
> **Trạng thái: KẾ HOẠCH — chưa triển khai code.** 5 quyết định thiết kế đã chốt tại [§10](#10-quyết-định-đã-chốt):
> (1) chia 6 PR theo vertical slice, (2) identity phải **đồng bộ** → Machine Profile Engine, (3) selector **random nhưng ổn định** bằng `CloakSeed` + VM UUID, (4) build qua **GitHub Actions + T3 self-hosted**, (5) `CloakEnabled=off` chỉ tắt lớp runtime; build-time asset phải dùng build stock riêng.
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

**Kết luận của tài liệu §57:** detector coherence-based mạnh hơn detector chỉ tìm literal `VBOX`. Vì vậy coherence là **acceptance gate của từng vertical slice** (PR-2/PR-3), không phải phase dọn dẹp cuối cùng.

---

## 3. Inventory đầy đủ: hook → vị trí trong mã nguồn

> Cột "Nguồn" trỏ tới mục tương ứng trong `ANTIOS-VIRTUALBOX-CLOAK-HOOK-INVENTORY-20260906.md`.
> Mọi `file:line` đã được verify trực tiếp trên `D:\virtualbox\src` (branch `VBox-7.2`, cây làm việc hiện tại). Khi rebase/merge phải re-map lại line number.
> **Đây là inventory hook/giá trị của fork gốc, không phải target cuối.** Target đã chốt nằm ở §4.5 và Phase 1/2; các giá trị như `ACRSYS`, `ASUS`, `10EC`, `8086:1551` chỉ còn là ví dụ/lịch sử, không dùng mặc định.

### 3.1 CPU / hypervisor / timing

| § | Hook | File:line | Ghi chú |
|---|---|---|---|
| 3.1 | Hyper-V vendor → `Microsoft   ` | `src/VBox/VMM/VMMR3/GIMR3Hv.cpp:245-248` | Chỉ dùng ở chế độ `HyperV`; vendor phải đúng 12 ký tự. Sink: leaf `0x40000000` EBX/ECX/EDX tại `GIMR3Hv.cpp:380-407` |
| 3.2 | **HVP presentation** | `src/VBox/VMM/VMMR3/target-x86/CPUMR3CpuId-x86.cpp:4017-4026` | Ở chế độ `Hidden`: clear HVP và **không** expose leaf/vendor Hyper-V. Ở chế độ `HyperV`: giữ HVP=1 và leaves đầy đủ. Không trộn hai trạng thái |
| 3.2b | GIM provider dispatch | `src/VBox/VMM/VMMR3/GIMR3.cpp:156-184`; `GIMR3Hv.cpp:372-375`; `GIMR3Kvm.cpp:255-258`; `GIMR3Minimal.cpp:60-63` | Cả 3 provider đều gọi chung `CPUMR3SetGuestCpuIdFeature(..., HVP)`; `Hidden` phải dùng GIM `Minimal`/không GIM, `HyperV` mới dùng `GIMR3Hv` |
| 4.1 | CPU profile mới, `DmiCPU → GuestCpuName` | `src/VBox/VMM/VMMR3/CPUMR3Db.cpp:154` (`g_apCpumDbEntries`), `:272-275` (`CPUMR3DbGetEntries`); đọc key: `target-x86/CPUMR3CpuId-x86.cpp:2817-2821` | Fork có 61 entry, stock 27. Profile: `i9-9900K`, `i7-9700K`, `i7-9750H`, `i9-9980XE`, `Ryzen 7 1800X`… ⚠ xem cảnh báo §7.8 bên dưới |
| 4.1b | Producer `GuestCpuName` | `src/VBox/Main/src-client/ConsoleImplConfigX86.cpp:764` | `InsertConfigString(pCPUM, "GuestCpuName", bstrCpuProfile);` |
| 5.1 | `TM/TSCMode=RealTSCOffset` | `src/VBox/VMM/VMMR3/...` (stock) | Đã có sẵn ở stock — chỉ cần expose trong UI, **không cần sửa VMM** |

**Cảnh báo quan trọng (tài liệu §7.8 / Pass 116):** 4 profile Intel của fork **không phải** model CPUID độc lập — cùng family 6 / model 15 / stepping 6 (`CPUID.1 EAX = 0x000006f6`), `enmMicroarch=13` (= `kCpumMicroarch_Intel_Core2_Merom` trong enum VirtualBox). `i9-9900K` vs `i7-9700K` chỉ khác **1 trong 23** CPUID record (leaf `0x80000003`). Ngoài ra profile `i9-9900K` lộ brand string `i9-9700K`, `i7-9750H` lộ `i7-9700H`.
→ **Không được copy brand string từ fork.** Phải dựng lại CPUID blob từ CPU thật, hoặc bỏ hẳn khỏi scope.

Ngược lại, profile `AMD Ryzen 7 1800X Eight-Core` của fork **byte-for-byte giống** Oracle 7.1.6 và 7.2.4 → negative control tốt.

**Quyết định HVP bắt buộc:** 3.1, 3.2 và 3.2b là **một thiết kế duy nhất**, không phải ba patch độc lập. Chọn `CloakHvPresentation`:

| Mode | CPUID.1:ECX[31] | Leaf `0x40000000` | GIM provider | Dùng khi |
|---|---|---|---|---|
| `Hidden` (mặc định cho cloak) | 0 | Không vendor/leaves Hyper-V | `Minimal`/không GIM | Muốn giấu hypervisor hoàn toàn |
| `HyperV` | 1 | `Microsoft Hv` + leaves đầy đủ | `GIMR3Hv` | Profile khai báo VBS/Hyper-V và chấp nhận bị thấy hypervisor |

Trạng thái `HVP=0` + vendor `Microsoft Hv` là **lỗi thiết kế**, không phải một tùy chọn.

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
| 8.1 | Embedded DSDT rebrand | `src/VBox/Devices/PC/vbox.dsl:28` | `DefinitionBlock ("DSDT.aml", "DSDT", 2, "VBOX  ", "VBOXBIOS", 2)` → fork target `"ACRSYS","ACRPRDCT"`; plan dùng build-time family, không mặc định ACRSYS |
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
| 10.1 | PC BIOS AMI branding | `src/VBox/Devices/PC/BIOS/orgs.asm:86-87` (`BIOS_COPYRIGHT 'Oracle VirtualBox BIOS'`, `BIOS_BUILD_DATE '06/23/99'`); `BIOS/bios.c:74`; `BIOS/logo.c:477` | Fork target: `American Megatrends V3.10`, ROM tail `AMI BIOS` tại `0xFF00`, build date `23/08/22` tại `0xFFF5`; plan chọn build-time family sau O4 |
| 10.2 | **Leak:** F12 boot menu | `BIOS/logo.c:477`; `BIOS/VBoxBiosAlternative8086.asm:1271`; `…386.asm:1537`; `…286.asm:1300` | `printf("\nVirtualBox temporary boot device selection\n\n…")` — residual fingerprint |
| 10.2b | Version banner trong ROM | `VBoxBiosAlternative8086.asm:1285`, `…386.asm:1568`, `…286.asm:1314` | `db 'VirtualBox 7.2.22', 000h` |
| 11.1 | VGA BIOS VBE vendor (fork target NVIDIA) | `src/VBox/Devices/Graphics/BIOS/vbe.c:88-97`; `vgabios.c:99`, `:138` | Fork target: `"VirtualBox VESA BIOS"` → `"NVIDIA VESA BIOS"`; `"VirtualBox VBE Display Adapter enabled"` → `"NVIDIA VBE Display Adapter enabled"`; `"Oracle VirtualBox VBE Adapter"` → `"NVIDIA Video Adapter"`. Plan dùng build-time family, không per-VM; `VBOX_VENDOR`/`VBOX_PRODUCT` ở `Config.kmk:106-108` |
| 11.1b | VGA BIOS flattened | `Graphics/BIOS/VBoxVgaBiosAlternative{8086,386,286}.asm` | `8086.asm:9369, 9372, 9375, 8447`; `386.asm:8667, 8679`; `286.asm:9215, 9221, 9227, 8293` |
| 11.2 | **Leak:** raw VGA ROM build path | `Graphics/BIOS/VBoxVgaBiosAlternative*.asm` | `C:\Devel\Antidetect5\Personal\VirtualBox\...\VBoxVgaBios*.sym` — guest raw ROM scanner thấy được |
| 12.1 | `EfiGuardDxe` | `src/VBox/Devices/EFI/Firmware/` (module mới) | DXE driver patch bootmgfw/winload/ntoskrnl/CI.dll. **Không thuộc scope** — cần binary DXE mới, activation semantics chưa rõ |
| 12.4 | UEFI `FirmwareVendor` (fork target `ASUS`) | `src/VBox/Devices/EFI/Firmware/MdeModulePkg/MdeModulePkg.dec:1879-1881` (`PcdFirmwareVendor` = `L"EDK II"`) | Sink: `MdeModulePkg/Universal/BdsDxe/BdsEntry.c:710` → `gST->FirmwareVendor`; `OvmfPkg/SmbiosPlatformDxe/SmbiosPlatformDxe.c:146`. ⚠ Override trong `OvmfPkg/OvmfPkgX64.dsc` (pattern có sẵn: `OvmfPkg/Bhyve/BhyveX64.dsc:522` override `PcdFirmwareVendor` → `L"BHYVE"`); plan chọn build-time family, không hardcode ASUS |
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
| 15.8 | VSCSI SBC/MMC vendor | `src/VBox/Devices/Storage/VSCSI/VSCSILunSbc.cpp:248-250`; `VSCSILunMmc.cpp:1146-1148`; `VSCSILunSsc.cpp:152-153` | **Fork giữ stock** `VBOX` — xử lý ở coherence gate của PR-3 |
| 15.9 | VSCSI SBC MODE SENSE(6) | `VSCSILunSbc.cpp` | Stock `08 0A 04` → fork `08 12 04` |
| 16.1 | USB HID VID rebrand | `src/VBox/Devices/Input/UsbKbd.cpp:125-127`, `:326-329`, `:567-568`; `src/VBox/Devices/Input/UsbMouse.cpp:65-69`, `:351-355`, `:1194-1249` | `0x80EE` → `0x3938`, giữ PID `0010/0011/0020..0023` |
| 16.2 | USB HID descriptor override | `UsbKbd.cpp` / `UsbMouse.cpp` | Key mới `VenDevId` (VID<<16\|PID), `Manufacturer` (max 0x40), `Product` (max 0x40) |
| 16.3 | USB webcam Logitech C270 | `src/VBox/Devices/Video/UsbWebcamDesc.cpp:793-794`, `:925-927` | `80EE:0030 / VirtualBox / VirtualBox Webcam` → `046D:0825 / Logitech / HD Webcam C270`; serial giữ `00000011` |
| 16.4 | Webcam `StaticImagePath` | `UsbWebcamDesc.cpp` (thêm mới) | Nạp ảnh tĩnh, dùng kích thước trong webcam path |
| 16.5 | USB MSD rebrand | `src/VBox/Devices/Storage/UsbMsd.cpp:59-61`, `:282-284`, `:547-602` | VID `3938`, manufacturer `Seagate`, giữ PID `0030/0031`, product `USB Harddisk` / `USB CD-ROM` |
| 17.1 | OHCI `VenDevId` override | `src/VBox/Devices/USB/DevOHCI.cpp:6001-6005` | Stock `106B:003F` + key override |
| 17.2 | xHCI PantherPoint DID | `src/VBox/Devices/USB/DevXHCI.cpp:8052` | `8086:1E31` → `8086:8D31`. LynxPoint `:8050` (`0x8C31`) giữ stock, Renesas `:8041-8043` giữ stock |
| 17.3 | i440FX root bridge | `src/VBox/Devices/Bus/DevPCI.cpp:1353-1355` | **Giữ stock** `8086:1237`; profile phải hợp với chipset. Không dùng `0400:1237` (không phải AMD) |
| 17.4 | PIIX3 ISA bridge | `DevPCI.cpp:1365-1366` | **Giữ stock** `8086:7000`; không dùng `8086:0484` (không phải PIIX3) |
| 17.5 | **VMMDev rebrand** | `src/VBox/Devices/VMMDev/VMMDev.cpp:4844-4847` | **Binding identity** — mặc định giữ `80EE:CAFE`. Chỉ đổi toàn cục cùng lúc với GA + ký lại; không random theo profile |
| 17.6 | `PciDevId` | — | **INERT** — không port |
| 18.1 | VirtIO shared vendor rewrite | `src/VBox/Devices/VirtIO/VirtioCore.h:261` (`DEVICE_PCI_VENDOR_ID_VIRTIO 0x1AF4`); `VirtioCore.cpp:3073-3084` | **Không port mặc định** — phá driver binding của virtio; chỉ mở nhánh experimental |
| 18.2 | virtio-net Realtek DID selector | `src/VBox/Devices/Network/DevVirtioNet.cpp:3698-3705` | **Không port mặc định** — Realtek VID + virtio caps là fingerprint mạnh |
| 18.4 | VirtIO-SCSI leak | `VirtioCore.cpp:3073-3084` | Không còn nếu 18.1 bị loại khỏi baseline |
| 18.5 | E1000 index-0 subsystem spoof | `src/VBox/Devices/Network/DevE1000.cpp:267-281` (`g_aChips[]`) | 82540EM ss `8086:001E` → `1043:85F0` (SVID:SID), không phải `85F0:1043` |
| 18.6 | E1000 EEPROM patch | `DevE1000.cpp:706-717` | `m_au16Data[0x0B]` (SID) / `[0x0C]` (SVID) → `85F0` / `1043`; phải verify endian/order với PCI config |
| 18.7 | E1000 82583V removal | `DevE1000.cpp:252-255`, `:280` | **Không port** (feature removal, tạo fingerprint riêng) |
| 19.2 | TPM2 manufacturer/vendor/firmware | `src/libs/libtpms-0.10.2/src/tpm2/VendorInfo.c:71-77` | `MANUFACTURER "IBM"`→`"INTC"`; `"SW  "/" TPM"`→`"CSME"/"PTT "`; `FIRMWARE_V1/V2` `0x20240125/0x00120000`→`0x01930001/0` |
| 19.3 | TPM failure-mode endian | `VendorInfo.c` + `PropertyCap.c:107-136` | `CTNI/EMSC/ TTP` — fork bug. **Cân nhắc sửa luôn** (coherence) |
| 19.4/19.5 | libtpms stale lineage + PCR properties | `src/libs/libtpms-0.10.2/src/tpm2/PCR.c:1205-1207`; `TpmTypes.h:650-669` | `TPM_PT_PCR_RESET_L3` bitmap `00 00 81` vs stock `00 00 F1`; `TPM_PT_PCR_POLICY`/`AUTH` `00 00 70` vs `00 00 00`. **Yêu cầu nâng libtpms** — scope lớn, tách PR riêng |

**Phân loại bắt buộc:** `17.5` VMMDev, `13.1` VGA/WDDM và toàn bộ `18.x` VirtIO là **binding identity**. Không được random các ID này theo profile. Quy tắc chi tiết ở [§4.5.8](#458-phân-loại-identity-theo-driver-binding).

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
- `VBoxGuest.inf` `PCI\VEN_80ee&DEV_cafe` — chỉ đổi nếu VMMDev ID đổi **toàn cục** và GA được build + ký lại trong cùng PR. Mặc định **giữ `80EE:CAFE`**.
- Host `VBoxGuestPropSvc` / `VBoxGuestControlSvc` / `VBoxSharedFolders` / `VBoxSharedClipboard` / `VBoxDragAndDropSvc` / `VBoxHostChannel` — 6 service DLL, tên file giữ nguyên trong fork (xem §59.1 coverage matrix)
- `VBoxCertUtil` + certificate bundle
- Chữ ký driver: Windows 10/11 + Secure Boot cần Microsoft ký (WHQL/attestation); đổi tên file `.sys`/INF mà không ký lại sẽ không load.

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

**(a) Whitelist CFGM + code đọc key.** Mỗi device có `PDMDEV_VALIDATE_CONFIG_RETURN` — key không có trong whitelist sẽ bị reject (device fail to construct). Key mới (e.g. `DmiMemDev`, `GpuModelId`) còn phải được device **đọc và dùng**; thêm whitelist một mình không đủ.

| File | Dòng whitelist | Cần thêm |
|---|---|---|
| `src/VBox/Devices/PC/DevPcBios.cpp` | `1404-1468` | `DmiMemDev`, `DmiPortConnectors`, `VenDevId` (`Flags` legacy → `/Cloak/Enabled`) |
| `src/VBox/Devices/EFI/DevEFI.cpp` | `1523-1574` | (mirror pcbios) |
| `src/VBox/Devices/PC/DevACPI.cpp` | `4360-4389` | `VenDevId` |
| `src/VBox/Devices/Graphics/DevVGA.cpp` | `s_szMscWorkaround[]` (`:6646-6693`) | `GpuModelId` |
| `src/VBox/Devices/Input/UsbKbd.cpp`, `UsbMouse.cpp` | (tương ứng) | `VenDevId`, `Manufacturer`, `Product` |
| `src/VBox/Devices/USB/DevOHCI.cpp` | | `VenDevId` |
| `src/VBox/Devices/Storage/DevAHCI.cpp` | | `VenDevId` |

**(b) Chọn đúng node firmware.** `i_configCfgmOverlay` không biết VM dùng BIOS hay EFI. Fork có "firmware path map" (`/pcbios/` ↔ `/efi/`). Trong thiết kế mới, **MPE** biết firmware mode và materialize trực tiếp vào `Devices/pcbios/...` hoặc `Devices/efi/...`; không cần bước rewrite toàn cục.

- Nếu vẫn muốn map path ở overlay: chỉ áp dụng cho key runtime, thực hiện trong **PR-2**, không phải PR-1.
- Một profile DMI có thể dùng cho cả 2 firmware mode bằng cách chọn node đích, không copy giá trị qua lại.

**(c) Cổng `Flags` chống lạm dụng.** Fork dùng `Flags & 0x1337` như license gate. Nếu port nguyên xi thì bất kỳ ai cũng set được. Đề xuất: dùng một cờ riêng (ví dụ `CloakEnabled`) và **không** bật mặc định — để người dùng chủ động bật.

### 4.4 Những gì **không** đụng tới

| Không đụng | Lý do |
|---|---|
| `include/VBox/VBoxGuest.h` COM interface (trừ hằng tên service) | Giữ ABI |
| `src/VBox/Main/idl/*.idl` | Giữ TypeLib hash → SDK cũ vẫn chạy |
| `src/VBox/Main/src-client/ConsoleImplConfigX86.cpp` (trừ overlay rewrite + điểm gọi MPE sau `i_configCfgmOverlay`) | Không cần `InsertConfigString` mới; MPE materialize qua CFGM, không thêm chuỗi trực tiếp |
| `Config.kmk` `VBOX_VENDOR` / `VBOX_PRODUCT` | Đổi sẽ ảnh hưởng toàn bộ string sản phẩm + licensing. Sửa cục bộ trong `vbe.c` / `vgabios.c` |
| `VBoxC` HGCM service names | 6 service DLL giữ nguyên; đổi sẽ phá tương thích guest |

---

### 4.5 Kiến trúc MPE — Machine Profile Engine (quyết định #2: "thông tin phải đồng bộ")

#### 4.5.1 Vấn đề cần giải

Yêu cầu: **mọi thông tin identity phải đồng bộ với nhau**. Ví dụ một máy phải là "máy Intel đời 8xx, chipset Intel, firmware AMI, GPU NVIDIA, NIC Intel, storage Samsung" — không được trộn CPU AMD với i440FX `8086:1237` (Intel), hoặc BIOS AMI nhưng ACPI OEM ID `ASUS` **khi tổ hợp đó không có nguồn/allowlist** (C3 là heuristic, không phải equality tuyệt đối).

Cách fork làm: **vá từng literal riêng lẻ** → tạo ra chính những mâu thuẫn mà tài liệu §48.1 liệt kê.

Cách ta làm: **profile là nguồn mặc định, effective CFGM là nguồn sự thật cuối** — MPE materialize từ `MachineProfile`, nhưng `validateEffectiveConfig()` kiểm tra toàn bộ giá trị CFGM sau khi user override. Asset build-time (DSDT/BIOS/VGA/OVMF) được ràng buộc bằng `BUILDIDENTITYMANIFEST`, không do MPE materialize.

#### 4.5.2 Vị trí đặt MPE

| Thành phần | Vị trí đề xuất | Lý do |
|---|---|---|
| Engine + profile registry | `src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp` / `.h` (file mới) | Chạy 1 lần, 1 nơi, sau overlay và trước khi device construct |
| Điểm gọi | `Console::i_configConstructorX86()` — **ngay sau** `i_configCfgmOverlay()` (`ConsoleImplConfigX86.cpp:2055`) | Overlay đã ghi giá trị user; MPE chỉ điền chỗ trống, không đè override |
| Control plane | Root CFGM `/Cloak/...` (từ ExtraData `VBoxInternal/Cloak/...`) | Không nằm dưới `/Devices` nên PDM không coi là device |
| Ghi kết quả | CFGM node thật `Devices/<dev>/0/Config/<key>` | Device đọc key như stock; key mới phải thêm code đọc + test |
| Validate cuối | `validateEffectiveConfig()` sau materialize, trước device construct | Bắt conflict do user override; không đè override |
| State guard | So seed/profile/manifest hash khi restore saved state/snapshot | Không trộn identity; mismatch fail rõ (xem §4.6.5) |
| Build contract | `BUILDIDENTITYMANIFEST` nhúng từ build | Profile không thể “khai” firmware/tính năng build không có |
| Device | Đọc CFGM key như hiện tại | Tái dùng cơ chế stock; không thêm device mới |

**Quyết định quan trọng:** MPE **không** sống trong VBoxDD. Nếu đặt ở VBoxDD thì mỗi device tự sinh giá trị → mất tính đồng bộ và mất tính ổn định (xem 4.6).

#### 4.5.3 Cấu trúc `MachineProfile`

```c
typedef enum CLOAKPROFILECLASS
{
    CLOAKPROFILE_DRAFT = 0,
    CLOAKPROFILE_RESEARCH_ONLY,
    CLOAKPROFILE_COMPATIBLE
} CLOAKPROFILECLASS;

typedef struct MACHINEPROFILE
{
    /* --- Identity nhà sản xuất / hệ điều hành --- */
    const char *pszSystemVendor;      /* "LENOVO"                    */
    const char *pszSystemProduct;     /* "ThinkPad T14 Gen 2"       */
    const char *pszSystemVersion;     /* "1.0"                       */
    const char *pszSystemFamily;      /* "ThinkPad T14 Gen 2"       */
    const char *pszSystemSKU;
    const char *pszSystemSerial;      /* DMI Type 1 serial           */
    const char *pszBiosVendor;        /* "LENOVO"                    */
    const char *pszBiosVersion;       /* "N2HET52W (1.50)"          */
    const char *pszBiosReleaseDate;   /* "20230201"                 */
    const char *pszBoardVendor;       /* "LENOVO"                    */
    const char *pszBoardProduct;      /* "20XW004VGE"                */
    const char *pszBoardSerial;       /* DMI Type 2 serial           */
    const char *pszChassisVendor;     /* "LENOVO"                    */
    const char *pszChassisType;       /* "Notebook"                 */
    const char *pszChassisSerial;     /* DMI Type 3 serial           */
    const char *pszProcManufacturer;  /* "GenuineIntel"             */

    /* --- Firmware / ACPI --- */
    const char *pszAcpiOemId;         /* "LENOVO"                   */
    const char *pszAcpiCreatorId;     /* profile-derived            */
    const char *pszAcpiOemTabId;      /* profile-derived            */
    const char *pszMpsOemId;          /* profile-derived            */
    const char *pszMpsProductId;      /* profile-derived            */
    const char *pszAcpiDmiOemId;      /* profile-derived; không ACRSYS mặc định */
    const char *pszAcpiDmiOemTabId;   /* profile-derived            */
    const char *pszBiosRomVendor;     /* build-time family          */

    /* --- CPU --- */
    const char *pszGuestCpuName;      /* "i7-1165G7"                */
    const char *pszCpuBrandString;    /* "Intel(R) Core(TM) i7-1165G7 CPU @ 2.80GHz" */

    /* --- Chipset (phải cùng đời với CPU; xem O5) --- */
    uint16_t    uI440FxVendorId;      /* 0x8086                     */
    uint16_t    uI440FxDeviceId;      /* 0x1237 — stock, không fake  */
    uint16_t    uPiix3IsaDeviceId;    /* 0x7000 — stock, không fake  */
    uint16_t    uXhciDeviceId;        /* profile-derived, verify     */
    uint16_t    uAhciDeviceId;        /* profile-derived, verify     */
    uint16_t    uAcpiPmDeviceId;      /* 0x7113                     */
    uint16_t    uHdaDeviceId;         /* 0x2668                     */
    uint16_t    uOhciDeviceId;        /* profile-derived, verify     */

    /* --- GPU --- */
    uint64_t    uGpuModelId;          /* VID<<48|DID<<32|SVID<<16|SID; binding-aware */
    const char *pszVbeVendor;         /* build-time; validate C4, không materialize */
    const char *pszVbeProduct;        /* build-time; validate C4    */
    const char *pszEdidManufacturer;  /* "DEL" / "SAM" / "BNQ"      */
    const char *pszEdidModel;
    const char *pszEdidSerial;

    /* --- Storage --- */
    const char *pszAtaModel;          /* "Samsung PRO 970"          */
    const char *pszAtapiVendor;       /* "Samsung"                  */
    const char *pszAtapiProduct;      /* "CD-ROM"                   */
    const char *pszInquiryVendor;     /* "Samsung"                  */
    const char *pszInquiryProduct;    /* "Extreme"                  */
    const char *pszStorageSerial;     /* serial ổ đĩa/ata/ahci       */
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

    /* --- Binding identity: build-level, phải khớp GA --- */
    uint16_t    uVmmDevVendorId;      /* 0x80EE — mặc định giữ      */
    uint16_t    uVmmDevDeviceId;      /* 0xCAFE — mặc định giữ      */

    /* --- Compatibility / build manifest --- */
    CLOAKPROFILECLASS enmClass;       /* COMPATIBLE/RESEARCH_ONLY   */
    uint32_t    fSupportedChipsets;   /* i440fx | piix3 | ich9      */
    const char *pszRequiredFirmwareFamily; /* khớp manifest          */
    const char *pszSourceModel;       /* model máy thật             */
    const char *pszSourceBiosDate;    /* ngày BIOS nguồn            */
    const char *pszProvenanceHash;    /* hash dump nguồn            */
} MACHINEPROFILE;
```

#### 4.5.4 Profile registry

**Trạng thái registry: 0 profile production đang active.** Không đưa profile chưa kiểm chứng vào registry. Ba profile dưới đây chỉ là **candidate/DRAFT**, không được selectable cho tới khi O4 hoàn tất:

| Candidate ID | Họ máy | Dữ liệu bắt buộc phải verify | Class | Trạng thái |
|---|---|---|---|---|
| `profile-lenovo-t14-g2-intel` | ThinkPad T14 Gen 2 Intel — Tiger Lake 11th gen (i5-1135G7/i7-1165G7), MX450 tùy cấu hình | SKU, BIOS/EC, SMBIOS, ACPI, PCI, EEPROM, EDID, storage | chưa phân loại | `DRAFT` |
| `profile-dell-latitude-5xxx` | Latitude 5xxx — 10th/11th gen U/H, không dùng CPU desktop | Model/SKU chính xác, BIOS, SMBIOS, ACPI, PCI | chưa phân loại | `DRAFT` |
| `profile-lenovo-t14-g3-amd` | ThinkPad T14 Gen 3 AMD — Ryzen 7 PRO 6850U (Rembrandt, Zen 3+, Radeon 680M) | SKU, BIOS/EC, SMBIOS, ACPI, PCI, EEPROM | chưa phân loại | `DRAFT` |

**Phân loại profile (bắt buộc trước khi selectable):**

| Class | Vai trò | Điều kiện |
|---|---|---|
| `COMPATIBLE` | Production: device model, firmware family và identity công bố tương thích | Provenance đầy đủ + manifest khớp + không có STRICT violation + device feasibility đã test |
| `RESEARCH_ONLY` | Đo sai khác, thử nghiệm | Có residual đã biết; **không selectable** cho production/release |
| `DRAFT` | Chưa đủ dữ liệu | Không selectable; chỉ lint offline |

**Các giá trị sai đã bị loại khỏi plan:**
- i7-9750H là Coffee Lake Refresh 9th gen, **không phải** Cascade Lake; không dùng trong T14 Gen 2.
- T14 Gen 2 Intel là Tiger Lake 11th gen, **không phải** i7-9750H + GV100.
- GV100 là GPU Volta datacenter/workstation, không có trong laptop T14.
- Ryzen 7 PRO 6850U là Rembrandt/Zen 3+/Radeon 680M, **không phải** Phoenix hay Raphael.
- i5-10400 là CPU desktop Comet Lake LGA1200, không dùng cho Latitude laptop.
- `0400:1237`, `8086:0484`, `85F0:1043`, `10EC:1048` là các tuple sai/không coherent; xem §3.5 và §4.5.8.

**Quy tắc bắt buộc khi thêm profile:**
1. Mỗi field phải có nguồn thật: dump `dmidecode`/`acpidump`/`lspci -nnvv`/`smartctl`/`ethtool -e`/EDID, kèm model + BIOS version + ngày.
2. Không ghép field từ nhiều máy. Không suy đoán CPU/chipset/GPU.
3. Phân loại `COMPATIBLE`/`RESEARCH_ONLY`; chỉ `COMPATIBLE` được selectable ở runtime. Registry linter từ chối `DRAFT` và `RESEARCH_ONLY` trong production.
4. `COMPATIBLE` phải chứng minh **device feasibility**: chipset VirtualBox hỗ trợ, firmware family khớp build manifest, binding ID khớp driver, không có STRICT violation.
5. Nếu không tìm được profile laptop hợp với chipset VirtualBox đang mô phỏng, chuyển sang profile desktop/workstation hoặc ghi nhận residual — xem O5. Profile chỉ “đúng trên giấy” nhưng không chạy được trên device model phải là `RESEARCH_ONLY`.
6. Phase 1.0 chỉ dùng `test-profile-synthetic` trong unit test.

Mỗi profile production là **một hàng dữ liệu literal** trong `ConsoleImplConfigCloak.cpp`; thêm profile mới = thêm 1 hàng + nguồn chứng minh.

#### 4.5.5 Thứ tự materialize

```
i_configConstructorX86()
  │
  ├─ [A] i_configCfgmOverlay()            ← ExtraData của user
  │      (ConsoleImplConfigCommon.cpp:680; gọi ở ConsoleImplConfigX86.cpp:2055)
  │      → ghi /Cloak/... và /Devices/<dev>/0/Config/...
  │
  ├─ [B] MPE đọc control plane tại root CFGM:
  │      /Cloak/Enabled, /Cloak/Profile, /Cloak/Seed
  │      ├─ nếu tắt → return, không materialize
  │      ├─ seed = KDF(CloakSeed, VM UUID)  (xem 4.6)
  │      └─ profile = registry[prng.pickProfile()]
  │
  ├─ [C] MPE materialize vào node THẬT:
  │      /Devices/<dev>/0/Config/<key>
  │      (chỉ set nếu key CHƯA tồn tại → user overlay thắng)
  │
  └─ [D] validateEffectiveConfig() đọc CFGM THỰC TẾ sau materialize
         → effective identity = profile + user override
         → strict conflict: fail; heuristic conflict: warn + residual
```

**Thứ tự bắt buộc A → B → C → D.** MPE chạy **sau** overlay và **trước** device construction. Với mỗi key, MPE dùng `CFGMR3Query*` để kiểm tra; nếu user đã set thì bỏ qua. Không đọc lại ExtraData lần hai.

**Vì sao cần [D]:** nếu chỉ validate `MACHINEPROFILE`, user override có thể làm cấu hình cuối mất coherent (ví dụ profile Intel nhưng user đổi ACPI OEM ID sang hãng khác) mà MPE vẫn coi profile hợp lệ. `validateEffectiveConfig()` đọc **giá trị CFGM thực tế** (không phải profile gốc), chạy lại các rule C1–C13 trên `EFFECTIVEIDENTITY`.

Quy tắc conflict:
- `STRICT`: fail-fast, log rõ key, giá trị profile, giá trị effective, rule bị vi phạm.
- `HEURISTIC`: warning + ghi residual; không fail nếu không có allowlist chứng minh.
- **Không bao giờ** âm thầm ghi đè override của user. Nếu user muốn cấu hình ngoài profile, họ phải chọn một profile `COMPATIBLE` khác hoặc tắt cloak; `RESEARCH_ONLY` chỉ dùng cho test/đo sai khác.
- Không ghi `CloakSeed`/ExtraData từ bước này; chỉ đọc CFGM.

`EFFECTIVEIDENTITY` tối thiểu gồm: DMI Type 1/2/3, ACPI OEM/creator/table ID, CPUID leaf/reg, PCI VID/DID/SVID/SDID, storage INQUIRY/flags, NIC EEPROM, EDID, TPM vendor, HVP/GIM. Đây là input cho C1–C13, không phải `MACHINEPROFILE` gốc.

**Không dùng `Devices/cloak/0/Config`.** `PDMR3Device.cpp:158-202` duyệt child của `/Devices` và coi tên child là PDM device; `cloak` sẽ fail với `VERR_PDM_DEVICE_NOT_FOUND`. Control plane dùng root `/Cloak/...`; metadata không bao giờ nằm dưới `/Devices`.

**Ranh giới với firmware/build-time asset:** MPE chỉ điều khiển các key runtime. DSDT, PC BIOS ROM, VGA BIOS ROM, OVMF và các literal build-time khác **không** do MPE sinh ra; xem §4.5.9.

**Nghiệm thu materialize:** không dùng `VBoxManage showvminfo` (nó không đọc CFGM nội bộ). Dùng `debugvm <vm> info pci verbose` + DMI/ACPI collector trong guest; nếu cần debug nội bộ, thêm một debug-info item `cfgm` (test-only) hoặc log có kiểm soát. Nghiệm thu [D] phải chứng minh user override vẫn thắng nhưng conflict STRICT bị chặn.

#### 4.5.6 Bộ luật coherence (validate lúc build-time hoặc run-time)

| # | Luật | Mức | Ví dụ / ghi chú |
|---|---|---|---|
| C1 | CPU đời ↔ chipset đời | `STRICT` nếu profile khai báo mapping; nếu không, `HEURISTIC` | CPU Core2 (model 15) + chipset 8xx; không dùng equality đơn giản |
| C2 | chipset vendor ↔ i440FX vendor | `STRICT` | CPU AMD Ryzen + i440FX `8086:1237` (Intel); hoặc `8086:1237` + xHCI `1022:...` (AMD) |
| C3 | ACPI OEM/creator ↔ SMBIOS/firmware | `HEURISTIC` + allowlist | ACPI `ASUS` + SMBIOS `LENOVO` chỉ fail nếu không có trong bảng tổ hợp đã chứng minh |
| C4 | GPU PCI ↔ VBE build-time asset | `STRICT` | PCI `10DE` + VBE build `NVIDIA`; build VBE AMD + GPU NVIDIA = fail |
| C5 | Storage model family ↔ INQUIRY ↔ nonrotational/TRIM/SMART | `STRICT` | Model `Samsung PRO 970` + INQUIRY `VBOX` |
| C6 | NIC PCI subsystem ↔ EEPROM ↔ INF | `STRICT` | PCI `1043:85F0` ↔ EEPROM `1043`/`85F0`; sai thứ tự field |
| C7 | TPM manufacturer ↔ CPU vendor | `HEURISTIC` | `INTC` + AMD có thể sai, nhưng dTPM ngoài cũng hợp lệ; cần allowlist |
| C8 | HDA codec ↔ chipset đời | `HEURISTIC` | Codec 2003-era + chipset 8xx |
| C9 | Storage controller ↔ CPU/chipset đời | `HEURISTIC` | AHCI `8086:8C82` (8-series) + CPU Tiger Lake (11th gen) |
| C10 | Monitor/EDID ↔ display identity | `HEURISTIC` | **Không** bắt buộc EDID manufacturer trùng GPU; monitor Dell + GPU NVIDIA là hợp lệ |
| C11 | HVP bit ↔ hypervisor vendor/leaves ↔ GIM provider | `STRICT` | HVP=0 nhưng leaf `0x40000000` trả `Microsoft Hv`; hoặc `Hidden` nhưng GIM HyperV |
| C12 | Binding identity ↔ driver/INF | `STRICT` | VMMDev `8086:1551` nhưng `VBoxGuest.inf` vẫn `80EE:CAFE`; VGA NVIDIA ID nhưng WDDM vẫn match `80EE:BEEF` |
| C13 | Profile provenance + class + build manifest | `STRICT` | Field không có nguồn/model/BIOS/ngày; `DRAFT`/`RESEARCH_ONLY` selectable ở production; manifest family không khớp |

`STRICT` = fail-fast; `HEURISTIC` = warning + residual, không tự sửa; `INFO` = chỉ ghi nhận. Profile `COMPATIBLE` không được có `STRICT` violation; `HEURISTIC` violation phải có waiver kèm nguồn. `RESEARCH_ONLY` được phép có residual nhưng không selectable cho production.

#### 4.5.6.1 Test độc lập cho từng rule

Mỗi rule phải có unit test offline **và** một ca runtime tương ứng; test phải chứng minh cả positive (hợp lệ) lẫn negative (bị chặn/cảnh báo), không chỉ test một chiều:

| Rule | Positive | Negative |
|---|---|---|
| C1 | CPU/chipset cùng thế hệ trong allowlist | CPU Core2 + chipset 8xx |
| C2 | CPU Intel + i440FX `8086:1237` | CPU AMD + i440FX Intel |
| C3 | Cặp Lenovo/AMI đã có nguồn | Cặp không có trong allowlist |
| C4 | GPU NVIDIA + VBE build NVIDIA | GPU AMD + VBE build NVIDIA |
| C5 | Samsung model + Samsung INQUIRY + SSD flags | Model Samsung + INQUIRY VBOX |
| C6 | E1000 subsystem/EEPROM đúng thứ tự | EEPROM đảo SVID/SID |
| C7 | Intel CPU + INTC PTT | AMD profile + TPM `INTC` không có nguồn |
| C8 | HDA codec cùng đời chipset | Codec 2003 + chipset 8xx |
| C9 | AHCI ID cùng đời chipset | AHCI 8-series + CPU 11th gen |
| C10 | EDID Dell + GPU NVIDIA | EDID không có nguồn/không parse được |
| C11 | `Hidden` + không leaves; `HyperV` + leaves | HVP=0 + `Microsoft Hv`; `Hidden` + GIM HyperV |
| C12 | VMMDev `80EE:CAFE` + INF tương ứng | Đổi VMMDev nhưng không đổi INF/ký |
| C13 | Profile `COMPATIBLE` + manifest khớp | `DRAFT`/`RESEARCH_ONLY` selectable; manifest mismatch |

Test C1–C13 nằm trong unit test của MPE (không cần VM), chạy ở T1; các ca runtime tương ứng chạy ở T3. C12 là **blocking**: profile vi phạm không được selectable.

#### 4.5.7 Phạm vi của MPE so với plan ban đầu

MPE **thay thế** phần lớn giá trị đích cứng trong Phase 1-2. Cụ thể:

| Task cũ | Task mới |
|---|---|
| 1.7 đổi default DMI vendor/product | MPE `pszSystemVendor` / `pszBiosVendor` / … |
| 1.8 ACPI OEM/Creator theo profile | MPE `pszAcpiOemId` / `pszAcpiCreatorId` (không random) |
| 1.9 ACPI OEM Table ID | MPE `pszAcpiOemTabId` |
| 1.13 MPS rebrand | MPE `pszMpsOemId` / `pszMpsProductId` |
| 2.4-2.6 storage model | MPE `pszAtaModel` / `pszInquiryVendor` / … |
| 2.13 i440FX + PIIX3 | **Không fake**; giữ `8086:1237` / `8086:7000` trừ khi có device model mới |
| 2.14 VMMDev | **BindingIdentity**, build-level; mặc định giữ `80EE:CAFE` |
| 2.16/2.17 VirtIO | **Loại khỏi baseline**; không đưa vào MPE |
| 2.18 E1000 | MPE `uNicVendorId` / `uEepromSubVendor`; tuple `1043:85F0` |
| 2.19 TPM | MPE `pszTpmManufacturer` / `uTpmFirmwareV1`; defer PR-6 |

Các task **không** nằm trong MPE (vì phụ thuộc runtime device hoặc binding): 2.1 (GPU `GpuModelId` — chỉ dùng khi có WDDM strategy), 2.2 (VMSVGA caps), 2.8-2.10 (USB), 2.14 (VMMDev), 2.16/2.17 (VirtIO).

#### 4.5.8 Phân loại identity theo driver binding

Không phải mọi ID đều có thể random. Chia làm 3 lớp:

| Lớp | Surface | Quy tắc |
|---|---|---|
| **Binding cứng** | VMMDev `80EE:CAFE` (`VBoxGuest.inf`, `VBoxGuest-linux.c`), VGA/WDDM `80EE:BEEF` (`VBoxWddm.inf:48`), VirtIO `1AF4:*` | **Build-level**. Chỉ đổi một lần toàn cục, cùng PR với driver/INF tương ứng và ký lại. Không random theo profile |
| **Binding mềm** | AHCI/xHCI/HDA/E1000 primary ID; GPU `GpuModelId` | Chỉ chọn từ allowlist đã test với driver stock/WHQL; profile linter kiểm tra. Nếu không chắc, giữ stock |
| **Cosmetic** | Subsystem ID, DMI/ACPI string, serial, EDID, UUID, MAC OUI | Có thể random theo VM; không được làm đổi driver binding |

Quy tắc tuyệt đối:

1. `VMMDev` và `VGA` primary ID **không** là field random của profile; nếu profile chứa giá trị khác build-level thì linter từ chối.
2. `VirtIO` vendor `1AF4` là contract của driver virtio; đổi sang `10EC` phá Linux `virtio_pci` và Windows NetKVM/viostor. **Không port mặc định.**
3. Mọi thay đổi binding cứng phải có test: Windows PnP không yellow-bang + GA service chạy; Linux `dmesg` không lỗi probe + `lspci -k` thấy driver đúng.
4. Đổi GA driver/INF mà không ký lại là **không hợp lệ** trên Windows 10/11 + Secure Boot.

#### 4.5.9 Build-time asset và nghĩa của `CloakEnabled=off`

`CloakEnabled=off` **không** làm binary trở lại stock. Phân lớp rõ:

| Lớp | Ví dụ | Tắt runtime được? |
|---|---|---|
| Runtime CFGM | DMI/ACPI/MPS values, serial, EDID, HDA codec | ✅ |
| Build-time asset | `vbox.dsl`, PC BIOS ROM, VGA BIOS ROM, OVMF branding | ❌ |
| Driver/INF | tên GA, PCI match ID, service name | ❌ (phải rebuild + ký) |

**Quyết định:** có hai build mode:
- `stock`: không patch asset build-time; dùng khi cần baseline.
- `cloak`: patch asset build-time; `CloakEnabled` chỉ điều khiển lớp runtime.

Mỗi mode sinh `BuildIdentityManifest` riêng; `CloakEnabled=true` chỉ hợp lệ với manifest `cloak`. Không hứa “off = stock”. Nếu cần per-VM asset, chỉ BIOS có cơ chế `BiosRom` (`DevPcBios.cpp:1650`); VGA BIOS/OVMF/DSDT chưa có cơ chế chọn per-VM đáng tin và **không** nằm trong baseline.

#### 4.5.10 Hypervisor presentation

Chọn đúng một mode trong `CloakHvPresentation` (xem bảng §3.1):

- `Hidden`: HVP=0; không vendor/leaves Hyper-V; GIM `Minimal`/không GIM; phải kiểm tra CPUID.1, `0x40000000..0x40000006`, MSRs và timing.
- `HyperV`: HVP=1; vendor `Microsoft Hv`; leaves đầy đủ; GIM `HyperV`; chỉ dùng khi profile khai báo VBS/Hyper-V.
- `HVP=0` + vendor Hyper-V = **fail**. `Hidden` + GIM HyperV = **fail**.
- Task 1.1 và 1.2 là một PR/one design, không merge riêng lẻ.

#### 4.5.11 BuildIdentityManifest

Một profile runtime không thể tự chứng minh nó khớp với asset build-time. Thêm manifest sinh lúc build và nhúng vào binary/artifact:

```c
typedef struct BUILDIDENTITYMANIFEST
{
    const char *pszBuildMode;          /* "stock" | "cloak" */
    const char *pszFirmwareFamily;     /* LENOVO/AMI, Dell/AMI, ... */
    const char *pszPcBiosVersion;
    const char *pszOvmfVersion;
    const char *pszDsdtHash;           /* SHA-256 */
    const char *pszVgaBiosHash;        /* SHA-256 */
    const char *pszBiosRomHash;        /* SHA-256 */
    uint32_t    fSupportedChipsets;    /* i440fx | piix3 | ich9 */
    uint16_t    uVmmDevVendorId;
    uint16_t    uVmmDevDeviceId;
    uint16_t    uVgaVendorId;
    uint16_t    uVgaDeviceId;
    uint16_t    uVirtioVendorId;
    const char *pszSourceRevision;     /* git sha */
    const char *pszBuildHash;          /* SHA-256 của các field trên, không gồm chính nó */
} BUILDIDENTITYMANIFEST;
```

Nguồn manifest:
- Sinh bởi build system (`Config.kmk`/kBuild) hoặc script build; ghi `build-identity.json` vào artifact.
- Nhúng bản read-only vào `VBoxC`/`VBoxRT` để runtime đọc; không đọc file bên ngoài.
- `pszBuildHash` bao gồm source revision + hash asset + build mode.

MPE kiểm tra trước khi materialize:
1. `pszBuildMode` phải là `cloak` khi `CloakEnabled=true`; build `stock` không được nhận profile cloak.
2. `pszRequiredFirmwareFamily` phải khớp `pszFirmwareFamily`.
3. `fSupportedChipsets` của profile phải là tập con của manifest.
4. Binding ID trong profile phải khớp manifest (VMMDev/VGA/virtio).
5. Manifest mismatch với profile `COMPATIBLE` → fail; với `RESEARCH_ONLY` → fail trừ khi test-only override có log rõ và không selectable production.
6. `VBoxInternal/Cloak/Profile` **không** được bỏ qua các kiểm tra trên.

Test bắt buộc: manifest khớp; manifest sai family; manifest sai chipset; manifest `stock` + cloak; manifest hash sai. T1 đọc `build-identity.json` và so với binary/expected; T3 đọc runtime manifest qua debug info.

---

### 4.6 Selector ổn định (quyết định #3: random nhưng không đổi khi mở lại VM)

#### 4.6.1 Yêu cầu

- Mỗi VM có **bộ identity riêng**, trông ngẫu nhiên → không bị detector đoán theo profile cố định.
- **Mở lại VM → giá trị y hệt** → không "nhảy" giá trị mỗi lần boot.
- VM khác → bộ giá trị khác.

#### 4.6.2 Nguồn seed

| Ứng viên | Ổn định? | Nhận xét |
|---|---|---|
| **`CloakSeed`** (32 byte, ExtraData host-side) | ✅ | **Seed gốc**. Provision một lần bằng CSPRNG; không regenerate mỗi boot |
| **VM UUID** (`pMachine->getId()` / config `UUID`) | ✅ | **Salt**, không phải secret; guest có thể đọc SMBIOS UUID. Dùng trong KDF để clone/migration đổi identity |
| Đường dẫn file `.vbox` | ❌ | Đổi khi move VM |
| Timestamp | ❌ | Đổi mỗi lần |
| `RTRandCreateSystem()` | ❌ | Không seedable → không tái lập được |

→ **Seed gốc = `CloakSeed`; VM UUID là salt.** Không dùng VM UUID làm seed duy nhất: UUID thường liên hệ SMBIOS UUID guest-visible, nên nếu algorithm biết được thì toàn bộ identity có thể tái tạo.

**Lưu trữ `CloakSeed`:**
- Key: `VBoxInternal/Cloak/Seed` (ExtraData host-side; overlay thành `/Cloak/Seed` ở CFGM root, **không** vào SMBIOS hay node device).
- Metadata: `VBoxInternal/Cloak/SeedHash`, `.../ProfileId`, `.../ManifestHash`; dùng cho state guard §4.6.5.
- **Chỉ sinh ở bước provision**, không sinh trong `i_configConstructorX86()`/MPE startup.
- Không hiển thị qua `VBoxManage showvminfo`; đọc/ghi qua ExtraData. Không log giá trị seed.
- Backup/restore seed cùng `.vbox`; seed mất → VM fail cho tới khi provision lại; provision lại sẽ đổi các field seed-derived.

**Cảnh báo bảo mật:** ExtraData **không phải** secret store. Người dùng/tiến trình có quyền quản lý VM hoặc đọc `.vbox` có thể đọc seed. Threat model chỉ chống guest và detector bên ngoài, **không** chống host admin. Nếu cần chống host, phải dùng DPAPI/credential store riêng — ngoài baseline.

#### 4.6.2.1 Provision seed vs consume seed

Tách tuyệt đối hai pha:

| Pha | Thời điểm | Hành vi |
|---|---|---|
| **Provision** | VM powered off, trước `startvm` | Sinh `CloakSeed` 32 byte bằng CSPRNG; persist qua `IMachine::setExtraData` hoặc CLI provision; verify đọc lại thành công |
| **Consume** | `i_configConstructorX86()` | Chỉ đọc `/Cloak/Seed`; không ghi ExtraData; dùng seed + UUID salt để materialize |

Lý do: `MachineImpl.cpp:4529-4532` từ chối `setExtraData` nếu không phải session machine; `:4559-4571` thực hiện save settings dưới lock. Ghi cấu hình trong constructor dễ fail, bị veto bởi `i_onExtraDataCanChange`, hoặc tạo trạng thái dở dang.

Đường provision:
- CLI host-side `VBoxManage cloak provision <vm>` (VM off) gọi helper Main API; không log seed.
- UI action “Provision cloak seed” có thể thêm ở PR-5, dùng cùng helper.
- Không expose seed qua `showvminfo` hay Guest Control.

Quy tắc:
- `CloakEnabled=true` + seed thiếu/rỗng/sai kích thước → **fail** với diagnostic rõ (“run cloak provision first”); **không** fallback sang VM UUID.
- `CloakEnabled=false` → không cần seed.
- Provision phải idempotent: nếu seed đã tồn tại, không ghi đè trừ khi `--force`/re-seed rõ ràng.
- Test dùng seed cố định qua test harness, không dùng seed production.
- Provision/consume phải có test cho: thiếu seed, seed sai độ dài, seed bị sửa, seed bị xóa, VM đang chạy.

#### 4.6.3 Thuật toán

```
CloakSeed = 32 bytes CSPRNG, lưu ExtraData VBoxInternal/Cloak/Seed

// trộn secret + UUID: UUID là salt, không phải secret
seed64 = first8( HMAC-SHA-256( CloakSeed, "VBoxCloakProfile" || VM_UUID_16_bytes ) )

// tách stream độc lập, mỗi stream 1 mục đích
stream_profile = splitmix64(seed64 + 0x01)
stream_serial  = splitmix64(seed64 + 0x02)
stream_jitter  = splitmix64(seed64 + 0x03)
```

- Dùng HMAC-SHA-256 (hoặc KDF tương đương có trong VBoxRT). `splitmix64` chỉ để mở rộng stream, không phải nguồn bí mật.
- **Không** dùng `FNV1a64(VM_UUID)` làm seed duy nhất.
- **Không** đưa `CloakSeed` vào bất kỳ DMI/ACPI/CFGM device value nào.

**Quy tắc bắt buộc:** chỉ materialize **một lần** trong MPE, rồi ghi kết quả vào CFGM. **Không** tính lại ở nhiều nơi — nếu thứ tự gọi khác nhau (thêm/bớt 1 lần gọi) thì các giá trị phía sau **đổi hết** → mất tính ổn định. Vì vậy:
- PRNG **chỉ** nằm trong MPE (VBoxC).
- Device chỉ đọc giá trị đã materialize từ CFGM.
- Không còn ngoại lệ virtio-net DID, vì 2.16/2.17 đã bị loại khỏi baseline.

**Vòng đời seed:**

| Tình huống | Hành vi |
|---|---|
| Bật cloak lần đầu | **Provision** (VM off): sinh `CloakSeed`, persist, verify |
| Mở lại VM | **Consume** seed cũ; không regenerate, không ghi ExtraData |
| Clone bằng `VBoxManage clonevm` | Nếu UUID mới → seed64 khác → các field seed-derived khác; hardware/firmware cố định giữ nguyên |
| Clone giữ nguyên UUID | Identity giữ nguyên; phải ghi rõ trong test |
| Export/import giữ UUID | Identity giữ nguyên |
| Export/import đổi UUID | Các field seed-derived đổi; đây là “máy mới” |
| Re-seed | Chỉ các field sinh từ seed đổi; CPU/chipset/firmware/build-time asset **không** đổi |

#### 4.6.4 Xác minh tính ổn định

Test bắt buộc:

| Test | Cách |
|---|---|
| Cùng VM, mở lại 3 lần | Giá trị identity giống hệt nhau (so `debugvm info pci verbose` + DMI/ACPI collector) |
| Clone bằng `VBoxManage clonevm` (new UUID) | Identity **khác**; không dùng test copy `.vbox` + disk thủ công |
| 2 VM trong 1 lần build | Bộ giá trị khác nhau, không trùng lặp |
| Re-seed (`CloakSeed` mới) | Chỉ các field seed-derived đổi; CPU/chipset/firmware/build asset không đổi |
| Xóa seed | Fail rõ ràng; yêu cầu provision lại; không tự sinh, không dùng UUID |
| Migration giữ UUID | Identity giữ nguyên |
| Migration đổi UUID | Các field seed-derived đổi có kiểm soát |

#### 4.6.5 Saved state, snapshot và migration

Identity phải ổn định không chỉ qua cold boot mà còn qua saved state/snapshot; nếu không, VM có thể mang DMI từ profile A nhưng PCI/device từ profile B.

Contract:
- Khi materialize lần đầu, ghi `VBoxInternal/Cloak/SeedHash`, `VBoxInternal/Cloak/ProfileId`, `VBoxInternal/Cloak/ManifestHash` vào ExtraData + metadata runtime state.
- Khi restore saved state/snapshot: so hash với cấu hình hiện tại **trước** device construct.
- Khớp → tiếp tục, không materialize lại.
- Không khớp → fail với diagnostic rõ; chỉ cho phép:
  - discard saved state/snapshot và cold boot lại, hoặc
  - provision/re-seed có chủ đích, hoặc
  - chọn đúng profile/manifest cũ.
- Không tự sinh seed mới, không tự chọn profile khác, không “best effort” trộn identity.
- Export/import: seed + hash phải đi cùng `.vbox`; nếu thiếu → fail. UUID giữ nguyên → identity giữ; UUID đổi → chỉ field seed-derived đổi.

Test bắt buộc:

| Test | Kỳ vọng |
|---|---|
| Save state → restore, không đổi gì | Identity giống hệt |
| Save state → đổi seed/profile → restore | Fail rõ; không trộn |
| Snapshot → restore, không đổi gì | Identity giống hệt |
| Snapshot → đổi seed/profile → restore | Fail rõ hoặc yêu cầu discard |
| Export/import giữ UUID | Identity giữ nguyên |
| Export/import đổi UUID | Field seed-derived đổi có kiểm soát |

Task implementation: `1.0.12` (state guard + hash) và test T3 `0.4.3c`.

#### 4.6.6 Cách ép 1 profile cụ thể (cho test)

Cần cơ chế override, nếu không sẽ không test được từng profile:

```
ExtraData: VBoxInternal/Cloak/Profile = test-profile-synthetic
```

Khi key này có mặt → MPE **bỏ qua** PRNG profile, dùng profile cố định. Giá trị random (serial, jitter) vẫn lấy từ PRNG → vẫn ổn định. Profile `DRAFT`/`RESEARCH_ONLY` bị từ chối ở production; manifest family/chipset/binding vẫn phải khớp. Trong giai đoạn O4 chỉ `test-profile-synthetic` dùng được cho test.

---

### 4.7 CI bằng GitHub Actions (quyết định #4)

> **Trạng thái hiện tại (2026-10-22):** `.github/workflows/build.yml` đã được commit, hiện **1000 dòng**, checkout đúng repo `${{ github.repository }}`, trigger đã có `feature/cloak*` và `pull_request`.
> Các mục 4.7.1-4.7.3 mô tả workflow hiện tại; 4.7.4 mô tả 3 tầng kiểm chứng; 4.7.9 là **lịch sử lỗi đã xử lý**, không phải trạng thái hiện tại.

#### 4.7.1 Workflow hiện có — `.github/workflows/build.yml`

| Thuộc tính | Giá trị |
|---|---|
| Tên | `Build VirtualBox 7.2 (Windows x64)` |
| Trigger | `workflow_dispatch`; `push`/`pull_request` → `main`, `VBox-7.2`, `feature/cloak*` |
| Runner | `windows-2022`, timeout 360 phút |
| Quyền | `contents: read` |
| Env | `VBOX_WITHOUT_ADDITIONS=1`, `VBOX_WITH_ADDITIONS_PACKING=""` |
| Output | `out\win.amd64\release\bin` |
| Jobs | `build`, `full-additions`, `smoke` |
| Artifact | `virtualbox-7.2-windows-amd64-binaries`, `virtualbox-windows-build-diagnostics`, `cloak-identity-report`, `virtualbox-guest-additions` |

Các bước (theo thứ tự trong file):

| # | Step | Nội dung |
|---|---|---|
| 1 | Checkout | `repository: ${{ github.repository }}`, `fetch-depth: 1`, `submodules: recursive` |
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

#### 4.7.3 Checkout và trigger — ĐÃ SỬA

Không còn lỗi build upstream. Trạng thái hiện tại:

- `.github/workflows/build.yml:42` dùng `repository: ${{ github.repository }}`.
- Trigger có `main`, `VBox-7.2`, `feature/cloak*` cho cả `push` và `pull_request`.
- `source-revision.txt` ghi repo/ref/sha vào artifact.

**Không tái đưa** `repository: VirtualBox/virtualbox` trở lại. Nếu cần kiểm tra, xem `source-revision.txt` trong artifact; nếu `source_repo` không phải repo hiện tại → fail CI.

#### 4.7.4 Ba tầng kiểm chứng (thay cho smoke chạy VM trên hosted runner)

GitHub-hosted `windows-2022` **không có `VBoxDrv`** và **không có nested virtualization**. Vì vậy không được coi `smoke` xanh là bằng chứng runtime.

| Tầng | Runner | Nội dung | Gate |
|---|---|---|---|
| **T1 — Build/static/binary** | `windows-2022` | Build; `scan-identity.ps1` quét string trong `VBoxDD.dll`, `VBoxVMM.dll`, `VBoxC.dll`, `VirtualBox.exe`; so baseline; kiểm `build-identity.json` | Mọi PR |
| **T2 — Config plane** | `windows-2022` | `VBoxManage createvm` + `setextradata` + `showvminfo --machinereadable`; không cần `VBoxDrv` | Mọi PR |
| **T3 — Runtime identity** | self-hosted Windows bare-metal có `VBoxDrv` + VT-x | Boot VM **3 lần** trên cùng VM; host `debugvm` + guest collector Windows/Linux; schema comparator; negative tests | PR-2/PR-3/PR-6 và release |

Quy tắc:
- `smoke` trên hosted runner chỉ là T1+T2. Không gọi là “identity verification”.
- T3 phải là job riêng `t3-runtime` trên self-hosted runner; **không** chạy trong `smoke`, không fallback sang hosted. Thiếu `VBoxDrv`/VT-x → **fail**, không skip.
- T3 boot **3 lần** liên tiếp trên cùng VM: boot 1 lấy baseline, boot 2 và 3 phải giống hệt boot 1; nếu bất kỳ boot nào khác → fail.
- T3 phải có ít nhất **1 guest Windows + 1 guest Linux**, vì binding VMMDev/VGA/virtio có thể khác nhau theo GA/driver.
- `showvminfo` không đọc CFGM nội bộ; T3 dùng `debugvm <vm> info pci verbose` + collector trong guest. Nếu cần kiểm tra materialize, thêm debug-info `cfgm` test-only.
- T3 chỉ có ý nghĩa khi guest thực sự boot tới userspace và collector chạy xong; “no bootable device” không phải T3.
- **Hiện trạng:** chưa có job `t3-runtime`, chưa có guest collector, script host chỉ chạy 2 lần; các task `0.4.3a–c` phải xong trước khi gate T3 có hiệu lực.

Yêu cầu VM cho T3:
- Guest Windows (PE/WinPE hoặc image test) và Linux live có disk ảo; T3 dùng VM có disk, **không** dùng chế độ no-disk của script host; `debugvm` chạy trên chính VM đó.
- Guest collector: Windows đọc WMI/registry/DMI/ACPI/PCI/EDID; Linux đọc `dmidecode`, `acpidump`, `lspci -nnvv`, `lsusb`, EDID, storage/NIC.
- Không dùng test “copy `.vbox` + disk” để kiểm tra clone; dùng `VBoxManage clonevm`.
- Guest không có shared folder/host credential; runner là máy chuyên dụng, không dùng production secrets.

#### 4.7.4.1 Fingerprint comparator (thay mask hex)

Script hiện tại mask `uuid:` và các chuỗi hex 8–16 ký tự; cách này có thể che cả PCI ID/CPUID/giá trị identity thật. T3 phải dùng comparator theo schema:

| Bước | Yêu cầu |
|---|---|
| Parse | Tách output collector thành field có kiểu: SMBIOS string, ACPI table/OEM ID, PCI BDF/VID/DID/SVID/SDID, CPUID leaf/reg, EDID block, storage INQUIRY, NIC EEPROM, TPM |
| Canonicalize | Chuẩn hóa thứ tự field, endianness, lowercase hex; **không** mask giá trị identity |
| Allowlist volatile | Chỉ bỏ field thật sự volatile (timestamp, uptime, session id, địa chỉ RAM) — danh sách nằm trong code, có review |
| Compare | So semantic equality; output diff theo field, không chỉ hash |
| Negative | Test cố ý đổi VID/DID, CPUID leaf, DMI serial, ACPI OEM ID → comparator **phải fail** |

Không dùng hash của raw text làm bằng chứng duy nhất; raw dump chứa serial/UUID và không được upload nguyên bản.

#### 4.7.4.2 T3 isolation & artifact protection

- Runner T3 là máy self-hosted chuyên dụng, network tối thiểu; không dùng runner dùng chung với workload khác.
- Artifact T3 có thể chứa serial/UUID/seed-adjacent data: chỉ upload **report đã redact**; raw dump giữ local có thời hạn, không đưa vào artifact công khai.
- Không đưa `CloakSeed`, `.vbox`, disk image hoặc dump DMI thô vào artifact.
- Artifact report phải ghi schema version, build hash, profile ID/class, boot count; retention ngắn và có access control.
- T3 fail vì artifact không đủ/không redact cũng là fail gate.

#### 4.7.5 Bổ sung: job `full-additions` (Guest Additions + WDK)

> **ĐÃ TRIỂN KHAI** — `.github/workflows/build.yml` (job `full-additions`) + `.github/scripts/install-wdk.ps1`

Job `build` đặt `VBOX_WITHOUT_ADDITIONS=1` → **không** build driver GA → PR-4 (đổi tên GA) không verify được. Job mới build lại toàn bộ với GA bật.

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
| Job build lại toàn bộ (~2-4h) | Chấp nhận được ở giai đoạn hiện tại; có thể tối ưu bằng `paths` filter khi PR-4 hoàn tất |

#### 4.7.6 Mapping PR → job

| PR | Job | Ghi chú |
|---|---|---|
| PR-1 `cloak-foundation` | `build` + T1/T2 | MPE/control plane, seed provision/consume, manifest skeleton, state guard; identity guest-visible **không đổi**; T3 differential bằng 0 khi T3 sẵn sàng (bắt buộc trước PR-2) |
| PR-2 `cloak-cpu-firmware` | `build` + T1/T2 + T3 | CPUID/HVP + DMI/ACPI/BIOS/VGA/EFI; cần T3 self-hosted 3 boot |
| PR-3 `cloak-devices` | `build` + T1/T2 + T3 | PCI/storage/USB/network; cần binding test Windows + Linux |
| PR-4 `cloak-ga-rename` | `full-additions` + lifecycle | Cần WDK; kiểm tra chữ ký, cài mới, upgrade, uninstall, rollback |
| PR-5 `cloak-provisioning` | `build` + guest integration | Đụng GUI (Qt); test quyền, rollback và guest state |
| PR-6 `cloak-coherence-tpm` | `build` + T3 | Residual coherence + TPM (2.19) + libtpms; không phải coherence lần đầu |

#### 4.7.7 Danh sách task CI cụ thể (Phase 0)

| # | Task | File | Trạng thái | Nghiệm thu |
|---|---|---|---|---|
| 0.3.1 | Commit workflow hiện có vào git | `.github/workflows/build.yml` | ✅ **đã commit** | `git ls-files .github/workflows` có file |
| 0.3.2 | Sửa checkout sang repo hiện tại + mở trigger `feature/cloak*` + `pull_request` | `.github/workflows/build.yml:3-14`, `:42` | ✅ **đã làm** | `source-revision.txt` có `source_repo` đúng |
| 0.3.3 | Thêm `setup-python` nếu thiếu | — | ⛔ **bỏ qua** | Python chỉ dùng cho macOS bindings; Windows build không cần |
| 0.3.4 | Cache `out/` để tăng tốc | — | ⛔ **bỏ qua (có lý do)** | kBuild so sánh timestamp; restore cache có thể build sai |
| 0.3.5 | Ghi `source-revision.txt` (repo/ref/sha) vào artifact | `.github/workflows/build.yml` | ✅ **đã làm** | Artifact diagnostics có file |
| 0.3.6 | `concurrency` để huỷ run cũ | `.github/workflows/build.yml:19-22` | ✅ **đã làm** | Push liên tiếp chỉ giữ run mới |
| 0.4.1 | T1/T2: scan binary + config plane | `.github/workflows/build.yml` + `.github/scripts/scan-identity.ps1`, `collect-identity.ps1` | ✅ **đã làm** | Artifact `cloak-identity-report` + `binary-identity.txt` |
| 0.4.1a | Verify `build-identity.json` + manifest nhúng | build + `.github/scripts/verify-manifest.ps1` | ⬜ **chưa làm** | Family/chipset/binding/hash khớp; mismatch fail |
| 0.4.2 | Thêm job `full-additions` + WDK | `.github/workflows/build.yml` + `.github/scripts/install-wdk.ps1` | ✅ **đã làm** | Xem [§4.7.5](#475-bổ-sung-job-full-additions-guest-additions--wdk) |
| 0.4.3 | T3 self-hosted runner + VM có disk | runner + `.github/workflows/build.yml` | ⬜ **chưa làm** | `t3-runtime` job; `VBoxDrv` + VT-x; fail nếu thiếu |
| 0.4.3a | Guest collector Windows + Linux | `.github/scripts/collect-guest-identity.ps1/.sh` | ⬜ **chưa làm** | Boot tới userspace; DMI/ACPI/PCI/EDID/storage/NIC |
| 0.4.3b | Schema comparator + negative tests | `.github/scripts/compare-identity.ps1` | ⬜ **chưa làm** | Không mask identity; negative test fail đúng |
| 0.4.3c | T3 3 boot + saved-state/snapshot test | T3 job | ⬜ **chưa làm** | 3 boot giống hệt; state restore không trộn identity |
| 0.4.4 | Gate T3 trên PR-2/PR-3/PR-6 | `.github/workflows/build.yml` | ⬜ **chưa làm** | Không có T3 xanh → không merge thay đổi identity |
| 0.4.5 | T3 artifact isolation/redaction | T3 job + script | ⬜ **chưa làm** | Report redact; không seed/.vbox/raw DMI trong artifact |

**Về script `collect-identity.ps1`** (`.github/scripts/collect-identity.ps1`):

| Đặc điểm | Chi tiết |
|---|---|
| Cơ chế | `VBoxManage debugvm <vm> info <item>` — 10 info item đã đăng ký qua `PDMDevHlpDBGFInfoRegister()`: `pci` (verbose), `acpi`, `vga`, `vbe`, `hda`, `ohci`, `xhci`, `vmsvga`, `lpc`, `hpet` |
| VM | Tạo headless **không có đĩa boot** → BIOS dừng ở "no bootable device" nhưng VMM vẫn sống → debugger info hoạt động |
| Phạm vi | Đây là **host-side collector**, không phải guest collector. Nó không đọc DMI/ACPI từ trong guest và không chứng minh guest-visible identity |
| Hardware UUID + `CloakSeed` | Cố định theo kịch bản → selector deterministic; không sinh seed mới trong test |
| Kiểm tra ổn định | T3 job gọi **3 lần** trên cùng VM (script cần hỗ trợ `--runs 3`; hiện tại chỉ 2), so schema fingerprint → fail nếu khác |
| Chuẩn hoá fingerprint | **Không dùng** mask hex hiện tại (`0x[0-9a-f]{8,16}` → `0xADDR`) vì có thể che PCI ID/CPUID/identity thật; thay bằng comparator §4.7.4.1 |
| Kịch bản | `ich9-bios` (mặc định), `piix3-bios` (`--chipset piix3`), `ich9-efi` (`--firmware efi`) — phủ cả 2 chipset và cả 2 đường DMI (pcbios/efi) |
| Runtime target | Headless không disk chỉ đủ cho debug info; T3 cần VM có disk Linux live/Windows PE để chạy collector trong guest |
| T3 variant | `collect-identity.ps1 -VmName <vm> --runs 3` gắn vào VM có disk do T3 job tạo; không tự tạo VM no-disk |
| Exit code | 0 = ổn định, 1 = không ổn định, 2 = lỗi môi trường; `-RequireRuntime` biến thiếu runtime thành fail. T3 **không được** chấp nhận exit 0 khi runtime thiếu |

> Script được upload thành artifact `cloak-ci-scripts` từ job `build` → job `smoke` **không cần checkout repo** (tránh clone lại ~1.4 GB).


#### 4.7.8 Vấn đề kỹ thuật còn lại

| # | Vấn đề | Xử lý |
|---|---|---|
| CI-1 | `CheckSourcePath` — path phải ASCII, không space | OK với runner mặc định |
| CI-2 | kBuild | Đã prebuilt trong repo — **không cần build** (đã xác minh qua step "Verify kBuild") |
| CI-3 | 32-bit OpenSSL/curl | Đã chạy được (workflow hiện tại build thành công) |
| CI-4 | WDK cho GA driver | `install-wdk.ps1` tải MSI/CAB 19041 trực tiếp; không dùng `choco install wdk`; vẫn có thể cần self-hosted nếu CDN đổi |
| CI-5 | Qt 6.8.0 download ~1 GB | `install-qt-action` đã có `cache: true` |
| CI-6 | RAM/CPU | `windows-2022` = 4 vCPU / 16 GB; timeout 360 phút đã đặt rộng |
| CI-7 | `env.bat` chứa đường dẫn tuyệt đối | Chạy `configure.vbs` **trong** job, không cache `env.bat` |
| CI-8 | `kmk` song song | `-j$([Environment]::ProcessorCount)` — đã có |
| CI-9 | Artifacts lớn | `upload-artifact` mặc định nén; cân nhắc `compression-level: 0` |
| CI-10 | Workflow build upstream | ✅ **đã sửa** — `build.yml:42` dùng `${{ github.repository }}` |
| CI-11 | `VBOX_WITHOUT_ADDITIONS=1` chặn PR-4 | 0.4.2 |
| CI-12 | `LocalConfig.kmk` bị ghi đè mỗi run | OK — file nằm trong `.gitignore`, sinh lại mỗi job |
| CI-13 | Hosted runner không có `VBoxDrv`/nested virt | T3 phải chạy self-hosted; `smoke` hosted chỉ T1/T2 |
| CI-14 | `collect-identity.ps1` skip runtime | Bắt buộc `-RequireRuntime` ở T3; không dùng exit 0 khi thiếu runtime |
| CI-15 | Chưa có job `t3-runtime`/guest collector trong workflow | Task `0.4.3a-c`; gate `0.4.4` |
| CI-16 | Comparator mask hex có thể che identity thật | Dùng schema comparator + negative tests §4.7.4.1 |
| CI-17 | T3 artifact có thể chứa serial/UUID | Redaction/isolation §4.7.4.2; không upload raw dump |

#### 4.7.9 Lịch sử lỗi CI và cách sửa

> **Đây là lịch sử, không phải trạng thái hiện tại.** Các lỗi dưới đây đã được xử lý; giữ lại để tránh tái phạm.
>
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

##### Lỗi C — run `39573977038`: layout của WDK **không có** `layout.exe`

```
==> Downloading WDK layout to D:\a\_temp\wdk-layout (~2 GB, goi 1 lan)
    wdksetup.exe /layout -> exit 0
Exception: install-wdk.ps1:183
  layout.exe not found under D:\a\_temp\wdk-layout - WDK layout is incomplete.
```

→ Giả định "layout của WiX Burn luôn có `layout.exe`" là **sai** với WDK 19041.

**Đã tìm ra cách đúng:** trích **Burn manifest** của `wdksetup.exe` (nằm trong PE section `.wixburn`,
UX container là file CAB). Manifest cho ra bảng **package → `KITSOPTION`**:

| Package | `KITSOPTION` (feature id) |
|---|---|
| `package_WindowsDriverKit_x86_en_us` | `OptionId.WindowsDriverKitComplete` |
| `package_WindowsDriverKitHeadersandLibs_x86_en_us` | `OptionId.WindowsDriverKitComplete` |
| `package_WindowsDriverKitBinaries_x86_en_us` | `OptionId.WindowsDriverKitComplete` |
| `package_WindowsDriverFrameworkHeadersandLibs_x86_en_us` | `OptionId.WindowsDriverKitComplete` |
| `package_WindowsDebuggingWDKIntegration_x86_en_us` | `OptionId.WindowsDriverKitComplete` |
| `package_WindowsDriverKitSxSContent_x86_en_us` | `OptionId.WindowsDriverKitComplete` |
| `package_OEMTestCertificates_x86_en_us` | `OptionId.WindowsDriverKitComplete` |
| **`package_Windows7WDKHeadersandLibs_x86_en_us`** | **`OptionId.WdkDownlevelContent`** |
| **`package_Windows8WDKHeadersandLibs_x86_en_us`** | **`OptionId.WdkDownlevelContent`** |
| **`package_Windows8.1WDKHeadersandLibs_x86_en_us`** | **`OptionId.WdkDownlevelContent`** |
| `package_WindowsDriverKitARM*` | `OptionId.WindowsDriverKitARMAddons` |
| `package_WindowsDriverKit*Dev16Content` | `OptionId.WDKVisualStudioDev16` |
| `package_WindowsDriverKitDownlevelDev14Content` | `OptionId.WDKVisualStudioDownlevel` |
| `package_SDKARM*` | `OptionId.ARMSoftwareDevelopmentKit` |
| `package_SDKDebuggersARM` | `OptionId.ARMWindowsDesktopDebuggers` |
| `package_MinimalWLPCContent` | `OptionId.MinWLPC` |
| `package_KitsConfigurationInstaller` | `OptionId.KitsConfiguration` |

→ **Fix cuối cùng (đã áp dụng):** cài trực tiếp với **cả hai** feature:

```powershell
wdksetup.exe /features OptionId.WindowsDriverKitComplete OptionId.WdkDownlevelContent /q /ceip off /norestart
```

Không cần layout nữa. Layout + `msiexec` chỉ còn làm **fallback** (phòng khi feature id đổi theo version).

##### Lỗi D — job `build` bị **cancelled** (không phải lỗi compile)

Run `39573977038`:
- `full-additions` fail lúc **09:05:38**
- `build` bị cancelled lúc **09:07:14** (đang compile OpenSSL)

Các dòng `kmk: *** [...crypto_asn1/p5_pbe.obj] Error 4 (0x4)` là **hậu quả** của việc `cl.exe` bị kill
(không có bất kỳ diagnostic nào của compiler) → không phải lỗi compile thật.

Đã xác nhận fix `VBOX_SVN_REV` **có hiệu lực**: log in ra `Using VBOX_SVN_REV = 115387` và lỗi
C2561 ở `buildconfig.cpp` **đã biến mất**; build tiến được tới bước compile OpenSSL.

Nguyên nhân cancel: khả năng cao là người dùng bấm "Cancel workflow" khi thấy job `full-additions` đỏ
(hoặc do `concurrency` khi có push mới). Không có lỗi disk / OOM trong log.

##### Ghi chú: toolset MSVC

Log cho thấy OpenSSL được compile bằng **MSVC 14.29.30133** (toolset VS2019) dù `msvc-dev-cmd` đã
đưa 14.44 (VS2022) vào `PATH` — vì kBuild tự dò toolchain qua `$(PATH_TOOL_MSVC_*)`, không dùng PATH
của action. Chưa có bằng chứng là vấn đề (không có diagnostic nào), nhưng nếu build OpenSSL lỗi thì
đây là điểm đầu tiên cần kiểm tra.

##### Lỗi E — run `39576116092`: job `build` **THÀNH CÔNG**, `full-additions` **TREO**

| Job | Kết quả | Thời gian |
|---|---|---|
| `build` | ✅ **success** (build VirtualBox đầy đủ) | 09:20:00 → 10:08:43 (48 phút) |
| `full-additions` | ⏳ **in_progress** — kẹt ở *"Install Windows SDK 10.0.19041 + WDK"* | > 50 phút |
| `smoke` | ❌ failure | 14 giây |

→ **Fix `VBOX_SVN_REV` đã được xác nhận hoạt động**: job `build` build thành công toàn bộ
VirtualBox (core + GUI Qt6 + driver deps). Đây là nền tảng cần thiết.

##### Lỗi J — run `39623216928`: kể cả `/layout` cũng treo (Modify UI)

```
==> Downloading WDK layout to D:\a\virtualbox\virtualbox\.wdk-layout (chi tai, khong apply)
    TIMEOUT after 2400 s - killing D:\a\_temp\wdksetup.exe
==> Layout contains 0 MSI package(s)
```

Burn log của lần này **giống hệt** lần trước:

```
i101: Detected package: package_WindowsDriverKit_x86_en_us, state: Obsolete
...
i000: Navigated to Microsoft.Bootstrapper.Presentation.LocationPage
i199: Detect complete, result: 0x0
```

→ **Burn luôn chạy Detect**, kể cả trong `/layout`; khi phát hiện version mới hơn đã cài thì plan thành
*Modify* → dùng **presentation BA** (có UI) → treo. **Layout của bundle này không dùng được trên
runner đã có WDK mới hơn.**

##### Lỗi K — giải pháp cuối: bỏ Burn hoàn toàn, tải MSI + CAB payload trực tiếp

**Phát hiện then chốt:** MSI của WDK **không self-contained** — nội dung nằm trong các file CAB
payload cùng thư mục. Test cục bộ (administrative install, **không** sửa hệ thống):

```
==> tải: Windows 7 WDK Headers and Libs-x86_en-us.msi (483 KB)
          b8805bec8f9c9005d982d0c9eb391b56.cab (16 KB)
          dcbcee8cf7426c70fe34947f02a5e2b9.cab (9.2 MB)
          655d2ea3e6730e0fb6db4507a52a03a7.cab (5.8 MB)
==> msiexec /a  ->  exit 0, extracted 166 files / 56.9 MB
    FOUND: Windows Kits\10\Lib\win7\km\x64\ntoskrnl.lib
    FOUND: Windows Kits\10\Lib\win7\km\x86\ntoskrnl.lib
```

(File `655d2ea3….cab` đúng là CAB mà Error 1311 đòi: *"Source file not found(cabinet)"*.)

**Cách lấy danh sách payload:** trích **Burn manifest** của `wdksetup.exe` — nằm trong PE section
`.wixburn`, UX container là file CAB, trong đó file `0` là manifest XML. Manifest cho `<Payload>`
với `FilePath="Installers\<tên file>"` cho từng package, và mọi payload đều ở
`https://download.microsoft.com/download/<GUID>/wdk/<FilePath>`.

**Kết quả (đã kiểm tra HEAD 36/36 file → 0 lỗi):**

| Package | Số payload | Dung lượng | Cài được |
|---|---:|---:|---|
| Windows Driver Kit Headers and Libs | 11 | 21.8 MB | `Include\10.0.19041.0\km`, `Lib\10.0.19041.0\km\{x64,x86}` |
| Windows 7 WDK Headers and Libs | 4 | 14.7 MB | `Lib\win7\km\{x64,x86}` |
| Windows 8 WDK Headers and Libs | 5 | 15.8 MB | `Lib\win8\km\*` |
| Windows 8.1 WDK Headers and Libs | 5 | 17.0 MB | `Lib\winv6.3\km\*` |
| Windows Driver Kit Binaries | 7 | 5.5 MB | tools |
| Windows Driver Framework Headers and Libs | 4 | 5.4 MB | WDF headers |
| **Tổng** | **36** | **~77 MB** | |

**Cố tình BỎ** package `Windows Driver Kit` (126 payload, **316 MB** — gần như toàn bộ là debugger
+ WDTF + test framework): `Config.kmk:4246` cho thấy `VBOX_INF2CAT` tìm `Inf2Cat.exe` trong
`$(PATH_SDK_WINSDK10_BIN)` — tức **Windows SDK** (đã có sẵn trên runner), không cần WDK.

**Cài đặt cuối cùng trong script:**

```
1. kill mọi wdksetup/winsdksetup/msiexec còn sót (giải phóng global mutex)
2. đọc .github/scripts/wdk-payloads.txt  (nhúng sẵn danh sách 36 file)
3. tải MSI + CAB từ CDN vào MỘT thư mục
4. msiexec /i <MSI> /qn /norestart cho từng nhóm
5. verify 6 thư mục lib bắt buộc
```

**Một lỗi nhỏ đã sửa:** `[uri]::EscapeDataString($rel)` encode cả `/` thành `%2F` → CDN trả 404.
Phải escape **từng segment** rồi join bằng `/`.

##### Trạng thái run `39623216928`

| Job | Kết quả |
|---|---|
| `build` | ✅ success |
| `smoke` | ✅ success |
| `full-additions` | ❌ fail ở bước WDK (Lỗi J → đã sửa bằng Lỗi K) |

##### Lỗi F — `smoke` fail: `VERR_VM_DRIVER_NOT_INSTALLED`

```
==> Starting VM (headless)
Exception: collect-identity.ps1:173
  VBoxManage startvm failed (exit 1): VBoxManage.exe: error: VirtualBox kernel driver not installed
  (VERR_VM_DRIVER_NOT_INSTALLED)
```

**Nguyên nhân (không phải bug script):** GitHub-hosted runner **không thể chạy VM**:
1. `VBoxDrv` (kernel driver host) chưa cài → `VERR_VM_DRIVER_NOT_INSTALLED`.
2. Azure runner **không expose nested virtualization** → dù cài driver cũng không boot được VM.

→ **Thiết kế lại job `smoke`:**

| Việc | Cách làm mới |
|---|---|
| Verify binary đã build | **Quét chuỗi identity** trong `VBoxDD.dll` / `VBoxVMM.dll` / `VBoxC.dll` / `VirtualBox.exe` → `.github/scripts/scan-identity.ps1` → artifact `binary-identity.txt` (baseline để diff giữa 2 commit) |
| Verify config plane | `VBoxManage createvm` + `showvminfo --machinereadable` (không cần `VBoxDrv`) — phần này **vẫn chạy được** |
| Verify runtime plane | `collect-identity.ps1` tự dò `VBoxDrv`; nếu không có → ghi `RUNTIME_TARGET_UNAVAILABLE` và **exit 0** (chỉ chấp nhận ở `smoke` T1/T2). T3 dùng `-RequireRuntime` và **fail** nếu thiếu driver/VT-x |
| Yêu cầu "identity ổn định 3 lần mở VM" | **Unit test selector** (Phase 1.0) + **T3 3 boot**; hàm thuần `hash(vmUuid) → profile` test được mà không cần VM. Xem §4.6.4 |

> Ghi chú: thuật ngữ `RUNTIME_TARGET_UNAVAILABLE` cố ý dùng y hệt phân loại Pass 129 trong tài liệu
> phân tích cloak — cùng một bài toán: host phân tích không có runtime target để capture.

##### Lỗi G — `full-additions` treo trong WDK bootstrapper

**Đã tìm ra nguyên nhân gốc** (nhờ bước *"Collect WDK installer diagnostics"* + `wdk-burn-*.log`):

```
i101: Detected package: package_WindowsDriverKit_x86_en_us, state: Obsolete, cached: None
i101: Detected package: package_OEMTestCertificates_x86_en_us, state: Obsolete, cached: None
...
i000: Navigated to Microsoft.Bootstrapper.Presentation.LocationPage
i199: Detect complete, result: 0x0
            ↓ (log hết ở đây — chờ input)
```

**Runner `windows-2022` đã có sẵn WDK 10.0.26100.7705.** Khi chạy bundle WDK **19041**, Burn thấy các
package của nó bị **Obsolete** (vì đã có version mới hơn) → chuyển sang luồng **Modify/Repair** →
điều hướng tới `Microsoft.Bootstrapper.Presentation.LocationPage` → **hiện UI và chờ mãi**, dù đã
truyền `/q`. Luồng Modify bắt buộc phải có UI.

Hệ quả thứ hai (log thứ 2 của run đó):

```
e000: Another instance of kit installer is already running.
i500: Shutting down, exit code: 0x652
```

→ Bundle bị kill (timeout 25 phút của ta) vẫn **giữ global mutex** → lần layout fallback abort ngay.

**Fix (đã áp dụng): bypass hoàn toàn apply phase của Burn.**

1. Kill mọi process `wdksetup` / `winsdksetup` / `msiexec` còn sót trước khi bắt đầu (để giải phóng mutex).
2. `wdksetup.exe /layout <dir> /quiet` → **chỉ tải payload** (`WixBundleAction=2`, không có apply
   phase ⇒ không có Modify UI ⇒ không treo).
3. Đọc `ProductName` của từng MSI trong layout (qua COM `WindowsInstaller.Installer`) → chọn đúng:
   - `Windows Driver Kit Headers and Libraries` → `Lib\10.0.19041.0\km\*`
   - `Windows 7 WDK Headers and Libraries` → `Lib\win7\km\*`
   - `Windows 8 WDK Headers and Libraries` → `Lib\win8\km\*`
   - `Windows 8.1 WDK Headers and Libraries` → `Lib\winv6.3\km\*`
   - `Windows Driver Kit` (tools: rc.exe, inf2cat…) + `Windows Driver Framework Headers and Libraries`
4. `msiexec /i <msi> /qn /norestart` cho từng MSI đã chọn (không qua Burn ⇒ không Modify UI).

Ngoài ra:
- **Cache layout** (`actions/cache`, key `wdk-layout-10.0.19041.0`) để không tải lại 3-4 GB mỗi run.
  Script tự bỏ qua bước tải nếu layout đã có MSI.
- `wdk-msi-inventory.txt` (tên file ↔ ProductName của mọi MSI trong layout) vào artifact để lần sau
  đối chiếu tên chính xác.

> **Bài học (đã ghi nhận):** trên runner có **kit mới hơn đã cài**, bundle **cũ hơn** sẽ rơi vào luồng
> Modify và treo. Cách duy nhất đáng tin: **tải layout + `msiexec` trực tiếp**, không dùng Burn apply.

##### Lỗi H — run `39614054361`: PowerShell StrictMode + `$null.Count`

```
==> Windows SDK 10.0.19041.0 already installed - skip
==> Downloading WDK bootstrapper (https://go.microsoft.com/fwlink/?linkid=2342425)
install-wdk.ps1: The property 'Count' cannot be found on this object. Verify that the property exists.
```

**Nguyên nhân (lỗi script của tôi, không phải lỗi môi trường):**

```powershell
$existing = Get-ChildItem -Path $layoutDir -Filter '*.msi' -Recurse -ErrorAction SilentlyContinue
if ($existing.Count -gt 0) { ... }
```

Khi `Get-ChildItem` **không tìm thấy gì** nó trả về `$null` (không phải mảng rỗng) → `$null.Count`
→ dưới `Set-StrictMode -Version Latest` → **terminating error**.

Đã tái hiện và kiểm chứng cục bộ:

```
old: ERROR -> The property 'Count' cannot be found on this object. Verify that the property exists.
new: empty (OK, khong loi)   new: count = 0
```

**Fix:** luôn ép kiểu mảng: `@(Get-ChildItem ...)`. Đã áp dụng cho `$existing` và `$msis` trong
`install-wdk.ps1`, và `$files` trong `scan-identity.ps1`.

##### Lỗi I — MSI SQL string bị PowerShell ăn mất backtick

Trong code đọc `ProductName` của MSI, truy vấn phải giữ backtick quanh reserved word:

```powershell
# SAI: double-quoted -> PowerShell xu ly backtick nhu escape -> mat backtick
$view = ... @("SELECT `Value` FROM `Property` WHERE `Property`='ProductName'")
# -> SELECT Value FROM Property WHERE Property='ProductName'   (MSI SQL bi loi)

# DUNG: single-quoted -> giu nguyen backtick
$query = 'SELECT `Value` FROM `Property` WHERE `Property`=''ProductName'''
# -> SELECT `Value` FROM `Property` WHERE `Property`='ProductName'   (OK)
```

Đã sửa. (Dù không sửa thì script vẫn chạy được nhờ fallback "cài tất cả MSI", nhưng sẽ tải
thêm gói debugger ~1.5 GB.)

##### Quy tắc rút ra cho mọi script CI

| Quy tắc | Lý do |
|---|---|
| Luôn bọc `@(...)` quanh kết quả cmdlet trước khi dùng `.Count` | `$null.Count` → lỗi dưới StrictMode |
| Dùng single-quoted string cho MSI SQL / WMI query có backtick | PowerShell coi backtick là escape char |
| Bọc mọi lời gọi native bằng try/catch + tắt `$ErrorActionPreference` tạm thời | `2>&1` + `EAP=Stop` → terminating error |
| Luôn có `-TimeoutSeconds` cho process con | Không muốn job treo hàng giờ |
| Luôn upload log chẩn đoán (`if: always()`) | Không đọc được log của job đang chạy |



---

## 5. Kế hoạch triển khai theo phase

> Mỗi task có: file:line cụ thể đã verify, giá trị đích, và tiêu chí nghiệm thu.
> Ưu tiên theo Tier 1/2/3 của tài liệu §39.

### Phase 0 — Nền tảng (bắt buộc trước mọi thứ)

| # | Task | File | Nghiệm thu |
|---|---|---|---|
| 0.1 | Tạo integration branch `feature/cloak` + PR-1 branch `feature/cloak-foundation` từ `VBox-7.2` | — | `git branch` |
| 0.2 | Chứng minh build Windows **cục bộ** chạy được | `configure.vbs` → `env.bat` + `AutoConfig.kmk` | Build sạch không lỗi |
| 0.3 | **Sửa workflow CI** (checkout + trigger + revision log) | `.github/workflows/build.yml` | ✅ **đã làm** — xem [§4.7.7](#477-danh-sách-task-ci-cụ-thể-phase-0) |
| 0.4 | Thêm T1/T2 (binary + config plane) | `.github/workflows/build.yml`, `.github/scripts/collect-identity.ps1`, `.github/scripts/scan-identity.ps1` | ✅ **đã làm** — hosted runner không chạy VM; T1/T2 là gate chính |
| 0.4b | Thêm job `full-additions` + WDK | `.github/workflows/build.yml` + `.github/scripts/install-wdk.ps1` | ✅ **đã làm** — WDK dùng MSI/CAB trực tiếp; chờ run xác nhận |
| 0.4c | Thêm T3 runtime self-hosted | `.github/workflows/build.yml` + `.github/scripts/collect-identity.ps1`, `collect-guest-identity.*`, `compare-identity.*` | ⬜ **chưa làm** — job `t3-runtime`, 3 boot, guest Windows + Linux, schema comparator |
| 0.5 | **Xác minh** path pcbios ↔ efi trong CFGM overlay (không sửa identity ở PR-1) | `ConsoleImplConfigCommon.cpp:724-843` | Ghi nhận key nào áp dụng cho BIOS/EFI; implementation chuyển sang PR-2 |
| 0.6 | Hạ tầng test: so sánh guest-visible identity giữa 2 build | `.github/scripts/collect-identity.ps1`, guest collector, comparator | T3 chạy 3 boot, Windows + Linux, schema comparator + negative tests |
| 0.7 | Baseline identity để so sánh (artifact từ build stock) | artifact `cloak-identity-report` | Có 1 bộ giá trị reference cho VM mẫu |
| 0.8 | Chốt `stock` vs `cloak` build, asset build-time và `BuildIdentityManifest` | `Config.kmk` / tài liệu build | Không còn tuyên bố “off = stock”; manifest sinh cho mỗi build mode |

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
| 1.0.1 | Khung `MACHINEPROFILE` + registry **rỗng** + `test-profile-synthetic` | `src/VBox/Main/src-client/ConsoleImplConfigCloak.h` (mới) | Compile; registry production không có `DRAFT` |
| 1.0.2 | `CloakSeed` + HMAC-SHA-256 + UUID salt + `splitmix64` stream | `ConsoleImplConfigCloak.cpp` (mới) | Unit test: cùng seed + UUID → cùng output; khác seed → khác output |
| 1.0.2a | **Provision/consume seed** tách khỏi startup; fail nếu thiếu seed | CLI/Main API + `ConsoleImplConfigCloak.cpp` | Provision VM off → persist; start với seed thiếu → fail rõ |
| 1.0.3 | `MPE::materialize()` → ghi CFGM vào node thật `Devices/<dev>/0/Config/*` | `ConsoleImplConfigCloak.cpp` | `debugvm info pci verbose` + DMI/ACPI collector; **không** dùng `showvminfo` |
| 1.0.4 | Tích hợp **sau** `i_configCfgmOverlay` | `ConsoleImplConfigX86.cpp:2055` | User override thắng; key thiếu mới được điền |
| 1.0.4a | `validateEffectiveConfig()` sau materialize, trên CFGM thực tế | `ConsoleImplConfigCloak.cpp` | Override conflict STRICT → fail; HEURISTIC → warn; không đè user |
| 1.0.5 | Bộ luật coherence C1–C13 + severity STRICT/HEURISTIC | `ConsoleImplConfigCloak.cpp` + unit test | Mỗi rule có positive/negative test; profile vi phạm fail/warn đúng mức |
| 1.0.6 | Lint offline toàn bộ profile registry + provenance + class | script test | Không `DRAFT`/`RESEARCH_ONLY` selectable; `COMPATIBLE` không có STRICT violation |
| 1.0.7 | Cơ chế ép profile cụ thể (`VBoxInternal/Cloak/Profile`) | `ConsoleImplConfigCloak.cpp` | Set ExtraData → profile đã verify; không bypass manifest |
| 1.0.8 | Bật/tắt (`VBoxInternal/Cloak/Enabled`) — **mặc định tắt** | `ConsoleImplConfigCloak.cpp` | Chỉ tắt runtime; build-time asset vẫn theo build mode |
| 1.0.9 | Phân loại binding/cosmetic + allowlist driver | `ConsoleImplConfigCloak.cpp` | Binding ID không random; profile vi phạm bị reject |
| 1.0.10 | `BUILDIDENTITYMANIFEST` + `build-identity.json` | build system + `ConsoleImplConfigCloak.cpp` | Profile family/chipset/binding khớp manifest; mismatch fail |
| 1.0.11 | Profile class `COMPATIBLE`/`RESEARCH_ONLY` + device feasibility check | registry + linter | Chỉ `COMPATIBLE` selectable production |
| 1.0.12 | Saved-state/snapshot guard: seed hash + profile ID + manifest hash | `ConsoleImplConfigCloak.cpp` + SSM | Restore mismatch → fail rõ; không trộn identity; test §4.6.5 |

### Phase 1 — Tier 1: CPU / firmware (giá trị cao nhất)

| # | Task | File:line | Giá trị đích | Rủi ro |
|---|---|---|---|---|
| 1.1 | Hyper-V vendor (chỉ `HyperV` mode) | `GIMR3Hv.cpp:245-248` | `"Microsoft   "` (12 ký tự) + leaves đầy đủ | Thấp |
| 1.2 | HVP presentation (một design với 1.1) | `target-x86/CPUMR3CpuId-x86.cpp:4017-4026` | `Hidden`: HVP=0 + không leaves; `HyperV`: HVP=1 + leaves | **Cao** |
| 1.3 | CPU DB profile | `CPUMR3Db.cpp:154` | profile CPUID thật, **không** copy brand string của fork; chờ O4 | Cao |
| 1.4 | SMBIOS Type 11 suppression | `DevFwCommon.cpp:977-999` | `DmiOEMVBoxVer/Rev` default `""` | Thấp |
| 1.5 | SMBIOS Type 17/19/8 | `DevFwCommon.cpp:889-975` + code mới | key `DmiMemDev`, `DmiPortConnectors` | Trung bình |
| 1.6 | Anti-detect gate | `DevFwCommon.cpp:487` | Thay `Flags & 0x1337` bằng `/Cloak/Enabled` (không dùng license gate) | Thấp |
| 1.7 | Default DMI vendor/product | `DevFwCommon.cpp:64-95` | Theo profile đã verify; **O4 blocker**, không hardcode | Thấp |
| 1.8 | ACPI OEM/Creator | `DevACPI.cpp:4670-4697` | Theo profile, **không** random theo UUID | Thấp |
| 1.9 | ACPI OEM Table ID | `DevACPI.cpp:4680-4687`, `:2918-2931` | Theo profile (e.g. `"A M I "` nếu AMI) | Thấp |
| 1.10 | DSDT rebrand | `PC/vbox.dsl:28` | Theo **build-time firmware family**; không dùng `ACRSYS` cho Lenovo/Dell | Thấp |
| 1.11 | Battery `_BIF` | `PC/vbox.dsl:1491-1495` | `i2battery` / `INTEL` | Thấp |
| 1.12 | DSDT CPU0 + thermal + voltage | `PC/vbox.dsl` + `DevACPI.cpp` | AML theo §3.3 (8.3-8.5); DSDT build-time, handler runtime | Trung bình |
| 1.13 | MPS rebrand | `DevFwCommon.cpp:1128-1133` | `INTELCPU` / `Intel` | Thấp |
| 1.14 | PC BIOS rebrand | `PC/BIOS/orgs.asm:86-87`, `bios.c:74`, `logo.c:477` + 3 `.asm` | Build-time vendor family; nội dung chọn sau O4 | Trung bình (`.asm` generated) |
| 1.15 | **Fix leak F12** | `PC/BIOS/logo.c:477` + 3 `.asm` | bỏ `VirtualBox` | Thấp |
| 1.16 | VGA BIOS VBE vendor | `Graphics/BIOS/vbe.c:88-97`, `vgabios.c:99` + 3 `.asm` | Build-time family; NVIDIA chỉ nếu build NVIDIA, AMD profile cần build khác | Trung bình |
| 1.17 | **Fix leak raw VGA ROM** | `Graphics/BIOS/VBoxVgaBiosAlternative*.asm` | bỏ `Antidetect5` / `VirtualBox` | Thấp |
| 1.18 | UEFI `FirmwareVendor` | `OvmfPkg/OvmfPkgX64.dsc` (override) | Build-time family, đồng bộ BIOS/ACPI; **không** hardcode `L"ASUS"` | Trung bình (cần EDK2 build) |
| 1.19 | ACPI PM `VenDevId` | `DevACPI.cpp:4881-4882` | key override | Thấp |

**Ràng buộc kỹ thuật quan trọng:**

- **HVP**: 1.1 và 1.2 phải merge cùng PR; không merge riêng lẻ. `Hidden` không dùng `GIMR3Hv`; `HyperV` không clear HVP.
- **BIOS / VGA BIOS**: file `.asm` checked-in là **artifact sinh ra** từ nguồn gốc
  (`PC/BIOS/Makefile.kmk:136-165`, `Graphics/BIOS/Makefile.kmk:71-104`).
  → Phải sửa **cả** nguồn gốc (`.asm` gốc, `logo.c`, `vbe.c`, `vgabios.c`) **và** file `.asm` đã flatten, nếu không lần regenerate sẽ mất patch.
- **DSDT**: build được trong tree — `bldRTIasl` build từ `src/VBox/Runtime/tools/RTIasl.cpp` (`src/VBox/Runtime/tools/Makefile.kmk:82-88`), `Config.kmk:2532` (`VBOX_RTIASL`), `Devices/Makefile.kmk:917-919`.
- **UEFI**: build OVMF riêng (`Devices/EFI/Firmware/Makefile.kmk:435-453`, `ACTIVE_PLATFORM = OvmfPkg/OvmfPkgX64.dsc`).
- **Build-time asset**: 1.10-1.18 là thay đổi asset, **không** tắt được bằng `CloakEnabled`; thuộc `cloak` build mode. Không hứa “off = stock”.
- **Một build = một firmware family**: DSDT/BIOS/VGA/OVMF là global; không thể mỗi VM một hãng. Runtime profile phải khớp family của build hoặc fail C1/C3/C4.
- **UEFI per-VM**: `ConsoleImplConfigX86.cpp:1571-1575` dùng tên firmware cố định; không có override per-VM. 1.18 là thay đổi toàn cục cho mọi VM dùng OVMF trong build đó.

### Phase 2 — Tier 2: device identity

> Phase 2 phải tuân §4.5.8: binding cứng không random; binding mềm chỉ chọn từ allowlist đã test; cosmetic mới random. Không task nào được đổi primary ID của VMMDev/VGA/VirtIO mà không có driver tương ứng.

| # | Task | File:line | Giá trị đích |
|---|---|---|---|
| 2.1 | GPU `GpuModelId` | `Graphics/DevVGA.cpp:6829-6843` | Chỉ dùng khi có WDDM strategy; nếu không, giữ `80EE:BEEF` |
| 2.2 | VMSVGA `CMD_BUFFERS_2` | `Graphics/DevVGA-SVGA.cpp:8074-8089` | bỏ bit 0x04000000 |
| 2.3 | HDA codec/subsystem | `Audio/DevHdaCodec.cpp:801-804`, `Audio/DevHda.cpp:5138-5141` | bảng hợp lệ theo profile, không dùng tuple lỗi |
| 2.4 | PIIX3 ATA model | `Storage/DevATA.cpp:8231-8232` | `Samsung PRO 970` / `Samsung CD-ROM` |
| 2.5 | AHCI controller | `Storage/DevAHCI.cpp:5769-5770` | Profile-derived; `8086:8C82` chỉ đúng cho 8-series, không dùng cho Tiger Lake |
| 2.6 | AHCI model/serial/INQUIRY | `Storage/DevAHCI.cpp:5414-5456` | Model/serial/INQUIRY phải cùng hãng; dùng `pszStorageSerial` |
| 2.7 | HostDVD inquiry | `Storage/DrvHostDVD.cpp:366-368` | `Hitachi/CD-ROM/1.0` |
| 2.8 | USB HID VID + override | `Input/UsbKbd.cpp:125-127,326-329`, `Input/UsbMouse.cpp:65-69,351-355` | `3938` + 3 key mới; không đổi driver binding |
| 2.9 | USB webcam | `Video/UsbWebcamDesc.cpp:793-794,925-927` | `046D:0825 / Logitech / HD Webcam C270` |
| 2.10 | USB MSD | `Storage/UsbMsd.cpp:59-61,282-284` | `3938` / `Seagate` |
| 2.11 | OHCI `VenDevId` | `USB/DevOHCI.cpp:6001-6005` | Chỉ override nếu khớp profile; `106B:003F` là Apple, không dùng cho Lenovo |
| 2.12 | xHCI | `USB/DevXHCI.cpp:8052` | Profile-derived; không hardcode `8086:8D31` cho Tiger Lake/Coffee Lake |
| 2.13 | i440FX + PIIX3 ISA | `Bus/DevPCI.cpp:1353-1355`, `:1365-1366` | **Giữ stock** `8086:1237` / `8086:7000`; không dùng `0400:1237` / `8086:0484` |
| 2.14 | **VMMDev** | `VMMDev/VMMDev.cpp:4844-4847` | **Deferred**: giữ `80EE:CAFE`; đổi toàn cục cùng GA + ký mới |
| 2.15 | ACPI PM `VenDevId` | `PC/DevACPI.cpp:4881-4882` | key override; profile/allowlist |
| 2.16 | VirtIO vendor | `VirtIO/VirtioCore.h:261`, `VirtioCore.cpp:3073-3084` | **Không thuộc baseline** — experimental, cần guest driver strategy |
| 2.17 | virtio-net Realtek DID | `Network/DevVirtioNet.cpp:3698-3705` | **Không thuộc baseline** — Realtek + virtio caps là fingerprint |
| 2.18 | E1000 subsystem + EEPROM | `Network/DevE1000.cpp:267-281`, `:706-717` | `1043:85F0` (SVID:SID); verify endian/EEPROM |
| 2.19 | TPM `INTC/CSME/PTT` | `src/libs/libtpms-0.10.2/src/tpm2/VendorInfo.c:71-77` | 4 hằng; chỉ dùng với CPU Intel; **defer PR-6** cùng libtpms |

**Loại khỏi baseline:** 2.16 và 2.17. Nếu muốn thử, tách branch `experimental/virtio-realtek`; phải test Linux `virtio_pci` + Windows NetKVM/viostor trước khi merge. Không đưa vào PR-3.

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
| 3.8 | Test lifecycle GA: install mới, upgrade từ GA stock, uninstall, rollback; Windows 10/11 + Secure Boot, Linux GA |
| 3.9 | Test ký driver và load sau reboot; không coi chữ ký là bằng chứng lifecycle |

### Phase 4 — Guest provisioning / UI runtime actions

| Task | File |
|---|---|
| 4.1 | Thêm slot `sltAntiOS*` vào `Frontends/VirtualBox/src/runtime/UIMachineLogic.h/.cpp` |
| 4.2 | Đăng ký action `AntiOS*` vào `Frontends/VirtualBox/src/globals/UIActionPoolRuntime.cpp` |
| 4.3 | Payload Guest Control: TCP fingerprint (M1D/M1D1), hop tuner, IPv6, firewall, browser hardened, GPS |
| 4.4 | Test quyền: user thường vs elevated; không yêu cầu quyền cao hơn stock nếu không có lý do |
| 4.5 | Test rollback: provisioning lỗi giữa chừng phải khôi phục guest state; không để guest nửa vời |

**Lưu ý phạm vi:** chỉ port các action **không** phụ thuộc payload bên ngoài đã bị AV quarantine hoặc chặn dịch vụ bên thứ ba (AutoKMS, hosts-blocklist anti-fraud). Các payload đó nằm ở `cloak/Iso/etc/`, không phải mã nguồn VirtualBox.

### Phase 5 — Cross-layer coherence (gate từng slice, không phải phase cuối)

Coherence **không phải** phase dọn dẹp. Mỗi vertical slice (PR-2, PR-3) phải pass coherence gate trước khi merge; Phase 5 chỉ còn residual/edge case.

| Mâu thuẫn | File:line | Xử lý |
|---|---|---|
| F12 còn `VirtualBox` | `PC/BIOS/logo.c:477` + 3 `.asm` | PR-2, sửa asset |
| Raw VGA ROM còn `Antidetect5` | `Graphics/BIOS/VBoxVgaBiosAlternative*.asm` | PR-2, sửa asset |
| USB MSD `Seagate` vs VSCSI `VBOX` | `Storage/VSCSI/VSCSILunSbc.cpp:248-250`, `VSCSILunMmc.cpp:1146-1148` | PR-3 |
| PIIX3 optical IDENTIFY vs INQUIRY | `Storage/DevATA.cpp:2431-2433` | PR-3 |
| AHCI optical `Toshiba` vs `SanDisk` | `Storage/DevAHCI.cpp:5436-5456` | PR-3 |
| SSD model vs nonrotational/TRIM/SMART | `Storage/DevATA.cpp`, `Storage/DevAHCI.cpp` (word 217/169) | PR-3 |
| E1000 PCI vs EEPROM thứ tự field | `Network/DevE1000.cpp:277` vs `:706-717` | PR-3 |
| TPM `INTC` vs libtpms cũ | `src/libs/libtpms-0.10.2/` | PR-6, tách khỏi PR-3 |
| HDA tuple vs chipset đời | cần bảng profile coherence | PR-3 |
| VMMDev `8086:1551` vs INF `PCI\VEN_80ee&DEV_cafe` | `Additions/common/VBoxGuest/win/VBoxGuest.inf:63` | **Không đổi VMMDev** trong baseline; nếu đổi, PR-4 + ký lại |
| HVP=0 + Hyper-V leaves | `GIMR3Hv.cpp`, `CPUMR3CpuId-x86.cpp` | PR-2; fail coherence C11 |

### Phase 6 — Verification

Reuse đúng các collector mà tài liệu đã viết và self-test sẵn (tất cả nằm trong `cloak/analysis_driverdiff/`):

| Collector | File | Kiểm tra |
|---|---|---|
| PCI final sink (Pass 118) | `pass118_pci_runtime_analyze.py` | `debugvm <vm> info pci verbose` → binding ID đúng (VMMDev `80EE:CAFE` mặc định); VirtIO vẫn `1AF4` nếu dùng; không có tuple giả |
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
5. Pass coherence gate của slice hiện tại (C1–C13); Phase 5 chỉ còn residual.

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
  binding:  {VMMDev, VGA/WDDM, VirtIO}   # build-level, không random
  build:    {mode, firmwareFamily, assetHash, buildHash}
  profile:  {class, supportedChipsets, requiredFirmwareFamily}
  state:    {seedHash, profileId, manifestHash}
  provenance:{source, model, BIOS version, date, hash}
  guest:    {GA service names, file names, PnP provider, WMI}
}
```

Check tự động:
- CPU generation ↔ chipset: kiểm theo allowlist, không dùng `8086:1237` + CPU Tiger Lake như một máy laptop
- ACPI OEM/creator ↔ SMBIOS/firmware: **heuristic + allowlist**, không bắt buộc trùng tuyệt đối
- Storage model family đồng nhất giữa IDENTIFY và INQUIRY; SSD ⟺ nonrotational + TRIM + SMART
- GPU PCI ↔ VBE **build-time asset**: strict
- EDID ↔ display identity: **heuristic**, không bắt buộc trùng GPU
- TPM manufacturer ↔ CPU/firmware: **heuristic**, cho phép dTPM
- HVP bit ↔ vendor/leaves/GIM provider: strict
- Binding ID ↔ driver/INF: strict; profile `DRAFT`/`RESEARCH_ONLY`/thiếu provenance bị reject
- Effective CFGM sau user override phải pass lại C1–C13; override conflict strict → fail, heuristic → warn
- Profile family/chipset/binding phải khớp `BUILDIDENTITYMANIFEST`
- Profile chỉ dùng dữ liệu từ một máy thật; nếu không, ghi rõ residual

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

Repo **đã có** workflow `.github/workflows/build.yml` (1000 dòng, đã commit) build VirtualBox 7.2 Windows x64 trên `windows-2022`:

| Job | Nội dung | Dependency cài thêm |
|---|---|---|
| `build` | Toàn bộ + GUI (Qt 6.8.0) — **trừ** Guest Additions (`VBOX_WITHOUT_ADDITIONS=1`); sinh `build-identity.json` | yasm, Qt 6.8.0, SDL 1.2.15 |
| `smoke` | T1/T2: scan binary + config plane + verify manifest; không chạy VM | — |
| `full-additions` | Build kèm Guest Additions (cần WDK) | WDK 19041 MSI/CAB |
| `t3-runtime` (kế hoạch) | T3: VM thật 3 boot + guest collector Windows/Linux | self-hosted runner có VT-x/VBoxDrv |

**Checkout đã sửa:** workflow dùng `repository: ${{ github.repository }}` tại `build.yml:42`, không còn build upstream. T3 runtime phải chạy self-hosted, xem [§4.7.4](#474-ba-tầng-kiểm-chứng-thay-cho-smoke-chạy-vm-trên-hosted-runner).

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
# PCI inventory (VM đang chạy)
VBoxManage debugvm "<vm>" info pci verbose

# Control plane (ExtraData), không phải CFGM nội bộ — lọc key, KHÔNG log seed
VBoxManage getextradata "<vm>" enumerate | Select-String -NotMatch "Seed"

# Chỉ là config summary, KHÔNG dùng để verify materialize
VBoxManage showvminfo "<vm>" --machinereadable
```

`showvminfo` không đọc CFGM nội bộ. Muốn verify MPE materialize, dùng `debugvm info pci verbose`, collector DMI/ACPI trong guest, hoặc thêm debug-info item `cfgm` test-only. Không chạy `getextradata enumerate` nguyên bản trong CI/artifact vì có thể lộ `CloakSeed`.

### 8.2 Kiểm tra runtime (theo collector)

Chạy collector trong guest **Windows và Linux**, so với giá trị mong đợi. Script tham khảo ở `cloak/analysis_driverdiff/`; T3 dùng collector riêng theo §4.7.4.

### 8.3 Kiểm tra differential

Cùng một cấu hình VM, chạy lần lượt dưới:
1. Build **stock** (baseline)
2. Build **cloak**

Dùng schema comparator §4.7.4.1, không diff raw text/mask hex. Chạy 3 boot cho mỗi build; mọi khác biệt phải map được về một task trong kế hoạch — khác biệt không giải thích được = regression. PR-1 phải có differential **bằng 0** (khi T3 sẵn sàng).

### 8.4 Regression check bắt buộc

| Hệ | Check |
|---|---|
| Windows 10/11 | Boot, PnP không có device lỗi, driver GA load, GPU driver, audio, network, storage |
| Linux (Debian/Ubuntu) | Boot, `lspci -k`, `lsusb`, `dmesg` không có "unknown device" |
| Binding identity | VMMDev/VGA/virtio driver bind đúng; GA service/DLL hoạt động |
| Hypervisor presentation | `CPUID.1:ECX[31]`, leaf `0x40000000..0x40000006`, `HypervisorPresent` nhất quán |
| GA lifecycle | Cài mới, upgrade từ GA stock, uninstall, rollback; reboot + Secure Boot |
| Saved state/snapshot | Restore không đổi identity; mismatch seed/profile/manifest → fail rõ |
| Provisioning | Thiếu seed → fail; seed sai kích thước/bị sửa → fail; provision idempotent; VM đang chạy bị từ chối |
| Build manifest | Profile family/chipset/binding khớp; build `stock` + cloak → fail |
| VBoxManage | `showvminfo`, `list hdds`, `getextradata`, `debugvm info pci verbose` |
| Shared clipboard / DnD / shared folder | Hoạt động sau khi đổi GA |
| Guest Control | `VBoxControl` chạy được |
| Seed/clone | `clonevm` new UUID → identity khác; mở lại 3 lần → giống hệt |

---

## 9. Rủi ro

| # | Rủi ro | Mức | Giảm thiểu |
|---|---|---|---|
| R1 | HVP mode không nhất quán làm Hyper-V/KVM provider lỗi | **Cao** | `Hidden` dùng GIM `Minimal`/không GIM; `HyperV` giữ HVP=1 + leaves. Không trộn. Test cả 3 provider |
| R2 | Đổi CPUID leaf/ID → guest BSOD (đặc biệt driver MSI) | **Cao** | Test Windows + Linux sau **mỗi** task Tier 1 |
| R3 | Key CFGM mới không có trong whitelist → device không construct | Trung bình | Sửa whitelist **cùng lúc** với code đọc key |
| R4 | `VBOX_VENDOR`/`VBOX_PRODUCT` đổi → đụng licensing, toàn bộ string sản phẩm | Trung bình | Sửa cục bộ trong `vbe.c`/`vgabios.c`, **không** sửa `Config.kmk` |
| R5 | Tạo cross-layer mismatch mới (tệ hơn leak cũ) | **Cao** | Coherence gate trong từng PR-2/PR-3; Phase 5 chỉ residual |
| R6 | `.asm` BIOS bị regenerate mất patch | Trung bình | Commit cả nguồn + flatten; ghi rõ trong commit message |
| R7 | EFI build cần toolchain riêng, lâu, khó debug | Trung bình | Làm sau các phase khác; tách PR riêng |
| R8 | Đổi tên GA làm guest cũ không load được driver | Trung bình | Đồng bộ host+guest trong cùng build; version-gate |
| R9 | Port CPUDB sai → CPUID incoherent | Cao | Dựng CPUID blob từ CPU thật, validate bằng Pass 116/124 |
| R10 | Nâng libtpms lên version mới → hàng loạt diff | Trung bình | Tách PR riêng, không gộp Phase 1 |
| R11 | GPL/trademark/pháp lý | **Trung bình–Cao** | Chỉ nghiên cứu, không phân phối; giữ notice GPL; review AMD/NVIDIA/Lenovo/AMI trademark; không dùng cho gian lận |
| R12 | CI build nhầm repo | **Cao** | ✅ **đã sửa** — `build.yml:42` dùng `${{ github.repository }}`; kiểm tra `source-revision.txt` |
| R13 | CI không build được Guest Additions (thiếu WDK) | Trung bình | `VBOX_WITHOUT_ADDITIONS=1` → job `full-additions`; WDK 19041 MSI/CAB direct; fallback self-hosted |
| R14 | MPE tạo giá trị không ổn định | **Cao** | `CloakSeed` + UUID salt; materialize 1 lần; test mở lại 3 lần ở T3 |
| R15 | MPE tạo mâu thuẫn chéo | Cao | C1–C13 + `validateEffectiveConfig`; reject `DRAFT`/`RESEARCH_ONLY`; manifest check |
| R16 | `.asm` BIOS bị regenerate trong CI → mất patch | Trung bình | §7.3 — không cài OpenWatcom, không regenerate |
| R17 | PR lớn, khó review | Trung bình | 6 PR theo §10.1; mỗi PR có gate riêng |
| R18 | CI chạy lâu (timeout 360 phút) | Thấp | Cache Qt; `smoke` dùng lại artifact; T3 tách runner |
| R19 | Đổi binding ID làm GA/GPU/storage/virtio không bind | **Cao** | §4.5.8: binding cứng build-level; test Windows PnP + Linux `lspci -k`; không random |
| R20 | `CloakEnabled=off` không khôi phục asset build-time | **Cao** | Build mode `stock` riêng; không hứa off = stock |
| R21 | Profile lấy từ máy không tồn tại/ghép field | **Cao** | O4 blocker; provenance + linter; registry rỗng đến khi verify |
| R22 | Clone/migration/saved-state làm trộn identity | Trung bình | Seed hash + profile ID + manifest hash; restore mismatch fail; test §4.6.5 |
| R23 | T3 artifact chứa serial/UUID/seed-adjacent data | **Cao** | Runner riêng; redact report; không upload raw dump/.vbox/seed; retention ngắn |
| R24 | Seed lộ qua ExtraData/.vbox hoặc shell history | Trung bình | Không log seed; provision qua CLI/API có kiểm soát; ExtraData không phải secret store; nêu rõ host-admin ngoài threat model |
| R25 | Provision/consume thất bại giữa chừng | Trung bình | Provision VM off, verify đọc lại, idempotent; startup chỉ đọc; thiếu seed fail rõ |

---

## 10. Quyết định đã chốt

> Đã chốt với người yêu cầu. Kế hoạch dưới đây được cập nhật theo 5 quyết định này.
> **Chỉ lập kế hoạch — chưa triển khai code cho tới khi có chỉ thị "triển khai".**

| # | Câu hỏi | Quyết định | Ảnh hưởng lên kế hoạch |
|---|---|---|---|
| 1 | Chia PR thế nào? | **6 PR theo vertical slice** | Mục 10.1 |
| 2 | Giá trị đích cho DMI vendor/product? | **Thông tin phải đồng bộ** | §4.5 — Machine Profile Engine; thêm Phase 1.0 |
| 3 | Selector random hay cố định? | **Random, nhưng ổn định qua các lần mở VM** | §4.6 — `CloakSeed` + UUID salt, materialize 1 lần |
| 4 | Môi trường build? | **GitHub Actions + T3 self-hosted** | §4.7 — T1/T2 hosted, T3 runtime self-hosted |
| 5 | `CloakEnabled=off` có trả về stock? | **Không** — chỉ tắt lớp runtime; asset build-time cần build `stock` riêng | §4.5.9 |

### 10.1 Chia PR (quyết định #1)

| PR | Branch | Nội dung | Phase | Gate bắt buộc |
|---|---|---|---|---|
| **PR-1** | `feature/cloak-foundation` | MPE/control plane, seed provision/consume, manifest skeleton, state guard, namespace, binding classifier, CI T1/T2 | 1.0 | T1/T2; T3 differential **bằng 0** khi T3 sẵn sàng (bắt buộc trước PR-2); không đổi identity guest-visible |
| **PR-2** | `feature/cloak-cpu-firmware` | CPUID/HVP + DMI/ACPI/BIOS/VGA/EFI assets | 1, 5 (slice) | T1/T2 + T3 3 boot; C1–C13 đúng severity |
| **PR-3** | `feature/cloak-devices` | PCI/storage/USB/network device identity | 2, 5 (slice) | T1/T2 + T3 Windows/Linux; binding test |
| **PR-4** | `feature/cloak-ga-rename` | Guest Additions rename (driver/service/file/INF/PE) | 3 | `full-additions` + chữ ký + install/upgrade/uninstall/rollback |
| **PR-5** | `feature/cloak-provisioning` | UI runtime actions + Guest Control provisioning | 4 | `build` + guest integration/permissions/rollback |
| **PR-6** | `feature/cloak-coherence-tpm` | Residual coherence + TPM (2.19 + libtpms); **không phải coherence lần đầu** | 5 | T3 3 boot + TPM test |

Quy tắc merge:
- PR-1 merge trước; là nền cho mọi PR sau.
- PR-2 và PR-3 mỗi PR phải pass coherence gate của slice mình, không đợi PR-6.
- PR-4 độc lập với PR-2/PR-3 về code, nhưng binding ID phải khớp; không đổi VMMDev trong baseline. Gate PR-4 phải chứng minh cài mới, upgrade từ GA stock, uninstall và rollback; chữ ký không thay thế test lifecycle.
- PR-5 phải có test guest integration, quyền thực thi và rollback khi provisioning lỗi; chỉ build xanh là chưa đủ.
- PR-6 chỉ chứa residual/TPM; không dùng để “dọn” mismatch đã tạo ở PR-2/PR-3.

### 10.2 Đồng bộ thông tin (quyết định #2)

→ Xem [§4.5](#45-kiến-trúc-mpe--machine-profile-engine-quyết-định-2-thông-tin-phải-đồng-bộ).

Tóm tắt thay đổi so với bản kế hoạch đầu:
- Thêm **Phase 1.0 — Machine Profile Engine** chạy trước Phase 1/2.
- MPE nằm ở **VBoxC** (`src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp/.h`), là nguồn mặc định cho **runtime**; effective CFGM sau override là nguồn sự thật cuối.
- Mọi giá trị identity được **materialize một lần** vào node thật `Devices/<dev>/0/Config/*`; device đọc như stock. Control plane là root `/Cloak/...`; **không** dùng `Devices/cloak`.
- MPE chạy **sau** `i_configCfgmOverlay` tại `ConsoleImplConfigX86.cpp:2055`; chỉ điền key chưa có → user override thắng; `validateEffectiveConfig()` chạy sau materialize.
- Seed chỉ **provision** khi VM off; startup **consume**; thiếu seed → fail, không fallback.
- Bộ luật coherence **C1–C13** có severity STRICT/HEURISTIC, kiểm tra lúc khởi tạo + lint offline + test từng rule.
- **`BUILDIDENTITYMANIFEST`** ràng buộc profile với firmware/chipset/binding của build.
- Registry production **rỗng** cho tới O4; 3 candidate `DRAFT` trong §4.5.4; test dùng `test-profile-synthetic`.
- Binding identity (VMMDev/VGA/VirtIO) là **build-level**, không random; xem §4.5.8.
- Mặc định **tắt** — bật qua `VBoxInternal/Cloak/Enabled`; off chỉ tắt runtime, không khôi phục asset build-time.

### 10.3 Selector ổn định (quyết định #3)

→ Xem [§4.6](#46-selector-ổn-định-quyết-định-3-random-nhưng-không-đổi-khi-mở-lại-vm).

Tóm tắt:
- Seed gốc = **`CloakSeed`** 32 byte, **chỉ sinh lúc provision**, lưu `VBoxInternal/Cloak/Seed` (host-side); startup chỉ đọc.
- VM UUID là **salt**, không phải secret; `seed64 = first8(HMAC-SHA-256(CloakSeed, domain || UUID))`.
- PRNG = `splitmix64`, tách 3 stream độc lập (profile / serial / jitter). Không còn stream virtio.
- **Materialize đúng một lần** trong MPE → ghi CFGM; `validateEffectiveConfig()` kiểm tra CFGM thực tế sau user override. Không tính lại ở device.
- Cơ chế ép profile cụ thể để test: `VBoxInternal/Cloak/Profile`; `DRAFT`/`RESEARCH_ONLY` bị từ chối ở production; manifest family/chipset phải khớp.
- Test bắt buộc: mở lại 3 lần → giống hệt; `clonevm` new UUID → khác; 2 VM → khác nhau; re-seed → chỉ field seed-derived đổi; export/import giữ UUID → giữ nguyên.
- Không dùng test copy `.vbox` + disk thủ công; không dùng `showvminfo` để verify CFGM.

### 10.4 CI GitHub Actions (quyết định #4)

→ Xem [§4.7](#47-ci-bằng-github-actions-quyết-định-4).

Tóm tắt:
- **CI hiện tại**: `.github/workflows/build.yml` đã commit, 1000 dòng, 3 job `build`/`full-additions`/`smoke`, checkout `${{ github.repository }}` tại `:42`.
- **Đã sửa (CI-10)**: không còn build upstream; trigger có `feature/cloak*` + `pull_request`.
- **T1/T2 hosted**: build + scan binary + config plane. **Không** chạy VM.
- **T3 self-hosted job `t3-runtime`**: host `collect-identity.ps1 -RequireRuntime` + guest collector Windows/Linux, **3 boot**, schema comparator; bắt buộc cho PR-2/PR-3/PR-6.
- **PR-4** dùng `full-additions` + WDK; kiểm tra chữ ký, install/upgrade/uninstall/rollback.
- **PR-5** dùng `build` + guest integration/permissions/rollback; không chỉ build xanh.
- Output: `out\win.amd64\release\bin`.
- Không cần OpenWatcom → giữ `.asm` BIOS checked-in (không regenerate).
- Đã loại trừ: 32-bit OpenSSL/curl, kBuild, SDL, Qt, SDK — workflow hiện tại đã xử lý thành công.

### 10.5 Blocker và việc còn mở

| # | Mục | Trạng thái | Xử lý |
|---|---|---|---|
| O1 | CPU profile nào port trước | **Blocked bởi O4** | Chỉ chọn sau khi có dữ liệu CPUID thật; không dùng i7-9750H làm “Cascade Lake” |
| O2 | Nội dung `EfiGuardDxe` | **Ngoài scope** | Cần binary DXE mới, activation semantics chưa rõ; detection/legal cao |
| O3 | Nâng libtpms 0.10.2 | **PR-6** | Diff lớn, cần test TPM; không gộp PR-3 |
| O4 | Profile đầy đủ + dữ liệu máy thật | **BLOCKER** | Phải có SMBIOS/ACPI/PCI/EEPROM/EDID/storage dump + model/BIOS/ngày; registry production rỗng đến khi xong |
| O5 | Chipset model không khớp laptop hiện đại | **BLOCKER** | VirtualBox chỉ có i440FX/PIIX3/ICH9; không thể giả HM370/Tiger Lake bằng ID. Chọn profile desktop/workstation hợp lệ hoặc ghi nhận residual |
| O6 | Chọn `CloakHvPresentation` | **BLOCKER** | `Hidden` hoặc `HyperV`; không trộn; chốt trước PR-2 |
| O7 | Binding identity strategy | **BLOCKER** | Mặc định giữ VMMDev/VGA/virtio; chỉ đổi với GA/driver + ký. Chốt trước PR-3 |
| O8 | T3 self-hosted runner + guest images | **BLOCKER** | Cần runner riêng có VT-x/VBoxDrv + Windows/Linux guest; chưa có trong repo |
| O9 | BuildIdentityManifest source/versioning | **Mở** | Chốt nguồn asset hash + version từ build system; không hard-code trong profile |

### 10.6 Điều kiện mở khóa triển khai

Chỉ bắt đầu code identity khi:
1. O4 có ít nhất một profile thật được verify, phân loại `COMPATIBLE` và pass linter C1–C13.
2. O5 có quyết định: profile desktop/workstation hợp lệ, hoặc chấp nhận residual và ghi rõ.
3. O6 chốt `Hidden`/`HyperV`.
4. O7 chốt binding policy; VMMDev/VGA mặc định giữ stock.
5. T3 self-hosted sẵn sàng; nếu chưa, PR-2/PR-3 không được merge.
6. O9 có manifest schema + nguồn hash asset; profile không được selectable nếu manifest chưa khớp.

---

## 11. Trạng thái triển khai

```
[x] Đọc tài liệu cloak/           → mục 1
[x] Đối chiếu với src/            → mục 3
[x] Lập kế hoạch                   → tài liệu này
[x] Chốt 5 quyết định thiết kế    → mục 10
[x] Revise theo 8 blocker         → MPE/binding/build/CI/profile
[x] Revise critique consistency   → seed/effective/manifest/T3/state/lifecycle
[x] Phase 0.3 — sửa workflow CI    → .github/workflows/build.yml
[x] Phase 0.4 — T1/T2 + script     → .github/scripts/
[x] Phase 0.4b — full-additions    → .github/scripts/install-wdk.ps1
[ ] Phase 0.4c — T3 self-hosted    ← chưa làm
[ ] TRIỂN KHAI phần còn lại        ← chờ chỉ thị
```

**Trạng thái hiện tại:**

| Hạng mục | Trạng thái |
|---|---|
| Mã nguồn VirtualBox (`src/`) | **Chưa sửa gì** |
| `.github/workflows/build.yml` | Đã commit; 3 job `build`, `full-additions`, `smoke`; checkout `${{ github.repository }}` `:42` |
| `.github/scripts/collect-identity.ps1` | Host-side `debugvm`; **chưa phải T3** (không guest collector, chỉ 2 run, mask hex). T3 cần refactor theo §4.7.4.1 |
| `.github/scripts/install-wdk.ps1` | Cài SDK+WDK 10.0.19041 (direct → layout fallback) + verify 6 thư mục |
| `.gitignore` | Sạch, không còn thay đổi `+cloak` |
| Tài liệu | `doc/cloak-plan/CLOAK-PLAN.md` — đã revise, **chưa commit** |

Khi nhận chỉ thị "triển khai", thứ tự đề xuất:

1. Phase 0.1-0.2 (branch + build local) — *chưa làm*
2. Phase 0.4c (T3 self-hosted) + Phase 0.5 (xác minh path pcbios ↔ efi; implementation ở PR-2)
3. Phase 1.0 (MPE/control plane) → **PR-1**
4. Phase 1 (CPU/firmware) → **PR-2**, coherence slice
5. Phase 2 (device identity) → **PR-3**, coherence slice + binding test
6. Phase 3 (GA rename) → **PR-4**
7. Phase 4 (provisioning) → **PR-5**
8. Phase 5 residual + TPM → **PR-6**

**Bước kiểm chứng đầu tiên sau khi có code:** push `feature/cloak-foundation` → workflow chạy →
- T1/T2 xanh; control plane/seed/manifest không làm đổi identity guest-visible.
- Khi T3 sẵn sàng: identity **ổn định qua 3 boot**; **differential stock-vs-cloak bằng 0** ở PR-1. Khác baseline chỉ bắt đầu từ PR-2 khi bật identity thật. T3 phải sẵn sàng trước PR-2.
- `full-additions` xanh → artifact `virtualbox-guest-additions` có `VBoxGuest.sys` + `VBoxGuestAdditions.iso` (chỉ cần từ PR-4; gate PR-4 còn phải test install/upgrade/uninstall/rollback).

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
| VMMDev | `src/VBox/Devices/VMMDev/VMMDev.cpp` — binding mặc định `80EE:CAFE` |
| Network | `src/VBox/Devices/Network/DevE1000.cpp`; `DevVirtioNet.cpp`/`VirtIO/VirtioCore.cpp` (experimental) |
| TPM | `src/libs/libtpms-0.10.2/src/tpm2/VendorInfo.c` |
| Guest Additions | `src/VBox/Additions/` — binding contract với VMMDev/VGA |
| Control plane | `src/VBox/Main/src-client/ConsoleImplConfigCommon.cpp`, `ConsoleImplConfigX86.cpp` |
| Cloak MPE | `src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp/.h` (mới) |
| Binding policy | §4.5.8 — VMMDev/VGA/virtio build-level |

## Phụ lục B — Baseline đối chiếu

> Các hash dưới đây lấy từ tài liệu fork, **chưa phải baseline build hiện tại**. Phải build stock từ HEAD `VBox-7.2` và ghi hash thật trước khi dùng làm gate T1.

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
