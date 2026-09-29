# Harbor → Atlas: Youzi public positioning

- Date: 2026-09-06. Owner: Harbor documentation, Local Mac.
- Branch: `harbor/youzi-project-positioning`, based on fetched `origin/main` at `8530d6b9`.
- Role files are absent in this checkout. Documentation-only worktree; no UI/backend files changed.
- GitHub About description updated and re-read: personal vibe-coding project, no commercial charging/promotion, Apple M-series laptops only, minimum recommended 24GB / preferred 64GB+, WorkBuddy inspiration and Rapid-MLX technical credit.
- README replaces upstream marketing/install instructions with Youzi positioning, hardware guidance, own repository links, source-build boundaries, privacy caveats and attribution. LICENSE is unchanged.
- Verification: relative README targets exist; Swift package declares macOS 14 / Swift 6; README hardware wording and `git diff --check` checked. No application compilation needed for this documentation-only change.
- No tags, release, deployment or main-branch merge performed.
- Integration pending: current local application work lives in a separate dirty integration worktree; this documentation PR must not be treated as delivery of that code. Fetch found 61 remote commits beyond that worktree's HEAD; they have NOT been merged or verified. Upstream workflow migration, local-first UI integration, API models/Responses validation and the prior settings backlog remain separate work.
- Next: Atlas review/merge documentation PR independently, then integrate and verify pending application changes before publishing a Youzi binary. Harbor configure and validate Youzi-only Actions/release flow separately; do not invoke inherited upstream publication workflows.

## README archive follow-up (2026-09-06)

- User explicitly requested preserving the previous README as `rapid-mlx-readme.md`.
- Archive is byte-for-byte `def79da6:README.md`, the README in the local application worktree before this task. It is deliberately not the newer remote README from `8530d6b9`; no remote feature integration is implied.
- Reworked Youzi homepage around personal use / sharing, M-series **laptops**, 24GB minimum recommendation / 64GB+ preference, workflow-oriented product direction, source-build boundaries and credits. Added an explicit archive link and warnings separating upstream installation, performance and support claims from Youzi.
- Preserved LICENSE, NOTICE and third-party attribution files unchanged. Feature descriptions are directions, not claims that all pending application work has shipped.
- Receiving owner: Atlas. PR #1 remains documentation-only; do not merge remote application changes as part of this task. No workflow, application, release or tag changes.
- Verification: archive hash matches committed local baseline; new README relative files exist; required positioning wording and `git diff --check` pass. Archived links/content are historical and not rewritten or asserted current.
