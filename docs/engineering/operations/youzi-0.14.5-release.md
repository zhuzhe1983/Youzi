# Youzi 0.14.5 release

Atlas owns integration and release, Pixel owns native UI verification, Harbor owns packaging. This task runs on the local Mac; role files are absent. The user explicitly authorized merging this batch to main and publishing 0.14.5. App build is 175; engine and app versions agree.

## Included changes and checks

- Unified model selection and files-first settings: 472 tests / 65 suites passed before integration; actual installed native list and file ordering accepted.
- Artifact generation metadata, file embedding and source-preserving reroll: 344 tests / 55 suites plus 8 focused final checks passed. Native details remain part of release acceptance; no paid generation is required to inspect the UI.
- Inline voice calls: 67 tests / 8 suites and four light/dark idle/error native renders passed. Original audio failure was VoiceProcessing I/O initialization -10875. Explicit compatible mode avoids that audio unit; actual attended acoustic quality remains unverified.
- Model add toolbar, category navigation and file actions: 63 tests / 8 suites passed.
- Release manifest and sidecar constraint checks: 8 Python tests passed. Remote credential/Keychain/sidecar checks after the fixes below: 39 Swift tests / 5 suites passed.

Always set `RAPID_DESKTOP_NO_PORT_SWEEP=1` for native checks. Serialize Swift build/test processes sharing a scratch directory.

## Fresh-build findings

The first native startup blocked on the main thread in `RemoteModelKeychain.read → SecItemCopyMatching → SecurityServer decrypt`. Remote credentials bypassed the existing non-interactive `SecurityKeychainItems` adapter. They now use that adapter for reads and writes. Its legacy process gate and `LAContext.interactionNotAllowed` fail unavailable access closed; no credential or Keychain ACL is changed. Missing and inaccessible credentials remain distinct, so an inaccessible key cannot become an anonymous request.

The fresh Python 3.12.13 image stack resolved Pillow 13.0.0. Its `PIL._typing` imported unavailable `numbers._IntegralLike`, so the existing Qwen-Image 2.1 import smoke failed before packaging. The shared Desktop constraints now pin Pillow 12.3.0; the metadata and torch-free image import gates remain enabled. This is based on the reproduced staged runtime, not a claim about every Pillow installation. [Pillow upstream source](https://github.com/python-pillow/Pillow/blob/main/src/PIL/_typing.py) and [12.3 release notes](https://pillow.readthedocs.io/en/stable/releasenotes/12.3.0.html).

## Delivery and rollback

Before replacement, clone the installed app, inactive runtime override and preferences; after a normal quit, clone the complete Rapid user-data directory. Preserve unrelated uncommitted main-worktree edits byte for byte. Only replace the complete signed bundle. Keep the stopped previous app and audit records in the local Client Backups directory.

Rollback restores the previous complete app while preserving current user-created data. Do not restore the data snapshot over newer conversations. No model-cache deletion or port sweep is part of delivery.

The original hosted package requests were queued while local acceptance proceeded. One request used the pre-push source and cannot meet the 0.14.5 version gate; it must not be published. Only an exact-source package with signatures, resources, matching runtime version, manifest hashes and native acceptance may be promoted. Final artifact provenance and acceptance results must be appended before claiming publication.
