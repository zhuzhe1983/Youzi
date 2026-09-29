# Release video-capabilities crash

Owner / receiver: Atlas. Host: Local Mac. Branch:
`atlas/youzi-video-capabilities-crash-20260930`, based on `7d8e70ac`.
Production fix: `53fe9055`.

The integration coordinator reproduced SIGSEGV with Swift 6.4 Release via
`YouziLocalModelToolsTests.videoCapabilitiesDispatch()` using fake model
providers and no actual model. The crash report shows `objc_retain` called by
compiler-generated `YouziLocalModelTools.run(_:)` code, with an invalid object
pointer `0x0032313578323135` containing the UTF-8 bytes of `512x512`. The aggregate
failure similarly contained `768x512`. The original code constructed a nested
`[String: Any]` dictionary and mapped capability presets in a large async frame.

The fix preserves exact JSON fields and value types but represents the response
with `Encodable` structs and encodes it in a synchronous `@inline(never)` helper.
This removes heterogeneous Objective-C bridging from that async expression and
keeps the serialization lifetime outside the async frame. Encoding failures flow
through the existing sanitized `generation_failed` handler. No admission,
approval, model loading, validation or test assertions changed.

## Evidence and limits

- Original full Release crash evidence belongs to the parent Butler run:
  `jobs/logs/native-tools-isolated.log` and
  `swiftpm-testing-helper-2026-09-30-024452.ips`.
- Swift frontend parse and whitespace checks pass.
- A small `swiftc -O -swift-version 6` harness using the actual production
  `VideoCapabilities` source and original async dictionary expression completed
  1000 calls without crashing. The expression alone is insufficient to reproduce
  the failure; larger async-frame/optimization interactions remain an inference.
- The actual typed helper, extracted unchanged, passed 1000 optimized comparisons
  against the old JSON response using all three presets `512x512`, `768x512`, and
  `512x768`. Parsed JSON objects were exactly equal.
- This agent did not run full app builds. The parent owns decisive verification:
  compile Release, rerun unchanged `videoCapabilitiesDispatch` and the complete
  `YouziLocalModelToolsTests` suite, then the aggregate integration regression.

Retain this typed boundary even if the compiler later fixes the interaction:
it also expresses the fixed wire contract without `Any` boxing. Reassess the
`@inline(never)` optimization workaround only with the Release regression intact.
