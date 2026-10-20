#!/usr/bin/env python3
"""Exercise Sparkle's real downloader, verifier, extractor, and installer locally.

Requires macOS, Xcode command-line tools, and the resolved Sparkle 2.9.5 source
checkout/artifact. Does not build or launch Youzi. Everything is disposable.
The official sparkle-cli sources are compiled unchanged against the artifact.
No replacement is implemented by this harness: only Sparkle replaces the app.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import xml.sax.saxutils


SCRIPT_DIR = Path(__file__).resolve().parent
FIXTURES = SCRIPT_DIR / "fixtures" / "youzi-update"


def run(command, *, env=None, timeout=60):
    result = subprocess.run(
        [str(part) for part in command], env=env, timeout=timeout,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {command[0]}\n{result.stdout}")
    return result.stdout.strip()


def write_plist(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(value))


def tree_hash(path):
    """Hash paths, bytes, permissions, and symlink targets, excluding timestamps."""
    digest = hashlib.sha256()
    for item in sorted(path.rglob("*")):
        digest.update(str(item.relative_to(path)).encode())
        digest.update(str(item.lstat().st_mode).encode())
        if item.is_symlink():
            digest.update(os.readlink(item).encode())
        elif item.is_file():
            digest.update(item.read_bytes())
    return digest.hexdigest()


def process_snapshot(marker):
    output = run(["/bin/ps", "-axo", "pid=,command="])
    found = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and marker in fields[1] and int(fields[0]) != os.getpid():
            found.append((int(fields[0]), fields[1]))
    return found


def cleanup_helpers(bundle_ids, marker):
    # Labels come from our unique fixture IDs, never a shared Sparkle service.
    for bundle_id in bundle_ids:
        for suffix in ("-sparkle-updater", "-sparkle-progress"):
            subprocess.run(
                ["/bin/launchctl", "remove", bundle_id + suffix],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
    owned = process_snapshot(marker)
    for pid, _ in owned:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while process_snapshot(marker) and time.monotonic() < deadline:
        time.sleep(0.1)
    remaining = process_snapshot(marker)
    if remaining:
        raise RuntimeError(f"Task-owned helpers did not exit: {remaining}")
    for bundle_id in bundle_ids:
        for suffix in ("-sparkle-updater", "-sparkle-progress"):
            job = subprocess.run(
                ["/bin/launchctl", "print", f"gui/{os.getuid()}/{bundle_id}{suffix}"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            if job.returncode == 0:
                raise RuntimeError(f"Task-owned launchd job still registered: {bundle_id}{suffix}")


def collect_helper_caches(root, bundle_ids):
    # launchd helpers do not inherit CFFIXED_USER_HOME. Preserve only their exact,
    # per-run cache domains as evidence after the processes have exited.
    collected = []
    for directory in ("Caches", "HTTPStorages"):
        for bundle_id in bundle_ids:
            cache = Path.home() / "Library" / directory / bundle_id
            if not cache.exists():
                continue
            if cache.is_symlink() or cache.stat().st_uid != os.getuid():
                raise RuntimeError(f"Refusing unexpected helper cache: {cache}")
            destination = root / "native-helper-caches" / directory / bundle_id
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(cache), str(destination))
            collected.append({"original": str(cache), "retained": str(destination)})
    return collected


def make_app(path, bundle_id, version, public_key, executable, preferences):
    path.mkdir(parents=True)
    write_plist(path / "Contents/Info.plist", {
        "CFBundleIdentifier": bundle_id, "CFBundleName": "Youzi Update Fixture",
        "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL",
        "CFBundleVersion": version, "CFBundleShortVersionString": version + ".0",
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "SUPublicEDKey": public_key, "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
        "SUEnableAutomaticChecks": False,
        # An absolute suite path keeps Sparkle defaults outside the user's home.
        "SUDefaultsDomain": str(preferences),
    })
    target = path / "Contents/MacOS/fixture"
    target.parent.mkdir()
    shutil.copy2(executable, target)
    (path / "Contents/Resources").mkdir()
    (path / "Contents/Resources/version.txt").write_text(version + "\n")
    run(["/usr/bin/codesign", "--force", "--sign", "-", path])
    run(["/usr/bin/codesign", "--verify", "--strict", path])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sparkle-root", type=Path,
                        default=SCRIPT_DIR.parent / ".build/artifacts/sparkle/Sparkle")
    parser.add_argument("--sparkle-source", type=Path,
                        default=SCRIPT_DIR.parent / ".build/checkouts/Sparkle")
    parser.add_argument("--output", type=Path, help="New output directory; logs/fixtures remain here.")
    parser.add_argument("--timeout", type=int, default=90, help="Per-case deadline in seconds.")
    args = parser.parse_args()
    if sys.platform != "darwin" or os.geteuid() == 0:
        parser.error("Run as a normal logged-in macOS user, never root.")
    if not 10 <= args.timeout <= 300:
        parser.error("--timeout must be between 10 and 300 seconds")
    source = args.sparkle_source.resolve()
    artifact = args.sparkle_root.resolve()
    framework = artifact / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != "2.9.5":
        parser.error("This acceptance harness requires Sparkle 2.9.5.")
    for name in ("main.m", "SPUCommandLineDriver.m", "SPUCommandLineUserDriver.m"):
        if not (source / "sparkle-cli" / name).is_file():
            parser.error(f"Missing official sparkle-cli source: {name}")
    if args.output:
        root = args.output.resolve()
        root.mkdir(parents=True, exist_ok=False)
    else:
        root = Path(tempfile.mkdtemp(prefix="youzi-update-smoke-")).resolve()
    root.chmod(0o700)
    marker = "youzi-update-smoke-" + uuid.uuid4().hex
    bundle_ids = []
    secret = root / "disposable-seed"
    server = None
    server_thread = None
    result = {
        "passed": False, "sparkle_version": "2.9.5", "run_directory": str(root),
        "macos_version": platform.mac_ver()[0], "architecture": platform.machine(),
        "python_version": platform.python_version(), "cases": [],
        "limitations": [
            "Disposable ad-hoc fixture, not the production Youzi bundle.",
            "App is not running; running-app termination/relaunch and update UI are not covered.",
            "Loopback HTTP, not production HTTPS/CDN or Developer ID/notarization.",
            "No elevated-permission installation is attempted.",
        ],
    }
    requests = []
    print(f"Artifacts: {root}", flush=True)
    # CFFIXED_USER_HOME is honored by Foundation; HOME is intentionally not
    # overwritten. SUDefaultsDomain additionally isolates host defaults.
    private_home = root / "home"
    for name in ("Library/Preferences", "Library/Caches", "tmp"):
        (private_home / name).mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, CFFIXED_USER_HOME=str(private_home),
               TMPDIR=str(private_home / "tmp"), CLANG_MODULE_CACHE_PATH=str(root / "modules"))

    def interrupted(signum, _frame):
        raise InterruptedError(f"Interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        result["clang_version"] = run(["xcrun", "clang", "--version"]).splitlines()[0]
        result["official_cli_source_sha256"] = {
            name: hashlib.sha256((source / "sparkle-cli" / name).read_bytes()).hexdigest()
            for name in ("main.m", "SPUCommandLineDriver.m", "SPUCommandLineUserDriver.m")
        }
        public_key = run(["xcrun", "swift", FIXTURES / "MakeTestKey.swift", secret],
                         env=env, timeout=120)
        if len(base64.b64decode(public_key, validate=True)) != 32:
            raise RuntimeError("Invalid disposable public key")
        executable = root / "fixture"
        run(["xcrun", "clang", FIXTURES / "TinyApp.c", "-o", executable], env=env)
        runner = root / "Runner.app"
        write_plist(runner / "Contents/Info.plist", {
            "CFBundleIdentifier": "ai.youzi." + marker + ".runner",
            "CFBundleName": "Youzi Sparkle Smoke", "CFBundleExecutable": "sparkle",
            "CFBundleVersion": "1", "CFBundlePackageType": "APPL",
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            "SUDefaultsDomain": str(root / "runner-preferences"),
            "LSUIElement": True,
        })
        framework_parent = runner / "Contents/Frameworks"
        framework_parent.mkdir()
        run(["/usr/bin/ditto", framework, framework_parent / "Sparkle.framework"])
        cli = runner / "Contents/MacOS/sparkle"
        cli.parent.mkdir()
        command = ["xcrun", "clang", "-fobjc-arc", "-fmodules",
                   "-DSPU_OBJC_DIRECT=__attribute__((objc_direct))",
                   "-DSPU_OBJC_DIRECT_MEMBERS=__attribute__((objc_direct_members))",
                   "-F", framework_parent, "-framework", "Sparkle", "-framework", "Cocoa",
                   "-Wl,-rpath,@executable_path/../Frameworks"]
        command += [source / "sparkle-cli" / name for name in (
            "main.m", "SPUCommandLineDriver.m", "SPUCommandLineUserDriver.m")]
        run(command + ["-o", cli], env=env, timeout=120)
        run(["/usr/bin/codesign", "--force", "--sign", "-", runner])
        feed_root = root / "server"
        feed_root.mkdir()
        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *a, **kw):
                super().__init__(*a, directory=str(feed_root), **kw)

            def log_message(self, message, *values):
                requests.append({"path": self.path, "message": message % values})

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        origin = f"http://127.0.0.1:{server.server_port}"
        signer = artifact / "bin/sign_update"
        for case in ("valid", "damaged-archive", "wrong-signature", "tampered-feed", "unsigned-feed"):
            case_root = root / case
            case_root.mkdir()
            bundle_id = "ai.youzi." + marker + "." + case
            bundle_ids.append(bundle_id)
            preferences = case_root / "preferences"
            installed = case_root / "installed/Fixture.app"
            candidate = case_root / "candidate/Fixture.app"
            make_app(installed, bundle_id, "1", public_key, executable, preferences)
            make_app(candidate, bundle_id, "2", public_key, executable, preferences)
            before_hash = tree_hash(installed)
            archive = feed_root / (case + ".zip")
            run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", candidate, archive])
            signature = run([signer, "--ed-key-file", secret, "-p", archive], env=env)
            run([signer, "--ed-key-file", secret, "--verify", archive, signature], env=env)
            if case == "damaged-archive":
                data = bytearray(archive.read_bytes())
                data[len(data) // 2] ^= 0x80
                archive.write_bytes(data)
            elif case == "wrong-signature":
                data = bytearray(base64.b64decode(signature))
                data[0] ^= 0x80
                signature = base64.b64encode(data).decode()
            feed = feed_root / (case + ".xml")
            feed.write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                '<channel><title>Disposable update acceptance</title><item><title>Fixture 2</title>'
                '<sparkle:version>2</sparkle:version>'
                '<sparkle:shortVersionString>2.0</sparkle:shortVersionString>'
                '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>'
                f'<enclosure url="{xml.sax.saxutils.escape(origin + "/" + archive.name)}" '
                f'length="{archive.stat().st_size}" type="application/octet-stream" '
                f'sparkle:edSignature="{signature}"/></item></channel></rss>\n'
            )
            if case != "unsigned-feed":
                run([signer, "--ed-key-file", secret, "--disable-signing-warning", feed], env=env)
                run([signer, "--ed-key-file", secret, "--verify", feed], env=env)
            if case == "tampered-feed":
                feed.write_bytes(feed.read_bytes().replace(b"Fixture 2", b"Fixture 9"))
            log_path = case_root / "sparkle.log"
            request_start = len(requests)
            started = time.monotonic()
            with log_path.open("w") as log:
                process = subprocess.Popen(
                    [str(cli), str(installed), "--check-immediately", "--verbose",
                     "--user-agent-name", "Youzi-local-acceptance", "--feed-url", origin + "/" + feed.name],
                    env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True,
                )
                try:
                    status = process.wait(timeout=args.timeout)
                except subprocess.TimeoutExpired:
                    raise RuntimeError(f"{case}: deadline exceeded; see {log_path}")
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
            log_text = log_path.read_text()
            actual_version = plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleVersion"]
            downloaded = any(item["path"] == "/" + archive.name for item in requests[request_start:])
            if case == "valid":
                passed = status == 0 and actual_version == "2" and downloaded and "Installation Finished." in log_text
                if passed:
                    run(["/usr/bin/codesign", "--verify", "--strict", installed])
                    passed = (installed / "Contents/Resources/version.txt").read_text() == "2\n"
            else:
                passed = status != 0 and actual_version == "1" and tree_hash(installed) == before_hash
                if case in ("damaged-archive", "wrong-signature"):
                    passed = passed and downloaded and "error 4005 (SUSparkleErrorDomain)" in log_text
                else:
                    passed = (passed and not downloaded
                              and "error 1000 (SUSparkleErrorDomain)" in log_text
                              and "improperly signed" in log_text)
            entry = {"case": case, "passed": passed, "exit_code": status,
                     "bundle_version": actual_version, "archive_requested": downloaded,
                     "seconds": round(time.monotonic() - started, 2), "log": str(log_path),
                     "before_bundle_sha256": before_hash,
                     "after_bundle_sha256": tree_hash(installed)}
            result["cases"].append(entry)
            print(json.dumps(entry), flush=True)
            (root / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
            cleanup_helpers([bundle_id], marker)
            if not passed:
                raise RuntimeError(f"{case}: acceptance failed; see {log_path}\n{log_text[-6000:]}")
        result["passed"] = True
    except Exception as error:
        result["passed"] = False
        result["error"] = str(error)
        print(str(error), file=sys.stderr, flush=True)
    finally:
        secret.unlink(missing_ok=True)
        if server:
            server.shutdown()
            server.server_close()
        if server_thread:
            server_thread.join(timeout=5)
        try:
            cleanup_helpers(bundle_ids, marker)
            result["owned_helpers_remaining"] = []
            result["native_helper_caches"] = collect_helper_caches(root, bundle_ids)
        except Exception as error:
            result["passed"] = False
            result["cleanup_error"] = str(error)
        # Read-only check that the unique fixture domains/caches did not escape.
        escaped = []
        for directory in ("Preferences", "Caches", "HTTPStorages"):
            escaped += [str(item) for item in
                        (Path.home() / "Library" / directory).glob("*" + marker + "*")]
        result["real_home_artifacts"] = escaped
        if escaped:
            result["passed"] = False
        (root / "requests.json").write_text(json.dumps(requests, indent=2) + "\n")
        (root / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
