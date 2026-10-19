# Atlas / Pixel — Unified GUI model preference

Owner: Atlas integration with Pixel UI; local Mac. Branch fix/youzi-model-settings-clarity. Role files are absent in this checkout; AGENTS.md lifecycle followed.

User chose one mixed local/remote list and one preferred model per workflow. GUI is primary. Only preferred locals auto-load; manually loaded secondary locals remain available and are exposed by the unchanged loaded-only external API. No duplicate API-side model preference. Model Files catalog moved above folder/storage controls. Loaded labels replace ready wording.

Preference stored in optional RemoteModelDocument.preferredModels; old source order/local arrays resolve read-only, preserving rollback data. ASR and TTS preferences independent. Local selection triggers existing safe manual loader; no automatic unloading. Existing task choices preserved. Agent media tools now include configured remotes and require no local process for remote image/speech/video. Video captures the provider and invalidates if endpoint or credentials change; no cross-provider retry. Local image normalization stays local.

472 tests / 65 suites passed, plus enabled Chinese/English render fixtures. No user credential or provider URL in tracked docs, no remote generation charge incurred. Main user's uncommitted edits are preserved. Installed candidate-5be59e1e and verified native Settings: mixed image list, existing remote preference preserved, local image not auto-loaded, catalog above storage, local chat marked loaded. No settings were changed in acceptance. No Python/runtime or public API change; bundle the prior 0.14.4 runtime unchanged.
