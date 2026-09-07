# Youzi tray resource card

The single AppKit status item hosts a read-only SwiftUI resource card via
`NSMenuItem.view`; it is not a second `MenuBarExtra`. Native title-only disabled
rows made important telemetry look unavailable, so the card uses normal label
contrast and the same model colours/track as the scenario picker:

- Blue: chat; amber: image; green: voice; purple: video.
- CPU/GPU/system memory percentages are separate host metrics.
- The stacked model bar is a **budget including runtime estimates**, not a
  precise physical-memory attribution. Audio without allocation telemetry is
  `—`, never a fabricated allocation. Video readiness does not promise permanent
  GPU weight residency.
- Registered/loading/failed/evicting models do not count as loaded segments.
  Busy models remain visible. Host free memory is the fallback when the backend
  has no available-budget sample, not the entire physical memory capacity.
- Full ready-model names are in one submenu, including ASR/TTS deduplication.
- Metrics/readiness refresh only while the root menu is open. Opening a submenu
  does not restart polling or rebuild the root menu; closing it does not stop the
  root poll. The existing authenticated residency transport is read-only.
- Copy endpoint/key and other actions retain existing readiness/auth gates.
  No credentials enter the telemetry card or model labels.

## Verification

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_TRAY_VISUAL_QA=1 \
  swift test --package-path apps/rapid-mac \
  --filter 'MenuBar|YouziCompactSettings|YouziScenarioModels|YouziResidentService|YouziTrayResource'
```

The opt-in render test writes eight isolated 400×152pt cards (Chinese/English,
light/dark, ready/no telemetry) to the temporary `youzi-tray-qa` directory.
Inspect the English four-lane legend for truncation as well as the Chinese dark
card. Rendering does not launch a server, activate a microphone, or read/change
personal defaults. A synthetic render is not full native menu interaction QA.

For native acceptance: open/close the tray repeatedly, wait for the second CPU
sample, enter/exit the model submenu, check the card still updates, and verify
Open/Settings/New task/copy controls and shortcuts. Do not expose/copy an actual
API key into a screenshot or test log.
