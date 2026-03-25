# SPEC v2 Conformance Review

Status: Updated review of the current Elixir reference implementation against
[`SPEC.md`](../../SPEC.md)

Reviewed on: 2026-03-25

## Scope

This review answers a practical project question:

> Is `SPEC` already implemented in the current Elixir codebase?

This is not a formal proof and not a line-by-line certification pass. It is a concrete engineering
review of the current implementation shape against the normative product areas defined in
`SPEC`.

## Verdict

The current Elixir implementation is aligned with `SPEC`.

The core runtime model is implemented:

- workflow loading and reload
- typed config resolution
- runtime settings overlay
- tracker adapter abstraction with tracker writes
- orchestrator-owned dispatch/retry/reconciliation state
- workspace lifecycle and safety checks
- app-server based agent execution
- guardrail approvals and full-access overrides
- durable run auditability
- operator control plane

There is no obvious major `SPEC-v2` subsystem that is completely missing from the codebase.

The previously identified follow-up gaps have now been closed:

- write-only secret handling now has a reusable runtime secret subsystem
- prompt render failures now have an explicit `template_render_error` path
- `SPEC` now has an explicit maintainer-facing test matrix in
  [`spec-v2-test-matrix.md`](./spec-v2-test-matrix.md)

## Implemented

### 1. Workflow specification and dynamic reload

Implemented in:

- [`workflow.ex`](../lib/symphony_elixir/workflow.ex)
- [`workflow_store.ex`](../lib/symphony_elixir/workflow_store.ex)

Evidence:

- explicit workflow path support and default `./WORKFLOW.md`
- YAML front matter parsing with body split
- typed errors for missing workflow file and invalid front matter shape
- last-known-good reload behavior in the workflow store
- polling-based workflow change detection

Assessment: implemented

### 2. Typed config layer and precedence baseline

Implemented in:

- [`config.ex`](../lib/symphony_elixir/config.ex)
- [`config/schema.ex`](../lib/symphony_elixir/config/schema.ex)

Evidence:

- typed schema with defaults and validation
- env-backed resolution and secret-like `$VAR` handling
- overlay application before schema parsing
- Codex runtime settings derivation including sandbox policy resolution
- validation of tracker-specific required fields

Assessment: implemented

### 3. Runtime settings overlay

Implemented in:

- [`settings_overlay.ex`](../lib/symphony_elixir/settings_overlay.ex)
- [`observability_api_controller.ex`](../lib/symphony_elixir_web/controllers/observability_api_controller.ex)

Evidence:

- persisted overlay file
- overlay history
- allowlisted UI-manageable fields
- authenticated update/reset flows
- overlay payload and history API

Assessment: implemented

### 4. Tracker adapter contract and tracker writes

Implemented in:

- [`tracker.ex`](../lib/symphony_elixir/tracker.ex)
- [`linear/adapter.ex`](../lib/symphony_elixir/linear/adapter.ex)
- [`trello/adapter.ex`](../lib/symphony_elixir/trello/adapter.ex)
- [`github/adapter.ex`](../lib/symphony_elixir/github/adapter.ex)

Evidence:

- generic adapter boundary
- candidate fetch
- issue-state refresh
- comment creation
- issue-state update
- human-response marker fetch

The orchestrator also uses tracker writes directly for completion handoff and tracker-facing run
summary behavior in [`orchestrator.ex`](../lib/symphony_elixir/orchestrator.ex).

Assessment: implemented

### 5. Orchestration state machine

Implemented in:

- [`orchestrator.ex`](../lib/symphony_elixir/orchestrator.ex)

Evidence:

- authoritative `running`, `claimed`, `retry_attempts`, `pending_approvals`, and override state
- startup terminal cleanup
- periodic tick scheduling
- reconciliation before dispatch
- retry scheduling and backoff handling
- pending approval pause state
- operator-driven approval decision and resume path
- explicit refresh request path that queues poll/reconcile work

Assessment: implemented

### 6. Workspace lifecycle and safety

Implemented in:

- [`workspace.ex`](../lib/symphony_elixir/workspace.ex)

Evidence:

- deterministic issue workspace mapping
- workspace reuse
- after-create / before-run / after-success / after-run / before-remove hooks
- workspace-root containment checks
- sanitized workspace names
- local and remote worker handling

Assessment: implemented

### 7. Agent runner and app-server execution

Implemented in:

- [`agent_runner.ex`](../lib/symphony_elixir/agent_runner.ex)
- [`codex/app_server.ex`](../lib/symphony_elixir/codex/app_server.ex)

Evidence:

- workspace preparation and hook execution
- prompt build before session start
- app-server startup and turn execution
- timeout configuration for turn/read/stall behavior
- streamed updates back into the orchestrator
- approval-pending and approval-denied exit paths

Assessment: implemented

### 8. Observability and durable auditability

Implemented in:

- [`audit_log.ex`](../lib/symphony_elixir/audit_log.ex)
- [`presenter.ex`](../lib/symphony_elixir_web/presenter.ex)
- [`status_dashboard.ex`](../lib/symphony_elixir/status_dashboard.ex)

Evidence:

- per-run summary artifacts
- append-only event streams
- issue rollups
- audit export bundles
- token accounting including cached vs uncached input
- rate-limit capture

Assessment: implemented

### 9. First-class operator control plane

Implemented in:

- [`router.ex`](../lib/symphony_elixir_web/router.ex)
- [`observability_api_controller.ex`](../lib/symphony_elixir_web/controllers/observability_api_controller.ex)
- [`dashboard_live.ex`](../lib/symphony_elixir_web/live/dashboard_live.ex)
- [`run_live.ex`](../lib/symphony_elixir_web/live/run_live.ex)

Evidence:

- approvals
- rule enable/disable/expire
- run/workflow full-access overrides
- settings overlay mutation
- GitHub config/token mutation
- Codex device auth start/cancel
- operator-token enforcement for mutating actions

Assessment: implemented

### 10. UI-managed GitHub access and device auth

Implemented in:

- [`github_access.ex`](../lib/symphony_elixir/github_access.ex)
- [`codex_auth.ex`](../lib/symphony_elixir/codex_auth.ex)
- [`secret_store.ex`](../lib/symphony_elixir/secret_store.ex)

Evidence:

- reusable write-only secret storage
- GitHub token handling via the shared secret subsystem
- GitHub config metadata and history
- device-code auth lifecycle and status snapshot

Assessment: implemented

## Partially Implemented

No material partial-alignment areas remain from this review.

This is still an engineering review rather than a formal proof system, but the previously
identified practical gaps are no longer large enough to justify open follow-up work of their own.

## Missing

No major `SPEC` runtime subsystem appears to be wholly missing from the current Elixir
implementation.

There are no obvious gaps of the form:

- section exists in `SPEC`
- no matching implementation concept exists anywhere in the codebase

No obvious major runtime gaps remain from this review pass.

## Section-by-section summary

- `Workflow specification and runtime configuration`: implemented
- `Configuration resolution and dynamic reload`: implemented
- `Orchestration state machine`: implemented
- `Polling, scheduling, and reconciliation`: implemented
- `Workspace management and safety`: implemented
- `Agent runner protocol`: implemented
- `Tracker adapter contract`: implemented
- `Prompt construction and context assembly`: implemented
- `Observability, auditability, and operator control plane`: implemented
- `Failure model and recovery`: implemented in runtime shape
- `Security and operational safety`: implemented
- `Reference algorithms`: documentation only, reflected by implementation shape
- `Test and validation matrix`: implemented through the suite plus
  [`spec-v2-test-matrix.md`](./spec-v2-test-matrix.md)
- `Conformance checklist`: broadly satisfied and now traceable through the matrix

## Practical answer

If the question is:

> Can we treat `SPEC.md` as the governing spec for the current Elixir implementation?

The answer is yes.

If the question is:

> Is `SPEC.md` now a reasonable governing spec for the current Elixir implementation?

The answer is also yes.

Normal maintenance still applies, but this review no longer identifies a meaningful open
implementation backlog against the current `SPEC.md`.
