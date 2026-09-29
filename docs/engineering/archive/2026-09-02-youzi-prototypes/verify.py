#!/usr/bin/env python3
"""Verify the historical source archive without executing its contents."""

import hashlib
import json
from pathlib import Path, PurePosixPath


def main() -> None:
    archive = Path(__file__).resolve().parent
    manifest = json.loads((archive / "manifest.json").read_text(encoding="utf-8"))
    source = archive / "source"
    if source.is_symlink() or not source.is_dir():
        raise SystemExit("Source root must be a regular directory")

    actual = set()
    for entry in source.rglob("*"):
        if entry.is_symlink():
            raise SystemExit("Archive contains a symlink")
        if entry.is_file():
            actual.add(entry.relative_to(source).as_posix())
        elif not entry.is_dir():
            raise SystemExit("Archive contains an unsupported filesystem entry")

    expected = set()
    total_bytes = 0
    for record in manifest["files"]:
        relative = PurePosixPath(record["path"])
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.as_posix() != record["path"]
            or not relative.parts
            or "\\" in record["path"]
            or record["path"] in expected
        ):
            raise SystemExit("Manifest contains an unsafe or duplicate path")
        expected.add(record["path"])
        path = source.joinpath(*relative.parts)
        if not path.is_file():
            raise SystemExit(f"Missing archive file: {relative}")
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        if (
            len(data) != record["bytes"]
            or digest != record["archived_sha256"]
            or digest != record["original_sha256"]
            or record["preservation"] != "exact"
        ):
            raise SystemExit(f"Preservation mismatch: {relative}")
        total_bytes += len(data)

    if actual != expected:
        raise SystemExit("Archive file set differs from the manifest")
    if (
        len(expected) != manifest["file_count"]
        or total_bytes != manifest["total_bytes"]
    ):
        raise SystemExit("Manifest totals do not match")
    print(f"Verified {len(expected)} exact files, {total_bytes} bytes; no symlinks")


if __name__ == "__main__":
    main()
