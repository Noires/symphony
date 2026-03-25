# UI-Managed Runtime Settings Backlog

Status: done on 2026-03-25.

This backlog covers a proper settings layer for Symphony where operators can change selected
runtime behavior from the dashboard instead of editing `WORKFLOW.md`, `.env`, or Docker bootstrap
files by hand.

## Scope

The goal is to let operators adjust day-to-day runtime settings from the UI without turning the
dashboard into a general secret editor or container management surface.

This backlog covers:

- a persisted runtime settings overlay
- dashboard and API controls for safe operator-managed settings
- merge rules between workflow config and runtime overrides
- auditability for all operator setting changes
- a clear split between UI-managed settings and bootstrap-only settings

## Product decisions

- `WORKFLOW.md` and env vars remain the bootstrap source of truth.
- The UI does not directly edit `.env`, Docker Compose files, or mounted host files.
- UI changes apply through a persisted runtime overlay layered on top of workflow config.
- Secrets are out of scope for V1:
  - no Trello API token editing
  - no GitHub token editing
  - no Codex login/auth editing
- Bootstrap/container concerns are out of scope for V1:
  - no Docker mount editing
  - no host path editing
  - no Codex binary path editing
- Operator changes must be authenticated and fully audited.
- UI-managed settings should be reversible and, where useful, support reset-to-workflow-default.

## Non-goals for V1

- generic `.env` editing in the browser
- Docker Compose editing or container rebuild orchestration
- multi-user role management beyond the existing operator token model
- secret storage or secret rotation UX
- arbitrary workflow prompt editing from the dashboard

## Why this layer is needed

Today, Symphony settings are split between:

- `WORKFLOW.md`
- env vars / `.env`
- Docker Compose env and volume mounts
- a few runtime operator controls like guardrails and full-access overrides

That makes bootstrap reliable, but it is too static for daily operations. Operators should be able
to adjust throughput, continuation behavior, advisory thresholds, and similar runtime knobs without
editing files and restarting the world.

## Settings split

### Good candidates for UI-managed runtime settings

- `agent.max_concurrent_agents`
- `agent.max_turns`
- `agent.continue_on_active_issue`
- `agent.max_concurrent_agents_by_state`
- `agent.completed_issue_state`
- `agent.completed_issue_state_by_state`
- token-efficiency thresholds under `observability`
- audit display limits under `observability`
- guardrail presets and review defaults
- repo bootstrap URL if treated as non-secret operational metadata
- Git author / committer identity for containerized runs

### Bootstrap-only or secret settings

These stay in workflow/env/Docker config:

- `TRELLO_API_KEY`
- `TRELLO_API_TOKEN`
- `TRELLO_BOARD_ID`
- `GITHUB_TOKEN`
- Codex auth / `codex login`
- Docker mount paths
- SSH material
- low-level Codex command path / process bootstrap details

## Architecture overview

The UI settings system should add four main pieces:

- `SettingsOverlay`
  - persisted operator-managed overrides
- `SettingsResolver`
  - merges workflow config and active runtime overlay into effective settings
- settings API + dashboard forms
  - authenticated mutation surface
- audit integration
  - records who changed what and when

## Merge model

The effective runtime settings should resolve in this order:

1. schema defaults
2. `WORKFLOW.md`
3. env fallbacks already supported by the workflow/config layer
4. UI-managed runtime overlay
5. ephemeral per-run/per-session overrides where applicable

Important rule:

- the overlay should only be allowed to touch an explicit allowlist of fields
- disallowed keys must be rejected at validation time

## Persistence model

V1 should use the existing flat-file audit/storage style for simplicity.

Suggested artifacts:

- `settings/runtime_overlay.json`
- `settings/history/*.json`

The runtime overlay should store:

- `version`
- `updated_at`
- `updated_by`
- allowed setting keys and values
- optional `expires_at` for temporary settings later

History entries should store:

- action id
- actor
- old value
- new value
- scope
- reason / note if provided
- timestamp

## API surface

Suggested endpoints:

- `GET /api/v1/settings`
  - effective settings snapshot
- `GET /api/v1/settings/overlay`
  - current operator overlay only
- `GET /api/v1/settings/history`
  - recent changes
- `POST /api/v1/settings`
  - patch allowed runtime settings
- `POST /api/v1/settings/reset`
  - reset selected keys back to workflow defaults

All mutating routes should require the existing operator token.

## Dashboard UX

The dashboard should gain a dedicated settings section with:

- current effective value
- workflow/default value
- editable value if the field is UI-managed
- source indicator:
  - default
  - workflow
  - env
  - ui_override
  - runtime_override
- reset button per field or per group
- save/apply feedback

The UI should group settings by operator intent, not by raw config module:

- Throughput
- Continuation and completion
- Guardrails
- Audit and dashboard
- Efficiency thresholds
- Repo bootstrap metadata

## Validation rules

- Only allow whitelisted fields.
- Keep existing schema validation semantics for allowed fields.
- Reject secrets and bootstrap-only fields explicitly with a clear error.
- Prevent obviously invalid runtime states, for example:
  - `max_concurrent_agents < 1`
  - malformed state maps
  - invalid threshold values

## Audit requirements

Every settings mutation should be auditable.

At minimum, each change should record:

- actor
- changed keys
- old values
- new values
- timestamp
- whether the change was applied immediately

The dashboard should expose recent settings changes so operators can see why behavior changed.

## Interaction with existing features

### Guardrails

- guardrail rules and full-access overrides remain separate from the settings overlay
- the settings UI may edit guardrail defaults, but not replace the existing rule/override model

### Docker

- the UI should not try to rewrite `docker-compose.yml`
- for container runs, UI-managed settings affect Symphony behavior inside the running container only
- if later we need startup-only settings from the UI, that becomes a separate restart/redeploy story

### Workflow reloads

- workflow file changes should continue to hot-reload as they do today
- if the workflow changes a field that is also UI-managed, the resolver should still apply the UI
  overlay last
- the UI should make it obvious when the workflow default changed underneath an override

## Proposed implementation phases

### Phase 1: Settings overlay foundation

- add a persisted runtime overlay store
- add explicit allowlist of UI-manageable fields
- add merge/resolution logic on top of current config loading
- expose effective settings and overlay-only settings via API

### Phase 2: Mutation API and audit

- add authenticated patch/reset endpoints
- validate changes through schema-compatible rules
- persist settings history entries
- surface history through API

### Phase 3: Dashboard settings UI

- add a settings page/panel
- show effective value, workflow value, and source
- support editing allowed fields
- support reset-to-workflow-default

### Phase 4: Runtime application semantics

- clarify which settings apply immediately vs. on next dispatch
- ensure orchestrator/runtime reads the resolved settings consistently
- add source badges or tooltips so operators understand active precedence

### Phase 5: Temporary operational overrides

- optional TTL-based settings for temporary throughput/threshold changes
- expiry handling and audit records
- visual warning when temporary settings are active

## Candidate V1 allowlist

Recommended first allowlist:

- `agent.max_concurrent_agents`
- `agent.max_turns`
- `agent.continue_on_active_issue`
- `agent.max_concurrent_agents_by_state`
- `agent.completed_issue_state`
- `agent.completed_issue_state_by_state`
- `observability.refresh_ms`
- `observability.audit_dashboard_runs`
- `observability.issue_rollup_limit`
- `observability.expensive_run_uncached_input_threshold`
- `observability.expensive_run_tokens_per_changed_file_threshold`
- `observability.expensive_run_retry_attempt_threshold`
- `guardrails.default_review_mode`
- `guardrails.builtin_rule_preset`

Optional V1.5 allowlist:

- repo source URL
- Git author/committer display identity

## Edge cases

- A workflow file reload changes a field currently overridden in the UI:
  - effective value should remain the overlay value
  - UI should show the new workflow baseline separately

- An operator tries to change a secret field:
  - reject with a clear “bootstrap-only/secret” error

- The overlay file becomes corrupt:
  - fail closed to workflow config
  - expose an audit/log warning

- Two operators edit the same field at once:
  - last write wins in V1
  - audit trail must still show both attempts

- A runtime-only change would affect currently running sessions:
  - define whether the setting applies only to future dispatches or immediately
  - prefer future dispatches in V1 unless the runtime contract is trivial

## Acceptance criteria

This backlog is done when:

- operators can change a defined allowlist of runtime settings from the UI/API
- the effective value clearly shows whether it comes from workflow or UI override
- changes are persisted and survive process restarts
- changes are fully auditable
- secrets and bootstrap-only fields are explicitly excluded
- reset-to-workflow-default is supported for edited keys

## Suggested implementation order

1. Overlay store and merge logic
2. Allowlist + validation
3. Authenticated API
4. Dashboard settings UI
5. Audit/history view
6. Temporary TTL-based overrides if still needed

## Outcome

- Operators can now change the defined allowlist of runtime settings through the dashboard and API.
- Changes apply through a persisted runtime overlay layered on top of `WORKFLOW.md`.
- Every change is stored in `settings/runtime_overlay.json` plus `settings/history/*.json`.
- The dashboard shows effective value, workflow baseline, default baseline, source, and recent settings history.
- Secrets and bootstrap-only fields remain explicitly excluded from the UI-managed surface.
- Reset-to-workflow-default is supported per setting.
