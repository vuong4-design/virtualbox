/* $Id$ */
/** @file
 * VBox Cloak - storage attachment routing and per-drive CFGM defaults.
 *
 * Copyright (C) 2026 Oracle and/or its affiliates.
 * SPDX-License-Identifier: GPL-3.0-only
 */
#ifndef MAIN_INCLUDED_ConsoleImplConfigCloakStorage_h
#define MAIN_INCLUDED_ConsoleImplConfigCloakStorage_h
#ifndef RT_WITHOUT_PRAGMA_ONCE
# pragma once
#endif

#include "ConsoleImplConfigCloakCfgm.h"

typedef struct CLOAKSTORAGEDEVICEIDENTITY
{
    const char *pszModel;
    const char *pszFirmware;
    const char *pszSerial;
} CLOAKSTORAGEDEVICEIDENTITY;
typedef const CLOAKSTORAGEDEVICEIDENTITY *PCCLOAKSTORAGEDEVICEIDENTITY;

/**
 * Explicitly synthetic lab ATAPI identity, never a real manufacturer's ID.
 * Optical and HDD profile switches are independent and disabled by default.
 */
typedef struct CLOAKSTORAGEOPTICALIDENTITY
{
    const char *pszModel;
    const char *pszFirmware;
    const char *pszSerial;
    const char *pszVendor;
    const char *pszProduct;
    const char *pszRevision;
} CLOAKSTORAGEOPTICALIDENTITY;
typedef const CLOAKSTORAGEOPTICALIDENTITY *PCCLOAKSTORAGEOPTICALIDENTITY;

/**
 * Maps a real storage attachment to the child of a controller's Config node.
 * The controller instance is supplied separately by the Console's COM graph.
 * IDE and SATA have different slot naming; never guess from Windows' SCSI ID.
 * Unsupported controllers are not modified.
 */
DECLINLINE(int) CloakStorageGetSlot(const char *pszDevice, int32_t iPort, int32_t iDevice,
                                   char *pszSlot, size_t cbSlot)
{
    if (!pszDevice || !pszSlot || !cbSlot)
        return VERR_INVALID_PARAMETER;
    if (!RTStrCmp(pszDevice, "ahci"))
    {
        if (iPort < 0 || iPort >= 32 || iDevice != 0)
            return VERR_INVALID_PARAMETER;
        char szPort[16];
        RTStrPrintf(szPort, sizeof(szPort), "Port%d", iPort);
        return RTStrCopy(pszSlot, cbSlot, szPort);
    }
    if (!RTStrCmp(pszDevice, "piix3ide"))
    {
        static const char * const s_apszSlots[2][2] =
        {
            { "PrimaryMaster", "PrimarySlave" },
            { "SecondaryMaster", "SecondarySlave" }
        };
        if (iPort < 0 || iPort >= 2 || iDevice < 0 || iDevice >= 2)
            return VERR_INVALID_PARAMETER;
        return RTStrCopy(pszSlot, cbSlot, s_apszSlots[iPort][iDevice]);
    }
    return VERR_NOT_SUPPORTED;
}

/** Stable, lab-only disk serial keyed by the machine's seed-derived stream
 * and its medium UUID. This is not a production hardware serial generator.
 * Never log the stream, UUID input or full output in a public CI artifact. */
DECLINLINE(int) CloakStorageLabSerial(uint64_t u64SerialStream, const char *pszMediumUuid,
                                     char *pszSerial, size_t cbSerial)
{
    if (!pszMediumUuid || !*pszMediumUuid || !pszSerial || cbSerial < 19)
        return VERR_INVALID_PARAMETER;
    RTUUID Uuid;
    int rc = RTUuidFromStr(&Uuid, pszMediumUuid);
    if (RT_FAILURE(rc))
        return rc;
    char szUuid[RTUUID_STR_LENGTH];
    rc = RTUuidToStr(&Uuid, szUuid, sizeof(szUuid));
    if (RT_FAILURE(rc))
        return rc;
    char szInput[128];
    size_t const cch = RTStrPrintf(szInput, sizeof(szInput), "CloakStorageLab-v1:%016RX64:%s",
                                   u64SerialStream, szUuid);
    if (cch >= sizeof(szInput))
        return VERR_BUFFER_OVERFLOW;
    uint8_t abHash[RTSHA256_HASH_SIZE];
    RTSha256(szInput, cch, abHash);
    RTMemWipeThoroughly(szInput, sizeof(szInput), 3);
    RTStrPrintf(pszSerial, cbSerial, "LB%02X%02X%02X%02X%02X%02X%02X%02X",
                abHash[0], abHash[1], abHash[2], abHash[3],
                abHash[4], abHash[5], abHash[6], abHash[7]);
    RTMemWipeThoroughly(abHash, sizeof(abHash), 3);
    return VINF_SUCCESS;
}

/** Stable synthetic optical serial derived from the VM's seed stream and
 * actual controller instance/slot. Does not require a mounted DVD image.
 * It will change after moving the optical drive to a different slot; stable
 * logical optical drive identifiers are not yet part of the lab protocol. */
DECLINLINE(int) CloakStorageLabOpticalSerial(uint64_t u64SerialStream, const char *pszDevice,
                                            uint32_t uInstance, const char *pszSlot,
                                            char *pszSerial, size_t cbSerial)
{
    if (!pszDevice || !*pszDevice || !pszSlot || !*pszSlot || !pszSerial || cbSerial < 19)
        return VERR_INVALID_PARAMETER;
    if (strlen(pszDevice) > 24 || strlen(pszSlot) > 32)
        return VERR_INVALID_PARAMETER;

    char szInput[160] = {};
    size_t const cch = RTStrPrintf(szInput, sizeof(szInput), "CloakOpticalLab-v1:%016RX64:%s:%u:%s",
                                   u64SerialStream, pszDevice, uInstance, pszSlot);
    if (cch >= sizeof(szInput))
    {
        RTMemWipeThoroughly(szInput, sizeof(szInput), 3);
        return VERR_BUFFER_OVERFLOW;
    }
    uint8_t abHash[RTSHA256_HASH_SIZE];
    RTSha256(szInput, cch, abHash);
    RTMemWipeThoroughly(szInput, sizeof(szInput), 3);
    RTStrPrintf(pszSerial, cbSerial, "LO%02X%02X%02X%02X%02X%02X%02X%02X",
                abHash[0], abHash[1], abHash[2], abHash[3],
                abHash[4], abHash[5], abHash[6], abHash[7]);
    RTMemWipeThoroughly(abHash, sizeof(abHash), 3);
    return VINF_SUCCESS;
}

/** Materialize per-attachment defaults only where no user ExtraData override
 * exists. All keys are already understood by stock DevAHCI and DevATA. */
DECLINLINE(int) CloakStorageMaterialize(PCCLOAKCFGMVTABLE pCfgm, void *pSlot,
                                       PCCLOAKSTORAGEDEVICEIDENTITY pIdentity)
{
    if (!pCfgm || !pSlot || !pIdentity
        || !pIdentity->pszModel || !*pIdentity->pszModel
        || !pIdentity->pszFirmware || !*pIdentity->pszFirmware
        || !pIdentity->pszSerial || !*pIdentity->pszSerial
        || strlen(pIdentity->pszModel) > 40
        || strlen(pIdentity->pszFirmware) > 8
        || strlen(pIdentity->pszSerial) > 20)
        return VERR_INVALID_PARAMETER;
    int rc = CloakCfgmMaterializeString(pCfgm, pSlot, "ModelNumber", pIdentity->pszModel);
    if (RT_SUCCESS(rc))
        rc = CloakCfgmMaterializeString(pCfgm, pSlot, "FirmwareRevision", pIdentity->pszFirmware);
    if (RT_SUCCESS(rc))
        rc = CloakCfgmMaterializeString(pCfgm, pSlot, "SerialNumber", pIdentity->pszSerial);
    return rc;
}

DECLINLINE(int) CloakStorageValidateEffective(PCCLOAKCFGMVTABLE pCfgm, void *pSlot)
{
    int rc = CloakCfgmValidateEffectiveString(pCfgm, pSlot, "ModelNumber", 40, true);
    if (RT_SUCCESS(rc))
        rc = CloakCfgmValidateEffectiveString(pCfgm, pSlot, "FirmwareRevision", 8, true);
    if (RT_SUCCESS(rc))
        rc = CloakCfgmValidateEffectiveString(pCfgm, pSlot, "SerialNumber", 20, true);
    return rc;
}

/** Synthetic, opt-in optical lab identity using the existing IDE/AHCI CFGM
 * backend sinks. This must NOT be called on host-drive/passthrough optical.
 * IDE uses OverwriteInquiry=1; AHCI does not expose that CFGM switch. */
DECLINLINE(int) CloakStorageMaterializeOptical(PCCLOAKCFGMVTABLE pCfgm, void *pSlot,
                                               PCCLOAKSTORAGEOPTICALIDENTITY pIdentity,
                                               bool fIde)
{
    if (!pCfgm || !pSlot || !pIdentity
        || !pIdentity->pszModel || !*pIdentity->pszModel
        || !pIdentity->pszFirmware || !*pIdentity->pszFirmware
        || !pIdentity->pszSerial || !*pIdentity->pszSerial
        || !pIdentity->pszVendor || !*pIdentity->pszVendor
        || !pIdentity->pszProduct || !*pIdentity->pszProduct
        || !pIdentity->pszRevision || !*pIdentity->pszRevision
        || strlen(pIdentity->pszModel) > 40 || strlen(pIdentity->pszFirmware) > 8
        || strlen(pIdentity->pszSerial) > 20
        || strlen(pIdentity->pszVendor) > 8 || strlen(pIdentity->pszProduct) > 16
        || strlen(pIdentity->pszRevision) > 4)
        return VERR_INVALID_PARAMETER;
    CLOAKSTORAGEDEVICEIDENTITY DiskFields = { pIdentity->pszModel, pIdentity->pszFirmware, pIdentity->pszSerial };
    int rc = CloakStorageMaterialize(pCfgm, pSlot, &DiskFields);
    if (RT_SUCCESS(rc))
        rc = CloakCfgmMaterializeString(pCfgm, pSlot, "ATAPIVendorId", pIdentity->pszVendor);
    if (RT_SUCCESS(rc))
        rc = CloakCfgmMaterializeString(pCfgm, pSlot, "ATAPIProductId", pIdentity->pszProduct);
    if (RT_SUCCESS(rc))
        rc = CloakCfgmMaterializeString(pCfgm, pSlot, "ATAPIRevision", pIdentity->pszRevision);
    if (RT_SUCCESS(rc) && fIde)
        rc = CloakCfgmMaterializeInteger(pCfgm, pSlot, "OverwriteInquiry", 1);
    return rc;
}

/**
 * Prevent falsely reporting lab storage materialization when there is no
 * supported attached HDD. This guard never changes device capabilities.
 */
DECLINLINE(int) CloakStorageValidateLabCoverage(bool fStorageLabEnabled, unsigned cEligible,
                                                unsigned cMaterialized)
{
    if (!fStorageLabEnabled)
        return VINF_SUCCESS;
    if (!cEligible)
        return VERR_NOT_FOUND;
    if (cMaterialized != cEligible)
        return VERR_MISMATCH;
    return VINF_SUCCESS;
}

/** Explicit optical coverage gate: mixed host-drive/virtual optical devices
 * cannot be represented as one lab identity profile. */
DECLINLINE(int) CloakStorageValidateLabOpticalCoverage(bool fEnabled, unsigned cPresent,
                                                       unsigned cEligible, unsigned cMaterialized)
{
    if (!fEnabled)
        return VINF_SUCCESS;
    if (!cPresent)
        return VERR_NOT_FOUND;
    if (cPresent != cEligible || cEligible != cMaterialized)
        return VERR_MISMATCH;
    return VINF_SUCCESS;
}

/**
 * LAB-only effective identity gate. ExtraData may override the inserted
 * defaults, but a partially overridden lab disk is NOT a coherent lab
 * device. Reject such a configuration before the virtual device starts.
 *
 * Keep the general-purpose CloakStorageValidateEffective() permissive
 * for non-lab callers. Never log or expose the expected serial here.
 */
DECLINLINE(int) CloakStorageValidateLabEffective(PCCLOAKCFGMVTABLE pCfgm, void *pSlot,
                                                PCCLOAKSTORAGEDEVICEIDENTITY pIdentity)
{
    if (!pCfgm || !pCfgm->pfnQueryString || !pSlot || !pIdentity
        || !pIdentity->pszModel || !pIdentity->pszFirmware || !pIdentity->pszSerial)
        return VERR_INVALID_PARAMETER;

    int rc = CloakStorageValidateEffective(pCfgm, pSlot);
    if (RT_FAILURE(rc))
        return rc;

    struct
    {
        const char *pszKey;
        const char *pszExpected;
    } const aFields[] =
    {
        { "ModelNumber",     pIdentity->pszModel },
        { "FirmwareRevision",pIdentity->pszFirmware },
        { "SerialNumber",    pIdentity->pszSerial }
    };
    for (size_t i = 0; i < RT_ELEMENTS(aFields); ++i)
    {
        char szValue[64] = {};
        rc = pCfgm->pfnQueryString(pCfgm->pvUser, pSlot, aFields[i].pszKey, szValue, sizeof(szValue));
        if (RT_SUCCESS(rc) && RTStrCmp(szValue, aFields[i].pszExpected))
            rc = VERR_MISMATCH;
        RTMemWipeThoroughly(szValue, sizeof(szValue), 3);
        if (RT_FAILURE(rc))
            return rc;
    }
    return VINF_SUCCESS;
}

/** Validate the exact optical descriptor values after user ExtraData overlay.
 * The separate public switches prevent accidental changes to stock optical.
 * Reject an IDE OverwriteInquiry=0 because then the reported SCSI identity
 * may come from another device rather than our CFGM vendor/product fields. */
DECLINLINE(int) CloakStorageValidateLabOpticalEffective(PCCLOAKCFGMVTABLE pCfgm, void *pSlot,
                                                        PCCLOAKSTORAGEOPTICALIDENTITY pIdentity,
                                                        bool fIde)
{
    if (!pCfgm || !pCfgm->pfnQueryString || !pSlot || !pIdentity)
        return VERR_INVALID_PARAMETER;
    CLOAKSTORAGEDEVICEIDENTITY DiskFields =
    {
        pIdentity->pszModel, pIdentity->pszFirmware, pIdentity->pszSerial
    };
    int rc = CloakStorageValidateLabEffective(pCfgm, pSlot, &DiskFields);
    if (RT_FAILURE(rc))
        return rc;

    struct
    {
        const char *pszKey;
        const char *pszExpected;
        size_t cchMax;
    } const aFields[] =
    {
        { "ATAPIVendorId",  pIdentity->pszVendor,  8 },
        { "ATAPIProductId", pIdentity->pszProduct, 16 },
        { "ATAPIRevision",  pIdentity->pszRevision, 4 }
    };
    for (size_t i = 0; i < RT_ELEMENTS(aFields); ++i)
    {
        if (!aFields[i].pszExpected || !*aFields[i].pszExpected)
            return VERR_INVALID_PARAMETER;
        rc = CloakCfgmValidateEffectiveString(pCfgm, pSlot, aFields[i].pszKey, aFields[i].cchMax, true);
        if (RT_FAILURE(rc))
            return rc;
        char szValue[64] = {};
        rc = pCfgm->pfnQueryString(pCfgm->pvUser, pSlot, aFields[i].pszKey, szValue, sizeof(szValue));
        if (RT_SUCCESS(rc) && RTStrCmp(szValue, aFields[i].pszExpected))
            rc = VERR_MISMATCH;
        RTMemWipeThoroughly(szValue, sizeof(szValue), 3);
        if (RT_FAILURE(rc))
            return rc;
    }
    if (fIde)
    {
        if (!pCfgm->pfnQueryInteger)
            return VERR_INVALID_PARAMETER;
        uint64_t uOverwrite = 0;
        rc = pCfgm->pfnQueryInteger(pCfgm->pvUser, pSlot, "OverwriteInquiry", &uOverwrite);
        if (RT_FAILURE(rc))
            return rc;
        if (uOverwrite != 1)
            return VERR_MISMATCH;
    }
    return VINF_SUCCESS;
}

#endif /* MAIN_INCLUDED_ConsoleImplConfigCloakStorage_h */
