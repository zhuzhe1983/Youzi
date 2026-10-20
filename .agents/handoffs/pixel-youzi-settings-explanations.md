# Settings density and capability management

- Owner/receiver: Pixel / Atlas, local Mac. Branch `fix/youzi-settings-hints`, based on the remote Keychain authorization fix. Role files are absent.
- The user requested a shared switch for verbose settings explanations and removal of tool management from Settings. Explanations default off, with a persistent title-bar toggle; validation, counts, controls, status and confirmation messages remain visible.
- The capability hub now separates experts, skills, built-in tools and connectors. Live MCP management moves there. Settings retains search-provider/key configuration under “Web Search”; security approvals remain in Security Center, whose connector-management link opens the hub.
- No tool enablement or MCP configuration is changed by navigation. Existing task connector records are preserved. The metadata-only “add connector” form is replaced by actual MCP configuration.
- Main contains unrelated user edits, including the shell. Preserve those edits when integrating the small capability-navigation hook; private backups retain the pre-integration diff.
- Guide: `docs/guides/youzi-settings-explanations.md`. Native acceptance and final test results are recorded after verification.
