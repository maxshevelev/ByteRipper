"""The local CAS, without Ghidra and without a dump: the skill's client
against the real `byteripper-cas`, which `cas.tool()` builds once.

    python3 -m unittest discover -s tests
"""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import cas


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def artifact(functions: int = 1) -> bytes:
    return json.dumps({
        "script_version": 2,
        "ghidra": "12.1.2",
        "functions": [
            {"entry": f"0x{index:X}", "name": f"FUN_{index:X}",
             "instructions": [{"address": f"0x{index:X}", "text": "RET"}]}
            for index in range(functions)
        ],
        "strings": [],
        "post_codes": [],
        "status_code_calls": [],
    }).encode("utf-8")


class CASTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = cas.Store(Path(self.directory.name) / "store")

    def tearDown(self):
        self.directory.cleanup()

    def module(self, label: bytes = b"module") -> dict:
        return {"sha256": digest(label), "size": len(label), "name": label.decode(),
                "kind": "TE", "language": "x86:LE:32:default", "image_base": "0x0"}

    def recipe(self, name: str = "code-v2-ghidra-12.1.2") -> dict:
        return {"id": name, "exporter": 2, "ghidra": "12.1.2", "script": "ExportCode.java"}

    # -- objects --------------------------------------------------------

    def testAnObjectIsItsHashAndSurvivesADuplicatePut(self):
        first = self.store.put_object(b"hello")
        second = self.store.put_object(b"hello")
        self.assertEqual(first, second)
        self.assertEqual(first, digest(b"hello"))
        self.assertEqual(self.store.get_object(first), b"hello")

    def testACorruptObjectIsRefusedOnRead(self):
        value = self.store.put_object(b"hello")
        path = self.store.root / "objects" / value
        path.write_bytes(b"HELLO")
        with self.assertRaises(cas.CASError):
            self.store.get_object(value)
        self.assertTrue(self.store.verify())

    def testAPathThatIsNotADigestIsRefused(self):
        with self.assertRaises(cas.CASError):
            self.store.get_object("../../etc/passwd")

    # -- analyses -------------------------------------------------------

    def testAnAnalysisNamesItsModuleItsRecipeAndItsObject(self):
        manifest = self.store.put_analysis(self.module(), self.recipe(), artifact(3))
        self.assertEqual(manifest["artifact"]["sha256"], digest(artifact(3)))
        self.assertEqual(manifest["stats"]["functions"], 3)
        found = self.store.analysis(self.module()["sha256"], "code-v2-ghidra-12.1.2")
        self.assertEqual(found["artifact"], manifest["artifact"])
        self.assertEqual(self.store.recipes(self.module()["sha256"]),
                         ["code-v2-ghidra-12.1.2"])

    def testTheSameRecipeWithAnotherArtifactIsRefusedUnlessReplaced(self):
        self.store.put_analysis(self.module(), self.recipe(), artifact(1))
        with self.assertRaises(cas.CASError):
            self.store.put_analysis(self.module(), self.recipe(), artifact(2))
        replaced = self.store.put_analysis(self.module(), self.recipe(), artifact(2), replace=True)
        self.assertEqual(replaced["artifact"]["sha256"], digest(artifact(2)))

    def testRebindingTheSameAnalysisUpdatesOnlyWhatIsNamed(self):
        data = artifact()
        first = self.store.put_analysis(
            self.module(), self.recipe(), data,
            source={"document": "d1", "node": "0.1"})
        self.assertEqual(first["source"]["node"], "0.1")
        rebound = self.store.put_analysis(
            self.module(), self.recipe(), data,
            source={"document": "d1", "node": "0.2"})
        self.assertEqual(rebound["source"]["node"], "0.2")
        found = self.store.analysis(self.module()["sha256"], "code-v2-ghidra-12.1.2")
        self.assertEqual(found["source"]["node"], "0.2")
        kept = self.store.put_analysis(self.module(), self.recipe(), data)
        self.assertEqual(kept["source"]["node"], "0.2")
        self.assertEqual(kept["source"]["document"], "d1")

    def testARecipeNameCannotEscapeItsDirectory(self):
        with self.assertRaises(cas.CASError):
            self.store.put_analysis(self.module(), self.recipe("../../outside"), artifact())

    def testTwoRecipesAreTwoAnalysesOfTheSameModule(self):
        self.store.put_analysis(self.module(), self.recipe(), artifact(1))
        self.store.put_analysis(self.module(), self.recipe("code-v2-ghidra-12.2"), artifact(2))
        self.assertEqual(self.store.recipes(self.module()["sha256"]),
                         ["code-v2-ghidra-12.1.2", "code-v2-ghidra-12.2"])

    # -- references and collection --------------------------------------

    def testAReferenceKeepsItsAnalysisAndGCLeavesTheRest(self):
        module = self.module(b"one")
        first = self.store.put_analysis(module, self.recipe(), artifact(1))
        other_module = self.module(b"two")
        self.store.put_analysis(other_module, self.recipe(), artifact(2))
        self.store.set_ref("project", [self.store.key(first)])

        report = self.store.gc(dry_run=False, delete_unreferenced_analyses=True)
        self.assertEqual(report["analyses"], 1)
        self.assertIsNotNone(self.store.analysis(module["sha256"]))
        self.assertIsNone(self.store.analysis(other_module["sha256"]))
        self.assertEqual(self.store.referenced_keys(), {self.store.key(first)})

    def testGCAgainstAnEmptyReferenceSetKeepsAnalyses(self):
        self.store.put_analysis(self.module(), self.recipe(), artifact())
        report = self.store.gc(dry_run=False, delete_unreferenced_analyses=False)
        self.assertEqual(report["analyses"], 0)
        self.assertIsNotNone(self.store.analysis(self.module()["sha256"]))

    def testAnObjectNoManifestNamesIsCollected(self):
        self.store.put_object(b"orphan")
        report = self.store.gc(dry_run=False)
        self.assertEqual(report["objects"], 1)
        self.assertFalse((self.store.root / "objects" / digest(b"orphan")).exists())

    # -- moving analyses ------------------------------------------------

    def testABundleCarriesTheManifestAndTheArtifact(self):
        module = self.module()
        manifest = self.store.put_analysis(module, self.recipe(), artifact(4))
        bundle = Path(self.directory.name) / "bundle.zip"
        self.store.export_bundle([self.store.key(manifest)], bundle)
        self.assertTrue(bundle.is_file())

        other = cas.Store(Path(self.directory.name) / "other")
        imported = other.import_bundle(bundle)
        self.assertEqual(len(imported["imported"]), 1)
        found = other.analysis(module["sha256"])
        self.assertEqual(found["artifact"], manifest["artifact"])
        self.assertEqual(other.verify(), [])

    # -- readings -------------------------------------------------------

    def testALaterReadingReplacesAndAMechanicalRunDoesNot(self):
        self.store.put_analysis(self.module(), self.recipe(), artifact(1),
                                reading={"project": "p", "rev": 1})
        second = self.store.put_analysis(self.module(), self.recipe(), artifact(2),
                                         reading={"project": "p", "rev": 2})
        self.assertEqual(second["reading"]["rev"], 2)
        with self.assertRaises(cas.CASError):
            self.store.put_analysis(self.module(), self.recipe(), artifact(3), replace=True)
        discarded = self.store.put_analysis(self.module(), self.recipe(), artifact(3),
                                            discard_reading=True)
        self.assertNotIn("reading", discarded)

    def testTheUEFIFieldsSurviveTheTool(self):
        recipe = {**self.recipe(), "types": "edk2-stable202608", "passes": ["ApplyUefi.java"]}
        module = {**self.module(), "phase": "pei"}
        manifest = self.store.put_analysis(module, recipe, artifact())
        self.assertEqual(manifest["recipe"]["types"], "edk2-stable202608")
        self.assertEqual(manifest["module"]["phase"], "pei")

    def testAFieldTheStoreDoesNotKnowIsRefusedNotDropped(self):
        with self.assertRaises(cas.CASError):
            self.store.put_analysis({**self.module(), "colour": "red"}, self.recipe(), artifact())

    def testAnotherProjectsReadingIsKeptAside(self):
        source = cas.Store(Path(self.directory.name) / "source")
        manifest = source.put_analysis(self.module(), self.recipe(), artifact(2),
                                       reading={"project": "q", "rev": 1})
        bundle = Path(self.directory.name) / "q.zip"
        source.export_bundle([source.key(manifest)], bundle)
        self.store.put_analysis(self.module(), self.recipe(), artifact(1),
                                reading={"project": "p", "rev": 1})
        result = self.store.import_bundle(bundle)
        self.assertEqual(len(result["conflicts"]), 1)
        self.assertEqual(self.store.conflicts()[0]["reading"]["project"], "q")
        self.assertEqual(self.store.analysis(self.module()["sha256"])["reading"]["project"], "p")


if __name__ == "__main__":
    unittest.main()
