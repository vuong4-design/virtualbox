#!/usr/bin/env python3
"""Reference-model tests for the opt-in lab ACPI header rewrite.

This validates ACPI table layout and checksum arithmetic using synthetic
tables. It is NOT a compiled VBoxDD test or a replacement for guest boot testing.
"""

from __future__ import annotations

import pathlib
import struct

HEADER = struct.Struct('<4sIBB6s8sI4sI')
assert HEADER.size == 36


def create_table(signature: bytes, body: bytes, oem: bytes = b'VBOX  ',
                 tab_id: bytes = b'VBOXBIOS') -> bytes:
    table = bytearray(HEADER.pack(signature, HEADER.size + len(body), 2, 0,
                                  oem, tab_id, 2, b'ASL ', 1) + body)
    table[9] = (-sum(table)) & 255
    assert sum(table) % 256 == 0
    return bytes(table)


def reference_patch(table: bytes, signature: bytes, suffix: bytes, enabled: bool) -> bytes:
    if not enabled:
        return table
    if len(table) < HEADER.size or table[:4] != signature:
        raise ValueError('bad signature / truncated table')
    if struct.unpack_from('<I', table, 4)[0] != len(table):
        raise ValueError('bad encoded length')
    result = bytearray(table)
    result[10:16] = b'LAB   '
    result[16:24] = b'LAB0' + suffix
    result[9] = 0
    result[9] = (-sum(result)) & 255
    assert sum(result) % 256 == 0
    assert result[36:] == table[36:]
    return bytes(result)


def test() -> None:
    for sig, suffix, table_id in ((b'DSDT', b'DSDT', b'VBOXBIOS'),
                                  (b'SSDT', b'CPUT', b'VBOXCPUT'),
                                  (b'SSDT', b'TPM0', b'VBOXTPM0')):
        body = bytes((i * 17 + 9) & 255 for i in range(512))
        original = create_table(sig, body, tab_id=table_id)
        assert reference_patch(original, sig, suffix, False) == original
        patched = reference_patch(original, sig, suffix, True)
        assert patched[:4] == sig
        assert patched[10:16] == b'LAB   '
        assert patched[16:24] == b'LAB0' + suffix
        assert len(patched) == len(original)
        assert patched[36:] == original[36:]
        assert sum(patched) % 256 == 0
        for bad in (original[:32], b'FADT' + original[4:]):
            try:
                reference_patch(bad, sig, suffix, True)
            except ValueError:
                pass
            else:
                raise AssertionError('Malformed table was accepted')
        damaged = bytearray(original)
        struct.pack_into('<I', damaged, 4, len(damaged) + 1)
        try:
            reference_patch(bytes(damaged), sig, suffix, True)
        except ValueError:
            pass
        else:
            raise AssertionError('Length mismatch was accepted')

    root = pathlib.Path(__file__).resolve().parents[2]
    cpp = (root / 'src/VBox/Devices/PC/ACPI/VBoxAcpi.cpp').read_text(encoding='utf-8')
    dev = (root / 'src/VBox/Devices/PC/DevACPI.cpp').read_text(encoding='utf-8')
    profile = (root / 'src/VBox/Main/src-client/ConsoleImplConfigCloak.cpp').read_text(encoding='utf-8')
    for hook in ('acpiLabPatchAmlHeader(pDevIns, pabAmlCodeDsdt',
                 'acpiLabPatchAmlHeader(pDevIns, pabAmlCodeSsdt',
                 'RTAcpiTblHdrChecksumGenerate(pHdr, cbAml)',
                 'CloakLabPatchHeaders'):
        assert hook in cpp, f'Missing ACPI source hook: {hook}'
    assert '"|CloakLabPatchHeaders"' in dev
    assert '"CloakLabPatchHeaders", 1' in profile
    assert 'Profile.pszAcpiOemTabId = "LAB0"' in profile
    print('PASS: ACPI header reference (3 table types, checksums, bytecode unchanged, invalid inputs rejected)')
    print('PASS: CFGM and source-hook contracts (not a substitute for compiling VBoxDD)')


if __name__ == '__main__':
    test()