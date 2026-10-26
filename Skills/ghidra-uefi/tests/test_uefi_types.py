"""The GUID table the UEFI pass names a module's GUIDs by.

The bytes are what the pass matches in memory, so the layout of an EFI_GUID —
three little-endian fields, then eight bytes as they are — must be right, and
EDK2's own names must win over the catalogue's.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import code_artifact
import uefi_types

PCI_IO = "00B2F54CB868A54C9EECB23E3F50029A"


class GuidTableTests(unittest.TestCase):
    def test_a_registry_guid_is_laid_out_as_in_memory(self):
        self.assertEqual(uefi_types.parse_registry_guid("4CF5B200-68B8-4CA5-9EEC-B23E3F50029A"), PCI_IO)
        self.assertIsNone(uefi_types.parse_registry_guid("not a guid"))

    def test_a_dec_entry_is_read(self):
        dec = ("[Protocols]\n  gEfiPciIoProtocolGuid = { 0x4cf5b200, 0x68b8, 0x4ca5, "
               "{ 0x9e, 0xec, 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a }}\n")
        self.assertEqual(uefi_types.dec_guids(dec), {PCI_IO: "gEfiPciIoProtocolGuid"})

    def test_catalogue_names_are_spelled_as_edk2_variables(self):
        self.assertEqual(uefi_types.canonical_name("EfiPciIoProtocolGuid"), "gEfiPciIoProtocolGuid")
        self.assertEqual(uefi_types.canonical_name("FirmwarePerformanceDxe"),
                         "gFirmwarePerformanceDxeGuid")
        self.assertEqual(uefi_types.canonical_name("gEfiFooGuid"), "gEfiFooGuid")
        self.assertIsNone(uefi_types.canonical_name("123"))

    def test_edk2_names_win_over_the_catalogue(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "MdePkg").mkdir()
            (root / "MdePkg" / "MdePkg.dec").write_text(
                "gEfiPciIoProtocolGuid = { 0x4cf5b200, 0x68b8, 0x4ca5, "
                "{ 0x9e, 0xec, 0xb2, 0x3e, 0x3f, 0x50, 0x02, 0x9a }}\n")
            csv = root / "guids.csv"
            csv.write_text("4CF5B200-68B8-4CA5-9EEC-B23E3F50029A,PciIo\n"
                           "00160F8D-2B35-4DF2-BBE0-B272A8D631F0,FirmwarePerformanceDxe\n")
            out = root / "guids.tsv"
            self.assertEqual(uefi_types.write_table(root, csv, out), 2)
            lines = out.read_text().splitlines()
            self.assertIn(f"{PCI_IO}\tgEfiPciIoProtocolGuid", lines)
            self.assertTrue(all(len(line.split("\t")[0]) == 32 for line in lines))


class PhaseTests(unittest.TestCase):
    def pe(self, machine: int) -> bytes:
        blob = bytearray(0x100)
        blob[0:2] = b"MZ"
        blob[0x3C:0x40] = (0x80).to_bytes(4, "little")
        blob[0x80:0x84] = b"PE\0\0"
        blob[0x84:0x86] = machine.to_bytes(2, "little")
        return bytes(blob)

    def test_the_phase_follows_the_image(self):
        self.assertEqual(code_artifact.guess_phase(b"VZ\x4c\x01" + bytes(36)), "pei")
        self.assertEqual(code_artifact.guess_phase(self.pe(0x14C)), "pei")
        self.assertEqual(code_artifact.guess_phase(self.pe(0x8664)), "dxe")
        self.assertEqual(code_artifact.machine(self.pe(0x8664)), 0x8664)


if __name__ == "__main__":
    unittest.main()
