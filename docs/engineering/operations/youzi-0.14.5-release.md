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

## Published result

Published [youzi-v0.14.5](https://github.com/zhuzhe1983/Youzi/releases/tag/youzi-v0.14.5) as Latest, non-draft and non-prerelease, at 2026-10-19 16:46:38 UTC. Tag and all distributed bytes refer to `4690465c4582ace96d975fab6f93fbe9c488921d`, already merged and pushed to main. The package was built locally while hosted jobs remained queued; it is not represented as a successful hosted build.

- Complete app and bundled runtime are both 0.14.5, app build 175. The installed app is the same complete signed bundle used for ZIP/DMG packaging.
- Final integrated Swift run: **378 tests / 62 suites passed**. Additional remote-editor and generation-detail render checks: **2 tests passed**, with output inspected.
- Deep/strict code-sign verification, packaged resources, relocated template loading and missing-template recovery passed. DMG verification and all six uploaded SHA-256 digests/sizes match local files. The release includes `build-info.json`, ZIP, DMG, runtime archive, `latest.json` and `SHA256SUMS`.
- Outside the checkout, the final bundled interpreter imported server, Qwen-Image 2.1, audio/video and Pillow 12.3.0; a Metal operation passed. The first probe launched from the main checkout saw its old source distribution metadata; the isolated probe avoids that contamination.
- A real offline Qwen-Image 2.1 request through the final installed runtime returned HTTP 200 and a valid non-uniform 512×512 PNG (269,157 bytes, 60.36 seconds). It used the already-cached revision `746a58556820933a2df5c75887a2570f1ad200c0`. The isolated server was shut down normally; this is a runtime smoke, not a quality or performance claim.
- Native startup no longer blocks on Keychain. Inline voice, details/compatible-mode entry, the top-right model add menu, removal of the redundant heading/footer, chat/audio local-category navigation, and absent delete actions on uncached visible rows were checked interactively. Later windows became unavailable to Computer Use; image/video navigation remains covered by the four-category routing regression. Remote editor and artifact details were checked through native fixture renders.
- No microphone conversation, acoustic AEC quality, paid remote generation, reroll against a real provider, user-model deletion or old-user-file metadata write was performed. Their deterministic paths have regression coverage; actual device/provider acceptance is not claimed.

The old app, user-data snapshot, unchanged-worktree diff and recovery manifests are retained in the private local Client Backups directory. Merged feature worktrees were moved to system Trash, with branch refs retained and exact original/Trash paths recorded locally. Release artifacts are retained outside the release worktree before its recoverable cleanup.
