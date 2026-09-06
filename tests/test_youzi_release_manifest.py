"""Hosted packaging must use the final versioned payload, never stale staging."""

import importlib.util
import io
import plistlib
import tarfile
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location(
    "youzi_release_manifest",
    Path(__file__).parents[1] / "scripts/youzi-release-manifest.py",
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def fixture(tmp_path, archived_version):
    app = tmp_path / "apps/rapid-mac/build/Rapid-MLX Desktop.app/Contents"
    runtime = app / "Resources/rapid-mlx"
    runtime.mkdir(parents=True)
    (app / "Info.plist").write_bytes(
        plistlib.dumps({"CFBundleShortVersionString": "0.14.3"})
    )
    (runtime / "VERSION").write_text("0.14.3\n")
    out = tmp_path / "dist"
    out.mkdir()
    (out / "Youzi-macos-arm64.dmg").write_bytes(b"installer")
    with tarfile.open(out / "rapid-mlx-sidecar.tar.gz", "w:gz") as archive:
        if archived_version is not None:
            data = archived_version.encode()
            info = tarfile.TarInfo("rapid-mlx/VERSION")
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return out


def test_manifest_needs_no_staging_tree(tmp_path):
    out = fixture(tmp_path, "0.14.3\n")
    result = module.build_manifest(tmp_path, out)
    assert result["sidecar_version"] == "0.14.3"
    assert result["tag_name"] == "youzi-v0.14.3"
    assert result["dmg_sha256"] == module.sha256(out / "Youzi-macos-arm64.dmg")
    assert result["dmg_url"].startswith("https://github.com/zhuzhe1983/Youzi/releases/")
    assert result["sidecar_size"] == (out / "rapid-mlx-sidecar.tar.gz").stat().st_size


@pytest.mark.parametrize("version", [None, "0.13.0"])
def test_reject_missing_or_stale_archive_version(tmp_path, version):
    out = fixture(tmp_path, version)
    with pytest.raises((KeyError, ValueError)):
        module.build_manifest(tmp_path, out)
