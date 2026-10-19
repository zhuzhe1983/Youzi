# Inline voice handoff

- Owner: Pixel implementation / Atlas integration; local Mac. Role files are absent in this checkout.
- Branch: `fix/youzi-inline-voice`; base includes artifact metadata `4a0e66a2`.
- Scope: inline controls in both chat surfaces; stable controller ownership; mute and input level; explicit compatible-mode retry; typed startup errors.
- Evidence: 67 tests in 8 suites passed; four native light/dark idle/error renders inspected. Original host log identifies VoiceProcessing I/O initialization -10875.
- Next action: integrate with model-settings changes, validate the packaged native UI, then release 0.14.5 under the user's explicit authorization. Hardware AEC/compatible-mode conversation acceptance is not yet established.
- Risks: device-specific CoreAudio failure can persist; permission and device failures must not be reported as AEC failures. No raw recording, model generation or remote requests were made by these tests.
- Reproduction and behavior: `docs/guides/youzi-inline-voice.md`.
