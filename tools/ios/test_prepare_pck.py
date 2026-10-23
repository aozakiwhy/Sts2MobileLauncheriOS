#!/usr/bin/env python3
"""Synthetic PCK tests; no commercial data or external engine required."""
import hashlib
from pathlib import Path
import struct
import tempfile
import unittest

from prepare_pck import disable_autoload, prepare, read_index, read_metadata


def project(properties):
    out = bytearray(b"ECFG" + struct.pack("<I", len(properties)))
    for key, value in properties:
        key = key.encode()
        out += struct.pack("<I", len(key)) + key
        out += struct.pack("<I", len(value)) + value
    return bytes(out)


def make_pck(path, autoload="autoload/SentryBootstrap"):
    contents = {
        ".godot/extension_list.cfg": b"res://addons/fmod/fmod.gdextension\nres://addons/sentry/sentry.gdextension\nres://addons/spine/spine_godot_extension.gdextension\n",
        "project.binary": project([(autoload, b"opaque-variant"), ("label", b"autoload/SentryBootstrap")]),
        "addons/sentry/sentry.gdextension": b"synthetic native descriptor",
        "assets/fixture.bin": b"untouched data" * 43,
        "src/Fixture.cs": b"\n",
    }
    data = bytearray(b"\0" * 112)
    entries = []
    for name, value in contents.items():
        offset = len(data)
        data += value
        data += b"\0" * ((-len(data)) % 16)
        encoded = name.encode()
        encoded += b"\0" * ((-len(encoded)) % 4)
        entries.append(struct.pack("<I", len(encoded)) + encoded
                       + struct.pack("<QQ", offset - 112, len(value))
                       + hashlib.md5(value).digest() + struct.pack("<I", 0))
    directory = len(data)
    data[:40] = struct.pack("<6I2Q", 0x43504447, 3, 4, 5, 1, 2, 112, directory)
    data += struct.pack("<I", len(entries)) + b"".join(entries)
    path.write_bytes(data)


class PreparePckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "original.pck"
        self.output = self.root / "candidate.pck"

    def tearDown(self):
        self.temp.cleanup()

    def test_known_autoload_variants_preserve_source_and_other_resources(self):
        for key in ("autoload/SentryInit", "autoload/SentryBootstrap"):
            with self.subTest(key=key):
                self.output.unlink(missing_ok=True)
                make_pck(self.source, key)
                original = self.source.read_bytes()
                flags, base, _, before = read_index(self.source)
                report = prepare(self.source, self.output)
                new_flags, new_base, _, after = read_index(self.output)
                indexed = {e.path: e for e in after}
                self.assertEqual(self.source.read_bytes(), original)
                self.assertEqual(report["disabled_autoloads"], [key])
                self.assertEqual(report["cs_entries_preserved"], 1)
                self.assertFalse(report["runtime_verified"])
                self.assertNotIn("addons/sentry/sentry.gdextension", indexed)
                with self.source.open("rb") as src, self.output.open("rb") as dst:
                    for entry in before:
                        if entry.path in ("assets/fixture.bin", "src/Fixture.cs"):
                            self.assertEqual(entry.stored_offset, indexed[entry.path].stored_offset)
                            self.assertEqual(read_metadata(src, entry, flags, base),
                                             read_metadata(dst, indexed[entry.path], new_flags, new_base))
                    text = read_metadata(dst, indexed["project.binary"], new_flags, new_base)
                    self.assertIn(key.replace("autoload", "xutoload", 1).encode(), text)
                    # Same text in a property value is unrelated and must remain unchanged.
                    self.assertIn(b"autoload/SentryBootstrap", text)
                    extensions = read_metadata(dst, indexed[".godot/extension_list.cfg"], new_flags, new_base)
                    self.assertNotIn(b"sentry.gdextension", extensions)
                    self.assertIn(b"fmod.gdextension", extensions)
                    self.assertIn(b"spine_godot_extension.gdextension", extensions)

    def test_unknown_autoload_refuses_without_output(self):
        make_pck(self.source, "autoload/UnknownBootstrap")
        with self.assertRaises(ValueError):
            prepare(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_encrypted_pack_refused(self):
        make_pck(self.source)
        with self.source.open("r+b") as f:
            f.seek(20)
            f.write(struct.pack("<I", 3))
        with self.assertRaises(ValueError):
            prepare(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_corrupt_metadata_refused(self):
        make_pck(self.source)
        _, base, _, entries = read_index(self.source)
        e = next(e for e in entries if e.path == "project.binary")
        with self.source.open("r+b") as f:
            f.seek(base + e.stored_offset)
            f.write(b"FAIL")
        with self.assertRaises(ValueError):
            prepare(self.source, self.output)
        self.assertFalse(self.output.exists())

    def test_source_and_existing_destination_cannot_be_overwritten(self):
        make_pck(self.source)
        self.output.write_bytes(b"keep")
        for destination in (self.source, self.output):
            with self.assertRaises(ValueError):
                prepare(self.source, destination)
        self.assertEqual(self.output.read_bytes(), b"keep")

    def test_truncated_project_refused(self):
        for data in (b"ECFG", b"ECFG\x01\x00\x00\x00", project([("autoload/SentryInit", b"x")])[:-1]):
            with self.assertRaises(ValueError):
                disable_autoload(data)


if __name__ == "__main__":
    unittest.main()
