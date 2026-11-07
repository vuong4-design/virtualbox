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
#include "ConsoleImplConfigCloakCfgm.h"
#include "ConsoleImplConfigCloakStorage.h"

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

#ifdef VBOX_WITH_CLOAK_LAB_PROFILE
/*
 * Explicitly opt-in development profile for real-VM DMI/ACPI testing.
 * This profile is NOT registered as a production-compatible profile and
 * never changes the Guest Additions PCI/graphics identity bindings.
 */
static const MACHINEPROFILE *cloakGetLabProfile(void)
{
    static const MACHINEPROFILE s_Profile = []() -> MACHINEPROFILE
    {
        MACHINEPROFILE Profile = {};
        Profile.pszProfileId = "lab-dmi-v1";
        Profile.pszDisplayName = "Lab-only DMI and ACPI profile";
        Profile.pszSystemVendor = "LabVendor";
        Profile.pszSystemProduct = "LabDesktop-01";
        Profile.pszSystemVersion = "1.0";
        Profile.pszSystemFamily = "Lab Desktop";
        Profile.pszBiosVendor = "LabFirmware";
        Profile.pszBiosVersion = "LAB-1.0";
        Profile.pszBiosReleaseDate = "20261104";
        Profile.pszBoardVendor = "LabVendor";
        Profile.pszBoardProduct = "LabBoard-01";
        Profile.pszChassisVendor = "LabVendor";
        Profile.pszChassisType = "Desktop";
        Profile.pszProcManufacturer = "GenuineIntel";
        Profile.pszAcpiOemId = "LAB";
        Profile.pszAcpiOemTabId = "LAB0";
        Profile.pszAtaModel = "LAB ATA DISK";
        Profile.pszAtapiVendor = "LAB";
        Profile.pszAtapiProduct = "CD-ROM";
        Profile.pszInquiryVendor = "LAB";
        Profile.pszInquiryProduct = "SCSI DISK";
        Profile.uI440FxVendorId = 0x8086;
        Profile.uI440FxDeviceId = 0x1237;
        Profile.uPiix3IsaDeviceId = 0x7000;
        Profile.uNicVendorId = 0x8086;
        Profile.uNicDeviceId = 0x100e;
        Profile.uVmmDevVendorId = CLOAKBINDING_VMMDEV_VENDOR_ID;
        Profile.uVmmDevDeviceId = CLOAKBINDING_VMMDEV_DEVICE_ID;
        Profile.enmClass = CLOAKPROFILE_DRAFT;
        Profile.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
        Profile.pszRequiredFirmwareFamily = "virtualbox-lab";
        Profile.pszSourceModel = "lab-only";
        Profile.pszSourceBiosDate = "20261104";
        Profile.pszProvenanceHash = "lab-only-not-for-production";
        return Profile;
    }();
    return &s_Profile;
}
#endif
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
    CLOAKBINDING_VMMDEV_VENDOR_ID,
    CLOAKBINDING_VMMDEV_DEVICE_ID,
    CLOAKBINDING_VGA_VENDOR_ID,
    CLOAKBINDING_VGA_DEVICE_ID,
    CLOAKBINDING_VIRTIO_VENDOR_ID,
    NULL,
    NULL
};
#else
# include "CloakBuildIdentity.h"
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

static bool cloakVmmCfgmExists(void *pvUser, void *pNode, const char *pszName)
{
    return ((PCVMMR3VTABLE)pvUser)->pfnCFGMR3Exists((PCFGMNODE)pNode, pszName);
}

static int cloakVmmCfgmInsertString(void *pvUser, void *pNode, const char *pszName, const char *pszValue)
{
    return ((PCVMMR3VTABLE)pvUser)->pfnCFGMR3InsertString((PCFGMNODE)pNode, pszName, pszValue);
}

static int cloakVmmCfgmInsertInteger(void *pvUser, void *pNode, const char *pszName, uint64_t u64Value)
{
    return ((PCVMMR3VTABLE)pvUser)->pfnCFGMR3InsertInteger((PCFGMNODE)pNode, pszName, u64Value);
}

static void *cloakVmmCfgmGetChild(void *pvUser, void *pRoot, const char *pszPath)
{
    return (void *)((PCVMMR3VTABLE)pvUser)->pfnCFGMR3GetChild((PCFGMNODE)pRoot, pszPath);
}

static int cloakVmmCfgmQueryString(void *pvUser, void *pNode, const char *pszName, char *pszValue, size_t cbValue)
{
    return ((PCVMMR3VTABLE)pvUser)->pfnCFGMR3QueryString((PCFGMNODE)pNode, pszName, pszValue, cbValue);
}

static int cloakVmmCfgmQueryInteger(void *pvUser, void *pNode, const char *pszName, uint64_t *pu64Value)
{
    return ((PCVMMR3VTABLE)pvUser)->pfnCFGMR3QueryInteger((PCFGMNODE)pNode, pszName, pu64Value);
}

static CLOAKCFGMVTABLE cloakCreateCfgmVTable(PCVMMR3VTABLE pVMM)
{
    CLOAKCFGMVTABLE Cfgm;
    Cfgm.pvUser = (void *)pVMM;
    Cfgm.pfnExists = cloakVmmCfgmExists;
    Cfgm.pfnInsertString = cloakVmmCfgmInsertString;
    Cfgm.pfnInsertInteger = cloakVmmCfgmInsertInteger;
    Cfgm.pfnGetChild = cloakVmmCfgmGetChild;
    Cfgm.pfnQueryString = cloakVmmCfgmQueryString;
    Cfgm.pfnQueryInteger = cloakVmmCfgmQueryInteger;
    return Cfgm;
}

int Console::i_configCloak(PCFGMNODE pRoot, IVirtualBox *pVirtualBox, IMachine *pMachine)
{
    RT_NOREF(pVirtualBox);

    PCFGMNODE pCloak = mpVMM->pfnCFGMR3GetChild(pRoot, "Cloak");
    if (!pCloak)
    {
        int vrc = i_cloakSetCurrentStateIdentity(false, NULL, NULL);
        if (RT_FAILURE(vrc))
            LogRel(("Cloak: saved state identity check failed, vrc=%Rrc\n", vrc));
        return vrc;
    }

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
        vrc = i_cloakSetCurrentStateIdentity(false, NULL, NULL);
        if (RT_FAILURE(vrc))
        {
            LogRel(("Cloak: saved state identity check failed, vrc=%Rrc\n", vrc));
            return vrc;
        }
        LogRel(("Cloak: runtime cloak disabled\n"));
        return VINF_SUCCESS;
    }

    char szProfile[CLOAK_PROFILE_ID_MAX];
    vrc = cloakQueryString(mpVMM, pCloak, "Profile", szProfile, sizeof(szProfile));
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: /Cloak/Profile is required; automatic selection is not implemented, vrc=%Rrc\n", vrc));
        return vrc;
    }

    /*
     * The lab profile is a deliberately separate, explicit development path:
     * it may materialize DMI/ACPI on a throwaway test VM, but never enters the
     * production registry or relaxes any production manifest validation.
     */
    bool fLabProfile = false;
#ifdef VBOX_WITH_CLOAK_LAB_PROFILE
    fLabProfile = !RTStrCmp(szProfile, cloakGetLabProfile()->pszProfileId);
#endif
    PCCLOAKBUILDMANIFEST pManifest = CloakGetBuildManifest();
    if (!fLabProfile)
    {
        if (!pManifest || !pManifest->pszBuildMode || RTStrCmp(pManifest->pszBuildMode, "cloak"))
        {
            LogRel(("Cloak: enabled in a '%s' build; a cloak build is required\n",
                    pManifest && pManifest->pszBuildMode ? pManifest->pszBuildMode : "unknown"));
            return VERR_NOT_SUPPORTED;
        }
        vrc = CloakValidateBuildManifest(pManifest);
        if (RT_FAILURE(vrc))
        {
            LogRel(("Cloak: build manifest is incomplete or violates the binding contract, vrc=%Rrc\n", vrc));
            return vrc;
        }
        vrc = CloakValidateProductionRegistry(g_apCloakProfiles, RT_ELEMENTS(g_apCloakProfiles), pManifest);
        if (RT_FAILURE(vrc))
        {
            LogRel(("Cloak: production profile registry is invalid, vrc=%Rrc\n", vrc));
            return vrc;
        }
    }

    const MACHINEPROFILE *pProfile = NULL;
#ifdef VBOX_WITH_CLOAK_LAB_PROFILE
    if (fLabProfile)
        pProfile = cloakGetLabProfile();
    else
#endif
        pProfile = CloakFindProfile(szProfile, false);
    if (!pProfile)
    {
        LogRel(("Cloak: profile '%s' is not available in the production registry\n", szProfile));
        return VERR_NOT_FOUND;
    }

    vrc = CloakValidateProfileForMaterialization(pProfile);
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: profile '%s' is missing materializable DMI/ACPI fields, vrc=%Rrc\n",
                pProfile->pszProfileId, vrc));
        return vrc;
    }
    if (fLabProfile)
    {
        if (pProfile->enmClass != CLOAKPROFILE_DRAFT
            || pProfile->uVmmDevVendorId != CLOAKBINDING_VMMDEV_VENDOR_ID
            || pProfile->uVmmDevDeviceId != CLOAKBINDING_VMMDEV_DEVICE_ID)
            return VERR_ACCESS_DENIED;
        LogRel(("Cloak: LAB DMI/ACPI profile selected (not a production cloak build)\n"));
    }
    else
    {
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

    vrc = i_cloakSetCurrentStateIdentity(true, pProfile->pszProfileId, szSeedHash);
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: saved state identity check failed for profile '%s', vrc=%Rrc\n",
                pProfile->pszProfileId, vrc));
        return vrc;
    }

    CLOAKCFGMVTABLE Cfgm = cloakCreateCfgmVTable(mpVMM);
    void *pFirmware = CloakCfgmGetFirmwareConfig(&Cfgm, pRoot);
    if (!pFirmware)
    {
        LogRel(("Cloak: firmware configuration is unavailable\n"));
        return VERR_NOT_FOUND;
    }

    void *pAcpi = (void *)mpVMM->pfnCFGMR3GetChild(pRoot, "Devices/acpi/0/Config");
    if (!pAcpi)
        LogRel(("Cloak: ACPI configuration is unavailable; ACPI identity will not be materialized\n"));
    vrc = CloakCfgmMaterializeProfile(&Cfgm, pFirmware, pAcpi, pProfile);
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: failed to materialize profile '%s', vrc=%Rrc\n", pProfile->pszProfileId, vrc));
        return vrc;
    }

    /* Complete the lab ACPI table header experiment only when the lab profile is selected. */
    if (fLabProfile)
    {
        if (!pAcpi)
        {
            LogRel(("Cloak: lab ACPI identity requires an ACPI device\n"));
            return VERR_NOT_FOUND;
        }
        /* Reject conflicting user overrides rather than creating mixed OEM headers. */
        char szLabOem[16];
        char szLabTableId[16];
        int rcOem = Cfgm.pfnQueryString(Cfgm.pvUser, pAcpi, "AcpiOemId", szLabOem, sizeof(szLabOem));
        int rcTab = Cfgm.pfnQueryString(Cfgm.pvUser, pAcpi, "AcpiOemTabId", szLabTableId, sizeof(szLabTableId));
        if (   RT_FAILURE(rcOem) || RT_FAILURE(rcTab)
            || RTStrCmp(szLabOem, pProfile->pszAcpiOemId)
            || RTStrCmp(szLabTableId, pProfile->pszAcpiOemTabId))
        {
            LogRel(("Cloak: lab ACPI OEM values conflict with CFGM overrides\n"));
            return VERR_MISMATCH;
        }
        vrc = CloakCfgmMaterializeInteger(&Cfgm, pAcpi, "CloakLabPatchHeaders", 1);
        if (RT_FAILURE(vrc))
            return vrc;
        uint64_t uLabEnabled = 0;
        vrc = Cfgm.pfnQueryInteger(Cfgm.pvUser, pAcpi, "CloakLabPatchHeaders", &uLabEnabled);
        if (RT_FAILURE(vrc) || uLabEnabled != 1)
        {
            LogRel(("Cloak: lab ACPI header switch is not enabled\n"));
            return VERR_INVALID_PARAMETER;
        }
    }

    vrc = CloakCfgmValidateEffectiveConfig(&Cfgm, pFirmware, pAcpi);
    if (RT_FAILURE(vrc))
    {
        LogRel(("Cloak: effective profile '%s' is inconsistent, vrc=%Rrc\n", pProfile->pszProfileId, vrc));
        return vrc;
    }

    /* Opt-in: a new host binary must not silently change boot disk identity. */
    bool fLabStorageEnabled = false;
    if (fLabProfile)
    {
        vrc = cloakQueryBool(mpVMM, pCloak, "StorageLabEnabled", &fLabStorageEnabled);
        if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
            fLabStorageEnabled = false;
        else if (RT_FAILURE(vrc))
            return vrc;
    }
    /* S2 is separately opt-in: an already-attached snapshot leaf must not
     * experience a surprise serial change merely due to a host upgrade. */
    bool fLabRootSerialEnabled = false;
    if (fLabProfile && fLabStorageEnabled)
    {
        vrc = cloakQueryBool(mpVMM, pCloak, "StorageLabRootSerialEnabled", &fLabRootSerialEnabled);
        if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
            fLabRootSerialEnabled = false;
        else if (RT_FAILURE(vrc))
            return vrc;
    }
    /* ATAPI has a separate lab-only opt-in. Existing optical descriptors stay
     * untouched on new host builds unless explicitly enabled. */
    bool fLabOpticalEnabled = false;
    if (fLabProfile)
    {
        vrc = cloakQueryBool(mpVMM, pCloak, "StorageLabOpticalEnabled", &fLabOpticalEnabled);
        if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
            fLabOpticalEnabled = false;
        else if (RT_FAILURE(vrc))
            return vrc;
    }
    /* Generic SCSI has a separate opt-in so a host upgrade cannot silently
     * alter existing SCSI/SAS/VirtioSCSI/USB inquiry strings. */
    bool fLabScsiEnabled = false;
    if (fLabProfile)
    {
        vrc = cloakQueryBool(mpVMM, pCloak, "StorageLabScsiEnabled", &fLabScsiEnabled);
        if (vrc == VERR_CFGM_VALUE_NOT_FOUND)
            fLabScsiEnabled = false;
        else if (RT_FAILURE(vrc))
            return vrc;
    }
    /* S0/S1 lab: enumerate actual attached media, not guessed guest bus IDs. */
    if (fLabProfile && pProfile->pszAtaModel)
    {
        com::SafeIfaceArray<IStorageController> Controllers;
        HRESULT hrc = pMachine->COMGETTER(StorageControllers)(ComSafeArrayAsOutParam(Controllers));
        if (FAILED(hrc))
            return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;

        unsigned cApplied = 0, cEligible = 0, cUnsupported = 0, cOptical = 0;
        unsigned cOpticalEligible = 0, cOpticalApplied = 0;
        unsigned cScsiPresent = 0, cScsiEligible = 0, cScsiApplied = 0;
        for (size_t i = 0; i < Controllers.size(); ++i)
        {
            StorageControllerType_T enmCtrl;
            hrc = Controllers[i]->COMGETTER(ControllerType)(&enmCtrl);
            if (FAILED(hrc))
                return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
            const char *pszDevice = i_storageControllerTypeToStr(enmCtrl);
            if (!pszDevice)
                return VERR_NOT_SUPPORTED;
            bool const fSupported = !RTStrCmp(pszDevice, "ahci") || !RTStrCmp(pszDevice, "piix3ide");
            StorageBus_T enmBus;
            hrc = Controllers[i]->COMGETTER(Bus)(&enmBus);
            if (FAILED(hrc))
                return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
            bool const fScsiPath = enmBus == StorageBus_SCSI || enmBus == StorageBus_SAS
                                || enmBus == StorageBus_VirtioSCSI || enmBus == StorageBus_USB;
            ULONG uInstance = 0;
            Bstr bstrCtrlName;
            hrc = Controllers[i]->COMGETTER(Instance)(&uInstance);
            if (FAILED(hrc))
                return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
            hrc = Controllers[i]->COMGETTER(Name)(bstrCtrlName.asOutParam());
            if (FAILED(hrc))
                return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
            com::SafeIfaceArray<IMediumAttachment> Attachments;
            hrc = pMachine->GetMediumAttachmentsOfController(bstrCtrlName.raw(), ComSafeArrayAsOutParam(Attachments));
            if (FAILED(hrc))
                return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;

            for (size_t j = 0; j < Attachments.size(); ++j)
            {
                DeviceType_T enmType;
                hrc = Attachments[j]->COMGETTER(Type)(&enmType);
                if (FAILED(hrc))
                    return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;

                /* H3/H4: SCSI/SAS/VirtioSCSI/USB MSD all pass through DrvSCSI.
                 * Keep this surface independently opt-in and never override a
                 * physical host drive.  SBC HDDs also get root-medium-stable
                 * VPD 0x80/0x83 identity; MMC/DVD VPD remains untouched. */
                if (fScsiPath && (enmType == DeviceType_HardDisk || enmType == DeviceType_DVD))
                {
                    cScsiPresent++;
                    if (!fLabScsiEnabled)
                        continue;

                    ComPtr<IMedium> pScsiMedium;
                    hrc = Attachments[j]->COMGETTER(Medium)(pScsiMedium.asOutParam());
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    BOOL fHostDrive = FALSE;
                    if (!pScsiMedium.isNull())
                    {
                        hrc = pScsiMedium->COMGETTER(HostDrive)(&fHostDrive);
                        if (FAILED(hrc))
                            return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    }
                    BOOL fPassThrough = FALSE;
                    if (enmType == DeviceType_DVD)
                    {
                        hrc = Attachments[j]->COMGETTER(Passthrough)(&fPassThrough);
                        if (FAILED(hrc))
                            return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    }
                    if (fHostDrive || fPassThrough)
                        continue;
                    cScsiEligible++;

                    LONG iScsiPort = -1, iScsiDevice = -1;
                    hrc = Attachments[j]->COMGETTER(Port)(&iScsiPort);
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    hrc = Attachments[j]->COMGETTER(Device)(&iScsiDevice);
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    unsigned uScsiLun = 0;
                    hrc = i_storageBusPortDeviceToLun(enmBus, iScsiPort, iScsiDevice, uScsiLun);
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;

                    PCFGMNODE pScsiLun = enmBus == StorageBus_USB
                        ? mpVMM->pfnCFGMR3GetChildF(pRoot, "USB/%s/%d/LUN#%u", pszDevice, iScsiPort, uScsiLun)
                        : mpVMM->pfnCFGMR3GetChildF(pRoot, "Devices/%s/%u/LUN#%u", pszDevice, uInstance, uScsiLun);
                    if (!pScsiLun)
                        return VERR_NOT_FOUND;
                    char szDriver[16] = {};
                    vrc = Cfgm.pfnQueryString(Cfgm.pvUser, pScsiLun, "Driver", szDriver, sizeof(szDriver));
                    if (RT_FAILURE(vrc) || RTStrCmp(szDriver, "SCSI"))
                    {
                        RTMemWipeThoroughly(szDriver, sizeof(szDriver), 3);
                        return RT_FAILURE(vrc) ? vrc : VERR_MISMATCH;
                    }
                    RTMemWipeThoroughly(szDriver, sizeof(szDriver), 3);

                    PCFGMNODE pScsiCfg = mpVMM->pfnCFGMR3GetChild(pScsiLun, "Config");
                    if (!pScsiCfg)
                    {
                        vrc = mpVMM->pfnCFGMR3InsertNode(pScsiLun, "Config", &pScsiCfg);
                        if (RT_FAILURE(vrc))
                            return vrc;
                    }
                    char szScsiSerial[21] = {};
                    const char *pszScsiSerial = NULL;
                    if (enmType == DeviceType_HardDisk)
                    {
                        if (pScsiMedium.isNull())
                            return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                        ComPtr<IMedium> pScsiRootMedium = pScsiMedium;
                        unsigned cScsiMediumParents = 0;
                        for (;;)
                        {
                            ComPtr<IMedium> pParentMedium;
                            hrc = pScsiRootMedium->COMGETTER(Parent)(pParentMedium.asOutParam());
                            if (FAILED(hrc))
                                return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                            if (pParentMedium.isNull())
                                break;
                            if (++cScsiMediumParents > 128)
                            {
                                LogRel(("Cloak: SCSI storage parent chain exceeds safety bound\n"));
                                return VERR_INVALID_STATE;
                            }
                            pScsiRootMedium = pParentMedium;
                        }
                        Bstr bstrScsiMediumId;
                        hrc = pScsiRootMedium->COMGETTER(Id)(bstrScsiMediumId.asOutParam());
                        if (FAILED(hrc))
                            return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                        Utf8Str strScsiMediumId(bstrScsiMediumId);
                        vrc = CloakStorageLabSerial(u64Serial, strScsiMediumId.c_str(),
                                                    szScsiSerial, sizeof(szScsiSerial));
                        if (RT_FAILURE(vrc))
                            return vrc;
                        pszScsiSerial = szScsiSerial;
                    }
                    CLOAKSTORAGESCSIIDENTITY ScsiIdentity =
                    {
                        enmType == DeviceType_DVD ? pProfile->pszAtapiVendor : pProfile->pszInquiryVendor,
                        enmType == DeviceType_DVD ? pProfile->pszAtapiProduct : pProfile->pszInquiryProduct,
                        "LAB1",
                        pszScsiSerial
                    };
                    vrc = CloakStorageMaterializeScsi(&Cfgm, pScsiCfg, &ScsiIdentity);
                    if (RT_SUCCESS(vrc))
                        vrc = CloakStorageValidateLabScsiEffective(&Cfgm, pScsiCfg, &ScsiIdentity);
                    RTMemWipeThoroughly(szScsiSerial, sizeof(szScsiSerial), 3);
                    if (RT_FAILURE(vrc))
                    {
                        LogRel(("Cloak: invalid synthetic SCSI lab CFGM at %s/%u/LUN#%u, vrc=%Rrc\n",
                                pszDevice, enmBus == StorageBus_USB ? (unsigned)iScsiPort : (unsigned)uInstance,
                                uScsiLun, vrc));
                        return vrc;
                    }
                    cScsiApplied++;
                    LogRel(("Cloak: synthetic SCSI INQUIRY%s at %s/%u/LUN#%u materialized\n",
                            enmType == DeviceType_HardDisk ? "/VPD80/VPD83" : "",
                            pszDevice, enmBus == StorageBus_USB ? (unsigned)iScsiPort : (unsigned)uInstance,
                            uScsiLun));
                    continue;
                }

                if (enmType == DeviceType_DVD)
                {
                    cOptical++;
                    if (!fLabOpticalEnabled)
                        continue; /* Existing optical identity remains unchanged. */
                    if (!fSupported)
                        continue; /* Counted but not eligible: coverage guard rejects mixed buses. */

                    ComPtr<IMedium> pOpticalMedium;
                    hrc = Attachments[j]->COMGETTER(Medium)(pOpticalMedium.asOutParam());
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    BOOL fHostDrive = FALSE;
                    if (!pOpticalMedium.isNull())
                    {
                        hrc = pOpticalMedium->COMGETTER(HostDrive)(&fHostDrive);
                        if (FAILED(hrc))
                            return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    }
                    BOOL fPassThrough = FALSE;
                    hrc = Attachments[j]->COMGETTER(Passthrough)(&fPassThrough);
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    if (fHostDrive || fPassThrough)
                        continue; /* Do not alter identity of a host physical drive. */

                    cOpticalEligible++;
                    LONG iOpticalPort = -1, iOpticalDevice = -1;
                    hrc = Attachments[j]->COMGETTER(Port)(&iOpticalPort);
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    hrc = Attachments[j]->COMGETTER(Device)(&iOpticalDevice);
                    if (FAILED(hrc))
                        return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                    char szOpticalSlot[32];
                    vrc = CloakStorageGetSlot(pszDevice, iOpticalPort, iOpticalDevice,
                                             szOpticalSlot, sizeof(szOpticalSlot));
                    if (RT_FAILURE(vrc))
                        return vrc;
                    PCFGMNODE pOpticalController = mpVMM->pfnCFGMR3GetChildF(pRoot,
                                                    "Devices/%s/%u/Config", pszDevice, uInstance);
                    if (!pOpticalController)
                        return VERR_NOT_FOUND;
                    PCFGMNODE pOpticalSlot = mpVMM->pfnCFGMR3GetChild(pOpticalController, szOpticalSlot);
                    if (!pOpticalSlot)
                    {
                        vrc = mpVMM->pfnCFGMR3InsertNode(pOpticalController, szOpticalSlot,
                                                        &pOpticalSlot);
                        if (RT_FAILURE(vrc))
                            return vrc;
                    }

                    char szOpticalSerial[21];
                    vrc = CloakStorageLabOpticalSerial(u64Serial, pszDevice, uInstance,
                                                      szOpticalSlot, szOpticalSerial,
                                                      sizeof(szOpticalSerial));
                    if (RT_FAILURE(vrc))
                        return vrc;
                    CLOAKSTORAGEOPTICALIDENTITY Optical =
                    {
                        "LAB CD-ROM", "LAB1", szOpticalSerial, "LAB", "CD-ROM", "LAB1"
                    };
                    bool const fIde = !RTStrCmp(pszDevice, "piix3ide");
                    vrc = CloakStorageMaterializeOptical(&Cfgm, pOpticalSlot, &Optical, fIde);
                    if (RT_SUCCESS(vrc))
                        vrc = CloakStorageValidateLabOpticalEffective(&Cfgm, pOpticalSlot,
                                                                     &Optical, fIde);
                    RTMemWipeThoroughly(szOpticalSerial, sizeof(szOpticalSerial), 3);
                    if (RT_FAILURE(vrc))
                    {
                        LogRel(("Cloak: invalid synthetic optical lab CFGM at %s/%u/%s, vrc=%Rrc\n",
                                pszDevice, uInstance, szOpticalSlot, vrc));
                        return vrc;
                    }
                    cOpticalApplied++;
                    LogRel(("Cloak: synthetic optical lab identity at %s/%u/%s materialized (serial redacted)\n",
                            pszDevice, uInstance, szOpticalSlot));
                    continue;
                }
                if (enmType != DeviceType_HardDisk)
                    continue;
                if (!fSupported)
                {
                    cUnsupported++;
                    continue;
                }
                cEligible++;

                LONG iPort = -1, iDevice = -1;
                hrc = Attachments[j]->COMGETTER(Port)(&iPort);
                if (FAILED(hrc))
                    return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                hrc = Attachments[j]->COMGETTER(Device)(&iDevice);
                if (FAILED(hrc))
                    return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                char szSlot[32];
                vrc = CloakStorageGetSlot(pszDevice, iPort, iDevice, szSlot, sizeof(szSlot));
                if (RT_FAILURE(vrc))
                    return vrc;
                LogRel(("Cloak: S0 detected HDD %s/%u/%s (medium ID redacted)\n",
                        pszDevice, uInstance, szSlot));
                if (!fLabStorageEnabled)
                    continue; /* S0 inventory only; no disk identity changes. */

                PCFGMNODE pControllerCfg = mpVMM->pfnCFGMR3GetChildF(pRoot, "Devices/%s/%u/Config",
                                                                       pszDevice, uInstance);
                if (!pControllerCfg)
                    return VERR_NOT_FOUND;
                PCFGMNODE pSlotCfg = mpVMM->pfnCFGMR3GetChild(pControllerCfg, szSlot);
                if (!pSlotCfg)
                {
                    vrc = mpVMM->pfnCFGMR3InsertNode(pControllerCfg, szSlot, &pSlotCfg);
                    if (RT_FAILURE(vrc))
                        return vrc;
                }

                ComPtr<IMedium> pMedium;
                hrc = Attachments[j]->COMGETTER(Medium)(pMedium.asOutParam());
                if (FAILED(hrc) || pMedium.isNull())
                    return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                /*
                 * S2 opt-in: derive from the root UUID, not the snapshot leaf.
                 * Without StorageLabRootSerialEnabled, preserve the old serial.
                 */
                ComPtr<IMedium> pRootMedium = pMedium;
                unsigned cMediumParents = 0;
                if (fLabRootSerialEnabled)
                {
                    for (;;)
                    {
                        ComPtr<IMedium> pParentMedium;
                        hrc = pRootMedium->COMGETTER(Parent)(pParentMedium.asOutParam());
                        if (FAILED(hrc))
                            return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                        if (pParentMedium.isNull())
                            break;
                        if (++cMediumParents > 128)
                        {
                            LogRel(("Cloak: storage parent chain exceeds safety bound\n"));
                            return VERR_INVALID_STATE;
                        }
                        pRootMedium = pParentMedium;
                    }
                }

                Bstr bstrMediumId;
                hrc = pRootMedium->COMGETTER(Id)(bstrMediumId.asOutParam());
                if (FAILED(hrc))
                    return VERR_MAIN_CONFIG_CONSTRUCTOR_COM_ERROR;
                Utf8Str strMediumId(bstrMediumId);
                char szSerial[21];
                vrc = CloakStorageLabSerial(u64Serial, strMediumId.c_str(), szSerial, sizeof(szSerial));
                if (RT_FAILURE(vrc))
                    return vrc;
                CLOAKSTORAGEDEVICEIDENTITY Identity = { pProfile->pszAtaModel, "LAB1", szSerial };
                vrc = CloakStorageMaterialize(&Cfgm, pSlotCfg, &Identity);
                if (RT_SUCCESS(vrc))
                    vrc = CloakStorageValidateLabEffective(&Cfgm, pSlotCfg, &Identity);
                /* Validate before wiping the expected serial. */
                RTMemWipeThoroughly(szSerial, sizeof(szSerial), 3);
                if (RT_FAILURE(vrc))
                {
                    LogRel(("Cloak: invalid lab storage config at %s/%u/%s, vrc=%Rrc\n",
                            pszDevice, uInstance, szSlot, vrc));
                    return vrc;
                }
                cApplied++;
                LogRel(("Cloak: lab storage %s/%u/%s materialized (serial redacted)\n",
                        pszDevice, uInstance, szSlot));
            }
        }
        vrc = CloakStorageValidateLabCoverage(fLabStorageEnabled, cEligible, cApplied);
        if (RT_SUCCESS(vrc))
            vrc = CloakStorageValidateLabOpticalCoverage(fLabOpticalEnabled, cOptical,
                                                         cOpticalEligible, cOpticalApplied);
        if (RT_SUCCESS(vrc))
            vrc = CloakStorageValidateLabScsiCoverage(fLabScsiEnabled, cScsiPresent,
                                                      cScsiEligible, cScsiApplied);
        if (RT_FAILURE(vrc))
        {
            LogRel(("Cloak: lab storage/optical/SCSI coverage incomplete or unsupported, vrc=%Rrc\n", vrc));
            return vrc;
        }
        LogRel(("Cloak: lab storage inventory: %u eligible ATA/AHCI HDD(s), %u unsupported HDD(s), "
                "%u ATA optical attachment(s) (%u eligible, %u materialized), %u HDD materialized; "
                "%u SCSI-path attachment(s) (%u eligible, %u materialized); "
                "StorageLabEnabled=%RTbool, StorageLabOpticalEnabled=%RTbool, StorageLabScsiEnabled=%RTbool\n",
                cEligible, cUnsupported, cOptical, cOpticalEligible, cOpticalApplied, cApplied,
                cScsiPresent, cScsiEligible, cScsiApplied,
                fLabStorageEnabled, fLabOpticalEnabled, fLabScsiEnabled));
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

    LogRel(("Cloak: profile '%s' materialized\n", pProfile->pszProfileId));
    return VINF_SUCCESS;
}

typedef struct CLOAKSSMSTREAMCTX
{
    PSSMHANDLE      pSSM;
    PCVMMR3VTABLE   pVMM;
} CLOAKSSMSTREAMCTX;

static int cloakSsmStreamPutU32(void *pvUser, uint32_t u32Value)
{
    CLOAKSSMSTREAMCTX *pCtx = static_cast<CLOAKSSMSTREAMCTX *>(pvUser);
    return pCtx->pVMM->pfnSSMR3PutU32(pCtx->pSSM, u32Value);
}

static int cloakSsmStreamPutBool(void *pvUser, bool fValue)
{
    CLOAKSSMSTREAMCTX *pCtx = static_cast<CLOAKSSMSTREAMCTX *>(pvUser);
    return pCtx->pVMM->pfnSSMR3PutBool(pCtx->pSSM, fValue);
}

static int cloakSsmStreamPutStrZ(void *pvUser, const char *pszValue)
{
    CLOAKSSMSTREAMCTX *pCtx = static_cast<CLOAKSSMSTREAMCTX *>(pvUser);
    return pCtx->pVMM->pfnSSMR3PutStrZ(pCtx->pSSM, pszValue);
}

static int cloakSsmStreamGetU32(void *pvUser, uint32_t *pu32Value)
{
    CLOAKSSMSTREAMCTX *pCtx = static_cast<CLOAKSSMSTREAMCTX *>(pvUser);
    return pCtx->pVMM->pfnSSMR3GetU32(pCtx->pSSM, pu32Value);
}

static int cloakSsmStreamGetBool(void *pvUser, bool *pfValue)
{
    CLOAKSSMSTREAMCTX *pCtx = static_cast<CLOAKSSMSTREAMCTX *>(pvUser);
    return pCtx->pVMM->pfnSSMR3GetBool(pCtx->pSSM, pfValue);
}

static int cloakSsmStreamGetStrZ(void *pvUser, char *pszValue, size_t cchValue)
{
    CLOAKSSMSTREAMCTX *pCtx = static_cast<CLOAKSSMSTREAMCTX *>(pvUser);
    return pCtx->pVMM->pfnSSMR3GetStrZ(pCtx->pSSM, pszValue, cchValue);
}

static CLOAKSTATEIDENTITYSTREAM cloakCreateSsmStream(CLOAKSSMSTREAMCTX *pCtx)
{
    CLOAKSTATEIDENTITYSTREAM Stream;
    Stream.pfnPutU32 = cloakSsmStreamPutU32;
    Stream.pfnPutBool = cloakSsmStreamPutBool;
    Stream.pfnPutStrZ = cloakSsmStreamPutStrZ;
    Stream.pfnGetU32 = cloakSsmStreamGetU32;
    Stream.pfnGetBool = cloakSsmStreamGetBool;
    Stream.pfnGetStrZ = cloakSsmStreamGetStrZ;
    Stream.pvUser = pCtx;
    return Stream;
}

int Console::i_cloakSaveStateIdentity(PSSMHANDLE pSSM, PCVMMR3VTABLE pVMM)
{
    AssertPtrReturn(pSSM, VERR_INVALID_POINTER);
    AssertPtrReturn(pVMM, VERR_INVALID_POINTER);

    bool fEnabled = mfCloakCurrentStateIdentityValid && mfCloakCurrentStateEnabled;
    CLOAKSTATEIDENTITY Identity = {};
    int vrc = CloakStateIdentitySet(&Identity, fEnabled,
                                    fEnabled ? mStrCloakCurrentStateProfileId.c_str() : "",
                                    fEnabled ? mStrCloakCurrentStateSeedHash.c_str() : "",
                                    fEnabled ? mStrCloakCurrentStateManifestHash.c_str() : "");
    if (RT_FAILURE(vrc))
        return vrc;

    CLOAKSSMSTREAMCTX Ctx = { pSSM, pVMM };
    CLOAKSTATEIDENTITYSTREAM Stream = cloakCreateSsmStream(&Ctx);
    return CloakStateIdentitySerialize(&Identity, &Stream);
}

int Console::i_cloakLoadStateIdentity(PSSMHANDLE pSSM, PCVMMR3VTABLE pVMM)
{
    AssertPtrReturn(pSSM, VERR_INVALID_POINTER);
    AssertPtrReturn(pVMM, VERR_INVALID_POINTER);

    CLOAKSSMSTREAMCTX Ctx = { pSSM, pVMM };
    CLOAKSTATEIDENTITYSTREAM Stream = cloakCreateSsmStream(&Ctx);
    CLOAKSTATEIDENTITY Identity = {};
    int vrc = CloakStateIdentityDeserialize(&Identity, &Stream);
    if (RT_FAILURE(vrc))
        return vrc;

    mfCloakSavedStateEnabled = Identity.fEnabled;
    mStrCloakSavedStateProfileId = Identity.szProfileId;
    mStrCloakSavedStateSeedHash = Identity.szSeedHash;
    mStrCloakSavedStateManifestHash = Identity.szManifestHash;
    mfCloakSavedStateIdentityValid = true;
    return VINF_SUCCESS;
}

int Console::i_cloakSetCurrentStateIdentity(bool fEnabled, const char *pszProfileId, const char *pszSeedHash)
{
    char szManifestHash[CLOAK_SEED_HEX_SIZE + 1] = "";
    int vrc;
    if (fEnabled)
    {
        vrc = CloakManifestHashHex(CloakGetBuildManifest(), szManifestHash, sizeof(szManifestHash));
        if (RT_FAILURE(vrc))
            return vrc;
    }

    CLOAKSTATEIDENTITY Current = {};
    vrc = CloakStateIdentitySet(&Current, fEnabled, pszProfileId, pszSeedHash, szManifestHash);
    if (RT_FAILURE(vrc))
        return vrc;

    if (mfCloakSavedStateIdentityValid && mSavedStateDataLoaded)
    {
        CLOAKSTATEIDENTITY Saved = {};
        vrc = CloakStateIdentitySet(&Saved, mfCloakSavedStateEnabled,
                                    mStrCloakSavedStateProfileId.c_str(),
                                    mStrCloakSavedStateSeedHash.c_str(),
                                    mStrCloakSavedStateManifestHash.c_str());
        if (RT_FAILURE(vrc))
            return VERR_SSM_DATA_UNIT_FORMAT_CHANGED;
        if (RT_FAILURE(CloakCompareStateIdentity(&Saved, &Current)))
        {
            LogRel(("Cloak: saved state identity does not match the current seed/profile/manifest; "
                    "refusing restore, delete the saved state or restore the matching cloak configuration\n"));
            return VERR_SSM_LOAD_CONFIG_MISMATCH;
        }
    }
    else if (fEnabled && mSavedStateDataLoaded)
    {
        LogRel(("Cloak: saved state has no cloak identity record; delete the saved state before enabling cloak\n"));
        return VERR_SSM_LOAD_CONFIG_MISMATCH;
    }

    mfCloakCurrentStateEnabled = fEnabled;
    mStrCloakCurrentStateProfileId = pszProfileId ? pszProfileId : "";
    mStrCloakCurrentStateSeedHash = pszSeedHash ? pszSeedHash : "";
    mStrCloakCurrentStateManifestHash = szManifestHash;
    mfCloakCurrentStateIdentityValid = true;
    return VINF_SUCCESS;
}
