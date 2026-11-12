# Tests for the on-device configuration helper. Run with:
#   python3 -m unittest discover -s Packages/KVMKit/Tests/HelperTests
# Needs ruamel.yaml and PyYAML (pip install ruamel.yaml pyyaml). A fake
# `kvmd` on PATH stands in for the real one.

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest

HELPER = os.path.join(os.path.dirname(__file__), "..", "..", "Sources", "KVMKit", "Resources", "pikvm_config_helper.py")

FAKE_KVMD = r'''#!/usr/bin/env python3
# Fake kvmd: "-m [--override-config F]" dumps a config, or fails if the
# override contains the key "bogus" (as kvmd fails on unknown options).
import sys, os
args = sys.argv[1:]
path = os.environ["PKC_OVERRIDE"]
if "--override-config" in args:
    path = args[args.index("--override-config") + 1]
text = open(path).read() if os.path.exists(path) else ""
if "bogus" in text:
    sys.stderr.write("ConfigError: The key 'bogus' is not allowed in %s\n" % path)
    sys.exit(1)
audio = "true" if "audio:\n" in text and "enabled: true" in text else "false"
print("kvmd:\n    hid:\n        jiggler:\n            enabled: true  # comment\n            interval: 60\n"
      "otg:\n    vendor_id: 0x1D6B\n    devices:\n        audio:\n            enabled: %s  ### Default: false\n" % audio)
'''


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = self.dir.name
        self.override = os.path.join(d, "override.yaml")
        bindir = os.path.join(d, "bin")
        os.mkdir(bindir)
        kvmd = os.path.join(bindir, "kvmd")
        with open(kvmd, "w") as f:
            f.write(FAKE_KVMD)
        os.chmod(kvmd, os.stat(kvmd).st_mode | stat.S_IEXEC)
        self.env = dict(os.environ)
        self.env.update({
            "PATH": bindir + os.pathsep + os.environ["PATH"],
            "PKC_OVERRIDE": self.override,
            "PKC_OVERRIDE_D": os.path.join(d, "override.d"),
            "PKC_BACKUPS": os.path.join(d, "backups"),
            "PKC_DRY_RUN": "1",
        })

    def tearDown(self):
        self.dir.cleanup()

    def call(self, **req):
        path = os.path.join(self.dir.name, "req.json")
        with open(path, "w") as f:
            json.dump(req, f)
        out = subprocess.run([sys.executable, HELPER, path], env=self.env, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, universal_newlines=True, check=True).stdout
        lines = [line for line in out.splitlines() if line.startswith("PKC_JSON:")]
        self.assertEqual(len(lines), 1, out)
        return json.loads(lines[0][len("PKC_JSON:"):])

    def write(self, text):
        with open(self.override, "w") as f:
            f.write(text)

    def test_load(self):
        self.write("kvmd:\n    hid:\n        jiggler:\n            enabled: true\n")
        r = self.call(op="load", paths=["kvmd/hid/jiggler/enabled", "otg/vendor_id", "otg/devices/camera/enabled"])
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["effective"], {"kvmd/hid/jiggler/enabled": True, "otg/vendor_id": 0x1D6B})
        self.assertIn("jiggler", r["text"])
        self.assertEqual(r["overridden"], ["kvmd/hid/jiggler/enabled"])
        self.assertEqual(r["backups"], [])

    def test_merge_keeps_comments(self):
        text = "# my notes\nkvmd:\n    # the mouse jiggler\n    hid:\n        jiggler:\n            enabled: false\n"
        r = self.call(op="merge", text=text, patch={"kvmd/hid/jiggler/enabled": True, "otg/devices/audio/enabled": True})
        self.assertTrue(r["ok"], r)
        self.assertIn("# my notes", r["text"])
        self.assertIn("# the mouse jiggler", r["text"])
        self.assertIn("            enabled: true", r["text"])
        self.assertIn("otg:\n    devices:\n        audio:\n            enabled: true\n", r["text"])

    def test_merge_writes_whole_floats_as_ints(self):
        r = self.call(op="merge", text="", patch={"kvmd/streamer/quality": 80.0})
        self.assertEqual(r["text"], "kvmd:\n    streamer:\n        quality: 80\n")

    def test_merge_delete_prunes_empty_sections(self):
        text = "otg:\n    devices:\n        audio:\n            enabled: true\nvnc:\n    desired_fps: 20\n"
        r = self.call(op="merge", text=text, patch={"otg/devices/audio/enabled": None})
        self.assertEqual(r["text"], "vnc:\n    desired_fps: 20\n")

    def test_merge_into_comment_only_file(self):
        text = textwrap.dedent("""\
            ####
            # Override KVMD settings.
            #vnc:
            #    keymap: x
            """)
        r = self.call(op="merge", text=text, patch={"vnc/desired_fps": 20})
        self.assertIn("# Override KVMD settings.", r["text"])
        self.assertIn("#    keymap: x", r["text"])
        self.assertTrue(r["text"].endswith("vnc:\n    desired_fps: 20\n"), r["text"])
        # Removing it again leaves only the comments.
        r = self.call(op="merge", text=r["text"], patch={"vnc/desired_fps": None})
        self.assertNotIn("{}", r["text"])
        self.assertIn("# Override KVMD settings.", r["text"])

    def test_merge_rejects_bad_yaml(self):
        r = self.call(op="merge", text="kvmd: [unclosed", patch={"a/b": 1})
        self.assertFalse(r["ok"])
        self.assertIn("not valid", r["error"])

    def test_validate(self):
        self.assertTrue(self.call(op="validate", text="vnc:\n    desired_fps: 20\n")["ok"])
        r = self.call(op="validate", text="kvmd:\n    bogus: 1\n")
        self.assertFalse(r["ok"])
        self.assertIn("bogus", r["details"])
        self.assertNotIn("pkc-candidate", r["details"])
        r = self.call(op="validate", text="- a list\n")
        self.assertFalse(r["ok"])
        self.assertIn("mapping", r["error"])

    def test_save_backs_up_and_reports_sections(self):
        self.write("vnc:\n    desired_fps: 20\n")
        r = self.call(op="save", text="vnc:\n    desired_fps: 25\notg:\n    devices:\n        audio:\n            enabled: true\n", restart=True)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["changed"], ["otg/devices/audio/enabled", "vnc/desired_fps"])
        self.assertEqual(r["sections"], ["otg", "vnc"])
        self.assertTrue(r["rebootRequired"])
        self.assertEqual(r["restarted"], ["kvmd-vnc"])
        with open(os.path.join(self.env["PKC_BACKUPS"], r["backup"])) as f:
            self.assertEqual(f.read(), "vnc:\n    desired_fps: 20\n")
        with open(self.override) as f:
            self.assertIn("desired_fps: 25", f.read())

        listed = self.call(op="load", paths=[])["backups"]
        self.assertEqual([b["name"] for b in listed], [r["backup"]])
        self.assertEqual(self.call(op="backup", name=r["backup"])["text"], "vnc:\n    desired_fps: 20\n")

        restored = self.call(op="restore", name=r["backup"], restart=False)
        self.assertTrue(restored["ok"], restored)
        with open(self.override) as f:
            self.assertEqual(f.read(), "vnc:\n    desired_fps: 20\n")
        self.assertEqual(len(self.call(op="load", paths=[])["backups"]), 2)

    def test_save_refuses_invalid_and_leaves_file(self):
        self.write("vnc:\n    desired_fps: 20\n")
        r = self.call(op="save", text="kvmd:\n    bogus: 1\n")
        self.assertFalse(r["ok"])
        with open(self.override) as f:
            self.assertEqual(f.read(), "vnc:\n    desired_fps: 20\n")
        self.assertFalse(os.path.exists(self.env["PKC_BACKUPS"]))

    def test_save_unchanged(self):
        self.write("vnc:\n    desired_fps: 20\n")
        r = self.call(op="save", text="vnc:\n    desired_fps: 20\n")
        self.assertTrue(r["unchanged"])

    def test_restore_rejects_path_tricks(self):
        r = self.call(op="backup", name="../override.yaml")
        self.assertFalse(r["ok"])

    def test_kvmd_section_restarts_kvmd(self):
        r = self.call(op="save", text="kvmd:\n    hid:\n        jiggler:\n            active: true\n")
        self.assertEqual(r["restarted"], ["kvmd"])
        self.assertFalse(r["rebootRequired"])

    def test_service_whitelist(self):
        self.assertFalse(self.call(op="service", unit="sshd", enabled=False)["ok"])
        self.assertTrue(self.call(op="service", unit="kvmd-vnc", enabled=True)["ok"])


if __name__ == "__main__":
    unittest.main()
