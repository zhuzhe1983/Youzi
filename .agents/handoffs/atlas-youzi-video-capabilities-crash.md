# Release video-capabilities crash

Owner / receiver: Atlas. Host: Local Mac. Branch:
`atlas/youzi-video-capabilities-crash-20260930`, based on `7d8e70ac`.
Final production fix: explicit fixed-size validation loop in
`VideoCapabilities.validated()` (`6e4a4c84`, followed by comment clarification).

The coordinator reproduced SIGSEGV with Swift 6.4 Release via unchanged
`YouziLocalModelToolsTests.videoCapabilitiesDispatch()`, using fake model
providers. `objc_retain` received `0x0032313578323135`, the UTF-8 small-string
bytes of `512x512`; an earlier failure contained `768x512`. The first hypothesis
was heterogeneous JSON boxing in the async dispatcher. A typed synchronous
response helper did not fix the minimal WMO failure and was reverted.

## Reproduced cause boundary

A standalone harness uses the actual `VideoCapabilities` implementation plus
minimal non-network enum/constants seams. It decodes the same capability JSON,
validates it, invokes the original async response expression, and repeats 1000
times. Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 macOS 27.0 (26A428):

| Build / change | Result |
| --- | --- |
| Original, `swiftc -O` | 1000 calls pass |
| Original, `-O -whole-module-optimization` | SIGSEGV, exit -11 |
| Typed synchronous JSON helper, WMO | SIGSEGV, exit -11 |
| Validation replaced by equivalent explicit loop, WMO | 1000 calls pass |
| Explicit loop, nine valid/invalid fixed-size cases, WMO | 9000 checks pass |

Additional bisection: moving validation before the async provider, discarding
its returned copy, non-inlining `validated()`, or non-inlining `parseSize` still
crash. Removing validation, disabling optimization for it, or moving its result
to a Boolean helper avoid the crash. The final patch uses no compiler-specific
attributes: a normal for-loop retains the nonempty requirement and rejects any
unparseable size, leaving every remaining validation guard unchanged. These
comparisons implicate the optimized `allSatisfy`/optional-tuple validation path;
they do not prove the precise compiler-internal defect.

## Reproduction artifacts and next action

Parent Butler run evidence is under:
`parallel/video-capabilities-wmo/` in run
`20260930-010940-resolve-all-remaining-youzi-branch-and-worktree-changes-ver`.
Run `python3 reproduce.py` there to regenerate original/typed/final comparisons.
The directory contains the compact probes, extracted capability source,
provenance, bisection results, and machine-readable `reproduction-results.json`.
The runner creates/removes a temporary build directory and never invokes a
model, production service, or desktop app. Deliberate original/typed crashes
produce local diagnostic reports. This is forensic evidence, not a future CI
requirement that compilers must continue to crash.

The net production diff is only the fixed-size validation loop in
`VideoClient.swift`; `YouziLocalModelTools.swift` is identical to the base.
Existing tests and assertions are unchanged. Swift parsing and diff checks pass.
Parent owns the decisive final gate: rebuild Release, run unchanged
`videoCapabilitiesDispatch`, then all `YouziLocalModelToolsTests` and the full
integration selection. No full app build was run by this agent.
