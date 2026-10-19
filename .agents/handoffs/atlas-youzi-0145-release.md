# 0.14.5 completion

- Atlas / Pixel / Harbor responsibilities completed on local Mac. Role files are absent.
- Main contains the full batch. Published tag `youzi-v0.14.5` points to tested source `4690465c4582ace96d975fab6f93fbe9c488921d`.
- Local complete package installed and promoted as Latest under explicit user authorization. Six assets verified against local SHA-256 and size; updater manifest reports app/runtime 0.14.5.
- 378 integrated Swift tests, 2 visual checks, 8 packaging Python tests passed; final packaged Qwen-Image 2.1 produced a valid 512×512 PNG. Startup Keychain hang and fresh Pillow dependency failure were fixed before publication.
- Device-level voice/AEC conversation and real-provider reroll remain unclaimed; no paid requests or microphone capture were used. Details and rollback: `docs/engineering/operations/youzi-0.14.5-release.md`.
- Unrelated main-worktree changes preserved. Merged task worktrees retired recoverably; local manifests retain recovery details and branches.
- No required implementation or release work remains. Future audio-device/provider reports should include exact device/API error and the chosen model.
