# Symphony Service Specification

Status: Active (product-aligned, language-agnostic)

Purpose: Define Symphony as a long-running agent orchestration service with:

- generic tracker adapters
- deterministic per-issue workspaces
- coding-agent execution over an app-server protocol
- a first-class operator control plane
- durable run auditability
- Docker/Linux-first operational guidance

This document serves as the primary product specification.

## 1. Problem statement

Symphony is a long-running automation service that continuously reads work from a supported issue
tracker, creates or reuses an isolated workspace for each issue, and runs a coding-agent session
for that issue inside the workspace.

The service solves these operational problems:

- It turns issue execution into a repeatable daemon workflow instead of ad-hoc manual scripts.
- It isolates agent execution in per-issue workspaces so commands run only inside issue workspaces.
- It keeps base workflow policy in-repo through `WORKFLOW.md`.
- It allows operators to supervise the running system through a first-class control plane.
- It preserves durable audit artifacts so completed work remains inspectable after workers exit.

Important boundary:

- Symphony is not just a scheduler. It is both a runtime coordinator and an operator-facing control
  surface.
- Tracker writes are a formal runtime responsibility when the flow requires them.
- A successful run may end at a workflow-defined handoff state such as `Human Review`, not
  necessarily `Done`.

## 2. Goals and non-goals

### 2.1 Goals

- Poll supported issue trackers on a fixed cadence and dispatch work with bounded concurrency.
- Maintain a single authoritative runtime state for dispatch, retries, approvals, and
  reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop or pause active runs when tracker state or guardrail state makes them ineligible to continue.
- Recover from transient failures with retries and exponential backoff.
- Load base workflow behavior from a repository-owned `WORKFLOW.md` contract.
- Support operator-managed runtime overlays and write-only secret handling.
- Expose operator-visible observability and active control surfaces.
- Support restart recovery without requiring a durable orchestration database.

### 2.2 Non-goals

- Multi-tenant SaaS administration model.
- Full RBAC/SSO requirements in the core spec.
- Prescribing a specific frontend framework.
- Requiring a specific tracker vendor.
- Requiring a relational database for core orchestration state.
- Replacing repository workflow policy with a purely UI-managed system.

## 3. System overview

### 3.1 Primary operating posture

Symphony is specified with a Docker/Linux-first operating posture.

This means:

- Linux container execution is the primary supported runtime profile.
- Host-local Linux/macOS runs are secondary development profiles.
- Host-local Windows runs are best-effort compatibility profiles.

The spec remains language-agnostic and portable, but the reference operational profile is a Linux
container runtime.

### 3.2 Main components

1. `Workflow Loader`
   - Reads `WORKFLOW.md`
   - Parses YAML front matter and prompt body
   - Returns `{base_config, prompt_template}`

2. `Config Layer`
   - Exposes typed getters for workflow, environment, overlay, and secret-backed values
   - Applies defaults and validation
   - Produces one effective runtime configuration

3. `Runtime Settings Overlay`
   - Stores operator-managed overrides for selected runtime fields
   - Applies on top of workflow and environment-backed values

4. `Secret Management Boundary`
   - Stores write-only secrets where supported
   - Exposes metadata without echoing secret values

5. `Tracker Adapter Layer`
   - Fetches candidate issues
   - Refreshes issue state
   - Fetches terminal issues for cleanup
   - Performs tracker writes when required

6. `Orchestrator`
   - Owns the polling loop
   - Owns in-memory runtime state
   - Decides dispatch, retry, pause, resume, stop, cleanup, and release behavior

7. `Workspace Manager`
   - Maps issues to workspace paths
   - Creates and reuses workspaces
   - Runs workspace lifecycle hooks
   - Enforces path-safety invariants

8. `Agent Runner`
   - Prepares workspace
   - Builds prompt input
   - Launches the coding-agent app-server client
   - Streams updates back to the orchestrator

9. `Observability Surface`
   - Structured logs
   - Runtime snapshots
   - Durable run artifacts
   - Human-readable dashboards or other views

10. `Operator Control Plane`
   - Approval decisions
   - Full-access overrides
   - Runtime settings changes
   - Secret entry/update/clear
   - Manual refresh/reconcile triggers
   - Device auth or equivalent runtime auth flows where implemented

### 3.3 Abstraction levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer`
   - repo-owned `WORKFLOW.md` prompt and workflow defaults

2. `Configuration Layer`
   - typed config, env resolution, overlay application, secret-backed values

3. `Coordination Layer`
   - poll loop, dispatch, retries, approvals, reconciliation

4. `Execution Layer`
   - workspace lifecycle, hook execution, app-server protocol handling

5. `Integration Layer`
   - tracker adapters, tracker writes, optional external tools

6. `Observability and Control Layer`
   - logs, audit, dashboards, operator mutations

## 4. Core domain model

### 4.1 Issue

Normalized issue record used by orchestration, prompt rendering, tracker writes, and observability.

Fields:

- `id` (string)
- `identifier` (string)
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
- `state` (string)
- `branch_name` (string or null)
- `url` (string or null)
- `labels` (list of strings; normalized to lowercase)
- `blocked_by` (list of blocker refs)
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)

### 4.2 Workflow definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
- `prompt_template` (string)

### 4.3 Effective runtime config

Typed runtime config derived from:

- base workflow front matter
- environment-backed resolution
- runtime settings overlay
- secret-backed values
- built-in defaults

### 4.4 Workspace

Filesystem workspace assigned to one issue identifier.

Logical fields:

- `path`
- `workspace_key`
- `created_now`

### 4.5 Run attempt

One execution attempt for one issue.

Fields:

- `issue_id`
- `issue_identifier`
- `attempt`
- `workspace_path`
- `started_at`
- `status`
- `error`

### 4.6 Live session

State tracked while a coding-agent subprocess/session is alive.

Fields include:

- `session_id`
- `thread_id`
- `turn_id`
- `codex_app_server_pid`
- `last_codex_event`
- `last_codex_timestamp`
- `last_codex_message`
- input/output/total token counters
- cached/uncached input token counters where available
- `turn_count`

### 4.7 Retry entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `identifier`
- `attempt`
- `due_at_ms`
- `timer_handle`
- `error`

### 4.8 Pending approval

State representing a guardrail approval request awaiting resolution.

Fields:

- `id`
- `issue_id`
- `issue_identifier`
- `run_id`
- `session_id`
- `worker_host`
- `workspace_path`
- `status`
- `action_type`
- `method`
- `summary`
- `risk_level`
- `reason`
- `fingerprint`
- `details`
- `payload`
- `requested_at`
- optional resolution metadata

### 4.9 Guardrail rule

Persisted allow/deny/review rule derived from operator policy or product defaults.

Fields:

- `id`
- `enabled`
- `scope`
- `scope_key`
- `action_type`
- `match`
- `decision`
- `constraints`
- `created_by`
- `created_at`
- `expires_at`
- `reason`

### 4.10 Override

Explicit operator override such as full-access mode.

Fields:

- `id`
- `scope`
- `scope_key`
- `enabled`
- `started_at`
- `expires_at`
- `reason`
- `created_by`

## 5. Workflow specification and runtime configuration

### 5.1 Workflow file discovery and path resolution

Workflow file path precedence:

1. explicit startup/runtime path
2. default `WORKFLOW.md` in current process working directory

Loader behavior:

- If the file cannot be read, return `missing_workflow_file`.
- The workflow file is expected to be repository-owned and version-controlled.

### 5.2 Workflow file format

`WORKFLOW.md` is a Markdown file with optional YAML front matter.

Parsing rules:

- If the file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter must decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: front matter root object
- `prompt_template`: trimmed Markdown body

### 5.3 Front matter schema

Top-level keys:

- `tracker`
- `polling`
- `workspace`
- `hooks`
- `agent`
- `codex`
- `guardrails`
- `observability`
- `server`

Unknown keys should be ignored for forward compatibility unless a stricter implementation chooses to
warn on them.

#### 5.3.1 `tracker` (object)

Required fields vary by adapter kind.

Common fields:

- `kind` (string)
- `endpoint` (string, optional)
- `active_states` (list of strings)
- `terminal_states` (list of strings)

Common auth fields:

- `api_key` (string or `$VAR_NAME`)
- `api_token` (string or `$VAR_NAME`)

Adapter-specific fields currently in scope:

- Linear:
  - `project_slug`
- Trello:
  - `board_id`
- GitHub:
  - `owner`
  - `repo`
  - `project_number`
  - `status_field_name`

Tracker field validation:

- required adapter-specific fields must be present after env/secret resolution
- empty strings after `$VAR` resolution are treated as missing

#### 5.3.2 `polling` (object)

Fields:

- `interval_ms` (integer or string integer)
  - default: `30000`

#### 5.3.3 `workspace` (object)

Fields:

- `root` (path string or `$VAR`)
  - default: `<system-temp>/symphony_workspaces`
  - `~` is expanded
  - path-like values are normalized
  - bare relative names may be preserved but are discouraged

#### 5.3.4 `hooks` (object)

Fields:

- `after_create`
- `before_run`
- `after_success` (extension, optional)
- `after_run`
- `before_remove`
- `timeout_ms`

Hook semantics:

- `after_create` runs only when a workspace directory is newly created
- `before_run` runs before each agent attempt
- `after_success` runs after a successful attempt where the implementation supports it
- `after_run` runs after each agent attempt
- `before_remove` runs before workspace deletion

`hooks.timeout_ms`:

- default: `60000`
- non-positive values are invalid and fall back to default

#### 5.3.5 `agent` (object)

Fields:

- `max_concurrent_agents`
  - default: `10`
- `max_turns`
  - default: `20`
- `max_retry_backoff_ms`
  - default: `300000`
- `max_concurrent_agents_by_state`
  - default: empty map
- `continue_on_active_issue`
  - default: implementation-defined; should be explicit in workflow examples
- `completed_issue_state`
  - optional
- `completed_issue_state_by_state`
  - optional map

#### 5.3.6 `codex` (object)

Fields:

- `command`
  - default: `codex app-server`
- `approval_policy`
- `thread_sandbox`
- `turn_sandbox_policy`
- `turn_timeout_ms`
  - default: `3600000`
- `read_timeout_ms`
  - default: `5000`
- `stall_timeout_ms`
  - default: `300000`

Policy-related fields should be treated as pass-through values compatible with the targeted
app-server version rather than a hand-maintained enum in the spec.

#### 5.3.7 `guardrails` (object)

Fields may include:

- `enabled`
- `operator_token`
- `default_review_mode`
- `builtin_rule_preset`
- `full_access_run_ttl_ms`
- `full_access_workflow_ttl_ms`

#### 5.3.8 `observability` (object)

Fields may include:

- audit enablement
- retention limits
- payload truncation/redaction settings
- token-efficiency thresholds
- tracker summary settings

#### 5.3.9 `server` (object)

Fields may include:

- `port`
- `host`

### 5.4 Prompt template contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template.

Rendering requirements:

- use a strict template engine
- unknown variables fail rendering
- unknown filters fail rendering

Template input variables:

- `issue`
- `attempt`

Optional additional prompt inputs may be documented by implementations if they are stable.

Fallback prompt behavior:

- If the prompt body is blank, the runtime may use a minimal default prompt.
- Workflow file read/parse failures must not silently fall back to an unrelated prompt.

### 5.5 Workflow validation and error surface

Error classes should include at least:

- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `template_parse_error`
- `template_render_error`

Behavior:

- workflow parse/read failures block new dispatches until fixed
- invalid reloads keep the last known good effective configuration
- prompt-template errors fail the affected run attempt

## 6. Configuration resolution and dynamic reload

### 6.1 Source precedence and resolution

Configuration precedence:

1. explicit startup path / CLI settings where applicable
2. runtime secret store where applicable
3. runtime settings overlay
4. environment indirection via `$VAR`
5. base `WORKFLOW.md`
6. built-in defaults

Value coercion semantics:

- path values support `~` expansion and env-backed resolution
- command strings remain shell command strings and should not be path-rewritten
- secret-managed values should not be echoed back after resolution

### 6.2 Overlay-eligible vs secret-managed vs bootstrap-only values

Implementations should maintain a clear allowlist:

- overlay-eligible runtime values:
  - concurrency
  - retry/turn behavior
  - selected observability thresholds
  - selected guardrail defaults
- secret-managed values:
  - GitHub token
  - tracker token where UI-managed secret storage exists
- bootstrap-only values:
  - mount paths
  - container image choice
  - process supervisor wiring

### 6.3 Dynamic reload semantics

Dynamic reload is required for `WORKFLOW.md`.

The software must:

- watch `WORKFLOW.md` for changes
- re-read and re-apply workflow config and prompt template without restart
- attempt to adjust future behavior without disturbing in-flight runs unless explicitly documented

Reloaded config applies to future:

- polling cadence
- dispatch decisions
- retry scheduling
- reconciliation decisions
- hook executions
- prompt rendering
- agent launches

Invalid reload behavior:

- do not crash
- keep last known good effective config
- emit operator-visible error

### 6.4 Dispatch preflight validation

Startup validation:

- validate required config before starting scheduler loop
- fail startup on invalid required dispatch config

Per-tick validation:

- re-validate before dispatch cycle
- if validation fails:
  - skip dispatch
  - keep reconciliation active
  - emit operator-visible error

Validation checks should include:

- workflow file can be loaded and parsed
- tracker kind is present and supported
- required tracker auth is present after resolution
- required tracker identity fields are present
- `codex.command` is present and non-empty

## 7. Orchestration state machine

The orchestrator is the only component that mutates authoritative scheduling state.

### 7.1 Internal issue orchestration states

These are internal runtime states, not tracker workflow states.

1. `Unclaimed`
2. `Claimed`
3. `Running`
4. `ApprovalPending`
5. `RetryQueued`
6. `Released`

Important nuance:

- A successful worker exit does not necessarily mean the issue is permanently done.
- A worker may continue through multiple turns inside one live session where configured.
- After a normal exit, the orchestrator may schedule a short continuation retry if the configured
  policy allows further work on still-active issues.

### 7.2 Run attempt lifecycle

A run attempt moves through logical phases such as:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `WaitingForApproval` (if guardrails pause the run)
7. `Finishing`
8. `Succeeded`
9. `Failed`
10. `TimedOut`
11. `Stalled`
12. `CanceledByReconciliation`

Distinct terminal reasons matter for retry and audit behavior.

### 7.3 Transition triggers

- poll tick
- worker exit (normal)
- worker exit (abnormal)
- app-server runtime event
- retry timer fired
- reconciliation state refresh
- stall timeout
- operator approval decision
- operator override enable/disable

### 7.4 Idempotency and recovery rules

- The orchestrator serializes scheduling state mutations through one authority.
- `claimed` and `running` checks are required before dispatch.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven.
- Durable operator artifacts may survive restart even though live worker state does not.

## 8. Polling, scheduling, and reconciliation

### 8.1 Poll loop

At startup, the service:

1. validates config
2. performs startup terminal cleanup
3. schedules an immediate tick
4. repeats every `polling.interval_ms`

Tick sequence:

1. reconcile running issues
2. reconcile pending approvals
3. run dispatch preflight validation
4. fetch candidate issues
5. sort issues by dispatch priority
6. dispatch eligible issues while slots remain
7. notify observers/control-plane subscribers of state changes

### 8.2 Candidate selection rules

An issue is dispatch-eligible only if all are true:

- has required normalized identifiers and state
- state is active and not terminal
- not already running
- not already claimed
- global concurrency slots available
- per-state concurrency slots available
- host capacity is available where host pools are used
- blocker rules pass

Recommended sort order:

1. priority ascending
2. created_at oldest first
3. identifier lexicographic tie-breaker

### 8.3 Concurrency control

Global limit:

- `max_concurrent_agents`

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present

Optional per-host limit:

- `worker.max_concurrent_agents_per_host`

### 8.4 Retry and backoff

Retry entry creation:

- cancel existing retry timer for same issue
- store attempt, identifier, error, due time, and timer handle

Backoff rules:

- continuation retries after a clean worker exit may use a short fixed delay
- failure-driven retries use exponential backoff capped by `agent.max_retry_backoff_ms`

Retry handling behavior:

1. re-fetch relevant candidate issues
2. locate the issue
3. release claim if issue is absent or ineligible
4. dispatch if still eligible and slots exist
5. otherwise requeue with explicit reason

### 8.5 Active run reconciliation

Reconciliation has two parts.

Part A: stall detection

- compute elapsed time from last runtime event or started-at
- if `elapsed_ms > codex.stall_timeout_ms`, terminate and queue retry
- if stall timeout is disabled, skip this part

Part B: tracker state refresh

- fetch current issue states for all running issue IDs
- for each running issue:
  - terminal -> stop and clean workspace
  - still active -> update in-memory snapshot
  - neither active nor terminal -> stop without cleanup
- if state refresh fails, keep workers running and try again later

### 8.6 Pending approval reconciliation

For issues paused on approvals:

- refresh tracker state on ticks
- if issue becomes terminal, cancel pending approval and release/clean up as appropriate
- if issue becomes non-active, cancel pending approval and release claim
- if issue remains active, keep approval pending

### 8.7 Startup terminal workspace cleanup

At service startup:

1. query tracker for terminal issues
2. remove matching workspaces
3. continue startup even if the terminal fetch fails, but emit warning

## 9. Workspace management and safety

### 9.1 Workspace layout

Workspace root:

- `workspace.root` after normalization

Per-issue workspace path:

- `<workspace.root>/<sanitized_issue_identifier>`

Persistence:

- workspaces are reused across runs for the same issue
- successful runs do not auto-delete workspaces by default

### 9.2 Workspace creation and reuse

Algorithm summary:

1. sanitize identifier to `workspace_key`
2. compute workspace path under workspace root
3. ensure the path exists as a directory
4. set `created_now`
5. run `after_create` only when newly created

### 9.3 Optional workspace population

The spec does not require built-in VCS bootstrap logic.

Population may happen via implementation-defined logic and/or hooks such as:

- clone
- dependency bootstrap
- sync/update

Failure handling:

- new workspace population failure may remove the partial directory
- reused workspaces should not be destructively reset unless explicitly documented

### 9.4 Workspace hooks

Supported hooks:

- `after_create`
- `before_run`
- `after_success`
- `after_run`
- `before_remove`

Execution contract:

- execute in a host-appropriate shell context
- workspace path is cwd
- hook timeout uses `hooks.timeout_ms`
- log start, timeout, and failure

Failure semantics:

- `after_create` failure/timeout is fatal to workspace creation
- `before_run` failure/timeout is fatal to current attempt
- `after_success` failure/timeout is implementation-defined but should be explicit
- `after_run` failure/timeout is logged and ignored
- `before_remove` failure/timeout is logged and ignored

### 9.5 Safety invariants

Invariant 1:

- coding-agent cwd must be the per-issue workspace path

Invariant 2:

- workspace path must remain inside workspace root

Invariant 3:

- workspace directory names use sanitized identifiers

Recommended sanitization:

- allow `[A-Za-z0-9._-]`
- replace all other characters with `_`

## 10. Agent runner protocol

### 10.1 Launch contract

Subprocess launch parameters:

- command: `codex.command`
- invocation: local shell or direct exec according to implementation
- working directory: workspace path
- stdout/stderr separated
- protocol framing: line-delimited JSON-like app-server messages on stdout

Notes:

- default command is `codex app-server`
- the launched process must speak a compatible app-server protocol over stdio

### 10.2 Session startup handshake

The client must perform the logical startup sequence:

1. `initialize`
2. `initialized`
3. `thread/start`
4. `turn/start`

Startup params must include the effective:

- client identity
- cwd
- approval policy
- sandbox / sandbox policy
- initial input
- title or equivalent issue descriptor

Session identifiers:

- read `thread_id` from `thread/start`
- read `turn_id` from `turn/start`
- compose `session_id = "<thread_id>-<turn_id>"`

### 10.3 Streaming turn processing

The client reads protocol messages until the turn terminates.

Completion conditions:

- `turn/completed`
- `turn/failed`
- `turn/cancelled`
- turn timeout
- subprocess exit

Continuation behavior:

- if configured, continuation turns reuse the same live thread
- continuation guidance should not blindly resend the original full prompt if thread history
  already contains it

Line handling:

- parse protocol messages from stdout
- buffer partial stdout lines
- treat stderr as diagnostics, not protocol

### 10.4 Emitted runtime events

The app-server client emits structured events upstream with:

- `event`
- `timestamp`
- `codex_app_server_pid` if available
- optional usage map
- event-specific payload fields

Important events may include:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `approval_required`
- `approval_auto_approved`
- `turn_input_required`
- `unsupported_tool_call`
- `notification`
- `malformed`

### 10.5 Approval, tool calls, and user input policy

Approval, sandbox, and user-input behavior are runtime policy concerns and must be documented.

Requirements:

- approval requests must not leave a run stalled indefinitely
- unsupported tool calls must fail without stalling the session
- user-input-required behavior must be explicit:
  - auto-resolve
  - surface to operator
  - fail the run

If guardrails are enabled, the runtime should be able to:

- classify approval requests
- auto-allow low-risk actions
- deny clearly
- create a pending approval for operator review
- resume after operator decision

### 10.6 Timeouts and error mapping

Timeouts:

- `codex.read_timeout_ms`
- `codex.turn_timeout_ms`
- `codex.stall_timeout_ms`

Recommended normalized error categories:

- `codex_not_found`
- `invalid_workspace_cwd`
- `response_timeout`
- `turn_timeout`
- `port_exit`
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`
- `approval_pending`
- `approval_denied`

### 10.7 Agent runner contract

The agent runner:

1. creates/reuses workspace
2. runs pre-run lifecycle
3. builds prompt
4. starts app-server session
5. forwards runtime events upstream
6. stops, pauses, retries, or succeeds according to outcome

Successful runs preserve workspaces by default.

## 11. Tracker adapter contract

### 11.1 Required operations

A conforming tracker adapter must support:

1. `fetch_candidate_issues`
2. `fetch_issues_by_states`
3. `fetch_issue_states_by_ids`
4. tracker write operations needed by the supported flow, such as:
   - `create_comment`
   - `update_issue_state`

### 11.2 Query semantics

Adapters may differ in transport details, but the normalized outputs must match the core issue model.

Typical query needs:

- candidate issues in active states
- terminal issues for cleanup
- current state refresh for running issues

### 11.3 Normalization rules

Recommended normalization:

- labels -> lowercase strings
- priorities -> integers only
- timestamps -> parsed ISO-8601 where available
- blockers -> normalized refs where tracker support exists

### 11.4 Error handling contract

Recommended categories:

- `unsupported_tracker_kind`
- `missing_tracker_auth`
- `missing_tracker_identity_field`
- adapter transport failures
- adapter payload/parse failures
- adapter semantic errors

Orchestrator behavior:

- candidate fetch failure -> skip dispatch for this tick
- state refresh failure -> keep current workers running
- terminal cleanup fetch failure -> log warning and continue startup

### 11.5 Tracker writes

Tracker writes are part of the formal runtime contract in v2.

Examples:

- comments
- status/list/field transitions
- handoff-state transitions
- blocked-on-human markers
- tracker-facing summaries

The implementation must define which writes are performed:

- by the agent through tools
- by the runtime/orchestrator
- or by a mixed model

## 12. Prompt construction and context assembly

### 12.1 Inputs

Inputs to prompt construction:

- workflow prompt template
- normalized issue object
- optional `attempt`
- optional prior run or handoff context if the implementation supports it

### 12.2 Rendering rules

- strict variable checking
- strict filter checking
- preserve nested arrays/maps for iteration
- issue object keys should be template-compatible

### 12.3 Retry and continuation semantics

`attempt` should be available because workflows may differentiate:

- first run
- continuation run
- retry after error/timeout/stall
- rework after human response

### 12.4 Failure semantics

If prompt rendering fails:

- fail the run attempt immediately
- let the orchestrator decide retry behavior

## 13. Observability, auditability, and operator control plane

### 13.1 Logging conventions

Required context for issue-related logs:

- `issue_id`
- `issue_identifier`

Required context for session lifecycle logs:

- `session_id`

Recommended logging style:

- stable `key=value` phrasing
- concise action outcome
- concise failure reason
- avoid large raw payloads unless necessary

### 13.2 Logging outputs and sinks

The spec does not prescribe a single sink.

Requirements:

- operators must be able to see startup, validation, and dispatch failures
- sink failure should not crash orchestration where possible

### 13.3 Runtime snapshot

If the implementation exposes a runtime snapshot, it should include:

- `running`
- `retrying`
- `pending_approvals`
- aggregate token/runtime totals
- latest rate limits where available

Recommended snapshot errors:

- `timeout`
- `unavailable`

### 13.4 Durable run history

Durable post-run artifacts are part of the v2 product model.

Recommended artifacts:

- one summary per run
- one append-only event stream per run
- issue-level rollups
- changed-file or diff-aware summaries where supported
- export bundles

### 13.5 Token accounting

If token metrics are exposed, distinguish at least:

- input tokens
- output tokens
- total tokens
- cached vs uncached input where available

### 13.6 Human-readable status surfaces

Human-readable surfaces are allowed and encouraged.

If present, they should derive from orchestrator/audit state and must not be required for runtime
correctness.

### 13.7 Control-plane model

The control plane is a first-class product surface.

Its responsibilities may include:

- approval inbox and decisions
- override management
- settings overlay updates
- secret management
- refresh/reconcile triggers
- device auth initiation/cancel where supported

### 13.8 Control-plane auth

Mutating operator actions must be authenticated.

The spec does not require a specific auth technology, but the implementation must document:

- how operator identity or operator token is supplied
- what happens when it is missing or invalid
- which endpoints/actions are mutating vs read-only

### 13.9 HTTP server extension

If the implementation ships an HTTP interface:

- it may expose dashboard HTML and JSON APIs
- CLI `--port` should override workflow `server.port`
- safe default bind host should be documented
- unsupported methods on defined routes should return `405`
- API errors should use a structured JSON envelope

Baseline read endpoints should cover:

- system state
- issue detail
- run detail/history
- settings/overlay views
- approval/rule/override inspection

Mutating endpoints may cover:

- refresh
- approval decisions
- rule enable/disable/expire
- override enable/disable
- settings update/reset
- secret set/clear
- device auth start/cancel

## 14. Failure model and recovery

### 14.1 Failure classes

1. workflow/config failures
2. workspace failures
3. agent session failures
4. tracker failures
5. observability/control-plane failures

### 14.2 Recovery behavior

- dispatch validation failures:
  - skip new dispatch
  - keep service alive
- worker failures:
  - convert to retries where applicable
- tracker fetch failures:
  - skip affected operation and retry later
- observability/control-plane failures:
  - do not crash orchestrator

### 14.3 Partial state recovery

The scheduler may remain intentionally in-memory.

After restart:

- retry timers are not required to be restored
- live sessions are not required to be resumed in-place
- recovery happens through:
  - startup cleanup
  - fresh polling
  - re-dispatch of eligible work
  - reload of durable operator artifacts where applicable

### 14.4 Operator intervention points

Operators can control behavior through:

- editing `WORKFLOW.md`
- runtime overlay changes
- tracker state changes
- guardrail decisions
- override changes
- service restart when required

## 15. Security and operational safety

### 15.1 Trust boundary assumption

Implementations must document whether they target:

- trusted environments
- more restrictive environments
- or both

### 15.2 Filesystem safety requirements

Mandatory:

- workspace path under workspace root
- coding-agent cwd inside issue workspace
- sanitized workspace names

Recommended:

- dedicated OS/container user
- restricted workspace permissions
- dedicated volume for workspaces where practical

### 15.3 Secret handling requirements

- support environment indirection where configured
- do not log secret values
- validate presence without printing them
- if UI-managed secret handling exists:
  - treat values as write-only
  - expose metadata only
  - audit metadata without secret disclosure

### 15.4 Hook safety

Hooks are trusted configuration.

Requirements:

- hooks run in workspace cwd
- hook output should be truncated in logs
- hook timeouts are required

### 15.5 Recommended reference posture

Recommended posture:

- Linux container runtime
- workspace-scoped write access
- network disabled by default unless explicitly allowed
- authenticated operator mutations
- explicit full-access overrides
- durable audit for operator decisions

## 16. Reference algorithms

### 16.1 Service startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  start_workflow_watch(on_change=reload_and_reapply_workflow)

  state = {
    poll_interval_ms: get_effective_poll_interval_ms(),
    max_concurrent_agents: get_effective_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    pending_approvals: {},
    guardrail_rules: load_persisted_rules(),
    guardrail_overrides: load_persisted_overrides(),
    codex_totals: empty_totals(),
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)
  event_loop(state)
```

### 16.2 Poll-and-dispatch tick

```text
on_tick(state):
  state = reconcile_running_issues(state)
  state = reconcile_pending_approvals(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  issues = tracker.fetch_candidate_issues()
  if issues failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  for issue in sort_for_dispatch(issues):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

### 16.3 Reconcile active runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

### 16.4 Dispatch one issue

```text
function dispatch_issue(issue, state, attempt):
  worker = spawn_worker(fn -> run_agent_attempt(issue, attempt, orchestrator_channel) end)

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    identifier: issue.identifier,
    issue,
    session_id: null,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker attempt

```text
function run_agent_attempt(issue, attempt, orchestrator_channel):
  workspace = workspace_manager.create_for_issue(issue.identifier)
  if workspace failed:
    fail_worker("workspace error")

  if run_hook("before_run", workspace.path) failed:
    fail_worker("before_run hook error")

  prompt = build_prompt(issue, attempt)
  if prompt failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("prompt error")

  session = app_server.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent session startup error")

  turn_result = app_server.run_turn(
    session=session,
    prompt=prompt,
    on_message=(msg) -> send(orchestrator_channel, {codex_update, issue.id, msg})
  )

  if turn_result == approval_pending:
    pause_worker_for_operator()

  if turn_result failed:
    app_server.stop_session(session)
    run_hook_best_effort("after_run", workspace.path)
    fail_worker("agent turn error")

  app_server.stop_session(session)
  run_hook_best_effort("after_run", workspace.path)
  exit_normal()
```

### 16.6 Worker exit and retry handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal and continue_on_active_issue_enabled():
    state = schedule_continuation_retry(state, issue_id, running_entry)
  else if reason != normal:
    state = schedule_failure_retry(state, issue_id, running_entry, reason)
  else:
    state.claimed.remove(issue_id)

  notify_observers()
  return state
```

## 17. Test and validation matrix

### 17.1 Workflow and config parsing

- workflow path precedence
- workflow reload detection and re-application
- invalid reload keeps last known good config
- missing workflow returns typed error
- invalid YAML/front matter returns typed error
- config defaults apply
- env-backed values resolve correctly
- overlay precedence behaves correctly
- secret-backed values override correctly where applicable
- prompt rendering is strict

### 17.2 Workspace manager and safety

- deterministic workspace path per issue identifier
- existing workspace reuse
- hook execution and timeout behavior
- workspace path containment
- sanitized workspace names
- agent cwd validation

### 17.3 Tracker adapters

- candidate fetch semantics
- state refresh semantics
- terminal fetch semantics
- normalization correctness
- error mapping
- tracker writes where supported

### 17.4 Orchestrator dispatch, reconciliation, and retry

- dispatch order
- blocker handling
- running-state reconciliation
- terminal cleanup
- non-active stop without cleanup
- retry scheduling
- backoff cap
- slot exhaustion behavior
- approval-pending pause behavior
- resume after operator decision

### 17.5 Coding-agent app-server client

- launch command and cwd behavior
- startup handshake
- read timeout
- turn timeout
- partial line buffering
- stdout/stderr separation
- approval handling
- unsupported tool behavior
- user-input-required handling
- token/rate-limit extraction

### 17.6 Observability and control plane

- structured logs include required context
- snapshot/read APIs are consistent
- mutating operator actions require auth
- durable run artifacts are produced
- approval/rule/override artifacts are audited
- settings overlay mutations are audited
- UI-managed secret operations do not echo secret values

### 17.7 CLI and host lifecycle

- explicit workflow path works
- default `./WORKFLOW.md` works
- startup failure is surfaced cleanly
- normal shutdown exits cleanly

### 17.8 Real integration profile

- valid tracker credentials and network access
- hook execution on target OS/runtime
- Docker/Linux-first path validated in the target environment
- optional HTTP/control-plane behavior validated if shipped

## 18. Conformance checklist

An implementation aligned with v2 should provide:

- workflow loader with YAML front matter and prompt body split
- typed config layer with defaults and env resolution
- runtime settings overlay support
- write-only secret handling semantics where secrets are UI-managed
- dynamic workflow reload
- generic tracker adapter contract
- tracker writes where supported flows require them
- workspace manager with lifecycle hooks and safety invariants
- app-server client with protocol handling and error mapping
- orchestrator-owned dispatch/retry/reconciliation state
- guardrail pause/resume behavior where guardrails are shipped
- structured logs
- durable run audit artifacts
- operator control plane with authenticated mutations
- documented Docker/Linux-first operational posture

## Appendix A. SSH worker extension

This appendix describes a common extension in which Symphony keeps one central orchestrator but
executes worker runs on remote hosts over SSH.

### A.1 Execution model

- orchestrator remains single source of truth
- SSH hosts provide candidate execution destinations
- workspace root is interpreted on the remote host
- coding-agent app-server is launched over SSH stdio
- continuation turns inside one worker lifetime stay on same host and workspace

### A.2 Scheduling notes

- SSH hosts may be treated as a pool
- previously used host may be preferred on retries
- per-host caps may be enforced
- when all SSH hosts are full, dispatch should wait rather than silently change execution mode

### A.3 Problems to consider

- remote environment drift
- workspace locality
- path and quoting safety
- host availability and failover semantics
