# Atlas / Pixel — Artifact provenance and reroll

Owner: Atlas feature integration / Pixel UI, local Mac. Branch feat/youzi-artifact-generation from main 1733103d. Role files absent. Scope: additive generation records, historical tool-receipt recovery, result detail and reroll, credential-free file metadata. Verification: Swift domain/client/tool/UI regressions, PNG pixel equality, WAV PCM bytes, MP4 offsets, export roundtrip, repeated-click guard and owner/source preservation. No Python runtime or public HTTP API change.

Implementation retains old artifacts and task ownership, captures requested/submitted/reported parameters separately, refuses source drift, and reuses existing media clients/loading consent. File insertion is additive with bounded format parsing; historical embedding is explicit and transactional. Unsupported containers retain original output and domain metadata. No audio time modification. User's main worktree changes remain untouched.

344 tests / 55 suites passed; final 8 focused tests and native information render passed. Next: native package acceptance; user's subsequent live voice panel/error request is a separate scoped task and will ship in the same local preview update. No production release or paid remote inference is authorized by these tests.
