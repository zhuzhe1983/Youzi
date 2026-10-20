"""Release seed files remain private and interoperable with Sparkle Ed25519."""

import base64
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(sys.platform != "darwin", reason="macOS CryptoKit tool")
TOOL = Path(__file__).resolve().parents[1] / "scripts/youzi-update-key.swift"


def run(command, key):
    return subprocess.run(
        ["swift", str(TOOL), command, "--private-key-file", str(key)],
        capture_output=True,
        text=True,
        check=False,
    )


def test_generated_seed_is_private_stable_and_never_overwritten(tmp_path):
    tmp_path.chmod(0o700)
    key = tmp_path / "release.seed"
    result = run("generate", key)
    assert result.returncode == 0, result.stderr
    original = key.read_bytes()
    assert stat.S_IMODE(key.stat().st_mode) == 0o600
    assert len(base64.b64decode(original)) == 32
    public = result.stdout.strip()
    assert len(base64.b64decode(public)) == 32
    assert base64.b64decode(original) != base64.b64decode(public)
    assert run("public-key", key).stdout.strip() == public
    refused = run("generate", key)
    assert refused.returncode != 0
    assert key.read_bytes() == original
    assert original.strip().decode() not in refused.stdout + refused.stderr


def test_public_key_matches_rfc8032_seed(tmp_path):
    # Public RFC 8032 test vector, never used for signing production updates.
    seed = bytes.fromhex(
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    )
    expected = bytes.fromhex(
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    )
    key = tmp_path / "fixture.seed"
    key.write_bytes(base64.b64encode(seed))
    key.chmod(0o600)
    result = run("public-key", key)
    assert result.returncode == 0, result.stderr
    assert base64.b64decode(result.stdout) == expected


def test_refuses_publicly_readable_symlink_and_malformed_seed(tmp_path):
    key = tmp_path / "fixture.seed"
    key.write_bytes(base64.b64encode(os.urandom(32)))
    key.chmod(0o644)
    assert run("public-key", key).returncode != 0
    key.chmod(0o600)
    link = tmp_path / "linked.seed"
    link.symlink_to(key)
    assert run("public-key", link).returncode != 0
    key.write_text("not a key")
    assert run("public-key", key).returncode != 0


def test_refuses_shared_parent_before_creating_secret(tmp_path):
    tmp_path.chmod(0o755)
    key = tmp_path / "release.seed"
    assert run("generate", key).returncode != 0
    assert not key.exists()
