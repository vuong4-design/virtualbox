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

#define LOG_GROUP LOG_GROUP_MAIN_CONSOLE
#include "LoggingNew.h"

#include "ConsoleImpl.h"
#include "ConsoleImplConfigCloak.h"

#include <VBox/com/Guid.h>
#include <VBox/err.h>
#include <VBox/vmm/vmmr3vtable.h>

static const MACHINEPROFILE *cloakGetTestProfile(void)
{
    static const MACHINEPROFILE s_Profile = []() -> MACHINEPROFILE
    {
        MACHINEPROFILE Profile = {};
        Profile.pszProfileId = "test-profile-synthetic";
        Profile.pszDisplayName = "Synthetic test profile";
        Profile.pszSystemVendor = "VBoxCloak";
        Profile.pszSystemProduct = "Synthetic";
        Profile.pszSystemVersion = "1.0";
        Profile.pszSystemFamily = "Synthetic";
        Profile.pszBiosVendor = "VBoxCloak";
        Profile.pszBiosVersion = "0.0";
        Profile.pszBiosReleaseDate = "19700101";
        Profile.pszBoardVendor = "VBoxCloak";
        Profile.pszBoardProduct = "Synthetic";
        Profile.pszChassisVendor = "VBoxCloak";
        Profile.pszChassisType = "Other";
        Profile.pszProcManufacturer = "GenuineIntel";
        Profile.pszAcpiOemId = "VBOX";
        Profile.pszGuestCpuName = "Synthetic CPU";
        Profile.pszCpuBrandString = "Synthetic CPU";
        Profile.uI440FxVendorId = 0x8086;
        Profile.uI440FxDeviceId = 0x1237;
        Profile.uPiix3IsaDeviceId = 0x7000;
        Profile.uNicVendorId = 0x8086;
        Profile.uNicDeviceId = 0x100e;
        Profile.uVmmDevVendorId = 0x80ee;
        Profile.uVmmDevDeviceId = 0xcafe;
        Profile.enmClass = CLOAKPROFILE_DRAFT;
        Profile.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
        Profile.pszRequiredFirmwareFamily = "synthetic";
        Profile.pszSourceModel = "test";
        Profile.pszSourceBiosDate = "19700101";
        Profile.pszProvenanceHash = "synthetic";
        return Profile;
    }();
    return &s_Profile;
}

DECLHIDDEN(const MACHINEPROFILE *) CloakGetTestProfile(void)
{
    return cloakGetTestProfile();
}

static const MACHINEPROFILE * const g_apCloakProfiles[] =
{
    NULL
};

DECLHIDDEN(const MACHINEPROFILE *) CloakFindProfile(const char *pszProfileId, bool fAllowTestProfile)
{
    if (!pszProfileId || !*pszProfileId)
        return NULL;

    if (fAllowTestProfile && !RTStrCmp(pszProfileId, cloakGetTestProfile()->pszProfileId))
        return cloakGetTestProfile();

    for (size_t i = 0; i < RT_ELEMENTS(g_apCloakProfiles); i++)
        if (g_apCloakProfiles[i] && !RTStrCmp(pszProfileId, g_apCloakProfiles[i]->pszProfileId))
            return g_apCloakProfiles[i];
    return NULL;
}

#ifndef VBOX_WITH_CLOAK_BUILD
static const CLOAKBUILDMANIFEST g_StockBuildManifest =
{
    "stock",
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    0,
    0x80ee,
    0xcafe,
    0x80ee,
    0xbeef,
    0x1af4,
    NULL,
    NULL
};
#else
static const CLOAKBUILDMANIFEST g_CloakBuildManifest =
{
    "cloak",
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    0,
    0x80ee,
    0xcafe,
    0x80ee,
    0xbeef,
    0x1af4,
    NULL,
    NULL
};
#endif

DECLHIDDEN(PCCLOAKBUILDMANIFEST) CloakGetBuildManifest(void)
{
#ifdef VBOX_WITH_CLOAK_BUILD
    return &g_CloakBuildManifest;
#else
    return &g_StockBuildManifest;
#endif
}

DECLHIDDEN(bool) CloakBuildSupportsCloak(void)
{
    return !RTStrCmp(CloakGetBuildManifest()->pszBuildMode, "cloak");
}

static int cloakQueryBool(PCVMMR3VTABLE pVMM, PCFGMNODE pNode, const char *pszName, bool *pfValue)
{
    uint64_t u64Value = 0;
    int vrc = pVMM->pfnCFGMR3QueryInteger(pNode, pszName, &u64Value);
    if (RT_SUCCESS(vrc))
    {
        *pfValue = u64Value != 0;
        return VINF_SUCCESS;
    }
    if (vrc != VERR_CFGM_NOT_INTEGER)
        return vrc;

    char szValue[16];
    vrc = pVMM->pfnCFGMR3QueryString(pNode, pszName, szValue, sizeof(szValue));
    if (RT_FAILURE(vrc))
        return vrc;

    if (   !RTStrICmp(szValue, "true")
        || !RTStrICmp(szValue, "yes")
        || !RTStrICmp(szValue, "on"))
    {
        *pfValue = true;
        return VINF_SUCCESS;
    }
    if (   !RTStrICmp(szValue, "false")
        || !RTStrICmp(szValue, "no")
        || !RTStrICmp(szValue, "off"))
    {
        *pfValue = false;
        return VINF_SUCCESS;
    }
    return VERR_INVALID_PARAMETER;
}

static int cloakQueryString(PCVMMR3VTABLE pVMM, PCFGMNODE pNode, const char *pszName,
                            char *pszValue, size_t cbValue)
{
    pszValue[0] = '\0';
    return pVMM->pfnCFGMR3QueryString(pNode, pszName, pszValue, cbValue);
}

int Console::i_configCloak(PCFGMNODE pRoot, IVirtualBox *pVirtualBox, IMachine *pMachine)
{
    RT_NOREF(pVirtualBox, pMachine);

    PCFGMNODE pCloak = mpVMM->pfnCFGMR3GetChild(pRoot, "Cloak");
    if (!pCloak)
        return VINF_SUCCESS;

    bool fEnabled = false;
    int vrc = cloakQueryBool(mpVMM, pCloak, "Enabled", &fEnabled);
    if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
        fEnabled = false;
    else if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: invalid /Cloak/Enabled value, vrc=%Rrc\n", vrc));
        return vrc;
    }
    if (!fEnabled)
    {
        LogRel(("Cloak: runtime cloak disabled\n"));
        return VINF_SUCCESS;
    }

    PCCLOAKBUILDMANIFEST pManifest = CloakGetBuildManifest();
    if (!pManifest || !pManifest->pszBuildMode || RTStrCmp(pManifest->pszBuildMode, "cloak"))
    {
        LogRel(("Cloak: enabled in a '%s' build; a cloak build is required\n",
                pManifest && pManifest->pszBuildMode ? pManifest->pszBuildMode : "unknown"));
        return VERR_NOT_SUPPORTED;
    }

    char szProfile[CLOAK_PROFILE_ID_MAX];
    vrc = cloakQueryString(mpVMM, pCloak, "Profile", szProfile, sizeof(szProfile));
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: /Cloak/Profile is missing or invalid, vrc=%Rrc\n", vrc));
        return vrc;
    }

    const MACHINEPROFILE *pProfile = CloakFindProfile(szProfile, false);
    if (!pProfile)
    {
        LogRel(("Cloak: profile '%s' is not available in the production registry\n", szProfile));
        return VERR_NOT_FOUND;
    }
    if (pProfile->enmClass != CLOAKPROFILE_COMPATIBLE)
    {
        LogRel(("Cloak: profile '%s' has non-production class %s\n",
                pProfile->pszProfileId, CloakProfileClassToString(pProfile->enmClass)));
        return VERR_ACCESS_DENIED;
    }

    vrc = CloakValidateProfileAgainstManifest(pProfile, pManifest);
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: profile '%s' is incompatible with the build manifest, vrc=%Rrc\n",
                pProfile->pszProfileId, vrc));
        return vrc;
    }

    char szSeedHashStored[RTSHA256_DIGEST_LEN + 1];
    vrc = cloakQueryString(mpVMM, pCloak, "SeedHash", szSeedHashStored, sizeof(szSeedHashStored));
    if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
        szSeedHashStored[0] = '\0';
    else if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: /Cloak/SeedHash is invalid, vrc=%Rrc\n", vrc));
        return vrc;
    }

    char szSeed[CLOAK_SEED_HEX_SIZE + sizeof("string:")];
    vrc = cloakQueryString(mpVMM, pCloak, "Seed", szSeed, sizeof(szSeed));
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: /Cloak/Seed is missing or invalid; run cloak provision first\n"));
        return VERR_NOT_FOUND;
    }

    uint8_t abSeed[CLOAK_SEED_SIZE];
    vrc = CloakSeedDecode(szSeed, abSeed, sizeof(abSeed));
    RTMemWipeThoroughly(szSeed, sizeof(szSeed), 3);
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: /Cloak/Seed is malformed; run cloak provision again\n"));
        RTMemWipeThoroughly(abSeed, sizeof(abSeed), 3);
        return vrc;
    }

    com::Guid Uuid(i_getId());
    if (Uuid.isZero())
    {
        RTMemWipeThoroughly(abSeed, sizeof(abSeed), 3);
        LogRel(("Cloak: machine UUID is invalid\n"));
        return VERR_INVALID_PARAMETER;
    }

    uint64_t u64Profile = 0;
    uint64_t u64Serial = 0;
    uint64_t u64Jitter = 0;
    vrc = CloakSeedStreams(abSeed, sizeof(abSeed), Uuid.raw(), &u64Profile, &u64Serial, &u64Jitter);
    if (RT_FAILURE(vrc))
    {
        RTMemWipeThoroughly(abSeed, sizeof(abSeed), 3);
        LogRel(("Cloak: failed to derive selector streams, vrc=%Rrc\n", vrc));
        return vrc;
    }

    char szSeedHash[RTSHA256_DIGEST_LEN + 1];
    vrc = CloakSeedHashHex(abSeed, sizeof(abSeed), szSeedHash, sizeof(szSeedHash));
    RTMemWipeThoroughly(abSeed, sizeof(abSeed), 3);
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: failed to hash seed, vrc=%Rrc\n", vrc));
        return vrc;
    }
    if (szSeedHashStored[0] && RTStrICmp(szSeedHashStored, szSeedHash))
    {
        LogRel(("Cloak: provisioned seed hash does not match the seed; refusing mixed identity\n"));
        return VERR_MISMATCH;
    }

    try
    {
        PCFGMNODE pResolved = NULL;
        InsertConfigNode(pCloak, "Resolved", &pResolved);
        InsertConfigString(pResolved, "ProfileId", pProfile->pszProfileId);
        InsertConfigString(pResolved, "Class", CloakProfileClassToString(pProfile->enmClass));
        InsertConfigString(pResolved, "SeedHash", szSeedHash);
        InsertConfigInteger(pResolved, "SelectorProfile", u64Profile);
        InsertConfigInteger(pResolved, "SelectorSerial", u64Serial);
        InsertConfigInteger(pResolved, "SelectorJitter", u64Jitter);
        RemoveConfigValue(pCloak, "Seed");
    }
    catch (ConfigError &x)
    {
        LogRel(("Cloak: failed to materialize control plane, vrc=%Rrc\n", x.m_vrc));
        return x.m_vrc;
    }

    LogRel(("Cloak: profile '%s' selected; runtime identity materialization deferred\n",
            pProfile->pszProfileId));
    return VINF_SUCCESS;
}
