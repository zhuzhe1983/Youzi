#!/usr/bin/env bash
# Execute the actual catalog loader in a relocated .app, with a poisoned SPM
# fallback. No UI, model startup, keychain access, or user defaults are involved.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: verify-relocated-templates.sh <packaged.app>}"
RESOURCE="$APP/Contents/Resources/youzi-templates-v1.json"
test -f "$RESOURCE" || { echo 'FAIL: packaged template catalog missing' >&2; exit 1; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/youzi-relocation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
PROBE="$TMP/Relocated.app/Contents"
mkdir -p "$PROBE/MacOS" "$PROBE/Resources"
cat > "$PROBE/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Probe</string><key>CFBundleIdentifier</key><string>dev.youzi.resource-probe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
cat > "$TMP/main.swift" <<'SWIFT'
import Foundation
// A reintroduced Bundle.module call must fail even on the developer's Mac.
extension Bundle {
    static var module: Bundle { fatalError("Forbidden SwiftPM checkout fallback") }
}
do {
    let catalog = try YouziBundledTemplateCatalog.loadBundled()
    precondition(CommandLine.arguments.last == "present")
    precondition(!catalog.templates.isEmpty)
    print("PASS: relocated packaged templates decoded: \(catalog.templates.count)")
} catch YouziBundledTemplateCatalog.LoadError.missingResource {
    precondition(CommandLine.arguments.last == "missing")
    print("PASS: missing packaged catalog throws without crashing")
} catch {
    fatalError("Unexpected catalog error: \(error)")
}
SWIFT
swiftc "$ROOT/Sources/Rapid/UI/YouziSimple/YouziBundledTemplates.swift" \
    "$TMP/main.swift" -o "$PROBE/MacOS/Probe"
cp "$RESOURCE" "$PROBE/Resources/youzi-templates-v1.json"
(cd "$TMP" && "$PROBE/MacOS/Probe" present)
rm "$PROBE/Resources/youzi-templates-v1.json"
(cd "$TMP" && "$PROBE/MacOS/Probe" missing)
