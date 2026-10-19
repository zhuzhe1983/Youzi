# Model settings navigation — Atlas → Harbor / Pixel

Branch: `feat/youzi-model-settings-navigation` (local Mac, 2026-10-19).

- Models has three sidebar children: files / loading / service. Loading alone
  has the four workflow tabs. Legacy deep links and stored tab values survive.
- File size is the second native-table column; existing measured/estimated/missing
  semantics remain intact. No model downloads or model migrations.
- Remote alternatives are visible next to each loading list, including separate
  ASR/TTS lanes. Editable display names follow provider IDs until customized;
  UUID routing and Keychain credentials are preserved. Scenario menus already
  consume these saved entries. No generation or provider calls on save.
- Startup/pool options belong to Loading; Service owns HTTP settings and a
  cancellable, read-only five-second poll of the actual local `/v1/models`.
  Existing loaded-only discovery and inference policy remain unchanged.
- Validation: 379 Swift tests in 60 suites passed; 75 Python tests passed
  (loaded-only discovery, loading policy and anonymous inference). Two synthetic
  native render tests passed; Chinese remote editor/list and model-file size
  screenshots inspected. Local installed-app acceptance follows integration.

No role files exist in this checkout. Atlas handled the cross-cutting navigation,
with focused tests for compatibility and synthetic credentials only.
