#!/usr/bin/env python3
"""Emit a stable-channel manifest from the final, versioned app payload."""

import hashlib
import importlib.util
import json
import plistlib
import sys
import tarfile
from datetime import datetime, timezone
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def release_notes(root: Path, version: str) -> str:
    """Use only this version's Youzi notes; never reuse an older summary."""
    notes = root / "docs/release-notes" / f"youzi-v{version}.md"
    if notes.is_file():
        content = notes.read_text(encoding="utf-8").strip()
        if not content:
            raise ValueError(f"Release notes are empty: {notes}")
        return content
    return (
        f"Youzi {version}. Release notes: "
        f"https://github.com/zhuzhe1983/Youzi/releases/tag/youzi-v{version}. "
        "Apple Silicon only. Ad-hoc signed, not notarized."
    )


def build_manifest(root: Path, out: Path) -> dict:
    app = root / "apps/rapid-mac/build/Rapid-MLX Desktop.app/Contents"
    with (app / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = info["CFBundleShortVersionString"]
    if info.get("SURequireSignedFeed") is True:
        # Fail closed when an updater-enabled build omits the new channel.
        # Structural consistency only; the signing tool must already have
        # cryptographically verified both this feed and the exact ZIP.
        feed = out / "appcast.xml"
        archive = out / "Youzi-macos-arm64.zip"
        if not feed.is_file() or not archive.is_file():
            raise ValueError("Signed-update build requires appcast.xml and the final ZIP; run youzi-update-appcast.py first")
        spec = importlib.util.spec_from_file_location(
            "youzi_update_appcast", Path(__file__).with_name("youzi-update-appcast.py")
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.validate_feed(feed, archive, info)
    engine_version = (app / "Resources/rapid-mlx/VERSION").read_text().strip()
    if engine_version != version:
        raise ValueError("App and bundled runtime versions differ")
    sidecar = out / "rapid-mlx-sidecar.tar.gz"
    # build.sh stamps VERSION in the final app, not its intermediate stage.
    # The updater tarball must contain that same stamp or runtime installation
    # cannot validate it, even if the outer manifest advertises a version.
    with tarfile.open(sidecar, "r:gz") as archive:
        member = archive.getmember("rapid-mlx/VERSION")
        if not member.isfile() or member.size > 128:
            raise ValueError("Invalid sidecar VERSION member")
        stream = archive.extractfile(member)
        assert stream is not None
        with stream:
            archived_version = stream.read().decode().strip()
    if archived_version != engine_version:
        raise ValueError("Sidecar archive and bundled runtime versions differ")
    tag = "youzi-v" + version
    release = "https://github.com/zhuzhe1983/Youzi/releases"
    dmg = out / "Youzi-macos-arm64.dmg"
    return {
        "schema_version": 1,
        "version": version,
        "tag_name": tag,
        "html_url": release + "/tag/" + tag,
        "published_at": datetime.now(timezone.utc).isoformat(),
        "notes": release_notes(root, version),
        "dmg_url": release + "/download/" + tag + "/" + dmg.name,
        "dmg_sha256": sha256(dmg),
        "dmg_size": dmg.stat().st_size,
        "sidecar_url": release + "/download/" + tag + "/" + sidecar.name,
        "sidecar_sha256": sha256(sidecar),
        "sidecar_size": sidecar.stat().st_size,
        "sidecar_version": engine_version,
    }


if __name__ == "__main__":
    output = Path(sys.argv[1])
    manifest = build_manifest(Path(__file__).resolve().parents[1], output)
    (output / "latest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    )
