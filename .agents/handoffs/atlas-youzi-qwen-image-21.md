# Qwen-Image 2.1 recommendation and local delivery

- Owner: Atlas; receiving roles: Atlas (integration), Pixel (model UI), Harbor (packaging).
- Host: local Apple M5 Max, 128GB unified memory.
- Branch: `feat/youzi-qwen-image-21`, implementation commit `10c9dce1`.
- Goal completed: Qwen-Image 2.1 native q4 is the preferred image recommendation;
  the local model is downloaded, selected and in the image automatic pool.
- Scope: image runtime/catalog/download checks, mflux 0.20.0 sidecar packaging,
  desktop recommendation/default steps, regression tests and user guide.
  Existing uncommitted UI/backend work remains outside these commits.

## Verified

- 423 focused Python tests, 32 Swift tests in ImageCatalogTests,
  ImageGenerationPhaseTests, SidecarBuildScriptTests and YouziModelTableTests.
- Native release build, resource validation, framework rpath, deep strict signature.
- The eight patched bundled Python/catalog files matched the base commit before
  patching (normalized code objects for sourceless modules, exact JSON bytes).
- Full local app replacement after normal quit. The inactive 0.13.3 runtime
  override was backed up and retained; the bundled 0.14.4 runtime is selected.
- Offline native-q4 inference, 512×512, seed42, actual40steps: 55.24s.
- Installed app runtime through the SDK image endpoint: 69.17s, valid PNG,
  model list/retrieve after lazy load, readiness maintained for >69s.
- Native Settings shows qwen-image-2.1 downloaded (8.9GiB) and automatic;
  Z-Image Turbo is on-demand. Main image picker shows Qwen-Image 2.1 selected.
- Previous chat service restored; the user's remote chat selection preserved.
- Live app model listing includes qwen-image-2.1; SDK Responses non-streaming
  and streaming both completed on the original Qwen3.8 chat model.

## Limits and next action

This is a local incremental runtime delivery, not a clean-room sidecar rebuild
or an upstream engine version migration. Public distribution should use the full
sidecar packaging workflow and its checks. No public release was published.
No 8GB/16GB device qualification or sustained throughput claim is made.
Single-image img2img is supported; it is not a separate instruction-edit model.
See `docs/guides/youzi-qwen-image-21.md` for pinned checkpoint and reproduction.

The existing anonymous service policy permits model listing but returned 401 for
individual model retrieval in this local session; authenticated retrieval passed
on the isolated image test service. This auth behavior was not changed by the
image task. Atlas may separately reconcile that behavior with the delivery guide.
