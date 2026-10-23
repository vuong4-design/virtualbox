#!/usr/bin/env bash
#
# collect-guest-identity.sh
#
# Collector identity chạy TRONG guest Linux cho T3 (kế hoạch §4.7.3/§4.7.4.1).
# Ghi JSON theo schema mà compare-identity.ps1 đọc (schemaVersion 1). Không mask
# giá trị identity; chỉ trường volatile (timestamp/session/address) nằm trong
# allowlist của comparator.
#
# Nguồn dữ liệu:
#   smbios  -> /sys/class/dmi/id/*
#   acpi    -> header của /sys/firmware/acpi/tables/* (OEM ID/OEM Table ID/Revision)
#   pci     -> lspci -Dnnv (VEN/DEV/SUBSYS/REV + BDF)
#   cpuid   -> /proc/cpuinfo (vendor/brand/family/model/stepping/microcode)
#   storage -> /sys/block/*/device (vendor/model/rev/serial)
#   nic     -> /sys/class/net/* (MAC + PCI ID)
#   edid    -> sha256 của /sys/class/drm/*/edid (không đưa EDID thô vào report)
#   tpm     -> /sys/class/tpm/tpm0
#   guest   -> /etc/os-release + uname
#
# Giới hạn: CPUID leaf/register cần tool riêng; script ghi các field từ
# /proc/cpuinfo.
#
# Cách dùng:
#   ./collect-guest-identity.sh [--output PATH] [--self-test]
#
# Exit code: 0 = ghi thành công, 2 = lỗi tham số/không ghi được JSON.

set -euo pipefail

OUTPUT="./guest-identity.json"
SELF_TEST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --output)
            if [ $# -lt 2 ]; then
                echo "missing value for --output" >&2
                exit 2
            fi
            OUTPUT="$2"
            shift 2
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        -h|--help)
            sed -n '1,40p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

declare -a UNAVAILABLE=()

json_escape() {
    printf '%s' "$1" | tr -d '\000\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:space:]]\+$//'
}

jstr() {
    printf '"%s"' "$(json_escape "$1")"
}

read_sys() {
    local path="$1"
    if [ -r "$path" ]; then
        cat "$path" 2>/dev/null || true
    fi
}

normalize_hex4() {
    local value="$1"
    value="${value#0x}"
    value="$(printf '%s' "$value" | tr 'A-F' 'a-f')"
    value="${value#"${value%%[!0]*}"}"
    if [ -z "$value" ]; then
        value="0"
    fi
    printf '%04s' "$value" | tr ' ' '0'
}

join_entries() {
    local first=1 entry
    for entry in "$@"; do
        if [ $first -eq 1 ]; then
            first=0
        else
            printf ','
        fi
        printf '%s' "$entry"
    done
}

hex_to_ascii() {
    local hex="$1"
    local out=""
    local i
    for (( i = 0; i + 1 < ${#hex}; i += 2 )); do
        out+="\\x${hex:$i:2}"
    done
    printf '%b' "$out" | tr -d '\000'
}

collect_guest() {
    local caption="" version="" kernel arch
    if [ -r /etc/os-release ]; then
        caption="$(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release | head -n 1)"
        version="$(sed -n 's/^VERSION_ID="\(.*\)"$/\1/p' /etc/os-release | head -n 1)"
    fi
    kernel="$(uname -r)"
    arch="$(uname -m)"
    printf '{"caption":%s,"version":%s,"kernel":%s,"architecture":%s}' \
        "$(jstr "$caption")" "$(jstr "$version")" "$(jstr "$kernel")" "$(jstr "$arch")"
}

collect_smbios() {
    local dir="/sys/class/dmi/id"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    local bios_vendor bios_version bios_date sys_vendor product_name product_serial product_uuid board_vendor board_name board_version board_serial chassis_type
    bios_vendor="$(read_sys "$dir/bios_vendor")"
    bios_version="$(read_sys "$dir/bios_version")"
    bios_date="$(read_sys "$dir/bios_date")"
    sys_vendor="$(read_sys "$dir/sys_vendor")"
    product_name="$(read_sys "$dir/product_name")"
    product_serial="$(read_sys "$dir/product_serial")"
    product_uuid="$(read_sys "$dir/product_uuid")"
    board_vendor="$(read_sys "$dir/board_vendor")"
    board_name="$(read_sys "$dir/board_name")"
    board_version="$(read_sys "$dir/board_version")"
    board_serial="$(read_sys "$dir/board_serial")"
    chassis_type="$(read_sys "$dir/chassis_type")"
    if [ -z "$bios_vendor" ] && [ -z "$product_name" ]; then
        return 0
    fi
    printf '{'
    printf '"biosVendor":%s,' "$(jstr "$bios_vendor")"
    printf '"biosVersion":%s,' "$(jstr "$bios_version")"
    printf '"biosReleaseDate":%s,' "$(jstr "$bios_date")"
    printf '"systemVendor":%s,' "$(jstr "$sys_vendor")"
    printf '"systemProduct":%s,' "$(jstr "$product_name")"
    printf '"systemSerial":%s,' "$(jstr "$product_serial")"
    printf '"systemUuid":%s,' "$(jstr "$product_uuid")"
    printf '"baseboardVendor":%s,' "$(jstr "$board_vendor")"
    printf '"baseboardProduct":%s,' "$(jstr "$board_name")"
    printf '"baseboardVersion":%s,' "$(jstr "$board_version")"
    printf '"baseboardSerial":%s,' "$(jstr "$board_serial")"
    printf '"chassisType":%s' "$(jstr "$chassis_type")"
    printf '}'
}

collect_cpuid() {
    local info
    if [ ! -r /proc/cpuinfo ]; then
        return 0
    fi
    info="$(awk '
        /^vendor_id[[:space:]]*:/ && vendor == "" { vendor = substr($0, index($0, ":") + 2) }
        /^model name[[:space:]]*:/ && brand == "" { brand = substr($0, index($0, ":") + 2) }
        /^cpu family[[:space:]]*:/ && family == "" { family = substr($0, index($0, ":") + 2) }
        /^model[[:space:]]*:/ && model == "" { model = substr($0, index($0, ":") + 2) }
        /^stepping[[:space:]]*:/ && stepping == "" { stepping = substr($0, index($0, ":") + 2) }
        /^microcode[[:space:]]*:/ && microcode == "" { microcode = substr($0, index($0, ":") + 2) }
        END {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", vendor)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", brand)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", family)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", model)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", stepping)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", microcode)
            printf "%s|%s|%s|%s|%s|%s", vendor, brand, family, model, stepping, microcode
        }
    ' /proc/cpuinfo)"
    local vendor brand family model stepping microcode
    IFS='|' read -r vendor brand family model stepping microcode <<< "$info"
    printf '{"vendor":%s,"brand":%s,"family":%s,"model":%s,"stepping":%s,"microcode":%s}' \
        "$(jstr "$vendor")" "$(jstr "$brand")" "$(jstr "$family")" "$(jstr "$model")" "$(jstr "$stepping")" "$(jstr "$microcode")"
}

collect_acpi() {
    local dir="/sys/firmware/acpi/tables"
    if [ ! -d "$dir" ] || [ ! -r "$dir" ]; then
        return 0
    fi
    local entries=() table signature header hex oem_raw oem_table_raw revision_hex revision
    for table in "$dir"/*; do
        [ -f "$table" ] || continue
        signature="$(basename "$table")"
        hex="$(od -An -t x1 -j 10 -N 26 "$table" 2>/dev/null | tr -d ' \n' || true)"
        if [ ${#hex} -lt 36 ]; then
            continue
        fi
        oem_raw="$(hex_to_ascii "${hex:0:12}")"
        oem_table_raw="$(hex_to_ascii "${hex:12:16}")"
        revision_hex="${hex:28:8}"
        revision="$(printf '%08x' "$(( 16#${revision_hex:6:2}${revision_hex:4:2}${revision_hex:2:2}${revision_hex:0:2} ))")"
        entries+=("$(printf '{"table":%s,"oemId":%s,"oemTableId":%s,"revision":%s}' \
            "$(jstr "$signature")" "$(jstr "$oem_raw")" "$(jstr "$oem_table_raw")" "$(jstr "$revision")")")
    done
    if [ ${#entries[@]} -eq 0 ]; then
        return 0
    fi
    mapfile -t entries < <(printf '%s\n' "${entries[@]}" | sort)
    printf '{"tables":[%s]}' "$(join_entries "${entries[@]}")"
}

collect_pci() {
    if ! command -v lspci >/dev/null 2>&1; then
        return 0
    fi
    declare -A device_vid=() device_did=() device_svid=() device_ssid=() device_rev=()
    local -a order=()
    local line bdf vid did rev
    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-9a-fA-F])[[:space:]] ]]; then
            bdf="$(printf '%s:%s.%s' "${BASH_REMATCH[2],,}" "${BASH_REMATCH[3],,}" "${BASH_REMATCH[4],,}")"
            order+=("$bdf")
            vid=""
            did=""
            rev=""
            if [[ "$line" =~ \[([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\] ]]; then
                vid="${BASH_REMATCH[1],,}"
                did="${BASH_REMATCH[2],,}"
            fi
            if [[ "$line" =~ \(rev[[:space:]]([0-9a-fA-F]{2})\) ]]; then
                rev="${BASH_REMATCH[1],,}"
            fi
            device_vid[$bdf]="$vid"
            device_did[$bdf]="$did"
            device_rev[$bdf]="$rev"
        elif [ -n "${bdf:-}" ] && [[ "$line" == *Subsystem:* ]] && [[ "$line" =~ \[([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\] ]]; then
            if [ -z "${device_svid[$bdf]:-}" ]; then
                device_svid[$bdf]="${BASH_REMATCH[1],,}"
                device_ssid[$bdf]="${BASH_REMATCH[2],,}"
            fi
        fi
    done < <(lspci -Dnnv 2>/dev/null || true)

    if [ ${#order[@]} -eq 0 ]; then
        return 0
    fi
    local entries=() bdf_key
    while IFS= read -r bdf_key; do
        entries+=("$(printf '{"bdf":%s,"vendorId":%s,"deviceId":%s,"subsystemVendorId":%s,"subsystemDeviceId":%s,"revision":%s}' \
            "$(jstr "$bdf_key")" \
            "$(jstr "${device_vid[$bdf_key]:-}")" \
            "$(jstr "${device_did[$bdf_key]:-}")" \
            "$(jstr "${device_svid[$bdf_key]:-}")" \
            "$(jstr "${device_ssid[$bdf_key]:-}")" \
            "$(jstr "${device_rev[$bdf_key]:-}")")")
    done < <(printf '%s\n' "${order[@]}" | sort -u)
    printf '{"devices":[%s]}' "$(join_entries "${entries[@]}")"
}

collect_storage() {
    local dir="/sys/block"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    local entries=() device vendor model rev serial
    for device in "$dir"/*; do
        [ -d "$device/device" ] || continue
        vendor="$(read_sys "$device/device/vendor")"
        model="$(read_sys "$device/device/model")"
        rev="$(read_sys "$device/device/rev")"
        serial="$(read_sys "$device/device/serial")"
        if [ -z "$serial" ]; then
            serial="$(read_sys "$device/device/wwid")"
        fi
        entries+=("$(printf '{"vendor":%s,"model":%s,"firmware":%s,"serial":%s}' \
            "$(jstr "$vendor")" "$(jstr "$model")" "$(jstr "$rev")" "$(jstr "$serial")")")
    done
    if [ ${#entries[@]} -eq 0 ]; then
        return 0
    fi
    mapfile -t entries < <(printf '%s\n' "${entries[@]}" | sort)
    printf '{"devices":[%s]}' "$(join_entries "${entries[@]}")"
}

collect_nic() {
    local dir="/sys/class/net"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    local entries=() interface mac pci_dir vendor device svid sdev rev
    for interface in "$dir"/*; do
        [ -e "$interface" ] || continue
        mac="$(read_sys "$interface/address" | tr 'A-F' 'a-f')"
        [ -n "$mac" ] || continue
        pci_dir="$(readlink -f "$interface/device" 2>/dev/null || true)"
        if [ -z "$pci_dir" ] || [ ! -d "$pci_dir" ]; then
            continue
        fi
        vendor="$(normalize_hex4 "$(read_sys "$pci_dir/vendor")")"
        device="$(normalize_hex4 "$(read_sys "$pci_dir/device")")"
        svid="$(normalize_hex4 "$(read_sys "$pci_dir/subsystem_vendor")")"
        sdev="$(normalize_hex4 "$(read_sys "$pci_dir/subsystem_device")")"
        rev="$(normalize_hex4 "$(read_sys "$pci_dir/revision")")"
        rev="${rev: -2}"
        entries+=("$(printf '{"mac":%s,"vendorId":%s,"deviceId":%s,"subsystemVendorId":%s,"subsystemDeviceId":%s,"revision":%s}' \
            "$(jstr "$mac")" "$(jstr "$vendor")" "$(jstr "$device")" "$(jstr "$svid")" "$(jstr "$sdev")" "$(jstr "$rev")")")
    done
    if [ ${#entries[@]} -eq 0 ]; then
        return 0
    fi
    mapfile -t entries < <(printf '%s\n' "${entries[@]}" | sort)
    printf '{"devices":[%s]}' "$(join_entries "${entries[@]}")"
}

collect_edid() {
    local dir="/sys/class/drm"
    if [ ! -d "$dir" ]; then
        return 0
    fi
    local entries=() edid connector hash
    for edid in "$dir"/*/edid; do
        [ -s "$edid" ] || continue
        connector="$(basename "$(dirname "$edid")")"
        if command -v sha256sum >/dev/null 2>&1; then
            hash="sha256:$(sha256sum "$edid" | cut -d' ' -f1)"
        else
            hash="sha256:$(od -An -v -t x1 "$edid" | tr -d ' \n')"
        fi
        entries+=("$(printf '{"connector":%s,"edidHash":%s}' "$(jstr "$connector")" "$(jstr "$hash")")")
    done
    if [ ${#entries[@]} -eq 0 ]; then
        return 0
    fi
    mapfile -t entries < <(printf '%s\n' "${entries[@]}" | sort)
    printf '{"displays":[%s]}' "$(join_entries "${entries[@]}")"
}

collect_tpm() {
    local dir="/sys/class/tpm/tpm0"
    if [ ! -d "$dir" ]; then
        printf '{"present":false}'
        return 0
    fi
    local version
    version="$(read_sys "$dir/tpm_version_major")"
    if [ -z "$version" ]; then
        version="$(read_sys "$dir/device/description")"
    fi
    printf '{"present":true,"version":%s}' "$(jstr "$version")"
}

write_document() {
    local path="$1"
    shift
    local directory
    directory="$(dirname "$path")"
    if [ -n "$directory" ] && [ ! -d "$directory" ]; then
        mkdir -p "$directory"
    fi
    printf '%s\n' "$1" > "$path"
}

build_document() {
    local collector
    collector="$(printf '{"tool":"collect-guest-identity.sh","version":"1","timestamp":%s}' "$(jstr "$(date -u +%Y-%m-%dT%H:%M:%SZ)")")"

    local -a sections=()
    local guest smbios cpuid acpi pci storage nic edid tpm
    guest="$(collect_guest)"
    smbios="$(collect_smbios)"
    cpuid="$(collect_cpuid)"
    acpi="$(collect_acpi)"
    pci="$(collect_pci)"
    storage="$(collect_storage)"
    nic="$(collect_nic)"
    edid="$(collect_edid)"
    tpm="$(collect_tpm)"

    if [ -n "$guest" ]; then
        sections+=("\"guest\":$guest")
    else
        UNAVAILABLE+=("guest")
    fi
    if [ -n "$smbios" ]; then
        sections+=("\"smbios\":$smbios")
    else
        UNAVAILABLE+=("smbios")
    fi
    if [ -n "$cpuid" ]; then
        sections+=("\"cpuid\":$cpuid")
    else
        UNAVAILABLE+=("cpuid")
    fi
    if [ -n "$acpi" ]; then
        sections+=("\"acpi\":$acpi")
    else
        UNAVAILABLE+=("acpi")
    fi
    if [ -n "$pci" ]; then
        sections+=("\"pci\":$pci")
    else
        UNAVAILABLE+=("pci")
    fi
    if [ -n "$storage" ]; then
        sections+=("\"storage\":$storage")
    else
        UNAVAILABLE+=("storage")
    fi
    if [ -n "$nic" ]; then
        sections+=("\"nic\":$nic")
    else
        UNAVAILABLE+=("nic")
    fi
    if [ -n "$edid" ]; then
        sections+=("\"edid\":$edid")
    else
        UNAVAILABLE+=("edid")
    fi
    if [ -n "$tpm" ]; then
        sections+=("\"tpm\":$tpm")
    fi

    local unavailable=""
    if [ ${#UNAVAILABLE[@]} -gt 0 ]; then
        local -a unavail_entries=()
        local item
        for item in "${UNAVAILABLE[@]}"; do
            unavail_entries+=("$(jstr "$item")")
        done
        unavailable="$(printf '%s\n' "${unavail_entries[@]}" | sort -u | paste -sd, -)"
    fi

    local output=""
    output+="{"
    output+="\"schemaVersion\":1,"
    output+="\"source\":$(jstr guest-linux),"
    output+="\"collector\":$collector"
    local section
    for section in "${sections[@]}"; do
        output+=",$section"
    done
    output+=",\"unavailable\":[$unavailable]"
    output+="}"
    printf '%s' "$output"
}

build_self_test_document() {
    cat <<'JSON'
{
  "schemaVersion": 1,
  "source": "guest-linux",
  "selfTest": true,
  "collector": { "tool": "collect-guest-identity.sh", "version": "1", "timestamp": "2026-01-01T00:00:00Z" },
  "guest": { "caption": "Ubuntu 24.04.3 LTS", "version": "24.04", "kernel": "6.8.0-45-generic", "architecture": "x86_64" },
  "smbios": {
    "biosVendor": "innotek GmbH", "biosVersion": "VirtualBox", "biosReleaseDate": "12/01/2006",
    "systemVendor": "innotek GmbH", "systemProduct": "VirtualBox", "systemSerial": "0",
    "systemUuid": "9f2c1d40-7a51-4c62-9b8e-0d3a5e6f7c81",
    "baseboardVendor": "Oracle Corporation", "baseboardProduct": "VirtualBox", "baseboardVersion": "1.2", "baseboardSerial": "0",
    "chassisType": "1"
  },
  "cpuid": { "vendor": "GenuineIntel", "brand": "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz", "family": "6", "model": "158", "stepping": "10", "microcode": "0xf4" },
  "acpi": { "tables": [ { "table": "DSDT", "oemId": "VBOX__", "oemTableId": "VBOXBIOS", "revision": "00001000" } ] },
  "pci": { "devices": [ { "bdf": "00:02.0", "vendorId": "80ee", "deviceId": "beef", "subsystemVendorId": "80ee", "subsystemDeviceId": "beef", "revision": "00" } ] },
  "storage": { "devices": [ { "vendor": "ATA", "model": "VBOX HARDDISK", "firmware": "1.0", "serial": "VB00000000000000" } ] },
  "nic": { "devices": [ { "mac": "08:00:27:12:34:56", "vendorId": "8086", "deviceId": "100e", "subsystemVendorId": "8086", "subsystemDeviceId": "001e", "revision": "00" } ] },
  "edid": { "displays": [ { "connector": "card0-Virtual-1", "edidHash": "sha256:0000000000000000000000000000000000000000000000000000000000000000" } ] },
  "tpm": { "present": false },
  "unavailable": []
}
JSON
}

if [ "$SELF_TEST" -eq 1 ]; then
    DOCUMENT="$(build_self_test_document)"
else
    DOCUMENT="$(build_document)"
fi

write_document "$OUTPUT" "$DOCUMENT"
echo "Guest identity written: $OUTPUT"
exit 0
