# Youzi unified product runtime

## Status

Accepted integration contract for `atlas/youzi-complete`.

## Context

Youzi adds a task-first simplified experience, durable workspaces/projects,
capability catalogs, personal memory graph, artifacts, automation, and realtime
voice to an existing Rapid-MLX macOS application. The existing application
already owns mature model lifecycle, chat, media, MCP, permission, telemetry,
diagnostic, update, and persistence state. Building the simplified experience
as a second application stack would duplicate authority and make switching
modes lose or contradict live work.

The complete product requirements are recorded in
`docs/plans/youzi-workbuddy-product-requirements.md`. Internal engineering
milestones may order work, but do not reduce that product scope.

## Decision

### One process and one runtime graph

Simple and Professional modes are two presentations of the same process-wide
runtime. `RapidApp` constructs each live service once. A persisted experience
preference selects the root presentation while both roots receive the same
environment instances. A mode switch must not recreate `ServerManager`,
`ChatViewModel`, media view models, connector registries, permission stores, or
the new Youzi repositories.

Professional Mode remains the existing control surface and source of detailed
model/runtime diagnostics. Simple Mode translates the same states into user
language and may deep-link to a precise professional repair surface.

### Stable product records and references

New product objects use stable identifiers and refer to one another by ID. The
initial durable format is a versioned JSON document written atomically under
the existing Application Support locator with owner-only permissions. The
repository must reject unknown newer schema versions instead of silently
discarding fields. Every future schema change adds an explicit migration.

A task owns one conversation reference and one workspace reference. A
workspace points to a real local directory, either user-selected through a
security-scoped bookmark or app-managed. A project groups durable rules,
assets, available capabilities, and task references; it is not a filesystem
alias and does not own a separate chat store.

### Capabilities and permissions

Helpers select persona and method, skills provide versioned workflow packages,
and connectors expose authenticated external tools/resources. Their manifests
are distinct, but the task orchestrator resolves them into one execution plan.
Every connector call continues through the existing permission boundary. No
voice, automation, helper, skill, or built-in MCP path can widen scope.

### Memory graph and citations

The memory graph is a local derived layer, not a replacement for source data.
Every node, edge, and conclusion carries stable source citations and scope.
Deletion propagates to graph relations, retrieval indexes, and derived
summaries. Context retrieval is intent- and scope-bounded; the whole graph is
never inserted into a prompt.

### Voice shares task execution and model residency

Global and agent-scoped voice use one realtime pipeline and the same task
orchestrator. VAD, ASR, LLM, TTS, and foreground inference participate in the
existing unified-memory residency policy. Global immersive UI and agent Live
UI may differ, but transcripts, tool calls, permissions, and artifacts join the
same task history.

### External model reuse is model-granular

An external OMLX or Hugging Face compatible model may be reused through one
validated symlink at model-directory granularity. Youzi never links the entire
external cache, overwrites a target, mutates source model bytes, or deletes a
source when removing a managed link.

## Consequences

- Root presentation code must remain thin; runtime construction stays in one
  place.
- UI work can progress before all services are live by using honest empty and
  disabled states backed by the shared repositories, not parallel mock stores.
- JSON keeps the first migration auditable and testable, but a future graph or
  full-text database may be added behind repository interfaces when measured
  scale requires it.
- Cross-mode and migration tests are release gates because duplicated state or
  silent schema loss would be user-data defects.
- Live third-party connector verification still requires credentials, but
  manifest, permission, disabled-state, and contract behavior remain locally
  testable.

## Alternatives rejected

- Separate Simple and Professional application targets: rejected because live
  model, conversation, permission, and connector state would diverge.
- Rebrand the existing technical sidebar without a new information
  architecture: rejected because it preserves the learning-cost problem.
- Start with unversioned ad-hoc preference keys: rejected because the complete
  object graph needs migrations and referential integrity.
- Copy external model directories into Youzi storage: rejected because it
  duplicates large files and makes source ownership ambiguous.

## Verification

- Tests prove experience selection persists without constructing runtime
  services.
- Domain repository tests cover complete round trips, permissions, corruption,
  unsupported versions, and migrations.
- Cross-mode UI/runtime tests prove both presentations observe the same active
  task, model, connector, and permission state.
- Model-link tests prove model-granular creation, idempotence, collision and
  cycle rejection, and managed-link-only removal.
- Memory and voice milestones add source-deletion, scope, interruption,
  latency, and residency evidence before final acceptance.

## Owner and date

- Owner: Atlas
- Date: 2026-09-02
