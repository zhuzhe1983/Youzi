#!/usr/bin/env python3
"""Emit the stable-channel manifest shipped only as a GitHub Release asset."""
import hashlib
import json
import plistlib
import sys
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1])
with (root / "apps/rapid-mac/Resources/Info.plist").open("rb") as f:
    version = plistlib.load(f)["CFBundleShortVersionString"]
tag = "youzi-v" + version
release = "https://github.com/zhuzhe1983/Youzi/releases"
sidecar = out / "rapid-mlx-sidecar.tar.gz"
dmg = out / "Youzi-macos-arm64.dmg"
with (root / "apps/rapid-mac/build/sidecar-stage/rapid-mlx/VERSION").open() as f:
    engine_version = f.read().strip()
manifest = {
    "schema_version": 1, "version": version, "tag_name": tag,
    "html_url": release + "/tag/" + tag,
    "published_at": datetime.now(timezone.utc).isoformat(),
    "notes": "Youzi: TTS voice validation, multimodal video service, square media gallery. Apple Silicon only. Ad-hoc signed, not notarized.",
    "dmg_url": release + "/download/" + tag + "/" + dmg.name,
    "dmg_sha256": hashlib.file_digest(dmg.open("rb"), "sha256").hexdigest(),
    "dmg_size": dmg.stat().st_size,
    "sidecar_url": release + "/download/" + tag + "/" + sidecar.name,
    "sidecar_sha256": hashlib.file_digest(sidecar.open("rb"), "sha256").hexdigest(),
    "sidecar_size": sidecar.stat().st_size, "sidecar_version": engine_version,
}
(out / "latest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
