#!/usr/bin/env python3
"""Sign the exact Youzi release ZIP and emit a verified Sparkle appcast.

Requires macOS, the official Sparkle tools, and an explicit external seed file.
There is deliberately no Keychain or unsigned-feed fallback.
"""

import argparse
import base64
import binascii
import hashlib
import html
import os
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
RELEASES = "https://github.com/zhuzhe1983/Youzi/releases"
FEED_URL = RELEASES + "/latest/download/appcast.xml"
ARCHIVE_NAME = "Youzi-macos-arm64.zip"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def digest(stream):
    result = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        result.update(chunk)
    return result.hexdigest()


def sha256(path):
    with path.open("rb") as stream:
        return digest(stream)


def run(command, label):
    # Tools can include key material in diagnostics on malformed input. Never
    # relay their output or a CalledProcessError (which includes arguments).
    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except OSError:
        raise ValueError(f"{label} could not start") from None
    if result.returncode:
        raise ValueError(f"{label} failed (exit {result.returncode})") from None
    return result.stdout.strip()


def validate_key_file(key_file, root):
    if key_file.is_symlink() or not key_file.is_file():
        raise ValueError("The private key must be a regular, non-symlink file")
    key_file = key_file.resolve()
    if key_file.is_relative_to(root.resolve()):
        raise ValueError("The private key must be stored outside the repository")
    metadata = key_file.stat()
    if stat.S_IMODE(metadata.st_mode) != 0o600 or metadata.st_uid != os.getuid():
        raise ValueError("The private key must be owned by this user with mode 0600")
    if metadata.st_size > 128:
        raise ValueError("The private key must contain a base64-encoded 32-byte seed")
    try:
        seed = base64.b64decode(key_file.read_bytes().strip(), validate=True)
    except (ValueError, binascii.Error):
        raise ValueError("The private key must contain a base64-encoded 32-byte seed") from None
    if len(seed) != 32:
        raise ValueError("The private key must contain a base64-encoded 32-byte seed")
    return key_file


def public_key(key_file, root):
    helper = root / "scripts/youzi-update-key.swift"
    if not helper.is_file():
        raise ValueError("Missing scripts/youzi-update-key.swift")
    return run(
        ["swift", str(helper), "public-key", "--private-key-file", str(key_file)],
        "Public-key derivation",
    )


def app_metadata(app):
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise ValueError("--app must be a built .app directory, not a symlink")
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException):
        raise ValueError("App Info.plist is missing or invalid") from None
    if info.get("CFBundleIdentifier") != "com.rapidmlx.rapid":
        raise ValueError("App bundle identifier is not Youzi")
    if info.get("CFBundlePackageType") != "APPL":
        raise ValueError("App bundle package type must be APPL")
    version = info.get("CFBundleShortVersionString", "")
    build = info.get("CFBundleVersion", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Youzi release version must be X.Y.Z")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9]\d*", build):
        raise ValueError("Youzi CFBundleVersion must be a positive integer string")
    executable = info.get("CFBundleExecutable", "")
    if not isinstance(executable, str) or not re.fullmatch(r"[^/\\]+", executable):
        raise ValueError("Invalid app executable name")
    binary = app / "Contents/MacOS" / executable
    if not binary.is_file() or not binary.stat().st_mode & 0o111:
        raise ValueError("App executable is missing or not executable")
    if not (app / "Contents/Frameworks/Sparkle.framework").is_dir():
        raise ValueError("App does not contain Sparkle.framework")
    try:
        runtime_version = (app / "Contents/Resources/rapid-mlx/VERSION").read_text().strip()
    except OSError:
        raise ValueError("App bundled runtime VERSION is missing") from None
    if runtime_version != version:
        raise ValueError("App and bundled runtime versions differ")
    if info.get("SUFeedURL") != FEED_URL:
        raise ValueError("App does not use the canonical Youzi appcast URL")
    for option in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
        if info.get(option) is not True:
            raise ValueError(f"App must enable {option}")
    try:
        if len(base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)) != 32:
            raise ValueError()
    except (ValueError, TypeError, binascii.Error):
        raise ValueError("App SUPublicEDKey must be a base64-encoded 32-byte public key") from None
    return info


def app_manifest(app):
    """Read every entry without following directory symlinks."""
    manifest = {}

    def visit(path):
        relative = path.relative_to(app).as_posix()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISLNK(metadata.st_mode):
            try:
                resolved = path.resolve(strict=True)
            except (OSError, RuntimeError):
                raise ValueError(f"Broken or cyclic app symlink: {relative}") from None
            if not resolved.is_relative_to(app.resolve()):
                raise ValueError(f"App symlink escapes the bundle: {relative}")
            manifest[relative] = ("link", mode, os.readlink(path))
        elif stat.S_ISREG(metadata.st_mode):
            manifest[relative] = ("file", mode, sha256(path))
        elif stat.S_ISDIR(metadata.st_mode):
            manifest[relative] = ("dir", mode, None)
            for child in sorted(path.iterdir()):
                visit(child)
        else:
            raise ValueError(f"Unsupported app entry: {relative}")

    visit(app)
    return manifest


def verify_archive(app, archive):
    """Compare ZIP content, permissions, and links without extracting it.

    ditto's __MACOSX AppleDouble records are permitted only for known app
    entries. They cannot introduce another application or a second payload.
    """
    manifest = app_manifest(app)
    seen = set()
    entries = set()
    try:
        with zipfile.ZipFile(archive) as zipped:
            for member in zipped.infolist():
                name = member.filename.rstrip("/")
                parts = PurePosixPath(name).parts
                if (
                    not name or name.startswith("/") or "\\" in name
                    or any(part in ("", ".", "..") for part in name.split("/"))
                    or name in entries
                ):
                    raise ValueError("Unsafe or duplicate ZIP entry")
                entries.add(name)
                if parts[0] == "__MACOSX":
                    if member.is_dir():
                        # ditto may include the root metadata directory.
                        target = "/".join(parts[2:]) or "."
                        if len(parts) > 1 and (
                            parts[1] != app.name or target not in manifest
                        ):
                            raise ValueError("Unexpected ZIP metadata directory")
                        continue
                    if len(parts) == 2 and parts[1] == "._" + app.name:
                        target = "."
                    elif len(parts) >= 3 and parts[1] == app.name and parts[-1].startswith("._"):
                        target = "/".join((*parts[2:-1], parts[-1][2:]))
                    else:
                        raise ValueError("Unexpected ZIP metadata entry")
                    if target not in manifest:
                        raise ValueError("ZIP metadata refers to an unknown app entry")
                    with zipped.open(member) as stream:
                        if stream.read(4) != b"\x00\x05\x16\x07":
                            raise ValueError("Invalid AppleDouble ZIP metadata")
                        digest(stream)  # Force CRC validation, including metadata.
                    continue
                if parts[0] != app.name:
                    raise ValueError("ZIP must contain only the specified app")
                relative = "/".join(parts[1:]) or "."
                expected = manifest.get(relative)
                if expected is None:
                    raise ValueError(f"Unexpected ZIP app entry: {relative}")
                mode = member.external_attr >> 16
                if member.create_system != 3:
                    raise ValueError("ZIP must preserve Unix permissions and symlinks (use ditto)")
                kind = (
                    "link" if stat.S_ISLNK(mode) else
                    "dir" if stat.S_ISDIR(mode) else
                    "file" if stat.S_ISREG(mode) else "unsupported"
                )
                content = None
                if kind == "link":
                    if member.file_size > 4096:
                        raise ValueError("Invalid ZIP symlink")
                    content = zipped.read(member).decode("utf-8")
                elif kind == "file":
                    with zipped.open(member) as stream:
                        content = digest(stream)
                if (kind, stat.S_IMODE(mode), content) != expected:
                    raise ValueError(f"ZIP differs from the built app: {relative}")
                seen.add(relative)
    except (zipfile.BadZipFile, EOFError, UnicodeError) as error:
        raise ValueError("ZIP is corrupt or has invalid contents") from error
    # ZIP directory records are optional; file/link records are not.
    missing = {name for name, item in manifest.items() if item[0] != "dir"} - seen
    if missing:
        raise ValueError(f"ZIP is missing app entries: {sorted(missing)[0]}")


def release_notes(root, version):
    relative = f"docs/release-notes/youzi-v{version}.md"
    tracked = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--error-unmatch", "--", relative],
        capture_output=True, check=False,
    )
    notes = root / relative
    if tracked.returncode == 0:
        content = notes.read_text(encoding="utf-8").strip()
        if not content:
            raise ValueError(f"Release notes are empty: {relative}")
        return content
    return f"Youzi {version}. Release notes: {RELEASES}/tag/youzi-v{version}."


def validate_feed(feed, archive, info):
    # Structural guard only: build_appcast also cryptographically verifies this
    # trailer with sign_update. The manifest builder can reuse this guard
    # without reading a private signing key.
    data = feed.read_bytes()
    trailer = re.search(rb"<!-- sparkle-signatures:\n(.*?)-->\s*$", data, re.DOTALL)
    if trailer is None:
        raise ValueError("Appcast has no signed-feed trailer")
    signatures = re.findall(rb"(?m)^edSignature: ([A-Za-z0-9+/=]+)$", trailer[1])
    lengths = re.findall(rb"(?m)^length: ([0-9]+)$", trailer[1])
    if (
        len(signatures) != 1 or len(lengths) != 1
        or int(lengths[0]) != trailer.start()
    ):
        raise ValueError("Appcast signed-feed trailer is invalid")
    try:
        if len(base64.b64decode(signatures[0], validate=True)) != 64:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise ValueError("Appcast feed signature has invalid encoding") from None
    try:
        tree = ET.ElementTree(ET.fromstring(data))
    except (OSError, ET.ParseError):
        raise ValueError("Generated appcast is missing or invalid") from None
    items = tree.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Appcast must contain exactly one release")
    item = items[0]
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1 or item.find(SPARKLE + "deltas") is not None:
        raise ValueError("Appcast must contain exactly one full update archive")
    enclosure = enclosures[0]
    version = info["CFBundleShortVersionString"]
    expected_url = f"{RELEASES}/download/youzi-v{version}/{ARCHIVE_NAME}"
    if enclosure.get("url") != expected_url:
        raise ValueError("Appcast download URL is not the exact versioned Youzi archive")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Appcast archive size does not match")
    for field, expected in (
        ("version", info["CFBundleVersion"]),
        ("shortVersionString", version),
    ):
        actual = item.findtext(SPARKLE + field) or enclosure.get(SPARKLE + field)
        if actual != expected:
            raise ValueError(f"Appcast {field} does not match the built app")
    if item.find(SPARKLE + "releaseNotesLink") is not None:
        raise ValueError("Appcast release notes must be embedded")
    signature = enclosure.get(SPARKLE + "edSignature", "")
    try:
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise ValueError("Appcast has no valid archive signature") from None
    return signature


def build_appcast(app, archive, output_dir, key_file, sparkle_bin, *, root=ROOT):
    app, archive = app.absolute(), archive.absolute()
    info = app_metadata(app)
    key_file = validate_key_file(key_file, root)
    if key_file.is_relative_to(app.resolve()) or key_file.is_relative_to(output_dir.resolve()):
        raise ValueError("The private key must be outside the app and release output")
    if public_key(key_file, root) != info["SUPublicEDKey"]:
        raise ValueError("Private key does not match the app SUPublicEDKey")
    if archive.is_symlink() or not archive.is_file() or archive.name != ARCHIVE_NAME:
        raise ValueError(f"--archive must be the final regular file named {ARCHIVE_NAME}")
    tools = {name: sparkle_bin / name for name in ("generate_appcast", "sign_update")}
    if any(not path.is_file() or not os.access(path, os.X_OK) for path in tools.values()):
        raise ValueError("--sparkle-bin must contain executable generate_appcast and sign_update")
    # generate_appcast caches extracted apps. Always check the supplied app,
    # including on retries, instead of relying on its first-extraction checks.
    run(["codesign", "--verify", "--deep", "--strict", str(app)], "App code-signature verification")
    verify_archive(app, archive)
    archive_hash = sha256(archive)
    output_dir.mkdir(parents=True, exist_ok=True)
    # Never let a stale appcast, model ZIP, or older app enter Sparkle discovery.
    with tempfile.TemporaryDirectory(prefix=".youzi-appcast-", dir=output_dir) as directory:
        staging = Path(directory).resolve()
        staged_archive = staging / ARCHIVE_NAME
        shutil.copyfile(archive, staged_archive)
        version = info["CFBundleShortVersionString"]
        # A fragment is embedded in the signed feed; no extra note asset or
        # unsigned remote content is required to view the release description.
        notes = html.escape(release_notes(root, version))
        (staging / f"{Path(ARCHIVE_NAME).stem}.html").write_text(
            f"<pre>{notes}</pre>\n", encoding="utf-8"
        )
        feed = staging / "appcast.xml"
        run([
            str(tools["generate_appcast"].resolve()),
            "--ed-key-file", str(key_file),
            "--download-url-prefix", f"{RELEASES}/download/youzi-v{version}/",
            "--embed-release-notes", "--maximum-deltas", "0",
            "--versions", info["CFBundleVersion"], "-o", str(feed), str(staging),
        ], "Sparkle appcast generation")
        signature = validate_feed(feed, staged_archive, info)
        verify = [str(tools["sign_update"].resolve()), "--verify", "--ed-key-file", str(key_file)]
        run([*verify, str(feed)], "Sparkle feed signature verification")
        run([*verify, str(staged_archive), signature], "Sparkle archive signature verification")
        if sha256(staged_archive) != archive_hash or sha256(archive) != archive_hash:
            raise ValueError("Release archive changed during appcast generation")
        if public_key(key_file, root) != info["SUPublicEDKey"]:
            raise ValueError("Private key changed during appcast generation")
        # Replace only after every check passes; the final ZIP is never modified.
        destination = output_dir / "appcast.xml"
        os.replace(feed, destination)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name, help_text in (
        ("app", "Final built Youzi .app directory"),
        ("archive", f"Exact release ZIP ({ARCHIVE_NAME}); never repack after signing"),
        ("output-dir", "Release output directory for the verified appcast.xml"),
        ("key-file", "External private Ed25519 seed file, owned by you, mode 0600"),
        ("sparkle-bin", "Official Sparkle bin directory (2.9 or later)"),
    ):
        parser.add_argument("--" + name, type=Path, required=True, help=help_text)
    args = parser.parse_args()
    try:
        output = build_appcast(
            args.app, args.archive, args.output_dir, args.key_file, args.sparkle_bin
        )
    except (ValueError, OSError) as error:
        print(f"error: {error}. Do not publish this release.", file=sys.stderr)
        return 1
    print(f"Verified signed appcast: {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
