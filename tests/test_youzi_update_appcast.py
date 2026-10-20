"""Release signatures must refer to the exact, complete Youzi app payload."""

import base64
import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location(
    "youzi_update_appcast", ROOT / "scripts/youzi-update-appcast.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

# RFC 8032 test vector, never a production signing key.
SEED = base64.b64encode(bytes.fromhex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
))
PUBLIC = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="


def write_zip(app, archive):
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
        def add(path):
            relative = path.relative_to(app.parent).as_posix()
            metadata = path.lstat()
            item = zipfile.ZipInfo(relative + ("/" if path.is_dir() and not path.is_symlink() else ""))
            item.create_system = 3
            item.external_attr = metadata.st_mode << 16
            if path.is_symlink():
                zipped.writestr(item, os.readlink(path).encode())
            elif path.is_dir():
                zipped.writestr(item, b"")
                for child in sorted(path.iterdir()):
                    add(child)
            else:
                zipped.writestr(item, path.read_bytes())
        add(app)


@pytest.fixture
def payload(tmp_path):
    app = tmp_path / "Rapid-MLX Desktop.app"
    contents = app / "Contents"
    (contents / "Resources/rapid-mlx").mkdir(parents=True)
    (contents / "Resources/rapid-mlx/VERSION").write_text("0.14.7\n")
    (contents / "Resources/message.txt").write_text("完整的应用资源\n")
    (contents / "MacOS").mkdir()
    binary = contents / "MacOS/Rapid"
    if sys.platform == "darwin":
        shutil.copyfile("/bin/echo", binary)
    else:
        binary.write_bytes(b"fixture executable")
    binary.chmod(0o755)
    framework = contents / "Frameworks/Sparkle.framework"
    (framework / "Versions/B").mkdir(parents=True)
    (framework / "Versions/B/Sparkle").write_bytes(b"fixture framework")
    (framework / "Versions/Current").symlink_to("B")
    (framework / "Sparkle").symlink_to("Versions/Current/Sparkle")
    info = {
        "CFBundleIdentifier": "com.rapidmlx.rapid",
        "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "Rapid",
        "CFBundleName": "Youzi",
        "CFBundleDisplayName": "Youzi",
        "CFBundleShortVersionString": "0.14.7",
        "CFBundleVersion": "177",
        "LSMinimumSystemVersion": "14.0",
        "SUPublicEDKey": PUBLIC,
        "SUFeedURL": module.FEED_URL,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    archive = tmp_path / module.ARCHIVE_NAME
    write_zip(app, archive)
    key = tmp_path / "private-seed"
    key.write_bytes(SEED + b"\n")
    key.chmod(0o600)
    return app, archive, key, info


def change_plist(app, key, value):
    path = app / "Contents/Info.plist"
    data = plistlib.loads(path.read_bytes())
    data[key] = value
    path.write_bytes(plistlib.dumps(data))


def test_archive_matches_full_app_including_symlinks_and_permissions(payload):
    app, archive, _, info = payload
    assert module.app_metadata(app) == info
    before = module.sha256(archive)
    module.verify_archive(app, archive)
    assert module.sha256(archive) == before


@pytest.mark.parametrize("mutation", ["resource", "version", "mode", "symlink", "missing"])
def test_reject_stale_or_altered_app_archive(payload, mutation):
    app, archive, _, _ = payload
    if mutation == "resource":
        (app / "Contents/Resources/message.txt").write_text("different bytes")
    elif mutation == "version":
        change_plist(app, "CFBundleVersion", "178")
    elif mutation == "mode":
        (app / "Contents/MacOS/Rapid").chmod(0o644)
    elif mutation == "symlink":
        link = app / "Contents/Frameworks/Sparkle.framework/Sparkle"
        link.unlink()
        link.symlink_to("Versions/B/Sparkle")
    else:
        (app / "Contents/Resources/extra.txt").write_text("not archived")
    with pytest.raises(ValueError, match="ZIP (differs|is missing)"):
        module.verify_archive(app, archive)


@pytest.mark.parametrize("name", [
    "Other.app/Contents/Info.plist",
    "model-weights.safetensors",
    "Rapid-MLX Desktop.app/../../outside",
    "__MACOSX/Other.app/._Info.plist",
])
def test_reject_extra_app_model_or_unsafe_zip_entry(payload, name):
    app, archive, _, _ = payload
    with zipfile.ZipFile(archive, "a") as zipped:
        zipped.writestr(name, b"extra")
    with pytest.raises(ValueError):
        module.verify_archive(app, archive)


def test_reject_corrupt_archive(payload):
    app, archive, _, _ = payload
    archive.write_bytes(archive.read_bytes()[:-40])
    with pytest.raises(ValueError, match="corrupt"):
        module.verify_archive(app, archive)


def test_reject_app_symlink_outside_bundle(payload):
    app, archive, key, _ = payload
    (app / "Contents/Resources/external").symlink_to(key)
    with pytest.raises(ValueError, match="escapes"):
        module.verify_archive(app, archive)


@pytest.mark.parametrize(("key", "value"), [
    ("CFBundleIdentifier", "other.app"),
    ("CFBundleVersion", "177-branch"),
    ("CFBundleShortVersionString", "0.14.7/other"),
    ("SURequireSignedFeed", False),
    ("SUVerifyUpdateBeforeExtraction", False),
    ("SUFeedURL", "https://example.com/appcast.xml"),
    ("SUPublicEDKey", "not a key"),
])
def test_reject_invalid_release_metadata(payload, key, value):
    app, _, _, _ = payload
    change_plist(app, key, value)
    with pytest.raises(ValueError):
        module.app_metadata(app)


def test_reject_stale_runtime_stamp(payload):
    app, _, _, _ = payload
    (app / "Contents/Resources/rapid-mlx/VERSION").write_text("0.14.6")
    with pytest.raises(ValueError, match="runtime versions differ"):
        module.app_metadata(app)


def test_key_mismatch_fails_before_official_tool_or_output_write(payload, tmp_path, monkeypatch):
    app, archive, key, _ = payload
    monkeypatch.setattr(module, "public_key", lambda *_: base64.b64encode(b"z" * 32).decode())
    output = tmp_path / "output"
    with pytest.raises(ValueError, match="does not match"):
        module.build_appcast(app, archive, output, key, tmp_path / "nonexistent")
    assert not output.exists()


def test_reject_private_key_inside_repo_or_with_loose_permissions(payload, tmp_path):
    _, _, key, _ = payload
    with pytest.raises(ValueError, match="outside"):
        module.validate_key_file(key, tmp_path)
    key.chmod(0o644)
    with pytest.raises(ValueError, match="0600"):
        module.validate_key_file(key, ROOT)


def write_fixture_feed(path, tree):
    ET.ElementTree(tree).write(path)
    data = path.read_bytes()
    signature = base64.b64encode(b"f" * 64)
    path.write_bytes(
        data + b"<!-- sparkle-signatures:\nedSignature: " + signature
        + b"\nlength: " + str(len(data)).encode() + b"\n-->\n"
    )


def fixture_feed(path, archive, info):
    root = ET.Element("rss")
    item = ET.SubElement(ET.SubElement(root, "channel"), "item")
    ET.SubElement(item, module.SPARKLE + "version").text = info["CFBundleVersion"]
    ET.SubElement(item, module.SPARKLE + "shortVersionString").text = info["CFBundleShortVersionString"]
    enclosure = ET.SubElement(item, "enclosure", {
        "url": f"{module.RELEASES}/download/youzi-v0.14.7/{module.ARCHIVE_NAME}",
        "length": str(archive.stat().st_size),
        module.SPARKLE + "edSignature": base64.b64encode(b"x" * 64).decode(),
    })
    write_fixture_feed(path, root)
    return root, item, enclosure


@pytest.mark.parametrize("mutation", ["url", "length", "version", "display_version", "extra_item"])
def test_reject_feed_for_other_release_or_payload(payload, tmp_path, mutation):
    _, archive, _, info = payload
    feed = tmp_path / "appcast.xml"
    tree, item, enclosure = fixture_feed(feed, archive, info)
    if mutation == "url":
        enclosure.set("url", module.FEED_URL.replace("appcast.xml", module.ARCHIVE_NAME))
    elif mutation == "length":
        enclosure.set("length", "1")
    elif mutation == "version":
        item.find(module.SPARKLE + "version").text = "176"
    elif mutation == "display_version":
        item.find(module.SPARKLE + "shortVersionString").text = "0.14.6"
    else:
        ET.SubElement(tree.find("channel"), "item")
    write_fixture_feed(feed, tree)
    with pytest.raises(ValueError):
        module.validate_feed(feed, archive, info)


def test_unsigned_feed_cannot_pass_manifest_guard(payload, tmp_path):
    _, archive, _, info = payload
    feed = tmp_path / "appcast.xml"
    tree, _, _ = fixture_feed(feed, archive, info)
    module.validate_feed(feed, archive, info)
    ET.ElementTree(tree).write(feed)
    with pytest.raises(ValueError, match="signed-feed trailer"):
        module.validate_feed(feed, archive, info)


def test_notes_use_only_matching_tracked_file(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    notes = tmp_path / "docs/release-notes"
    notes.mkdir(parents=True)
    (notes / "youzi-v0.14.6.md").write_text("Old notes")
    (notes / "youzi-v0.14.7.md").write_text("Untracked notes")
    assert "Untracked notes" not in module.release_notes(tmp_path, "0.14.7")
    subprocess.run(["git", "-C", str(tmp_path), "add", "docs"], check=True)
    assert module.release_notes(tmp_path, "0.14.7") == "Untracked notes"
    assert "/tag/youzi-v0.14.8" in module.release_notes(tmp_path, "0.14.8")
    (notes / "youzi-v0.14.7.md").write_text(" \n")
    with pytest.raises(ValueError, match="empty"):
        module.release_notes(tmp_path, "0.14.7")


def test_tool_diagnostics_never_disclose_key_material():
    with pytest.raises(ValueError, match=r"Signing failed \(exit 2\)") as error:
        module.run(
            [sys.executable, "-c", "import sys; print('PRIVATE-SEED'); sys.exit(2)"],
            "Signing",
        )
    assert "PRIVATE-SEED" not in str(error.value)


@pytest.mark.skipif(
    sys.platform != "darwin" or not os.environ.get("YOUZI_SPARKLE_BIN"),
    reason="Set YOUZI_SPARKLE_BIN to official Sparkle 2.9+ bin directory on macOS",
)
def test_official_tools_sign_exact_ditto_archive_and_reject_tampering(payload, tmp_path):
    app, archive, key, info = payload
    sparkle_bin = Path(os.environ["YOUZI_SPARKLE_BIN"])
    framework = app / "Contents/Frameworks/Sparkle.framework"
    shutil.rmtree(framework)
    shutil.copytree(
        sparkle_bin.parent / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework",
        framework,
        symlinks=True,
    )
    subprocess.run([
        "codesign", "--force", "--sign", "-", "--timestamp=none", str(app)
    ], check=True, capture_output=True)
    # Exercise macOS metadata, executable bits and framework symlinks using
    # the same archive command as the Youzi release packaging workflow.
    archive.unlink()
    subprocess.run([
        "ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive)
    ], check=True)
    before = module.sha256(archive)
    output = tmp_path / "release"
    output.mkdir()
    (output / "model.zip").write_bytes(b"unrelated stale model archive")
    (output / "appcast.xml").write_text("stale feed")
    feed = module.build_appcast(app, archive, output, key, sparkle_bin)
    signature = module.validate_feed(feed, archive, info)
    assert module.sha256(archive) == before
    assert (output / "model.zip").read_bytes() == b"unrelated stale model archive"
    assert list(output.glob(".youzi-appcast-*")) == []
    assert "youzi-v0.14.7/Youzi-macos-arm64.zip" in feed.read_text()
    assert "https://github.com/zhuzhe1983/Youzi/releases/tag/youzi-v0.14.7" in feed.read_text()
    verify = [str(sparkle_bin / "sign_update"), "--verify", "--ed-key-file", str(key)]
    assert subprocess.run([*verify, str(feed)], capture_output=True).returncode == 0
    feed.write_bytes(feed.read_bytes().replace(b"Youzi", b"Changed", 1))
    assert subprocess.run([*verify, str(feed)], capture_output=True).returncode != 0
    with archive.open("ab") as stream:
        stream.write(b"tampered")
    assert subprocess.run([*verify, str(archive), signature], capture_output=True).returncode != 0
