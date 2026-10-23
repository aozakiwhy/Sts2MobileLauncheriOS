#!/usr/bin/env python3
"""Prepare a private copy of an unencrypted Godot v3 PCK for iOS bring-up.

Disables only Sentry extension registration and the known Sentry autoload keys.
Does not supply an engine, native libraries, game assets, or compatibility proof.

PCK layout and the Sentry-isolation approach reference jhaizhou-ops/sts2-ios.
See UPSTREAM_LICENSE.txt. This parser also supports the newer Bootstrap key.
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import tempfile


@dataclasses.dataclass
class Entry:
    path_bytes: bytes
    stored_offset: int
    size: int
    md5: bytes
    flags: int

    @property
    def path(self):
        return self.path_bytes.rstrip(b"\0").decode("utf-8").removeprefix("res://")


def read_exact(f, count):
    value = f.read(count)
    if len(value) != count:
        raise ValueError("Truncated PCK")
    return value


def read_index(path):
    length = path.stat().st_size
    with path.open("rb") as f:
        header = read_exact(f, 104)
        magic, fmt, major, minor, patch, flags, base, directory = struct.unpack_from("<6I2Q", header)
        if magic != 0x43504447 or fmt != 3 or flags & ~2:
            raise ValueError("Only unencrypted Godot PCK format 3 with known flags is supported")
        if not 104 <= base <= directory < length:
            raise ValueError("Invalid PCK layout")
        f.seek(directory)
        count = struct.unpack("<I", read_exact(f, 4))[0]
        if not 0 < count <= 100_000:
            raise ValueError("Invalid PCK entry count")
        entries, seen = [], set()
        for _ in range(count):
            n = struct.unpack("<I", read_exact(f, 4))[0]
            if not 0 < n <= 65536:
                raise ValueError("Invalid path length")
            name = read_exact(f, n)
            off, size = struct.unpack("<QQ", read_exact(f, 16))
            entry = Entry(name, off, size, read_exact(f, 16), struct.unpack("<I", read_exact(f, 4))[0])
            text = entry.path
            parts = text.split("/")
            if (not text or PurePosixPath(text).is_absolute() or "\\" in text or ":" in text
                    or any(p in ("", ".", "..") for p in parts)
                    or any(ord(c) < 32 for c in text) or text in seen):
                raise ValueError("Unsafe or duplicate resource path")
            absolute = off + base if flags & 2 else off
            if entry.flags or absolute < 104 or absolute + size > directory:
                raise ValueError("Encrypted/unknown entry or invalid data bounds")
            seen.add(text)
            entries.append(entry)
        if f.tell() != length:
            raise ValueError("PCK directory must be the final section")
    return flags, base, directory, entries


def read_metadata(f, entry, flags, base):
    if entry.size > 1024 * 1024:
        raise ValueError("Metadata resource is unexpectedly large")
    f.seek(entry.stored_offset + base if flags & 2 else entry.stored_offset)
    data = read_exact(f, entry.size)
    if hashlib.md5(data).digest() != entry.md5:
        raise ValueError("Metadata MD5 does not match the PCK index")
    return data


def disable_autoload(data):
    """Parse ECFG property keys; never replace a matching string in a value."""
    if len(data) < 8 or data[:4] != b"ECFG":
        raise ValueError("Unknown project.binary format")
    output = bytearray(data)
    count = struct.unpack_from("<I", data, 4)[0]
    pos, changed = 8, []
    if count > 100_000:
        raise ValueError("Invalid project property count")
    for _ in range(count):
        if pos + 4 > len(data):
            raise ValueError("Truncated project property")
        n = struct.unpack_from("<I", data, pos)[0]
        pos += 4
        if pos + n + 4 > len(data):
            raise ValueError("Invalid project property key length")
        key = data[pos:pos+n]
        if key in (b"autoload/SentryInit", b"autoload/SentryBootstrap"):
            output[pos:pos+8] = b"xutoload"
            changed.append(key.decode())
        pos += n
        n = struct.unpack_from("<I", data, pos)[0]
        pos += 4 + n
        if pos > len(data):
            raise ValueError("Invalid project property value length")
    if pos != len(data) or not changed:
        raise ValueError("Unknown project layout or no supported Sentry autoload")
    return bytes(output), changed


def prepare(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve() or destination.exists():
        raise ValueError("Use a new output path; never replace the source or an existing file")
    flags, base, directory, entries = read_index(source)
    indexed = {e.path: e for e in entries}
    removed = "addons/sentry/sentry.gdextension"
    if removed not in indexed:
        raise ValueError("Sentry extension entry is absent; input may already be patched")
    with source.open("rb") as f:
        extensions = indexed[".godot/extension_list.cfg"]
        old = read_metadata(f, extensions, flags, base)
        lines = old.splitlines(keepends=True)
        new = b"".join(line for line in lines if line.strip() not in (
            b"res://addons/sentry/sentry.gdextension", b"addons/sentry/sentry.gdextension"))
        if new == old:
            raise ValueError("Sentry extension registration is absent")
        project = indexed["project.binary"]
        patched_project, autoloads = disable_autoload(read_metadata(f, project, flags, base))
    changes = [(extensions, new), (project, patched_project)]
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="pck-ios-", suffix=".part", dir=destination.parent)
    os.close(fd)
    try:
        shutil.copyfile(source, temporary)
        remaining = [e for e in entries if e.path != removed]
        with open(temporary, "r+b") as out:
            for entry, replacement in changes:
                if len(replacement) > entry.size:
                    raise ValueError("Metadata replacement cannot grow")
                out.seek(entry.stored_offset + base if flags & 2 else entry.stored_offset)
                out.write(replacement)
                entry.size = len(replacement)
                entry.md5 = hashlib.md5(replacement).digest()
            out.seek(directory)
            out.write(struct.pack("<I", len(remaining)))
            for entry in remaining:
                out.write(struct.pack("<I", len(entry.path_bytes)) + entry.path_bytes)
                out.write(struct.pack("<QQ", entry.stored_offset, entry.size))
                out.write(entry.md5 + struct.pack("<I", entry.flags))
            out.truncate()
        # Validate the published layout and edited metadata before committing it.
        new_flags, new_base, _, verified = read_index(Path(temporary))
        with open(temporary, "rb") as f:
            for e in verified:
                if e.path in ("project.binary", ".godot/extension_list.cfg"):
                    read_metadata(f, e, new_flags, new_base)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return {"input_entries": len(entries), "output_entries": len(remaining),
            "disabled_autoloads": autoloads, "removed_extension": removed,
            "cs_entries_preserved": sum(e.path.endswith(".cs") for e in remaining),
            "runtime_verified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    print(json.dumps(prepare(args.source, args.destination), indent=2))
