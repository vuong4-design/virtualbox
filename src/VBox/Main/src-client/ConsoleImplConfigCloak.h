/* $Id$ */
/** @file
 * VBox Console COM Class implementation - Cloak Machine Profile Engine.
 */

/*
 * Copyright (C) 2026 Oracle and/or its affiliates.
 *
 * This file is part of VirtualBox base platform packages, as
 * available from https://www.virtualbox.org.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation, in version 3 of the
 * License.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, see <https://www.gnu.org/licenses>.
 *
 * SPDX-License-Identifier: GPL-3.0-only
 */

#ifndef MAIN_INCLUDED_ConsoleImplConfigCloak_h
#define MAIN_INCLUDED_ConsoleImplConfigCloak_h
#ifndef RT_WITHOUT_PRAGMA_ONCE
# pragma once
#endif

#include <iprt/assertcompile.h>
#include <iprt/cdefs.h>
#include <iprt/err.h>
#include <iprt/mem.h>
#include <iprt/sha.h>
#include <iprt/string.h>
#include <iprt/types.h>
#include <iprt/uuid.h>

#include <string.h>

#define CLOAK_SEED_SIZE                 32U
#define CLOAK_SEED_HEX_SIZE             (CLOAK_SEED_SIZE * 2U)
#define CLOAK_PROFILE_ID_MAX            64U

AssertCompile(CLOAK_SEED_SIZE == RTSHA256_HASH_SIZE);
AssertCompile(CLOAK_SEED_HEX_SIZE == RTSHA256_DIGEST_LEN);

#define CLOAKCHIPSET_I440FX             RT_BIT_32(0)
#define CLOAKCHIPSET_PIIX3              RT_BIT_32(1)
#define CLOAKCHIPSET_ICH9               RT_BIT_32(2)

typedef enum CLOAKPROFILECLASS
{
    CLOAKPROFILE_DRAFT = 0,
    CLOAKPROFILE_RESEARCH_ONLY,
    CLOAKPROFILE_COMPATIBLE
} CLOAKPROFILECLASS;

typedef struct MACHINEPROFILE
{
    const char *pszProfileId;
    const char *pszDisplayName;
    const char *pszSystemVendor;
    const char *pszSystemProduct;
    const char *pszSystemVersion;
    const char *pszSystemFamily;
    const char *pszSystemSKU;
    const char *pszSystemSerial;
    const char *pszBiosVendor;
    const char *pszBiosVersion;
    const char *pszBiosReleaseDate;
    const char *pszBoardVendor;
    const char *pszBoardProduct;
    const char *pszBoardSerial;
    const char *pszChassisVendor;
    const char *pszChassisType;
    const char *pszChassisSerial;
    const char *pszProcManufacturer;
    const char *pszAcpiOemId;
    const char *pszAcpiCreatorId;
    const char *pszAcpiOemTabId;
    const char *pszMpsOemId;
    const char *pszMpsProductId;
    const char *pszAcpiDmiOemId;
    const char *pszAcpiDmiOemTabId;
    const char *pszBiosRomVendor;
    const char *pszGuestCpuName;
    const char *pszCpuBrandString;
    uint16_t    uI440FxVendorId;
    uint16_t    uI440FxDeviceId;
    uint16_t    uPiix3IsaDeviceId;
    uint16_t    uXhciDeviceId;
    uint16_t    uAhciDeviceId;
    uint16_t    uAcpiPmDeviceId;
    uint16_t    uHdaDeviceId;
    uint16_t    uOhciDeviceId;
    uint64_t    uGpuModelId;
    const char *pszVbeVendor;
    const char *pszVbeProduct;
    const char *pszEdidManufacturer;
    const char *pszEdidModel;
    const char *pszEdidSerial;
    const char *pszAtaModel;
    const char *pszAtapiVendor;
    const char *pszAtapiProduct;
    const char *pszInquiryVendor;
    const char *pszInquiryProduct;
    const char *pszStorageSerial;
    uint8_t     uNonRotational;
    uint8_t     fTrimSupported;
    uint8_t     fSmartSupported;
    uint16_t    uNicVendorId;
    uint16_t    uNicDeviceId;
    uint16_t    uNicSubVendorId;
    uint16_t    uNicSubDeviceId;
    const char *pszEepromSubVendor;
    const char *pszEepromSubDevice;
    const char *pszTpmManufacturer;
    const char *pszTpmVendor1;
    const char *pszTpmVendor2;
    uint32_t    uTpmFirmwareV1;
    uint32_t    uTpmFirmwareV2;
    const char *pszBatteryType;
    const char *pszBatteryOem;
    uint16_t    uVmmDevVendorId;
    uint16_t    uVmmDevDeviceId;
    CLOAKPROFILECLASS enmClass;
    uint32_t    fSupportedChipsets;
    const char *pszRequiredFirmwareFamily;
    const char *pszSourceModel;
    const char *pszSourceBiosDate;
    const char *pszProvenanceHash;
} MACHINEPROFILE;

typedef struct CLOAKBUILDMANIFEST
{
    const char *pszBuildMode;
    const char *pszFirmwareFamily;
    const char *pszPcBiosVersion;
    const char *pszOvmfVersion;
    const char *pszDsdtHash;
    const char *pszVgaBiosHash;
    const char *pszBiosRomHash;
    uint32_t    fSupportedChipsets;
    uint16_t    uVmmDevVendorId;
    uint16_t    uVmmDevDeviceId;
    uint16_t    uVgaVendorId;
    uint16_t    uVgaDeviceId;
    uint16_t    uVirtioVendorId;
    const char *pszSourceRevision;
    const char *pszBuildHash;
} CLOAKBUILDMANIFEST;
typedef const CLOAKBUILDMANIFEST *PCCLOAKBUILDMANIFEST;

DECLINLINE(int) CloakValidateProfileAgainstManifest(const MACHINEPROFILE *pProfile, PCCLOAKBUILDMANIFEST pManifest)
{
    if (!pProfile || !pManifest || !pManifest->pszBuildMode)
        return VERR_INVALID_PARAMETER;
    if (pProfile->enmClass != CLOAKPROFILE_COMPATIBLE)
        return VERR_ACCESS_DENIED;
    if (RTStrCmp(pManifest->pszBuildMode, "cloak"))
        return VERR_NOT_SUPPORTED;
    if (   !pProfile->pszRequiredFirmwareFamily
        || !pManifest->pszFirmwareFamily
        || RTStrCmp(pProfile->pszRequiredFirmwareFamily, pManifest->pszFirmwareFamily))
        return VERR_NOT_SUPPORTED;
    if (   !pProfile->fSupportedChipsets
        || (pProfile->fSupportedChipsets & ~pManifest->fSupportedChipsets))
        return VERR_NOT_SUPPORTED;
    if (   pProfile->uVmmDevVendorId != pManifest->uVmmDevVendorId
        || pProfile->uVmmDevDeviceId != pManifest->uVmmDevDeviceId)
        return VERR_NOT_SUPPORTED;
    if (!pProfile->pszProvenanceHash || !*pProfile->pszProvenanceHash)
        return VERR_NOT_SUPPORTED;
    return VINF_SUCCESS;
}

DECLHIDDEN(const MACHINEPROFILE *) CloakGetTestProfile(void);
DECLHIDDEN(const MACHINEPROFILE *) CloakFindProfile(const char *pszProfileId, bool fAllowTestProfile);
DECLHIDDEN(PCCLOAKBUILDMANIFEST) CloakGetBuildManifest(void);
DECLHIDDEN(bool) CloakBuildSupportsCloak(void);

DECLINLINE(const char *) CloakProfileClassToString(CLOAKPROFILECLASS enmClass)
{
    switch (enmClass)
    {
        case CLOAKPROFILE_DRAFT:         return "DRAFT";
        case CLOAKPROFILE_RESEARCH_ONLY: return "RESEARCH_ONLY";
        case CLOAKPROFILE_COMPATIBLE:    return "COMPATIBLE";
        default:                         return "UNKNOWN";
    }
}

DECLINLINE(uint64_t) CloakSplitMix64(uint64_t *pu64State)
{
    uint64_t u64Z = (*pu64State += 0x9e3779b97f4a7c15ULL);
    u64Z = (u64Z ^ (u64Z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    u64Z = (u64Z ^ (u64Z >> 27)) * 0x94d049bb133111ebULL;
    return u64Z ^ (u64Z >> 31);
}

DECLINLINE(void) CloakHmacSha256(const void *pvKey, size_t cbKey, const void *pvData, size_t cbData,
                                 uint8_t pabDigest[RTSHA256_HASH_SIZE])
{
    uint8_t abKey[RTSHA256_HASH_SIZE * 2];
    RT_ZERO(abKey);
    if (cbKey > sizeof(abKey))
        RTSha256(pvKey, cbKey, abKey);
    else if (cbKey)
        memcpy(abKey, pvKey, cbKey);

    uint8_t abPad[RTSHA256_HASH_SIZE * 2];
    uint8_t abInner[RTSHA256_HASH_SIZE];
    RTSHA256CONTEXT Ctx;

    for (size_t i = 0; i < sizeof(abPad); i++)
        abPad[i] = abKey[i] ^ 0x36;
    RTSha256Init(&Ctx);
    RTSha256Update(&Ctx, abPad, sizeof(abPad));
    RTSha256Update(&Ctx, pvData, cbData);
    RTSha256Final(&Ctx, abInner);

    for (size_t i = 0; i < sizeof(abPad); i++)
        abPad[i] = abKey[i] ^ 0x5c;
    RTSha256Init(&Ctx);
    RTSha256Update(&Ctx, abPad, sizeof(abPad));
    RTSha256Update(&Ctx, abInner, sizeof(abInner));
    RTSha256Final(&Ctx, pabDigest);

    RTMemWipeThoroughly(abKey, sizeof(abKey), 3);
    RTMemWipeThoroughly(abPad, sizeof(abPad), 3);
    RTMemWipeThoroughly(abInner, sizeof(abInner), 3);
    RTMemWipeThoroughly(&Ctx, sizeof(Ctx), 3);
}

DECLINLINE(int) CloakSeedDecode(const char *pszValue, uint8_t *pabSeed, size_t cbSeed)
{
    if (!pszValue || !pabSeed || cbSeed != (size_t)CLOAK_SEED_SIZE)
        return VERR_INVALID_PARAMETER;
    if (RTStrStartsWith(pszValue, "string:"))
        pszValue += sizeof("string:") - 1;
    if (RTStrNLen(pszValue, (size_t)CLOAK_SEED_HEX_SIZE + 1) != (size_t)CLOAK_SEED_HEX_SIZE)
        return VERR_INVALID_PARAMETER;

    int vrc = RTStrConvertHexBytes(pszValue, pabSeed, cbSeed, 0);
    return RT_SUCCESS(vrc) ? VINF_SUCCESS : VERR_INVALID_PARAMETER;
}

DECLINLINE(int) CloakSeedStreams(const uint8_t *pabSeed, size_t cbSeed, PCRTUUID pUuid,
                                 uint64_t *pu64Profile, uint64_t *pu64Serial, uint64_t *pu64Jitter)
{
    if (!pabSeed || cbSeed != (size_t)CLOAK_SEED_SIZE || !pUuid || !pu64Profile || !pu64Serial || !pu64Jitter)
        return VERR_INVALID_PARAMETER;

    static const char s_szDomain[] = "VBoxCloakProfile";
    uint8_t abMsg[sizeof(s_szDomain) - 1 + sizeof(pUuid->au8)];
    memcpy(abMsg, s_szDomain, sizeof(s_szDomain) - 1);
    memcpy(&abMsg[sizeof(s_szDomain) - 1], pUuid->au8, sizeof(pUuid->au8));

    uint8_t abHash[RTSHA256_HASH_SIZE];
    CloakHmacSha256(pabSeed, cbSeed, abMsg, sizeof(abMsg), abHash);

    uint64_t u64Base;
    memcpy(&u64Base, abHash, sizeof(u64Base));
    u64Base = RT_LE2H_U64(u64Base);

    uint64_t u64State = u64Base + 1;
    *pu64Profile = CloakSplitMix64(&u64State);
    u64State = u64Base + 2;
    *pu64Serial = CloakSplitMix64(&u64State);
    u64State = u64Base + 3;
    *pu64Jitter = CloakSplitMix64(&u64State);

    RTMemWipeThoroughly(abMsg, sizeof(abMsg), 3);
    RTMemWipeThoroughly(abHash, sizeof(abHash), 3);
    RTMemWipeThoroughly(&u64Base, sizeof(u64Base), 3);
    RTMemWipeThoroughly(&u64State, sizeof(u64State), 3);
    return VINF_SUCCESS;
}

DECLINLINE(int) CloakSeedHashHex(const uint8_t *pabSeed, size_t cbSeed, char *pszHash, size_t cchHash)
{
    if (!pabSeed || cbSeed != (size_t)CLOAK_SEED_SIZE || !pszHash || cchHash < (size_t)RTSHA256_DIGEST_LEN + 1)
        return VERR_INVALID_PARAMETER;

    uint8_t abHash[RTSHA256_HASH_SIZE];
    RTSha256(pabSeed, cbSeed, abHash);
    int vrc = RTStrPrintHexBytes(pszHash, cchHash, abHash, sizeof(abHash), RTSTRPRINTHEXBYTES_F_UPPER);
    RTMemWipeThoroughly(abHash, sizeof(abHash), 3);
    return vrc;
}

#endif /* !MAIN_INCLUDED_ConsoleImplConfigCloak_h */
