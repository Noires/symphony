# Guardrails And Operator Controls Backlog

This backlog covers the implementation plan for interactive guardrails in Symphony's Elixir runtime.
It consolidates the earlier discussions about sandboxing, approval workflows, policy rules, dashboard
interaction, "always allow" behavior, and an operator-controlled full-access mode.

## Scope

The goal is to move Symphony from "sandboxed but mostly automatic" operation to an operator-supervised
mode with:

- network disabled by default for Codex turns
- explicit approval requests for risky actions
- reusable allow rules for low-risk actions
- operator controls in the dashboard
- a temporary full-access mode that can be enabled and disabled from the dashboard
- durable audit logs for all approvals, denials, overrides, and mode changes

This backlog assumes the current tracker support stays in place for Linear, Trello, and GitHub.

## Product decisions

- Default execution profile should be safe by default:
  - `thread_sandbox: workspace-write`
  - turn sandbox rooted at the current issue workspace
  - `networkAccess: false` unless an operator-approved policy or override applies
- "Always allow" is supported, but only by creating a concrete policy rule. It must not mean
  "always allow everything forever".
- "Full access mode" is supported, but only as an explicit operator override with visible state,
  audit trail, and easy disable behavior.
- `allow_for_session` means "allow for the current run".
- Tracker mutations are not review-required by default in V1.
- Full access mode enables network as part of the override.
- Full access mode should be available in V1 both:
  - per run
  - workflow-wide
- Dashboard actions that change safety posture must be authenticated before they are shipped for
  anything beyond localhost use.

## Non-goals for the first guarded release

- full RBAC or SSO
- multi-tenant policy administration
- tracker-native approval UX
- policy sync across multiple Symphony instances
- machine-learned risk scoring
- automatic PR merge governance beyond the existing workflow hooks

## Implementation status

The backlog below is now implemented in the current Elixir runtime, with the guarded operator flow
available through:

- persistent approval, rule, and override storage under the audit backend
- runtime pause and resume for approval-driven runs
- operator APIs under `/api/v1/guardrails/*`
- dashboard controls for approval decisions, rule enable/disable/expire, and full-access toggles
- dashboard filtering for pending approvals by issue, action type, risk, worker host, and free-text query
- run-detail operator controls so blocked approvals can be resolved from the affected run page itself
- richer policy classification for shell wrappers, likely networked commands, and sensitive file paths
- dry-run approval explanations that show the effective rule or review path before a decision is applied
- run-scoped and workflow-wide full-access overrides
- guarded workflow examples and operator docs
- idempotent approval and operator actions for duplicate clicks or already-resolved state

## Historical gaps

- `AppServer` currently treats approval-required events as a blocking error instead of parking the
  run and waiting for an operator decision.
- There is no persisted approval queue or approval state machine.
- There is no policy engine that classifies commands, tool calls, file changes, or networked actions.
- The dashboard is observability-focused and does not yet act as an operator control plane.
- The current system has no first-class concept of "full access mode" beyond directly changing
  workflow config.

## Architecture overview

The guarded design should add five main pieces:

- `Guardrails.Policy`
  - classifies requested actions and resolves allow/deny/manual-review outcomes
- `Guardrails.Approvals`
  - persistent queue/state machine for pending operator approvals
- `Guardrails.Overrides`
  - persistent operator overrides including temporary full-access mode
- dashboard and API surfaces for pending approvals, decisions, policy rules, and overrides
- runtime integration so `AppServer` pauses and resumes turns instead of hard-failing on approval requests

## Action model

The approval system should work on action classes, not only raw shell commands.

Initial action types:

- `command_execution`
- `file_change`
- `dynamic_tool_call`
- `tracker_mutation`
- `network_access`
- `user_input_request`
- `landing_action`

Every approval candidate should capture:

- `issue_id`
- `issue_identifier`
- `run_id`
- `session_id`
- `worker_host`
- `workspace_path`
- action type
- normalized action fingerprint
- raw payload
- summarized human-readable description
- risk category
- suggested default decision
- timestamps

## Decision types

The operator should be able to choose:

- `allow_once`
- `allow_for_session`
- `allow_via_rule`
- `deny`

Additional operator controls:

- `enable_full_access_for_run`
- `disable_full_access_for_run`
- `enable_full_access_for_workflow`
- `disable_full_access_for_workflow`

## Policy model

The policy layer should be explicit and persisted.

Policy rule fields:

- `id`
- `enabled`
- `scope`
  - run
  - workflow
  - repository
- `action_type`
- `match`
  - executable
  - argv pattern
  - tool name
  - tracker mutation type
  - file path globs
  - network destination class
- `decision`
  - allow
  - deny
  - review
- `constraints`
  - workspace-only
  - no-network
  - max file count
  - max diff size
  - only on specific branches
- `created_by`
- `created_at`
- `expires_at`
- `reason`

Suggested built-in low-risk default rules:

- `rg`
- `git status`
- `git diff`
- `ls`
- `cat`
- repository-local test/lint/format commands inside the workspace

Suggested default review-required actions:

- any networked command
- `git push`
- merge or landing actions
- destructive file operations
- writes outside the workspace
- shell wrappers that hide the true executable
- secret, deploy, auth, CI, or infrastructure file changes

## Full access mode

Full access mode is a deliberate override, not a normal policy rule.

V1 behavior:

- can be enabled for one active run
- can be enabled workflow-wide as an explicit maintenance-mode override
- visibly changes the run state in the dashboard
- is recorded in audit logs with actor, reason, start time, and end time
- can be revoked immediately from the dashboard
- requires confirmation and reason
- should support TTL for workflow-wide mode where feasible
- run-level override expires automatically when the run ends
- workflow-wide override remains active until disabled or expired

Full access mode should modify:

- thread sandbox
- turn sandbox policy
- approval routing
- network allowance

It should not silently bypass audit logging.

## Runtime behavior

When Codex requests approval:

1. `AppServer` parses the request.
2. `Guardrails.Policy` evaluates whether the action is already allowed or denied.
3. If allowed, Symphony auto-responds and audits the event.
4. If denied, Symphony rejects the action and audits the event.
5. If review is required, Symphony stores a pending approval, marks the run as waiting, and keeps
   the session resumable.
6. The dashboard shows the pending request.
7. The operator decides.
8. Symphony resumes the blocked run with the selected decision.

This is the key runtime change: approval requests must no longer collapse into generic run failure.

## Dashboard UX

The dashboard should grow from observability into operations.

New views and controls:

- approval inbox
  - pending approvals across all runs
  - filter by issue, action type, risk, worker host
- run detail actions
  - approve once
  - approve for session
  - create allow rule
  - deny
  - enable full access for run
  - disable full access for run
- policy rules page
  - list rules
  - enable/disable
  - expire
  - inspect scope and matchers
- override status banner
  - shows when any run is operating in full access mode

Each approval card should show:

- issue identifier and tracker link
- concise action summary
- exact command or tool name
- relevant arguments
- workspace path
- affected files if known
- whether network is requested
- why the action was classified as review-required

## API surface

Add operator APIs for:

- listing pending approvals
- fetching one approval request
- approving once
- approving for session
- creating an allow rule from an approval
- denying
- enabling full access for run
- disabling full access for run
- listing rules
- updating or disabling rules
- listing active overrides

The current `/api/v1/*` observability surface is the natural starting point, but mutating endpoints
must be treated as privileged operations.

## Authentication and safety boundary

Operator actions must not be left unauthenticated if the dashboard is exposed beyond localhost.

Minimum acceptable rollout:

- localhost-only remains possible for early development
- introduce a simple operator token for mutating guardrail endpoints
- require that token for:
  - approval decisions
  - rule creation and edits
  - full-access toggles

Later improvements:

- real login
- per-operator identity
- richer audit attribution

## Audit requirements

All safety-relevant events must be persisted:

- approval requested
- policy auto-allowed
- policy auto-denied
- operator allowed once
- operator allowed for session
- operator created allow rule
- operator denied
- full access enabled
- full access disabled
- rule edited
- rule disabled
- run resumed after approval
- run remained blocked or expired waiting for approval

Every event should include actor, scope, reason, timestamps, and the normalized action fingerprint.

## Edge cases

- stale approval decision after run ended
  - decision must be rejected safely and marked stale
- duplicate operator clicks
  - decisions must be idempotent
- rule conflict
  - deny should beat allow; explicit run override should beat reusable allow rules
- session restart while approval is pending
  - pending approvals must survive process restarts
- dashboard unavailable while approval is pending
  - run remains paused, not failed
- tracker item moved to terminal state while approval is pending
  - pending approval is cancelled and audited
- operator enables full access, then run moves to another issue state
  - override remains scoped only to that run
- approval created from hidden shell wrapper
  - UI must show both wrapper and resolved executable when available
- networked tracker tools
  - host-side dynamic tools should stay separately classified from arbitrary shell network access
- after_create hooks
  - hooks remain outside per-command approval in phase 1; their risk must be clearly documented

## Rollout plan

### Phase 0: Product baseline

- document the guardrail model and the exact semantics of each decision type
- define the built-in low-risk rule set
- define both run-level and workflow-wide full-access scopes for V1
- define audit payload limits and redaction behavior

### Phase 1: Runtime foundation

- add `Guardrails.Policy`
- add `Guardrails.Approvals`
- add `Guardrails.Overrides`
- add config for:
  - guardrails enabled flag
  - operator token
  - default review mode
  - built-in rule presets
  - full-access TTL defaults
- replace "approval required means turn failure" with "approval required means pending review"

### Phase 2: Persistence and audit

- persist approval requests and decisions under the existing audit backend
- persist allow rules
- persist full-access overrides
- expose all of the above through `AuditLog`

### Phase 3: Dashboard and API

- add approval inbox page
- add run-detail approval controls
- add policy rule management page
- add override status banner
- add mutating API endpoints with operator-token checks

### Phase 4: Session resume mechanics

- ensure pending approvals can resume the exact blocked session safely
- support `allow_once` and `allow_for_session`
- support deny with clear feedback to the run and audit trail

### Phase 5: Always allow rules

- create rules from approval decisions
- validate matcher shapes
- add expiry and disable controls
- add a dry-run explanation path that shows which rule matched

### Phase 6: Full access mode

- implement run-level full-access override
- implement workflow-wide full-access override
- add dashboard toggles
- add clear visual warning state
- add workflow-wide warning banner across dashboard views
- auto-expire on run completion
- support workflow-wide disable and optional TTL expiry
- audit every transition

### Phase 7: Hardening

- tighten handling for secret, deploy, and infra paths
- add rate limiting or debounce for operator actions
- add tests for restart behavior and stale decisions
- add docs and workflow examples for guarded mode

## Acceptance criteria

The guarded mode is ready when:

- a risky command no longer fails the run immediately
- the dashboard shows a pending approval with enough context to decide
- the operator can allow once, allow for session, create an allow rule, or deny
- a blocked run resumes correctly after approval
- default network remains off for normal turns
- a run can be placed into full access mode and taken out again from the dashboard
- the workflow can be placed into and out of full access mode from the dashboard
- every approval and override action is visible in the audit trail
- the mutating control surface is protected by at least an operator token

## Suggested implementation order

1. Runtime pause/resume for approvals
2. Approval persistence and audit events
3. Mutating operator API
4. Dashboard approval inbox and controls
5. Reusable allow rules
6. Run-level and workflow-wide full access mode
7. Docs and guarded workflow examples
