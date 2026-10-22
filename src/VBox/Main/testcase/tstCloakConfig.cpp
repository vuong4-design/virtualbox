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

#include <iprt/test.h>
#include <iprt/uuid.h>

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

static void testManifestValidation(RTTEST hTest)
{
    RTTestSub(hTest, "Build manifest validation");

    MACHINEPROFILE Profile = {};
    Profile.pszProfileId = "test-profile";
    Profile.enmClass = CLOAKPROFILE_COMPATIBLE;
    Profile.pszRequiredFirmwareFamily = "ami";
    Profile.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3;
    Profile.uVmmDevVendorId = 0x80ee;
    Profile.uVmmDevDeviceId = 0xcafe;
    Profile.pszProvenanceHash = "sha256:test";

    CLOAKBUILDMANIFEST Manifest = {};
    Manifest.pszBuildMode = "cloak";
    Manifest.pszFirmwareFamily = "ami";
    Manifest.fSupportedChipsets = CLOAKCHIPSET_I440FX | CLOAKCHIPSET_PIIX3 | CLOAKCHIPSET_ICH9;
    Manifest.uVmmDevVendorId = 0x80ee;
    Manifest.uVmmDevDeviceId = 0xcafe;

    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, &Manifest), VINF_SUCCESS);

    CLOAKBUILDMANIFEST Bad = Manifest;
    Bad.pszBuildMode = "stock";
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, &Bad), VERR_NOT_SUPPORTED);

    MACHINEPROFILE BadProfile = Profile;
    BadProfile.enmClass = CLOAKPROFILE_DRAFT;
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
    BadProfile.pszProvenanceHash = NULL;
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&BadProfile, &Manifest), VERR_NOT_SUPPORTED);

    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(NULL, &Manifest), VERR_INVALID_PARAMETER);
    RTTESTI_CHECK_RC(CloakValidateProfileAgainstManifest(&Profile, NULL), VERR_INVALID_PARAMETER);
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
        testManifestValidation(hTest);
        testSeedHash(hTest);
        testProfileClassNames(hTest);

        rcExit = RTTestSummaryAndDestroy(hTest);
    }
    return rcExit;
}
