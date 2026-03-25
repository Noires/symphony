# Spec Gap Backlog

This backlog covers the work needed to bring `SPEC.md` back into alignment with the current
Symphony Elixir product and to decide where the product has intentionally moved beyond the original
language-agnostic draft.

It is not a rewrite backlog.

The current codebase already matches the core orchestration model well enough that a from-scratch
rebuild would likely destroy useful working behavior, operator UX, and test coverage without fixing
the actual problem. The actual problem is specification drift.

## Recommendation

- Do not rebuild from scratch.
- Keep `SPEC.md` reflecting the real product.
- Keep the existing implementation and refactor incrementally where the drift revealed unclear
  boundaries.

## Implementation status

- `SPEC.md` now exists at the repository root as the active product-aligned specification.
- `SPEC.md` includes the normative detail that was previously split between the former v1 and v2
  documents, including workflow/config semantics, orchestration, workspace safety, app-server
  protocol, tracker contract, observability/control-plane behavior, failure model, reference
  algorithms, and conformance material.
- Primary repo references have been moved to `SPEC.md`.
- The concrete completion backlog is now closed in
  [spec-v2-completion-backlog.md](./spec-v2-completion-backlog.md).

## Current status

This gap backlog is effectively complete.

What remains from here is normal spec maintenance:

- keep `SPEC.md` aligned with future product changes
- keep supporting docs and implementation references in sync
- use new backlogs only for future product expansion, not for the v1-to-v2 migration itself

## What changed since the current spec

The former v1 spec presented Symphony as:

- Linear-first
- primarily a scheduler/runner with optional observability
- configured mainly through repo-owned `WORKFLOW.md`
- host/runtime-agnostic

The current Elixir product is now meaningfully broader:

- tracker support exists for Linear, Trello, and GitHub Projects v2
- the dashboard is a real operator control plane, not only passive observability
- there is a runtime settings overlay in addition to `WORKFLOW.md`
- there is write-only secret handling for GitHub access in the UI layer
- there is guardrail approval flow, persisted policy rules, and full-access overrides
- there is device-code Codex auth from the dashboard
- Docker/Linux is now the intended default runtime posture
- post-run auditability is first-class and durable

## Main drift areas

### 1. Tracker model is no longer Linear-first

The spec still says "Linear in this specification version" and treats pluggable non-Linear adapters
as future work.

Current product reality:

- Linear support exists
- Trello support exists
- GitHub Projects v2 support exists

Spec work needed:

- make tracker adapters first-class in the core spec
- keep one normalized issue model
- separate tracker transport details from normalized behavior
- treat tracker-specific tooling as extension points

### 2. Dashboard/API are now operator surfaces, not just observability

The spec is still conservative about the HTTP surface and warns against making it a required product
surface.

Current product reality:

- approvals can be decided through the dashboard/API
- full-access mode can be toggled through the dashboard/API
- settings overlays can be edited through the dashboard/API
- GitHub token/config can be managed through the dashboard/API
- Codex device auth can be started and cancelled through the dashboard/API

Spec work needed:

- split passive observability from operator mutation surfaces
- define which control-plane actions are first-class product features
- define auth requirements for mutating operator endpoints

### 3. `WORKFLOW.md` is no longer the only runtime control source

The spec strongly emphasizes repo-owned workflow policy.

Current product reality:

- `WORKFLOW.md` still matters and remains the base contract
- runtime settings overlays exist
- operator-managed GitHub access config exists
- write-only secret storage exists

Spec work needed:

- define config ownership layers explicitly
- define precedence between workflow, environment, UI-managed overlay, and write-only secrets
- keep repo-owned policy as the base, but document approved runtime overrides

### 4. Guardrails are now a first-class system

The current spec allows implementations to choose approval policy, but it does not model a rich
operator approval system.

Current product reality:

- risky actions can become pending approvals
- approvals persist and can be resumed later
- allow-rules persist
- full-access overrides exist
- approval decisions are audited

Spec work needed:

- define guardrails as either a core optional subsystem or a formal extension chapter
- describe pause/resume semantics
- describe persistent approval/rule/override state
- describe operator decision types and audit requirements

### 5. Runtime auditability is much richer than specified

The current spec mentions logs, snapshots, and token accounting, but not the current run-history
product shape.

Current product reality:

- per-run persisted summaries
- per-run event streams
- run drill-down pages
- exports/bundles
- efficiency rollups
- tracker-facing summaries

Spec work needed:

- decide whether durable run history is recommended or part of the formal product contract
- define post-run observability artifacts
- define retention/redaction expectations

### 6. Platform posture changed: Docker/Linux first

The spec is still mostly platform-neutral.

Current product reality:

- Docker/Linux is the recommended operational path
- host-local Windows is effectively fallback/best-effort

Spec work needed:

- state platform posture explicitly
- keep the spec portable, but document the reference operational profile as Linux container-first

## Backlog

## Phase 1: Define `SPEC v2` structure

- Decide whether `SPEC.md` stays one file or splits into:
  - `SPEC-core.md`
  - `SPEC-operator-control-plane.md`
  - optional tracker appendices
- Define the normative boundary between:
  - core orchestration behavior
  - optional operator/UI features
  - implementation-specific deployment choices
- Add a short product status note near the top of the spec so readers do not assume the current
  draft still matches the current Elixir product exactly.

## Phase 2: Rework system overview and goals

- Update system overview to reflect:
  - multiple tracker adapters
  - operator control plane
  - durable audit artifacts
  - settings overlay layer
  - secret-management boundary
- Revisit goals/non-goals:
  - "rich web UI" as a blanket non-goal is no longer true in the current product
  - the control plane should be described as operational, not multi-tenant/admin-heavy

## Phase 3: Rework configuration ownership and precedence

- Keep `WORKFLOW.md` as the base repo-owned contract
- Add explicit config layers:
  - workflow front matter
  - environment variables
  - runtime settings overlay
  - write-only secret store
- Define precedence and scope:
  - what applies immediately
  - what only affects future runs
  - what is bootstrap-only
- Clarify that not all runtime changes belong in the repo-owned workflow

## Phase 4: Rework tracker integration chapter

- Replace Linear-specific framing with a generic tracker adapter contract
- Keep normalized issue semantics stable
- Add tracker-specific notes as examples or appendices:
  - Linear
  - Trello
  - GitHub Projects v2
- Clarify which tracker mutations are:
  - done by the agent through tools
  - done by the orchestrator/runtime itself

## Phase 5: Rework agent runner and approval model

- Update approval semantics to include:
  - auto-approval
  - pending operator approval
  - operator deny
  - resume after decision
- Document user-input-required handling explicitly
- Describe persisted approvals/rules/overrides if guardrails are shipped
- Clarify full-access override semantics and audit expectations

## Phase 6: Rework observability into observability + control plane

- Split read-only runtime snapshot concerns from mutating operator concerns
- Document:
  - baseline read endpoints
  - optional operator mutation endpoints
  - auth/token expectations for mutation
- Add the current durable run-history/audit model as a formal recommended extension
- Clarify the role of the dashboard:
  - not required for core orchestration
  - but first-class if the implementation ships it

## Phase 7: Rework security and operational posture

- Document the actual trust/safety choices:
  - Docker/Linux-first recommendation
  - host-local fallback posture
  - sandboxing
  - operator token requirement for mutating controls
  - secret-store boundaries
- Clarify that UI-managed settings and secrets expand the trust surface and must be treated as such

## Phase 8: Rework conformance and test matrix

- Update Section 18 conformance items to reflect:
  - pluggable tracker adapters now exist
  - dynamic reload already exists
  - guardrail/operator features are optional but structured
  - durable run audit may be a recommended extension rather than core requirement
- Update the test matrix to cover:
  - tracker adapters beyond Linear
  - runtime settings overlays
  - guardrail pause/resume
  - dashboard/device auth flows if those are kept in scope

## Phase 9: Refactor implementation boundaries only where the new spec reveals confusion

This is the only code-facing phase, and only if needed.

Candidates:

- clarify the boundary between orchestrator decisions and tracker writes
- clarify the boundary between workflow config and runtime/operator overlays
- further separate read-only observability from mutating control-plane endpoints
- keep large coordination modules under control as the spec becomes clearer

This phase is intentionally incremental. It is not a reboot.

## Concrete deliverables

- `SPEC v2` outline
- updated problem statement and system overview
- updated configuration and precedence chapter
- tracker adapter contract rewritten as generic
- approval/guardrails extension chapter or section
- observability vs operator-control-plane split
- updated conformance checklist
- updated implementation/status note in `README.md`

## Product decisions

The following decisions are now fixed for `SPEC v2`:

- The operator control plane is a first-class product surface, not merely an optional extension.
- Runtime settings overlays belong in the standard runtime definition.
- UI-managed secret handling belongs in the spec and should not be left entirely implementation-defined.
- Docker/Linux-first posture is part of the standard spec guidance, not only a reference implementation note.
- Tracker writes are a formal runtime responsibility when the implementation supports tracker-driven
  handoff flows.

Implications:

- The spec should model read-only observability and mutating operator controls as separate but
  equally real parts of the product.
- The config model should explicitly include a runtime overlay layer on top of `WORKFLOW.md` and
  environment-backed values.
- Secret handling should be described as a formal subsystem with clear boundaries:
  - write-only UI semantics where applicable
  - non-echoing API behavior
  - audit metadata without secret value disclosure
  - explicit precedence relative to workflow/env/runtime config
- Docker/Linux-first guidance should be reflected in the operational posture and deployment chapters.
- Tracker write capabilities should be described as part of the formal runtime contract rather than
  being implied away into agent-only behavior.

## Done when

This backlog is done when:

- the spec no longer presents Trello/GitHub/operator-control features as if they do not exist
- the base config and operator overlay model are explicitly documented
- the control plane is described honestly instead of being implied away
- the implementation no longer feels "off-spec" just because the spec is stale
- no one reading `SPEC.md` gets the wrong product shape by default
