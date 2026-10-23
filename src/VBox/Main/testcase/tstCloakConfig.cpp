/* $Id$ */
/** @file
 * VBox Cloak configuration testcase.
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

#include "ConsoleImplConfigCloak.h"
#include "ConsoleImplConfigCloakCfgm.h"

#include <iprt/test.h>
#include <iprt/uuid.h>

typedef struct TESTCFGMVALUE
{
    struct TESTCFGMVALUE *pNext;
    char szName[64];
    bool fInteger;
    uint64_t u64Value;
    char szValue[256];
} TESTCFGMVALUE;

typedef struct TESTCFGMNODE
{
    struct TESTCFGMNODE *pNext;
    char szPath[128];
    TESTCFGMVALUE *pValues;
} TESTCFGMNODE;

typedef struct TESTCFGM
{
    TESTCFGMNODE *pNodes;
    int rcGetChild;
    int rcInsertString;
    int rcInsertInteger;
    int rcQueryString;
    int rcQueryInteger;
} TESTCFGM;

static TESTCFGMNODE *testCfgmFindNode(TESTCFGM *pCfgm, const char *pszPath)
{
    if (!pCfgm || !pszPath)
        return NULL;
    for (TESTCFGMNODE *pNode = pCfgm->pNodes; pNode; pNode = pNode->pNext)
        if (!RTStrCmp(pNode->szPath, pszPath))
            return pNode;
    return NULL;
}

static TESTCFGMNODE *testCfgmAddNode(TESTCFGM *pCfgm, const char *pszPath)
{
    TESTCFGMNODE *pNode = testCfgmFindNode(pCfgm, pszPath);
    if (pNode)
        return pNode;
    pNode = (TESTCFGMNODE *)RTMemAllocZ(sizeof(*pNode));
    if (!pNode)
        return NULL;
    RTStrCopy(pNode->szPath, sizeof(pNode->szPath), pszPath);
    pNode->pNext = pCfgm->pNodes;
    pCfgm->pNodes = pNode;
    return pNode;
}

static TESTCFGMVALUE *testCfgmFindValue(TESTCFGMNODE *pNode, const char *pszName)
{
    if (!pNode || !pszName)
        return NULL;
    for (TESTCFGMVALUE *pValue = pNode->pValues; pValue; pValue = pValue->pNext)
        if (!RTStrCmp(pValue->szName, pszName))
            return pValue;
    return NULL;
}

static TESTCFGMVALUE *testCfgmGetOrCreateValue(TESTCFGMNODE *pNode, const char *pszName)
{
    TESTCFGMVALUE *pValue = testCfgmFindValue(pNode, pszName);
    if (pValue)
        return pValue;
    pValue = (TESTCFGMVALUE *)RTMemAllocZ(sizeof(*pValue));
    if (!pValue)
        return NULL;
    RTStrCopy(pValue->szName, sizeof(pValue->szName), pszName);
    pValue->pNext = pNode->pValues;
    pNode->pValues = pValue;
    return pValue;
}

static int testCfgmSetString(TESTCFGMNODE *pNode, const char *pszName, const char *pszValue)
{
    if (!pNode || !pszName || !pszValue)
        return VERR_INVALID_PARAMETER;
    TESTCFGMVALUE *pValue = testCfgmGetOrCreateValue(pNode, pszName);
    if (!pValue)
        return VERR_NO_MEMORY;
    pValue->fInteger = false;
    pValue->u64Value = 0;
    return RTStrCopy(pValue->szValue, sizeof(pValue->szValue), pszValue);
}

static int testCfgmSetInteger(TESTCFGMNODE *pNode, const char *pszName, uint64_t u64Value)
{
    if (!pNode || !pszName)
        return VERR_INVALID_PARAMETER;
    TESTCFGMVALUE *pValue = testCfgmGetOrCreateValue(pNode, pszName);
    if (!pValue)
        return VERR_NO_MEMORY;
    pValue->fInteger = true;
    pValue->u64Value = u64Value;
    pValue->szValue[0] = '\0';
    return VINF_SUCCESS;
}

static void testCfgmRemoveValue(TESTCFGMNODE *pNode, const char *pszName)
{
    if (!pNode)
        return;
    TESTCFGMVALUE **ppValue = &pNode->pValues;
    while (*ppValue)
    {
        if (!RTStrCmp((*ppValue)->szName, pszName))
        {
            TESTCFGMVALUE *pValue = *ppValue;
            *ppValue = pValue->pNext;
            RTMemFree(pValue);
            return;
        }
        ppValue = &(*ppValue)->pNext;
    }
}

static const char *testCfgmGetString(TESTCFGMNODE *pNode, const char *pszName)
{
    TESTCFGMVALUE *pValue = testCfgmFindValue(pNode, pszName);
    return pValue && !pValue->fInteger ? pValue->szValue : NULL;
}

static uint64_t testCfgmGetInteger(TESTCFGMNODE *pNode, const char *pszName, uint64_t u64Default)
{
    TESTCFGMVALUE *pValue = testCfgmFindValue(pNode, pszName);
    return pValue && pValue->fInteger ? pValue->u64Value : u64Default;
}

static void testCfgmDestroy(TESTCFGM *pCfgm)
{
    TESTCFGMNODE *pNode = pCfgm->pNodes;
    while (pNode)
    {
        TESTCFGMNODE *pNextNode = pNode->pNext;
        TESTCFGMVALUE *pValue = pNode->pValues;
        while (pValue)
        {
            TESTCFGMVALUE *pNextValue = pValue->pNext;
            RTMemFree(pValue);
            pValue = pNextValue;
        }
        RTMemFree(pNode);
        pNode = pNextNode;
    }
    pCfgm->pNodes = NULL;
}

static bool testCfgmExists(void *pvUser, void *pNode, const char *pszName)
{
    TESTCFGM *pCfgm = (TESTCFGM *)pvUser;
    return pCfgm && pNode && testCfgmFindValue((TESTCFGMNODE *)pNode, pszName) != NULL;
}

static int testCfgmInsertString(void *pvUser, void *pNode, const char *pszName, const char *pszValue)
{
    TESTCFGM *pCfgm = (TESTCFGM *)pvUser;
    if (!pCfgm)
        return VERR_INVALID_PARAMETER;
    if (pCfgm->rcInsertString)
        return pCfgm->rcInsertString;
    return testCfgmSetString((TESTCFGMNODE *)pNode, pszName, pszValue);
}

static int testCfgmInsertInteger(void *pvUser, void *pNode, const char *pszName, uint64_t u64Value)
{
    TESTCFGM *pCfgm = (TESTCFGM *)pvUser;
    if (!pCfgm)
        return VERR_INVALID_PARAMETER;
    if (pCfgm->rcInsertInteger)
        return pCfgm->rcInsertInteger;
    return testCfgmSetInteger((TESTCFGMNODE *)pNode, pszName, u64Value);
}

static void *testCfgmGetChild(void *pvUser, void *pRoot, const char *pszPath)
{
    TESTCFGM *pCfgm = (TESTCFGM *)pvUser;
    if (!pCfgm || !pRoot || pCfgm->rcGetChild)
        return NULL;
    return testCfgmFindNode(pCfgm, pszPath);
}

static int testCfgmQueryString(void *pvUser, void *pNode, const char *pszName, char *pszValue, size_t cbValue)
{
    TESTCFGM *pCfgm = (TESTCFGM *)pvUser;
    if (!pCfgm)
        return VERR_INVALID_PARAMETER;
    if (pCfgm->rcQueryString)
        return pCfgm->rcQueryString;
    TESTCFGMVALUE *pValue = testCfgmFindValue((TESTCFGMNODE *)pNode, pszName);
    if (!pValue)
        return VERR_CFGM_VALUE_NOT_FOUND;
    if (pValue->fInteger)
        return VERR_CFGM_NOT_STRING;
    if (strlen(pValue->szValue) >= cbValue)
        return VERR_CFGM_NOT_ENOUGH_SPACE;
    return RTStrCopy(pszValue, cbValue, pValue->szValue);
}

static int testCfgmQueryInteger(void *pvUser, void *pNode, const char *pszName, uint64_t *pu64Value)
{
    TESTCFGM *pCfgm = (TESTCFGM *)pvUser;
    if (!pCfgm)
        return VERR_INVALID_PARAMETER;
    if (pCfgm->rcQueryInteger)
        return pCfgm->rcQueryInteger;
    TESTCFGMVALUE *pValue = testCfgmFindValue((TESTCFGMNODE *)pNode, pszName);
    if (!pValue)
        return VERR_CFGM_VALUE_NOT_FOUND;
    if (!pValue->fInteger)
        return VERR_CFGM_NOT_INTEGER;
    *pu64Value = pValue->u64Value;
    return VINF_SUCCESS;
}

static CLOAKCFGMVTABLE testCfgmMakeVTable(TESTCFGM *pCfgm)
{
    CLOAKCFGMVTABLE VTable;
    VTable.pvUser = pCfgm;
    VTable.pfnExists = testCfgmExists;
    VTable.pfnInsertString = testCfgmInsertString;
    VTable.pfnInsertInteger = testCfgmInsertInteger;
    VTable.pfnGetChild = testCfgmGetChild;
    VTable.pfnQueryString = testCfgmQueryString;
    VTable.pfnQueryInteger = testCfgmQueryInteger;
    return VTable;
}

static void testSeedDecode(RTTEST hTest)
{
    RTTestSub(hTest, "Seed decoding");

    char szHex[CLOAK_SEED_HEX_SIZE + 1];
    static const char s_szDigits[] = "0123456789abcdef";
    for (size_t i = 0; i < CLOAK_SEED_SIZE; i++)
    {
        szHex[i * 2]     = s_szDigits[(i * 7) & 15];
        szHex[i * 2 + 1] = s_szDigits[(i * 11 + 3) & 15];
    }
    szHex[CLOAK_SEED_HEX_SIZE] = '\0';

    uint8_t abSeed[CLOAK_SEED_SIZE];
    RTTESTI_CHECK_RC(CloakSeedDecode(szHex, abSeed, sizeof(abSeed)), VINF_SUCCESS);

    char szRoundTrip[CLOAK_SEED_HEX_SIZE + 1];
    RTTESTI_CHECK_RC(RTStrPrintHexBytes(szRoundTrip, sizeof(szRoundTrip), abSeed, sizeof(abSeed), 0),
                     VINF_SUCCESS);
    RTTESTI_CHECK(!RTStrICmp(szRoundTrip, szHex));

    char szPrefixed[sizeof("string:") + CLOAK_SEED_HEX_SIZE];
    RTTESTI_CHECK(RTStrPrintf(szPrefixed, sizeof(szPrefixed), "string:%s", szHex) == sizeof(szPrefixed) - 1);
    RTTESTI_CHECK_RC(CloakSeedDecode(szPrefixed, abSeed, sizeof(abSeed)), VINF_SUCCESS);

    RTTESTI_CHECK_RC(CloakSeedDecode(NULL, abSeed, sizeof(abSeed)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakSeedDecode(szHex, NULL, sizeof(abSeed)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakSeedDecode(szHex, abSeed, 16), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakSeedDecode("", abSeed, sizeof(abSeed)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakSeedDecode("00", abSeed, sizeof(abSeed)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakSeedDecode(szPrefixed + sizeof("string:") - 1, abSeed, sizeof(abSeed)), VINF_SUCCESS);

    char szBad[CLOAK_SEED_HEX_SIZE + 1];
    RTStrCopy(szBad, sizeof(szBad), szHex);
    szBad[0] = 'z';
    RTTESTI_CHECK_RC(CloakSeedDecode(szBad, abSeed, sizeof(abSeed)), VERR_INVALID_PARAMETER);

    RTStrCopy(szBad, sizeof(szBad), szHex);
    szBad[CLOAK_SEED_HEX_SIZE - 1] = '\0';
    RTTESTI_CHECK_RC(CloakSeedDecode(szBad, abSeed, sizeof(abSeed)), VERR_INVALID_PARAMETER);

    char szLong[CLOAK_SEED_HEX_SIZE + 2];
    RTStrPrintf(szLong, sizeof(szLong), "%s0", szHex);
    RTTESTI_CHECK_RC(CloakSeedDecode(szLong, abSeed, sizeof(abSeed)), VERR_INVALID_PARAMETER);
}

static void testHmac(RTTEST hTest)
{
    RTTestSub(hTest, "HMAC-SHA-256");

    static const char s_szKey[] = "Jefe";
    static const char s_szData[] = "what do ya want for nothing?";
    uint8_t abExpected[RTSHA256_HASH_SIZE];
    RTTESTI_CHECK_RC(RTStrConvertHexBytes("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
                                          abExpected, sizeof(abExpected), 0), VINF_SUCCESS);

    uint8_t abDigest[RTSHA256_HASH_SIZE];
    CloakHmacSha256(s_szKey, sizeof(s_szKey) - 1, s_szData, sizeof(s_szData) - 1, abDigest);
    RTTESTI_CHECK(!memcmp(abDigest, abExpected, sizeof(abDigest)));
}

static void testSeedStreams(RTTEST hTest)
{
    RTTestSub(hTest, "Seed streams");

    uint8_t abSeedA[CLOAK_SEED_SIZE];
    uint8_t abSeedB[CLOAK_SEED_SIZE];
    memset(abSeedA, 0x11, sizeof(abSeedA));
    memset(abSeedB, 0x22, sizeof(abSeedB));

    RTUUID UuidA;
    RTUUID UuidB;
    RTTESTI_CHECK_RC(RTUuidFromStr(&UuidA, "00112233-4455-6677-8899-aabbccddeeff"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(RTUuidFromStr(&UuidB, "00112233-4455-6677-8899-aabbccddeefe"), VINF_SUCCESS);

    uint64_t u64ProfileA = 0;
    uint64_t u64SerialA = 0;
    uint64_t u64JitterA = 0;
    RTTESTI_CHECK_RC(CloakSeedStreams(abSeedA, sizeof(abSeedA), &UuidA,
                                      &u64ProfileA, &u64SerialA, &u64JitterA), VINF_SUCCESS);

    uint64_t u64ProfileA2 = 0;
    uint64_t u64SerialA2 = 0;
    uint64_t u64JitterA2 = 0;
    RTTESTI_CHECK_RC(CloakSeedStreams(abSeedA, sizeof(abSeedA), &UuidA,
                                      &u64ProfileA2, &u64SerialA2, &u64JitterA2), VINF_SUCCESS);
    RTTESTI_CHECK(u64ProfileA == u64ProfileA2);
    RTTESTI_CHECK(u64SerialA == u64SerialA2);
    RTTESTI_CHECK(u64JitterA == u64JitterA2);

    uint64_t u64ProfileB = 0;
    uint64_t u64SerialB = 0;
    uint64_t u64JitterB = 0;
    RTTESTI_CHECK_RC(CloakSeedStreams(abSeedB, sizeof(abSeedB), &UuidA,
                                      &u64ProfileB, &u64SerialB, &u64JitterB), VINF_SUCCESS);
    RTTESTI_CHECK(u64ProfileA != u64ProfileB);
    RTTESTI_CHECK(u64SerialA != u64SerialB);
    RTTESTI_CHECK(u64JitterA != u64JitterB);

    uint64_t u64ProfileC = 0;
    uint64_t u64SerialC = 0;
    uint64_t u64JitterC = 0;
    RTTESTI_CHECK_RC(CloakSeedStreams(abSeedA, sizeof(abSeedA), &UuidB,
                                      &u64ProfileC, &u64SerialC, &u64JitterC), VINF_SUCCESS);
    RTTESTI_CHECK(u64ProfileA != u64ProfileC);
    RTTESTI_CHECK(u64SerialA != u64SerialC);
    RTTESTI_CHECK(u64JitterA != u64JitterC);

    RTTESTI_CHECK_RC(CloakSeedStreams(abSeedA, 16, &UuidA,
                                      &u64ProfileB, &u64SerialB, &u64JitterB), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakSeedStreams(abSeedA, sizeof(abSeedA), NULL,
                                      &u64ProfileB, &u64SerialB, &u64JitterB), VERR_INVALID_PARAMETER);
}

static void setValidBuildHash(CLOAKBUILDMANIFEST *pManifest, char *pszHash, size_t cchHash)
{
    pManifest->pszBuildHash = NULL;
    RTTESTI_CHECK_RC(CloakBuildHashHex(pManifest, pszHash, cchHash), VINF_SUCCESS);
    pManifest->pszBuildHash = pszHash;
}

static void testBuildManifestValidation(RTTEST hTest)
{
    RTTestSub(hTest, "Build manifest contract");

    CLOAKBUILDMANIFEST Manifest = {};
    Manifest.pszBuildMode = "cloak";
    Manifest.pszFirmwareFamily = "ami";
    Manifest.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
    Manifest.uVmmDevVendorId = CLOAKBINDING_VMMDEV_VENDOR_ID;
    Manifest.uVmmDevDeviceId = CLOAKBINDING_VMMDEV_DEVICE_ID;
    Manifest.uVgaVendorId = CLOAKBINDING_VGA_VENDOR_ID;
    Manifest.uVgaDeviceId = CLOAKBINDING_VGA_DEVICE_ID;
    Manifest.uVirtioVendorId = CLOAKBINDING_VIRTIO_VENDOR_ID;
    Manifest.pszDsdtHash = "sha256:dsdt";
    Manifest.pszVgaBiosHash = "sha256:vga";
    Manifest.pszBiosRomHash = "sha256:bios";
    Manifest.pszSourceRevision = "abcdef0";
    char szBuildHash[CLOAK_SEED_HEX_SIZE + 1] = "";
    setValidBuildHash(&Manifest, szBuildHash, sizeof(szBuildHash));

    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Manifest), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakValidateBuildManifestHash(&Manifest), VINF_SUCCESS);

    char szHashA[CLOAK_SEED_HEX_SIZE + 1] = "";
    char szHashB[CLOAK_SEED_HEX_SIZE + 1] = "";
    RTTESTI_CHECK_RC(CloakBuildHashHex(&Manifest, szHashA, sizeof(szHashA)), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakBuildHashHex(&Manifest, szHashB, sizeof(szHashB)), VINF_SUCCESS);
    RTTESTI_CHECK(!RTStrCmp(szHashA, szHashB));
    RTTESTI_CHECK(strlen(szHashA) == CLOAK_SEED_HEX_SIZE);
    RTTESTI_CHECK(!RTStrICmp(szHashA, "F62C060EEA27D2FFB22BE2E6212D8C22E6EC93545CD9F87C1DD39C3C9F15D9E7"));
    RTTESTI_CHECK(!RTStrICmp(szHashA, Manifest.pszBuildHash));

    CLOAKBUILDMANIFEST Changed = Manifest;
    Changed.pszSourceRevision = "abcdef1";
    RTTESTI_CHECK_RC(CloakBuildHashHex(&Changed, szHashB, sizeof(szHashB)), VINF_SUCCESS);
    RTTESTI_CHECK(RTStrCmp(szHashA, szHashB));
    Changed.pszBuildHash = szHashB;
    RTTESTI_CHECK_RC(CloakValidateBuildManifestHash(&Changed), VINF_SUCCESS);

    char szBadHash[CLOAK_SEED_HEX_SIZE + 1];
    memset(szBadHash, '0', CLOAK_SEED_HEX_SIZE);
    szBadHash[CLOAK_SEED_HEX_SIZE] = '\0';

    CLOAKBUILDMANIFEST Bad = Manifest;
    Bad.pszBuildMode = "stock";
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.pszFirmwareFamily = "";
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.fSupportedChipsets = 0;
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.fSupportedChipsets = RT_BIT_32(31);
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.uVmmDevDeviceId = 0x1551;
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.uVgaVendorId = 0x10de;
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.uVirtioVendorId = 0x10ec;
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.pszDsdtHash = NULL;
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.pszSourceRevision = "";
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.pszBuildHash = NULL;
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.pszBuildHash = szBadHash;
    RTTESTI_CHECK_RC(CloakValidateBuildManifest(&Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.pszBuildHash = "short";
    RTTESTI_CHECK_RC(CloakValidateBuildManifestHash(&Bad), VERR_NOT_SUPPORTED);

    RTTESTI_CHECK_RC(CloakBuildHashHex(NULL, szHashB, sizeof(szHashB)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakBuildHashHex(&Manifest, NULL, sizeof(szHashB)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakBuildHashHex(&Manifest, szHashB, CLOAK_SEED_HEX_SIZE), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakValidateBuildManifestHash(NULL), VERR_NOT_SUPPORTED);

    RTTESTI_CHECK_RC(CloakValidateBuildManifest(NULL), VERR_INVALID_PARAMETER);
}

static void testManifestValidation(RTTEST hTest)
{
    RTTestSub(hTest, "Profile/manifest validation");

    MACHINEPROFILE Profile = {};
    Profile.pszProfileId = "test-profile";
    Profile.enmClass = CLOAKPROFILE_COMPATIBLE;
    Profile.pszRequiredFirmwareFamily = "ami";
    Profile.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
    Profile.uVmmDevVendorId = 0x80ee;
    Profile.uVmmDevDeviceId = 0xcafe;
    Profile.pszSourceModel = "test-model";
    Profile.pszSourceBiosDate = "19700101";
    Profile.pszProvenanceHash = "sha256:test";

    CLOAKBUILDMANIFEST Manifest = {};
    Manifest.pszBuildMode = "cloak";
    Manifest.pszFirmwareFamily = "ami";
    Manifest.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3 | CLOAKCHIPSET_ICH9;
    Manifest.uVmmDevVendorId = CLOAKBINDING_VMMDEV_VENDOR_ID;
    Manifest.uVmmDevDeviceId = CLOAKBINDING_VMMDEV_DEVICE_ID;
    Manifest.uVgaVendorId = CLOAKBINDING_VGA_VENDOR_ID;
    Manifest.uVgaDeviceId = CLOAKBINDING_VGA_DEVICE_ID;
    Manifest.uVirtioVendorId = CLOAKBINDING_VIRTIO_VENDOR_ID;
    Manifest.pszDsdtHash = "sha256:dsdt";
    Manifest.pszVgaBiosHash = "sha256:vga";
    Manifest.pszBiosRomHash = "sha256:bios";
    Manifest.pszSourceRevision = "abcdef0";
    char szBuildHash[CLOAK_SEED_HEX_SIZE + 1] = "";
    setValidBuildHash(&Manifest, szBuildHash, sizeof(szBuildHash));

    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, &Manifest), VINF_SUCCESS);

    CLOAKBUILDMANIFEST Bad = Manifest;
    Bad.pszBuildMode = "stock";
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, &Bad), VERR_NOT_SUPPORTED);

    MACHINEPROFILE BadProfile = Profile;
    BadProfile.enmClass = CLOAKPROFILE_DRAFT;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&BadProfile, &Manifest), VERR_ACCESS_DENIED);

    BadProfile.enmClass = CLOAKPROFILE_RESEARCH_ONLY;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&BadProfile, &Manifest), VERR_ACCESS_DENIED);

    Bad = Manifest;
    Bad.pszFirmwareFamily = "insyde";
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, &Bad), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.fSupportedChipsets = CLOAKCHIPSET_I440FX;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, &Bad), VERR_NOT_SUPPORTED);

    BadProfile = Profile;
    BadProfile.fSupportedChipsets = 0;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&BadProfile, &Manifest), VERR_NOT_SUPPORTED);

    Bad = Manifest;
    Bad.uVmmDevDeviceId = 0xbeef;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, &Bad), VERR_NOT_SUPPORTED);

    BadProfile = Profile;
    BadProfile.pszSourceModel = NULL;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&BadProfile, &Manifest), VERR_NOT_SUPPORTED);

    BadProfile = Profile;
    BadProfile.pszSourceBiosDate = "";
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&BadProfile, &Manifest), VERR_NOT_SUPPORTED);

    BadProfile = Profile;
    BadProfile.pszProvenanceHash = NULL;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&BadProfile, &Manifest), VERR_NOT_SUPPORTED);

    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(NULL, &Manifest), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, NULL), VERR_INVALID_PARAMETER);
}

static MACHINEPROFILE makeMaterializableProfile(void);

static void testProductionRegistry(RTTEST hTest)
{
    RTTestSub(hTest, "Production registry validation");

    MACHINEPROFILE Profile = makeMaterializableProfile();
    Profile.enmClass = CLOAKPROFILE_COMPATIBLE;
    Profile.pszRequiredFirmwareFamily = "ami";
    Profile.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
    Profile.uVmmDevVendorId = CLOAKBINDING_VMMDEV_VENDOR_ID;
    Profile.uVmmDevDeviceId = CLOAKBINDING_VMMDEV_DEVICE_ID;
    Profile.pszSourceModel = "test-model";
    Profile.pszSourceBiosDate = "19700101";
    Profile.pszProvenanceHash = "sha256:test";

    CLOAKBUILDMANIFEST Manifest = {};
    Manifest.pszBuildMode = "cloak";
    Manifest.pszFirmwareFamily = "ami";
    Manifest.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
    Manifest.uVmmDevVendorId = CLOAKBINDING_VMMDEV_VENDOR_ID;
    Manifest.uVmmDevDeviceId = CLOAKBINDING_VMMDEV_DEVICE_ID;
    Manifest.uVgaVendorId = CLOAKBINDING_VGA_VENDOR_ID;
    Manifest.uVgaDeviceId = CLOAKBINDING_VGA_DEVICE_ID;
    Manifest.uVirtioVendorId = CLOAKBINDING_VIRTIO_VENDOR_ID;
    Manifest.pszDsdtHash = "sha256:dsdt";
    Manifest.pszVgaBiosHash = "sha256:vga";
    Manifest.pszBiosRomHash = "sha256:bios";
    Manifest.pszSourceRevision = "abcdef0";
    char szBuildHash[CLOAK_SEED_HEX_SIZE + 1] = "";
    setValidBuildHash(&Manifest, szBuildHash, sizeof(szBuildHash));

    const MACHINEPROFILE *apProfiles[] = { &Profile, NULL };
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(apProfiles, RT_ELEMENTS(apProfiles), &Manifest), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(NULL, 0, NULL), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(NULL, 1, &Manifest), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(apProfiles, RT_ELEMENTS(apProfiles), NULL), VERR_INVALID_PARAMETER);

    MACHINEPROFILE DraftProfile = Profile;
    DraftProfile.enmClass = CLOAKPROFILE_DRAFT;
    const MACHINEPROFILE *apDraft[] = { &DraftProfile, NULL };
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(apDraft, RT_ELEMENTS(apDraft), &Manifest), VERR_ACCESS_DENIED);

    MACHINEPROFILE MissingSource = Profile;
    MissingSource.pszSourceModel = NULL;
    const MACHINEPROFILE *apMissingSource[] = { &MissingSource, NULL };
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(apMissingSource, RT_ELEMENTS(apMissingSource), &Manifest),
                     VERR_NOT_SUPPORTED);

    MACHINEPROFILE MissingAcpi = Profile;
    MissingAcpi.pszAcpiOemId = "";
    const MACHINEPROFILE *apMissingAcpi[] = { &MissingAcpi, NULL };
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(apMissingAcpi, RT_ELEMENTS(apMissingAcpi), &Manifest),
                     VERR_INVALID_PARAMETER);

    CLOAKBUILDMANIFEST BadManifest = Manifest;
    BadManifest.pszFirmwareFamily = "insyde";
    const MACHINEPROFILE *apOne[] = { &Profile };
    RTTESTI_CHECK_RC(CloakValidateProductionRegistry(apOne, RT_ELEMENTS(apOne), &BadManifest), VERR_NOT_SUPPORTED);
}

static void testManifestHashAndStateIdentity(RTTEST hTest)
{
    RTTestSub(hTest, "Manifest hash and saved-state identity");

    CLOAKBUILDMANIFEST Manifest = {};
    Manifest.pszBuildMode = "cloak";
    Manifest.pszFirmwareFamily = "ami";
    Manifest.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
    Manifest.uVmmDevVendorId = CLOAKBINDING_VMMDEV_VENDOR_ID;
    Manifest.uVmmDevDeviceId = CLOAKBINDING_VMMDEV_DEVICE_ID;
    Manifest.uVgaVendorId = CLOAKBINDING_VGA_VENDOR_ID;
    Manifest.uVgaDeviceId = CLOAKBINDING_VGA_DEVICE_ID;
    Manifest.uVirtioVendorId = CLOAKBINDING_VIRTIO_VENDOR_ID;
    Manifest.pszDsdtHash = "sha256:dsdt";
    Manifest.pszVgaBiosHash = "sha256:vga";
    Manifest.pszBiosRomHash = "sha256:bios";
    Manifest.pszSourceRevision = "abcdef0";
    Manifest.pszBuildHash = "sha256:build";

    char szHashA[CLOAK_SEED_HEX_SIZE + 1] = "";
    char szHashB[CLOAK_SEED_HEX_SIZE + 1] = "";
    RTTESTI_CHECK_RC(CloakManifestHashHex(&Manifest, szHashA, sizeof(szHashA)), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakManifestHashHex(&Manifest, szHashB, sizeof(szHashB)), VINF_SUCCESS);
    RTTESTI_CHECK(!RTStrCmp(szHashA, szHashB));
    RTTESTI_CHECK(strlen(szHashA) == CLOAK_SEED_HEX_SIZE);

    CLOAKBUILDMANIFEST Changed = Manifest;
    Changed.pszBuildHash = "sha256:build2";
    RTTESTI_CHECK_RC(CloakManifestHashHex(&Changed, szHashB, sizeof(szHashB)), VINF_SUCCESS);
    RTTESTI_CHECK(RTStrCmp(szHashA, szHashB));

    Changed = Manifest;
    Changed.uVgaDeviceId = 0x1234;
    RTTESTI_CHECK_RC(CloakManifestHashHex(&Changed, szHashB, sizeof(szHashB)), VINF_SUCCESS);
    RTTESTI_CHECK(RTStrCmp(szHashA, szHashB));

    RTTESTI_CHECK_RC(CloakManifestHashHex(NULL, szHashB, sizeof(szHashB)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakManifestHashHex(&Manifest, NULL, sizeof(szHashB)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakManifestHashHex(&Manifest, szHashB, CLOAK_SEED_HEX_SIZE), VERR_INVALID_PARAMETER);

    CLOAKSTATEIDENTITY Saved = {};
    CLOAKSTATEIDENTITY Current = {};
    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Saved, false, NULL, NULL, NULL), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Current, false, NULL, NULL, NULL), VINF_SUCCESS);
    RTTESTI_CHECK(CloakStateIdentityEquals(&Saved, &Current));
    RTTESTI_CHECK_RC(CloakCompareStateIdentity(&Saved, &Current), VINF_SUCCESS);

    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Saved, true, "profile-a", szHashA, szHashA), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Current, true, "profile-a", szHashA, szHashA), VINF_SUCCESS);
    RTTESTI_CHECK(CloakStateIdentityEquals(&Saved, &Current));
    RTTESTI_CHECK_RC(CloakCompareStateIdentity(&Saved, &Current), VINF_SUCCESS);

    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Current, true, "profile-b", szHashA, szHashA), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCompareStateIdentity(&Saved, &Current), VERR_MISMATCH);

    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Current, true, "profile-a", szHashB, szHashA), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCompareStateIdentity(&Saved, &Current), VERR_MISMATCH);

    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Current, true, "profile-a", szHashA, szHashB), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCompareStateIdentity(&Saved, &Current), VERR_MISMATCH);

    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Current, false, NULL, NULL, NULL), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCompareStateIdentity(&Saved, &Current), VERR_MISMATCH);

    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Current, false, "ignored", szHashA, szHashA), VINF_SUCCESS);
    RTTESTI_CHECK(!Current.szProfileId[0]);
    RTTESTI_CHECK(!Current.szSeedHash[0]);
    RTTESTI_CHECK(!Current.szManifestHash[0]);

    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Saved, true, "profile-a", "short", szHashA), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Saved, true, NULL, szHashA, szHashA), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakCompareStateIdentity(NULL, &Current), VERR_INVALID_PARAMETER);
}

typedef struct TESTIDENTITYSTREAM
{
    uint8_t abData[1024];
    size_t  cbData;
    size_t  off;
} TESTIDENTITYSTREAM;

static int testIdentityStreamPutU32(void *pvUser, uint32_t u32Value)
{
    TESTIDENTITYSTREAM *pStream = (TESTIDENTITYSTREAM *)pvUser;
    if (pStream->cbData + sizeof(u32Value) > sizeof(pStream->abData))
        return VERR_BUFFER_OVERFLOW;
    memcpy(&pStream->abData[pStream->cbData], &u32Value, sizeof(u32Value));
    pStream->cbData += sizeof(u32Value);
    return VINF_SUCCESS;
}

static int testIdentityStreamPutBool(void *pvUser, bool fValue)
{
    TESTIDENTITYSTREAM *pStream = (TESTIDENTITYSTREAM *)pvUser;
    if (pStream->cbData + 1 > sizeof(pStream->abData))
        return VERR_BUFFER_OVERFLOW;
    pStream->abData[pStream->cbData++] = fValue ? 1 : 0;
    return VINF_SUCCESS;
}

static int testIdentityStreamPutStrZ(void *pvUser, const char *pszValue)
{
    TESTIDENTITYSTREAM *pStream = (TESTIDENTITYSTREAM *)pvUser;
    size_t cchValue = strlen(pszValue) + 1;
    if (pStream->cbData + cchValue > sizeof(pStream->abData))
        return VERR_BUFFER_OVERFLOW;
    memcpy(&pStream->abData[pStream->cbData], pszValue, cchValue);
    pStream->cbData += cchValue;
    return VINF_SUCCESS;
}

static int testIdentityStreamGetU32(void *pvUser, uint32_t *pu32Value)
{
    TESTIDENTITYSTREAM *pStream = (TESTIDENTITYSTREAM *)pvUser;
    if (pStream->off + sizeof(*pu32Value) > pStream->cbData)
        return VERR_SSM_DATA_UNIT_FORMAT_CHANGED;
    memcpy(pu32Value, &pStream->abData[pStream->off], sizeof(*pu32Value));
    pStream->off += sizeof(*pu32Value);
    return VINF_SUCCESS;
}

static int testIdentityStreamGetBool(void *pvUser, bool *pfValue)
{
    TESTIDENTITYSTREAM *pStream = (TESTIDENTITYSTREAM *)pvUser;
    if (pStream->off + 1 > pStream->cbData)
        return VERR_SSM_DATA_UNIT_FORMAT_CHANGED;
    *pfValue = pStream->abData[pStream->off++] != 0;
    return VINF_SUCCESS;
}

static int testIdentityStreamGetStrZ(void *pvUser, char *pszValue, size_t cchValue)
{
    TESTIDENTITYSTREAM *pStream = (TESTIDENTITYSTREAM *)pvUser;
    size_t cch = 0;
    while (   cch < cchValue
           && pStream->off + cch < pStream->cbData
           && pStream->abData[pStream->off + cch] != '\0')
        cch++;
    if (cch >= cchValue || pStream->off + cch >= pStream->cbData)
        return VERR_SSM_DATA_UNIT_FORMAT_CHANGED;
    memcpy(pszValue, &pStream->abData[pStream->off], cch + 1);
    pStream->off += cch + 1;
    return VINF_SUCCESS;
}

static CLOAKSTATEIDENTITYSTREAM testIdentityStreamCreate(TESTIDENTITYSTREAM *pStream)
{
    CLOAKSTATEIDENTITYSTREAM Stream;
    Stream.pfnPutU32 = testIdentityStreamPutU32;
    Stream.pfnPutBool = testIdentityStreamPutBool;
    Stream.pfnPutStrZ = testIdentityStreamPutStrZ;
    Stream.pfnGetU32 = testIdentityStreamGetU32;
    Stream.pfnGetBool = testIdentityStreamGetBool;
    Stream.pfnGetStrZ = testIdentityStreamGetStrZ;
    Stream.pvUser = pStream;
    return Stream;
}

static void testStateIdentitySerialization(RTTEST hTest)
{
    RTTestSub(hTest, "Saved-state identity serialization");

    char szHashA[CLOAK_SEED_HEX_SIZE + 1];
    char szHashB[CLOAK_SEED_HEX_SIZE + 1];
    memset(szHashA, 'A', CLOAK_SEED_HEX_SIZE);
    memset(szHashB, 'B', CLOAK_SEED_HEX_SIZE);
    szHashA[CLOAK_SEED_HEX_SIZE] = '\0';
    szHashB[CLOAK_SEED_HEX_SIZE] = '\0';

    CLOAKSTATEIDENTITY Identity = {};
    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Identity, true, "profile-a", szHashA, szHashB), VINF_SUCCESS);
    RTTESTI_CHECK(CloakStateIdentityIsValid(&Identity));

    TESTIDENTITYSTREAM TestStream = {};
    CLOAKSTATEIDENTITYSTREAM Stream = testIdentityStreamCreate(&TestStream);
    RTTESTI_CHECK_RC(CloakStateIdentitySerialize(&Identity, &Stream), VINF_SUCCESS);
    RTTESTI_CHECK(TestStream.cbData > 0);

    TestStream.off = 0;
    CLOAKSTATEIDENTITY Loaded = {};
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(&Loaded, &Stream), VINF_SUCCESS);
    RTTESTI_CHECK(CloakStateIdentityEquals(&Identity, &Loaded));
    RTTESTI_CHECK(TestStream.off == TestStream.cbData);

    TESTIDENTITYSTREAM DisabledStream = {};
    Stream = testIdentityStreamCreate(&DisabledStream);
    CLOAKSTATEIDENTITY Disabled = {};
    RTTESTI_CHECK_RC(CloakStateIdentitySet(&Disabled, false, NULL, NULL, NULL), VINF_SUCCESS);
    RTTESTI_CHECK(CloakStateIdentityIsValid(&Disabled));
    RTTESTI_CHECK_RC(CloakStateIdentitySerialize(&Disabled, &Stream), VINF_SUCCESS);
    DisabledStream.off = 0;
    Loaded = {};
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(&Loaded, &Stream), VINF_SUCCESS);
    RTTESTI_CHECK(CloakStateIdentityEquals(&Disabled, &Loaded));
    RTTESTI_CHECK(Loaded.fEnabled == false);
    RTTESTI_CHECK(DisabledStream.off == DisabledStream.cbData);

    size_t cbIdentity = TestStream.cbData;
    TestStream.abData[0] ^= 0xff;
    TestStream.off = 0;
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(&Loaded, &Stream), VERR_SSM_DATA_UNIT_FORMAT_CHANGED);

    TestStream.abData[0] ^= 0xff;
    TestStream.cbData = 3;
    TestStream.off = 0;
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(&Loaded, &Stream), VERR_SSM_DATA_UNIT_FORMAT_CHANGED);

    TestStream.cbData = cbIdentity;
    TestStream.abData[sizeof(uint32_t)] = 0;
    TestStream.off = 0;
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(&Loaded, &Stream), VERR_SSM_DATA_UNIT_FORMAT_CHANGED);

    CLOAKSTATEIDENTITY Invalid = {};
    Invalid.fEnabled = true;
    RTTESTI_CHECK_RC(RTStrCopy(Invalid.szProfileId, sizeof(Invalid.szProfileId), "profile-a"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(RTStrCopy(Invalid.szSeedHash, sizeof(Invalid.szSeedHash), "short"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(RTStrCopy(Invalid.szManifestHash, sizeof(Invalid.szManifestHash), szHashA), VINF_SUCCESS);
    RTTESTI_CHECK(!CloakStateIdentityIsValid(&Invalid));
    RTTESTI_CHECK_RC(CloakStateIdentitySerialize(&Invalid, &Stream), VERR_INVALID_PARAMETER);

    CLOAKSTATEIDENTITY DisabledGarbage = {};
    RTTESTI_CHECK_RC(RTStrCopy(DisabledGarbage.szProfileId,
                               sizeof(DisabledGarbage.szProfileId), "profile-a"), VINF_SUCCESS);
    RTTESTI_CHECK(!CloakStateIdentityIsValid(&DisabledGarbage));

    RTTESTI_CHECK_RC(CloakStateIdentitySerialize(NULL, &Stream), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakStateIdentitySerialize(&Identity, NULL), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(NULL, &Stream), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(&Loaded, NULL), VERR_INVALID_PARAMETER);

    CLOAKSTATEIDENTITYSTREAM EmptyStream = {};
    RTTESTI_CHECK_RC(CloakStateIdentitySerialize(&Identity, &EmptyStream), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakStateIdentityDeserialize(&Loaded, &EmptyStream), VERR_INVALID_PARAMETER);
}

static void testSeedHash(RTTEST hTest)
{
    RTTestSub(hTest, "Seed hash");

    uint8_t abSeedA[CLOAK_SEED_SIZE];
    uint8_t abSeedB[CLOAK_SEED_SIZE];
    memset(abSeedA, 0x33, sizeof(abSeedA));
    memset(abSeedB, 0x44, sizeof(abSeedB));

    char szHashA[RTSHA256_DIGEST_LEN + 1];
    char szHashA2[RTSHA256_DIGEST_LEN + 1];
    char szHashB[RTSHA256_DIGEST_LEN + 1];
    RTTESTI_CHECK_RC(CloakSeedHashHex(abSeedA, sizeof(abSeedA), szHashA, sizeof(szHashA)), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakSeedHashHex(abSeedA, sizeof(abSeedA), szHashA2, sizeof(szHashA2)), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakSeedHashHex(abSeedB, sizeof(abSeedB), szHashB, sizeof(szHashB)), VINF_SUCCESS);
    RTTESTI_CHECK(!RTStrCmp(szHashA, szHashA2));
    RTTESTI_CHECK(RTStrCmp(szHashA, szHashB) != 0);
    RTTESTI_CHECK(!RTStrCmp(szHashA,
                            "DEB0E38CED1E41DE6F92E70E80C418D2D356AFAAA99E26F5939DBC7D3EF4772A"));
    RTTESTI_CHECK(RTStrNLen(szHashA, sizeof(szHashA)) == (size_t)RTSHA256_DIGEST_LEN);

    RTTESTI_CHECK_RC(CloakSeedHashHex(abSeedA, 16, szHashA, sizeof(szHashA)), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakSeedHashHex(abSeedA, sizeof(abSeedA), szHashA, 16), VERR_INVALID_PARAMETER);
}

static MACHINEPROFILE makeMaterializableProfile(void)
{
    MACHINEPROFILE Profile = {};
    Profile.pszProfileId = "test-profile-materialize";
    Profile.pszSystemVendor = "VBoxCloak";
    Profile.pszSystemProduct = "Synthetic";
    Profile.pszSystemVersion = "1.0";
    Profile.pszSystemFamily = "Synthetic";
    Profile.pszBiosVendor = "VBoxCloak";
    Profile.pszBiosVersion = "1.0";
    Profile.pszBiosReleaseDate = "19700101";
    Profile.pszBoardVendor = "VBoxCloak";
    Profile.pszBoardProduct = "Synthetic";
    Profile.pszChassisVendor = "VBoxCloak";
    Profile.pszChassisType = "Notebook";
    Profile.pszAcpiOemId = "VBOX";
    return Profile;
}

static void testChassisType(RTTEST hTest)
{
    RTTestSub(hTest, "Chassis type mapping");

    uint32_t u32Type = 0;
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("Other", &u32Type), VINF_SUCCESS);
    RTTESTI_CHECK(u32Type == 1);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("Notebook", &u32Type), VINF_SUCCESS);
    RTTESTI_CHECK(u32Type == 10);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("36", &u32Type), VINF_SUCCESS);
    RTTESTI_CHECK(u32Type == 36);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("37", &u32Type), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("0", &u32Type), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("Desktop-Stock", &u32Type), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("", &u32Type), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString(NULL, &u32Type), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakChassisTypeFromString("Other", NULL), VERR_INVALID_PARAMETER);
}

static void testProfileMaterializationFields(RTTEST hTest)
{
    RTTestSub(hTest, "Profile materialization fields");

    MACHINEPROFILE Profile = makeMaterializableProfile();
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VINF_SUCCESS);

    Profile.pszSystemVendor = "";
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    Profile = makeMaterializableProfile();
    Profile.pszBiosReleaseDate = "";
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    Profile = makeMaterializableProfile();
    Profile.pszAcpiOemId = "";
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    char szLong[256 + 1];
    memset(szLong, 'A', 256);
    szLong[256] = '\0';

    Profile = makeMaterializableProfile();
    Profile.pszSystemVendor = szLong;
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    Profile = makeMaterializableProfile();
    Profile.pszSystemSKU = szLong;
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    char szProfileId[CLOAK_PROFILE_ID_MAX + 1];
    memset(szProfileId, 'A', CLOAK_PROFILE_ID_MAX);
    szProfileId[CLOAK_PROFILE_ID_MAX] = '\0';
    Profile = makeMaterializableProfile();
    Profile.pszProfileId = szProfileId;
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    Profile = makeMaterializableProfile();
    Profile.pszAcpiOemId = "TOOLONG";
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    Profile = makeMaterializableProfile();
    Profile.pszAcpiCreatorId = "TOOLS";
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    Profile = makeMaterializableProfile();
    Profile.pszAcpiOemTabId = "ABC";
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    Profile = makeMaterializableProfile();
    Profile.pszChassisType = "Unsupported";
    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(&Profile), VERR_INVALID_PARAMETER);

    RTTESTI_CHECK_RC(CloakValidateProfileForMaterialization(NULL), VERR_INVALID_PARAMETER);
}

static void testCfgmMaterialization(RTTEST hTest)
{
    RTTestSub(hTest, "CFGM materialization");

    TESTCFGM Cfgm = {};
    TESTCFGMNODE *pRoot = testCfgmAddNode(&Cfgm, "root");
    TESTCFGMNODE *pFirmware = testCfgmAddNode(&Cfgm, "Devices/pcbios/0/Config");
    TESTCFGMNODE *pAcpi = testCfgmAddNode(&Cfgm, "Devices/acpi/0/Config");
    CLOAKCFGMVTABLE VTable = testCfgmMakeVTable(&Cfgm);
    MACHINEPROFILE Profile = makeMaterializableProfile();

    RTTESTI_CHECK(pRoot != NULL);
    RTTESTI_CHECK(CloakCfgmGetFirmwareConfig(&VTable, pRoot) == pFirmware);

    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTable, pFirmware, pAcpi, &Profile), VINF_SUCCESS);
    RTTESTI_CHECK(!RTStrCmp(testCfgmGetString(pFirmware, "DmiSystemVendor"), "VBoxCloak"));
    RTTESTI_CHECK(testCfgmGetInteger(pFirmware, "DmiChassisType", 0) == 10);
    RTTESTI_CHECK(!RTStrCmp(testCfgmGetString(pAcpi, "AcpiOemId"), "VBOX"));
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VINF_SUCCESS);

    RTTESTI_CHECK_RC(testCfgmSetString(pFirmware, "DmiSystemVendor", "UserVendor"), VINF_SUCCESS);
    Profile.pszSystemVendor = "ProfileVendor";
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTable, pFirmware, pAcpi, &Profile), VINF_SUCCESS);
    RTTESTI_CHECK(!RTStrCmp(testCfgmGetString(pFirmware, "DmiSystemVendor"), "UserVendor"));
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VINF_SUCCESS);

    RTTESTI_CHECK_RC(testCfgmSetInteger(pFirmware, "DmiChassisType", 3), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTable, pFirmware, pAcpi, &Profile), VINF_SUCCESS);
    RTTESTI_CHECK(testCfgmGetInteger(pFirmware, "DmiChassisType", 0) == 3);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VINF_SUCCESS);
    RTTESTI_CHECK_RC(testCfgmSetInteger(pFirmware, "DmiChassisType", 10), VINF_SUCCESS);

    RTTESTI_CHECK_RC(testCfgmSetString(pFirmware, "DmiSystemVendor", ""), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(testCfgmSetString(pFirmware, "DmiSystemVendor", "UserVendor"), VINF_SUCCESS);

    RTTESTI_CHECK_RC(testCfgmSetInteger(pFirmware, "DmiChassisType", 99), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(testCfgmSetInteger(pFirmware, "DmiChassisType", 10), VINF_SUCCESS);

    RTTESTI_CHECK_RC(testCfgmSetString(pAcpi, "AcpiOemTabId", "ABC"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(testCfgmSetString(pAcpi, "AcpiOemTabId", "OEMT"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VINF_SUCCESS);

    RTTESTI_CHECK_RC(testCfgmSetString(pAcpi, "AcpiCreatorId", "TOOLS"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(testCfgmSetString(pAcpi, "AcpiCreatorId", "TOOL"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VINF_SUCCESS);

    testCfgmRemoveValue(pAcpi, "AcpiOemId");
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VERR_NOT_FOUND);
    RTTESTI_CHECK_RC(testCfgmSetString(pAcpi, "AcpiOemId", "VBOX"), VINF_SUCCESS);

    testCfgmRemoveValue(pFirmware, "DmiSystemFamily");
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTable, pFirmware, pAcpi), VERR_NOT_FOUND);
    testCfgmDestroy(&Cfgm);

    TESTCFGM CfgmNoAcpi = {};
    TESTCFGMNODE *pFirmwareNoAcpi = testCfgmAddNode(&CfgmNoAcpi, "Devices/pcbios/0/Config");
    CLOAKCFGMVTABLE VTableNoAcpi = testCfgmMakeVTable(&CfgmNoAcpi);
    Profile = makeMaterializableProfile();
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTableNoAcpi, pFirmwareNoAcpi, NULL, &Profile), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTableNoAcpi, pFirmwareNoAcpi, NULL), VINF_SUCCESS);
    RTTESTI_CHECK(testCfgmGetString(pFirmwareNoAcpi, "AcpiOemId") == NULL);
    testCfgmDestroy(&CfgmNoAcpi);

    TESTCFGM CfgmMissing = {};
    CLOAKCFGMVTABLE VTableMissing = testCfgmMakeVTable(&CfgmMissing);
    RTTESTI_CHECK(CloakCfgmGetFirmwareConfig(&VTableMissing, NULL) == NULL);
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTableMissing, NULL, NULL, &Profile), VERR_NOT_FOUND);
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTableMissing, NULL, NULL), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTableMissing, NULL, NULL, NULL), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakCfgmMaterializeString(NULL, NULL, "X", "Y"), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakCfgmMaterializeInteger(NULL, NULL, "X", 1), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakCfgmMaterializeString(&VTableMissing, NULL, "X", "Y"), VINF_SUCCESS);
    RTTESTI_CHECK_RC(CloakCfgmMaterializeInteger(&VTableMissing, NULL, "X", 1), VINF_SUCCESS);
    testCfgmDestroy(&CfgmMissing);

    TESTCFGM CfgmSelect = {};
    TESTCFGMNODE *pRootSelect = testCfgmAddNode(&CfgmSelect, "root");
    TESTCFGMNODE *pEfi = testCfgmAddNode(&CfgmSelect, "Devices/efi/0/Config");
    CLOAKCFGMVTABLE VTableSelect = testCfgmMakeVTable(&CfgmSelect);
    RTTESTI_CHECK(CloakCfgmGetFirmwareConfig(&VTableSelect, pRootSelect) == pEfi);
    TESTCFGMNODE *pPcBios = testCfgmAddNode(&CfgmSelect, "Devices/pcbios/0/Config");
    RTTESTI_CHECK(CloakCfgmGetFirmwareConfig(&VTableSelect, pRootSelect) == pPcBios);
    testCfgmDestroy(&CfgmSelect);

    TESTCFGM CfgmError = {};
    TESTCFGMNODE *pFirmwareError = testCfgmAddNode(&CfgmError, "Devices/pcbios/0/Config");
    CLOAKCFGMVTABLE VTableError = testCfgmMakeVTable(&CfgmError);
    Profile = makeMaterializableProfile();
    CfgmError.rcGetChild = VERR_ACCESS_DENIED;
    RTTESTI_CHECK(CloakCfgmGetFirmwareConfig(&VTableError, pFirmwareError) == NULL);
    CfgmError.rcGetChild = VINF_SUCCESS;
    CfgmError.rcInsertString = VERR_NO_MEMORY;
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTableError, pFirmwareError, NULL, &Profile), VERR_NO_MEMORY);
    CfgmError.rcInsertString = VINF_SUCCESS;
    CfgmError.rcInsertInteger = VERR_NO_MEMORY;
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTableError, pFirmwareError, NULL, &Profile), VERR_NO_MEMORY);
    CfgmError.rcInsertInteger = VINF_SUCCESS;
    RTTESTI_CHECK_RC(CloakCfgmMaterializeProfile(&VTableError, pFirmwareError, NULL, &Profile), VINF_SUCCESS);
    CfgmError.rcQueryString = VERR_ACCESS_DENIED;
    RTTESTI_CHECK_RC(CloakCfgmValidateEffectiveConfig(&VTableError, pFirmwareError, NULL), VERR_ACCESS_DENIED);
    testCfgmDestroy(&CfgmError);
}

static void testProfileClassNames(RTTEST hTest)
{
    RTTestSub(hTest, "Profile class names");

    RTTESTI_CHECK(!RTStrCmp(CloakProfileClassToString(CLOAKPROFILE_DRAFT), "DRAFT"));
    RTTESTI_CHECK(!RTStrCmp(CloakProfileClassToString(CLOAKPROFILE_RESEARCH_ONLY), "RESEARCH_ONLY"));
    RTTESTI_CHECK(!RTStrCmp(CloakProfileClassToString(CLOAKPROFILE_COMPATIBLE), "COMPATIBLE"));
    RTTESTI_CHECK(!RTStrCmp(CloakProfileClassToString((CLOAKPROFILECLASS)99), "UNKNOWN"));
}

int main()
{
    RTTEST      hTest;
    RTEXITCODE  rcExit = RTTestInitAndCreate("tstCloakConfig", &hTest);
    if (rcExit == RTEXITCODE_SUCCESS)
    {
        RTTestBanner(hTest);

        testSeedDecode(hTest);
        testHmac(hTest);
        testSeedStreams(hTest);
        testBuildManifestValidation(hTest);
        testManifestValidation(hTest);
        testProductionRegistry(hTest);
        testManifestHashAndStateIdentity(hTest);
        testStateIdentitySerialization(hTest);
        testSeedHash(hTest);
        testChassisType(hTest);
        testProfileMaterializationFields(hTest);
        testCfgmMaterialization(hTest);
        testProfileClassNames(hTest);

        rcExit = RTTestSummaryAndDestroy(hTest);
    }
    return rcExit;
}
