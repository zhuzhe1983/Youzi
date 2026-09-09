# Pixel → Atlas: personalized sidebar profile

- Branch: `pixel/youzi-profile-display-name`, based on `atlas/youzi-remote-models`.
- Owner/host: Pixel / Local Mac. Role files and Orca absent; dedicated Git worktree.
- Only lower profile logo removed. Display name observes `userAddress`, not the AI's name;
  blank values use localized Youzi fallback. Upper branding and mode switch retained.
- Verification: 31 tests in 7 suites passed; native render fixture covered both languages,
  four text sizes, both modes and live edit/clear. Extra-large long Chinese name reviewed.
- Command: `RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_PROFILE_VISUAL_QA=1 swift test --package-path apps/rapid-mac -j 6 --filter 'YouziAccountMenu|YouziProfile|CustomInstructions|YouziExperienceMode|YouziSidebarLayout'`.
- No settings/data migration or service changes. Not yet installed/restarted.
- Next: integrate with dependent composer/model-picker UI after its regression checks;
  do not merge incomplete memory work or interrupt active chat. No release authorized.
