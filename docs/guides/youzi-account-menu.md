# Shared account menu

Both Simple and Professional presentations use the same account menu and the
same persisted `youzi.experience-mode.v1` preference.

- The sidebar entry is a single row: logo, Youzi name, **Simple / Pro** badge,
  disclosure chevron. Chinese uses **简约 / 专业**.
- A native segmented picker at the top-right of the popover selects either
  mode directly. Full mode names remain available to accessibility clients.
- Selecting the other mode dismisses the popover before changing the shell.
  It does not restart models, change the active conversation or create another
  runtime. Selecting the current mode has no effect.
- No local-runtime subtitle, duplicate switch-mode row, help row or second-line
  mode label appears in this menu. Settings, theme, update checking and the
  compact status row remain.
- The popover width accommodates localized labels and the configured font scale.

## UI verification

`YouziAccountMenuContent` and `YouziAccountMenuTrigger` are presentation-only
surfaces. The optional native fixtures inject synthetic status text, isolated
preference domains and no-op settings/update actions — no model, audio, network
request or real user setting is required.

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 \
YOUZI_ACCOUNT_MENU_RENDER=1 \
swift test --package-path apps/rapid-mac -c release \
  --filter 'YouziAccountMenu|YouziExperienceMode|AppearanceConfig'
```

Optional window captures require pre-existing Screen Recording permission:
`YOUZI_ACCOUNT_MENU_WINDOW_CAPTURE=1` and
`YOUZI_ACCOUNT_MENU_RENDER_DIR=/tmp/youzi-account-menu-render`.
They only capture fixture windows and never request permission.
