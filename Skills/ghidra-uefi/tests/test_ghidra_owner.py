"""The owner's client, without Ghidra: a fake owner answers the bridge, and
the real store (through `byteripper-cas`) keeps what a publish stores.

    python3 -m unittest discover -s Skills/ghidra-uefi/tests
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import cas
import ghidra_owner


def artifact(functions: int) -> bytes:
    return json.dumps({
        "script_version": 4, "ghidra": "12.1.2",
        "program": {"name": "M.pe", "language": "x86:LE:32:default", "image_base": "0x0"},
        "functions": [{"entry": f"0x{i:X}", "name": f"FUN_{i:X}", "instructions": []}
                      for i in range(functions)],
        "strings": [], "post_codes": [], "status_code_calls": [],
    }, sort_keys=True).encode("utf-8")


class FakeOwner(BaseHTTPRequestHandler):
    """Answers the bridge's hello, publish and review with what the class
    attributes hold."""
    served = artifact(1)
    document = b'{"functions": {}}'
    reviewed = False

    def do_GET(self):
        if self.path == "/v1/hello":
            self._answer(json.dumps({"protocol": 1}).encode())
        else:
            self._answer(FakeOwner.document if self.path == "/v1/review" else None)

    def do_POST(self):
        self._answer(FakeOwner.served if self.path == "/v1/publish" else None)

    def _answer(self, body):
        if body is None:
            self.send_response(404)
            body = json.dumps({"error": "no such call"}).encode()
        else:
            self.send_response(200)
            self.send_header("X-Owner-Reviewed", "true" if FakeOwner.reviewed else "false")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class OwnerClientTests(unittest.TestCase):
    def setUp(self):
        FakeOwner.reviewed = False
        FakeOwner.document = b'{"functions": {}}'
        self.directory = tempfile.TemporaryDirectory()
        root = Path(self.directory.name)
        self.store = cas.Store(root / "store")
        self.sha = hashlib.sha256(b"module").hexdigest()
        self.project = ghidra_owner.Project(root / "projects", self.sha)
        self.project.dir.mkdir(parents=True)
        (self.project.dir / "module.gpr").write_text("")
        self.project.write_state({
            "schema": 1, "project": "p", "program": "M.pe",
            "module": {"sha256": self.sha, "size": 6, "name": "M", "kind": "PE32", "phase": "dxe"},
            "made_with": {"ghidra": "12.1.2", "types": "edk2-stable202608", "passes": ["ApplyUefi.java"]},
            "source": {"path": "/tmp/M.pe", "document": "dump.bin", "node": "0.1"},
            "reviewed": False, "published": None,
        })
        self.server = HTTPServer(("127.0.0.1", 0), FakeOwner)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.project.owner_path.write_text(json.dumps(
            {"pid": os.getpid(), "port": self.server.server_address[1]}))

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.directory.cleanup()

    def testAPublishStoresTheArtifactUnderTheProjectsRecipe(self):
        FakeOwner.served = artifact(2)
        manifest = ghidra_owner.publish(self.project, self.store)
        self.assertEqual(manifest["recipe"]["id"], "code-v4-ghidra-12.1.2")
        self.assertEqual(manifest["recipe"]["types"], "edk2-stable202608")
        self.assertEqual(manifest["module"]["phase"], "dxe")
        self.assertEqual(manifest["module"]["language"], "x86:LE:32:default")
        self.assertEqual(manifest["source"]["node"], "0.1")
        self.assertNotIn("reading", manifest, "phase 1 publishes the mechanical reading")
        self.assertEqual(self.project.state()["published"]["artifact"], manifest["artifact"]["sha256"])

    def testAPublishReplacesItsOwnButNotAnotherAnalysis(self):
        FakeOwner.served = artifact(1)
        ghidra_owner.publish(self.project, self.store)
        FakeOwner.served = artifact(2)
        second = ghidra_owner.publish(self.project, self.store)
        self.assertEqual(second["stats"]["functions"], 2, "its own last publish is superseded")

        # Someone else's analysis under the same key is not this project's.
        self.store.put_analysis(second["module"], second["recipe"], artifact(3), discard_reading=True)
        FakeOwner.served = artifact(4)
        with self.assertRaises(cas.CASError):
            ghidra_owner.publish(self.project, self.store)

    def testAReviewedProgramPublishesARevisionOfItsReading(self):
        FakeOwner.served = artifact(1)
        ghidra_owner.publish(self.project, self.store)       # before the review: mechanical
        FakeOwner.reviewed = True
        FakeOwner.document = b'{"functions": {"0x0": {"name": "Init"}}}'
        FakeOwner.served = artifact(2)
        first = ghidra_owner.publish(self.project, self.store)
        self.assertEqual(first["reading"]["rev"], 1, "a reading replaces the mechanical artifact")
        self.assertEqual(self.store.get_object(first["reading"]["review"]), FakeOwner.document)
        again = ghidra_owner.publish(self.project, self.store)
        self.assertEqual(again["reading"]["rev"], 1, "an unchanged program is the same revision")
        # A comment: the document changes, the artifact need not.
        FakeOwner.document = b'{"comments": [{"address": "0x0"}], "functions": {"0x0": {"name": "Init"}}}'
        third = ghidra_owner.publish(self.project, self.store)
        self.assertEqual(third["reading"]["rev"], 2)
        self.assertEqual(third["artifact"], first["artifact"])
        self.assertEqual(self.store.analysis(self.sha)["reading"]["rev"], 2)
        self.assertTrue(self.project.state()["reviewed"])
        # The history has each revision once, the unchanged repeat included in
        # revision 1, and the store is sound after every publish.
        history = self.store.review_history(self.sha)
        self.assertEqual([r["rev"] for r in history["revisions"]], [1, 2])
        self.assertEqual(history["revisions"][1]["review"], third["reading"]["review"])
        self.assertEqual(self.store.verify(), [])

    def testAnOwnerWhoseProcessIsGoneIsNotRunning(self):
        self.project.owner_path.write_text(json.dumps({"pid": 999999, "port": 1}))
        self.assertIsNone(self.project.owner())
        self.assertFalse(self.project.owner_path.exists())
        with self.assertRaises(ghidra_owner.OwnerError):
            ghidra_owner.publish(self.project, self.store)

    def testABridgeRefusalIsAnOwnerError(self):
        with self.assertRaises(ghidra_owner.OwnerError) as refused:
            ghidra_owner.call(self.server.server_address[1], "GET", "/v1/nothing")
        self.assertIn("no such call", str(refused.exception))


if __name__ == "__main__":
    unittest.main()
