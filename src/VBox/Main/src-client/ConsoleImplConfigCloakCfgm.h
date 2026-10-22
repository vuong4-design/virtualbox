/* $Id$ */
/** @file
 * VBox Console COM Class implementation - Cloak CFGM materialization helpers.
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

#ifndef MAIN_INCLUDED_ConsoleImplConfigCloakCfgm_h
#define MAIN_INCLUDED_ConsoleImplConfigCloakCfgm_h
#ifndef RT_WITHOUT_PRAGMA_ONCE
# pragma once
#endif

#include "ConsoleImplConfigCloak.h"

#include <VBox/err.h>

/** Minimal CFGM interface used by the materialization helpers.
 * This keeps the production VMM vtable out of the unit test. */
typedef struct CLOAKCFGMVTABLE
{
    void *pvUser;
    bool (*pfnExists)(void *pvUser, void *pNode, const char *pszName);
    int (*pfnInsertString)(void *pvUser, void *pNode, const char *pszName, const char *pszValue);
    int (*pfnInsertInteger)(void *pvUser, void *pNode, const char *pszName, uint64_t u64Value);
    void *(*pfnGetChild)(void *pvUser, void *pRoot, const char *pszPath);
    int (*pfnQueryString)(void *pvUser, void *pNode, const char *pszName, char *pszValue, size_t cbValue);
    int (*pfnQueryInteger)(void *pvUser, void *pNode, const char *pszName, uint64_t *pu64Value);
} CLOAKCFGMVTABLE;
typedef const CLOAKCFGMVTABLE *PCCLOAKCFGMVTABLE;

DECLINLINE(bool) CloakCfgmExists(PCCLOAKCFGMVTABLE pCfgm, void *pNode, const char *pszName)
{
    if (!pCfgm || !pCfgm->pfnExists || !pNode || !pszName)
        return false;
    return pCfgm->pfnExists(pCfgm->pvUser, pNode, pszName);
}

DECLINLINE(int) CloakCfgmMaterializeString(PCCLOAKCFGMVTABLE pCfgm, void *pNode,
                                           const char *pszName, const char *pszValue)
{
    if (!pCfgm || !pCfgm->pfnExists || !pCfgm->pfnInsertString)
        return VERR_INVALID_PARAMETER;
    if (!pNode)
        return VINF_SUCCESS;
    if (!pszName)
        return VERR_INVALID_PARAMETER;
    if (!pszValue || !*pszValue || CloakCfgmExists(pCfgm, pNode, pszName))
        return VINF_SUCCESS;
    return pCfgm->pfnInsertString(pCfgm->pvUser, pNode, pszName, pszValue);
}

DECLINLINE(int) CloakCfgmMaterializeInteger(PCCLOAKCFGMVTABLE pCfgm, void *pNode,
                                            const char *pszName, uint64_t u64Value)
{
    if (!pCfgm || !pCfgm->pfnExists || !pCfgm->pfnInsertInteger)
        return VERR_INVALID_PARAMETER;
    if (!pNode)
        return VINF_SUCCESS;
    if (!pszName)
        return VERR_INVALID_PARAMETER;
    if (CloakCfgmExists(pCfgm, pNode, pszName))
        return VINF_SUCCESS;
    return pCfgm->pfnInsertInteger(pCfgm->pvUser, pNode, pszName, u64Value);
}

DECLINLINE(void *) CloakCfgmGetFirmwareConfig(PCCLOAKCFGMVTABLE pCfgm, void *pRoot)
{
    if (!pCfgm || !pCfgm->pfnGetChild || !pRoot)
        return NULL;

    void *pNode = pCfgm->pfnGetChild(pCfgm->pvUser, pRoot, "Devices/pcbios/0/Config");
    if (!pNode)
        pNode = pCfgm->pfnGetChild(pCfgm->pvUser, pRoot, "Devices/efi/0/Config");
    return pNode;
}

DECLINLINE(int) CloakCfgmMaterializeProfile(PCCLOAKCFGMVTABLE pCfgm, void *pFirmware, void *pAcpi,
                                            const MACHINEPROFILE *pProfile)
{
    if (!pCfgm || !pProfile)
        return VERR_INVALID_PARAMETER;
    if (!pFirmware)
        return VERR_NOT_FOUND;

    int vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiSystemVendor", pProfile->pszSystemVendor);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiSystemProduct", pProfile->pszSystemProduct);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiSystemVersion", pProfile->pszSystemVersion);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiSystemFamily", pProfile->pszSystemFamily);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiSystemSKU", pProfile->pszSystemSKU);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiSystemSerial", pProfile->pszSystemSerial);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiBIOSVendor", pProfile->pszBiosVendor);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiBIOSVersion", pProfile->pszBiosVersion);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiBIOSReleaseDate", pProfile->pszBiosReleaseDate);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiBoardVendor", pProfile->pszBoardVendor);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiBoardProduct", pProfile->pszBoardProduct);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiBoardSerial", pProfile->pszBoardSerial);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiChassisVendor", pProfile->pszChassisVendor);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pFirmware, "DmiChassisSerial", pProfile->pszChassisSerial);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pAcpi, "AcpiOemId", pProfile->pszAcpiOemId);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pAcpi, "AcpiCreatorId", pProfile->pszAcpiCreatorId);
    if (RT_SUCCESS(vrc)) vrc = CloakCfgmMaterializeString(pCfgm, pAcpi, "AcpiOemTabId", pProfile->pszAcpiOemTabId);

    uint32_t u32ChassisType = 0;
    if (RT_SUCCESS(vrc))
        vrc = CloakChassisTypeFromString(pProfile->pszChassisType, &u32ChassisType);
    if (RT_SUCCESS(vrc))
        vrc = CloakCfgmMaterializeInteger(pCfgm, pFirmware, "DmiChassisType", u32ChassisType);
    return vrc;
}

DECLINLINE(int) CloakCfgmValidateEffectiveString(PCCLOAKCFGMVTABLE pCfgm, void *pNode, const char *pszName,
                                                 size_t cchMax, bool fRequired)
{
    if (!pCfgm || !pCfgm->pfnQueryString || !pNode || !pszName)
        return VERR_INVALID_PARAMETER;

    char szValue[256];
    int vrc = pCfgm->pfnQueryString(pCfgm->pvUser, pNode, pszName, szValue, sizeof(szValue));
    if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
        return fRequired ? VERR_NOT_FOUND : VINF_SUCCESS;
    if (RT_FAILURE(vrc))
        return vrc;

    size_t cchValue = strlen(szValue);
    if (cchValue > cchMax || (cchValue == 0 && fRequired))
        return VERR_INVALID_PARAMETER;
    return VINF_SUCCESS;
}

DECLINLINE(int) CloakCfgmValidateEffectiveExactString(PCCLOAKCFGMVTABLE pCfgm, void *pNode, const char *pszName,
                                                      size_t cchExact, bool fRequired)
{
    if (!pCfgm || !pCfgm->pfnQueryString || !pNode || !pszName)
        return VERR_INVALID_PARAMETER;

    char szValue[256];
    int vrc = pCfgm->pfnQueryString(pCfgm->pvUser, pNode, pszName, szValue, sizeof(szValue));
    if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
        return fRequired ? VERR_NOT_FOUND : VINF_SUCCESS;
    if (RT_FAILURE(vrc))
        return vrc;
    return strlen(szValue) == cchExact ? VINF_SUCCESS : VERR_INVALID_PARAMETER;
}

DECLINLINE(int) CloakCfgmValidateEffectiveConfig(PCCLOAKCFGMVTABLE pCfgm, void *pFirmware, void *pAcpi)
{
    if (!pCfgm || !pCfgm->pfnQueryInteger || !pFirmware)
        return VERR_INVALID_PARAMETER;

    static const char * const s_apszDmiRequired[] =
    {
        "DmiSystemVendor",
        "DmiSystemProduct",
        "DmiSystemVersion",
        "DmiSystemFamily",
        "DmiBIOSVendor",
        "DmiBIOSVersion",
        "DmiBIOSReleaseDate",
        "DmiBoardVendor",
        "DmiBoardProduct",
        "DmiChassisVendor"
    };
    for (size_t i = 0; i < RT_ELEMENTS(s_apszDmiRequired); i++)
    {
        int vrc = CloakCfgmValidateEffectiveString(pCfgm, pFirmware, s_apszDmiRequired[i], 255, true);
        if (RT_FAILURE(vrc))
            return vrc;
    }

    uint64_t u64ChassisType = 0;
    int vrc = pCfgm->pfnQueryInteger(pCfgm->pvUser, pFirmware, "DmiChassisType", &u64ChassisType);
    if (RT_FAILURE(vrc))
        return vrc;
    if (u64ChassisType < 1 || u64ChassisType > 36)
        return VERR_INVALID_PARAMETER;

    if (pAcpi)
    {
        vrc = CloakCfgmValidateEffectiveString(pCfgm, pAcpi, "AcpiOemId", 6, true);
        if (RT_SUCCESS(vrc))
            vrc = CloakCfgmValidateEffectiveString(pCfgm, pAcpi, "AcpiCreatorId", 4, false);
        if (RT_SUCCESS(vrc))
            vrc = CloakCfgmValidateEffectiveExactString(pCfgm, pAcpi, "AcpiOemTabId", 4, false);
    }
    return vrc;
}

#endif /* !MAIN_INCLUDED_ConsoleImplConfigCloakCfgm_h */
