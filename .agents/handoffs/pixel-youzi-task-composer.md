# Pixel / Atlas — Task composer layout

Local Mac, branch feat/youzi-task-composer-layout. WorkBuddy observed: finance category changes suggestions; + opens files/experts/skills/connectors; chosen expert appears in toolbar, skill becomes a chip, connector menu has status and management. No request sent and no third-party account connected during inspection.

New task page now has category pills, a taller composer, context-specific suggestions below, selected expert and current model in the toolbar, removable skill/connector references, and workspace/project selectors beneath. Conversations retain compact composer, send/stop, voice and attachment handling. Scene references remain the existing request semantics; this is not new agent delegation or connector auth implementation.

20 tests in 4 suites passed. Needs integrated native visual acceptance at the installed app; retain user local changes in Shell/RapidApp when packaging. No domain schema migration. Main settings capability management consolidation was discussed but is not implemented here; existing actual MCP configuration must be migrated completely before removing its settings entry.
