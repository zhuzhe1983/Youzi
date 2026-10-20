"""Hosted packaging must use the final versioned payload, never stale staging."""

import base64
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


def fixture(tmp_path, archived_version, *, version="0.14.6", runtime_version=None):
    app = tmp_path / "apps/rapid-mac/build/Rapid-MLX Desktop.app/Contents"
    runtime = app / "Resources/rapid-mlx"
    runtime.mkdir(parents=True)
    (app / "Info.plist").write_bytes(
        plistlib.dumps(
            {"CFBundleShortVersionString": version, "CFBundleVersion": "176"}
        )
    )
    (runtime / "VERSION").write_text((runtime_version or version) + "\n")
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
    out = fixture(tmp_path, "0.14.6\n")
    result = module.build_manifest(tmp_path, out)
    assert result["sidecar_version"] == "0.14.6"
    assert result["tag_name"] == "youzi-v0.14.6"
    assert result["dmg_sha256"] == module.sha256(out / "Youzi-macos-arm64.dmg")
    assert result["dmg_url"].startswith("https://github.com/zhuzhe1983/Youzi/releases/")
    assert result["sidecar_size"] == (out / "rapid-mlx-sidecar.tar.gz").stat().st_size


@pytest.mark.parametrize("version", [None, "0.13.0"])
def test_reject_missing_or_stale_archive_version(tmp_path, version):
    out = fixture(tmp_path, version)
    with pytest.raises((KeyError, ValueError)):
        module.build_manifest(tmp_path, out)


def test_reject_app_runtime_version_mismatch(tmp_path):
    out = fixture(tmp_path, "0.14.5\n", runtime_version="0.14.5")
    with pytest.raises(ValueError, match="App and bundled runtime versions differ"):
        module.build_manifest(tmp_path, out)


def test_manifest_uses_notes_for_the_built_version(tmp_path):
    out = fixture(tmp_path, "0.14.6\n")
    notes_dir = tmp_path / "docs/release-notes"
    notes_dir.mkdir(parents=True)
    notes_dir.joinpath("youzi-v0.14.5.md").write_text("Stale release summary")
    current_notes = "# Youzi 0.14.6\n\n保留中断回复，修复内存释放。\n"
    notes_dir.joinpath("youzi-v0.14.6.md").write_text(current_notes, encoding="utf-8")

    result = module.build_manifest(tmp_path, out)

    assert result["notes"] == current_notes.strip()
    assert "Stale release summary" not in result["notes"]


@pytest.mark.parametrize("version", ["0.14.3", "0.14.7"])
def test_missing_notes_use_current_version_without_old_feature_claims(
    tmp_path, version
):
    out = fixture(tmp_path, version + "\n", version=version)
    notes_dir = tmp_path / "docs/release-notes"
    notes_dir.mkdir(parents=True)
    notes_dir.joinpath("youzi-v0.14.5.md").write_text("Stale release summary")

    result = module.build_manifest(tmp_path, out)

    assert result["notes"].startswith(f"Youzi {version}.")
    assert f"/tag/youzi-v{version}" in result["notes"]
    assert "Apple Silicon only" in result["notes"]
    assert "Ad-hoc signed, not notarized" in result["notes"]
    assert "Stale release summary" not in result["notes"]
    assert "0.14.5" not in result["notes"]


def test_empty_versioned_notes_are_rejected(tmp_path):
    out = fixture(tmp_path, "0.14.6\n")
    notes_dir = tmp_path / "docs/release-notes"
    notes_dir.mkdir(parents=True)
    notes_dir.joinpath("youzi-v0.14.6.md").write_text("\n ")

    with pytest.raises(ValueError, match="Release notes are empty"):
        module.build_manifest(tmp_path, out)


def signed_fixture(tmp_path, *, version="0.14.6", build="176"):
    out = fixture(tmp_path, "0.14.6\n")
    info_path = tmp_path / "apps/rapid-mac/build/Rapid-MLX Desktop.app/Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["SURequireSignedFeed"] = True
    info_path.write_bytes(plistlib.dumps(info))
    archive = out / "Youzi-macos-arm64.zip"
    archive.write_bytes(b"fixture update archive")
    signature = base64.b64encode(b"x" * 64).decode()
    # Deliberately not cryptographic: the manifest checks required structure;
    # test_youzi_update_appcast exercises official signature verification.
    xml = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
    <sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>{version}</sparkle:shortVersionString>
    <enclosure url="https://github.com/zhuzhe1983/Youzi/releases/download/youzi-v{version}/Youzi-macos-arm64.zip"
    length="{archive.stat().st_size}" sparkle:edSignature="{signature}" />
    </item></channel></rss>'''.encode()
    (out / "appcast.xml").write_bytes(xml + (
        f"<!-- sparkle-signatures:\nedSignature: {signature}\nlength: {len(xml)}\n-->\n"
    ).encode())
    return out


def test_signed_release_requires_appcast_and_zip(tmp_path):
    out = signed_fixture(tmp_path)
    module.build_manifest(tmp_path, out)
    (out / "appcast.xml").unlink()
    with pytest.raises(ValueError, match="run youzi-update-appcast.py first"):
        module.build_manifest(tmp_path, out)


def test_signed_release_rejects_missing_zip(tmp_path):
    out = signed_fixture(tmp_path)
    (out / "Youzi-macos-arm64.zip").unlink()
    with pytest.raises(ValueError, match="final ZIP"):
        module.build_manifest(tmp_path, out)


@pytest.mark.parametrize(("version", "build"), [("0.14.5", "176"), ("0.14.6", "175")])
def test_signed_release_rejects_stale_appcast(tmp_path, version, build):
    out = signed_fixture(tmp_path, version=version, build=build)
    with pytest.raises(ValueError, match="does not match|exact versioned"):
        module.build_manifest(tmp_path, out)


def test_signed_release_rejects_unsigned_feed(tmp_path):
    out = signed_fixture(tmp_path)
    feed = out / "appcast.xml"
    feed.write_bytes(feed.read_bytes().split(b"<!-- sparkle-signatures:")[0])
    with pytest.raises(ValueError, match="no signed-feed trailer"):
        module.build_manifest(tmp_path, out)
