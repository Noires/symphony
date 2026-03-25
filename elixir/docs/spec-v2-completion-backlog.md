# Spec v2 Completion Backlog

Status: Completed

This backlog tracked the concrete work needed to turn [`SPEC.md`](../../SPEC.md) into the
real primary specification for the project and retire the old root-spec flow into historical
context.

That work is now complete.

## Objective

Ship a complete `SPEC` that is:

- product-aligned with the current Elixir implementation
- detailed enough to guide future implementations
- explicit about operator control plane, runtime overlays, secrets, tracker writes, and
  Docker/Linux-first posture
- detailed enough that the archived v1 material is no longer required as a companion specification

## Outcome

`SPEC.md` now contains the missing normative detail that previously only existed in the old v1
draft, while also reflecting the current product direction.

The completed document now covers:

- workflow specification and runtime configuration
- configuration resolution and dynamic reload
- orchestration state machine
- polling, scheduling, reconciliation, retries, and cleanup
- workspace management and safety invariants
- agent runner and app-server protocol behavior
- generic tracker adapter contract and tracker writes
- prompt construction and context assembly
- observability, auditability, and first-class operator control plane behavior
- failure model, restart recovery, and operational safety
- reference algorithms
- test matrix, conformance checklist, and SSH worker extension

## Completed Workstreams

### 1. Workflow and configuration contract

Completed in `SPEC` Sections 5 and 6.

Implemented outcomes:

- explicit workflow front matter and prompt template contract
- layered config model for workflow, environment, runtime overlay, secrets, and defaults
- field categories for workflow-owned, overlay-eligible, secret-managed, and bootstrap-only values
- reload semantics, validation rules, and dispatch preflight expectations

### 2. Orchestration state machine

Completed in `SPEC` Sections 7 and 8.

Implemented outcomes:

- named orchestration states and transitions
- claim, dispatch, running, paused, retrying, and terminal behavior
- bounded concurrency and candidate selection rules
- reconciliation, restart recovery, and terminal cleanup semantics
- explicit paused-run behavior for approvals and operator intervention

### 3. Workspace and safety contract

Completed in `SPEC` Section 9.

Implemented outcomes:

- workspace creation and reuse rules
- normative containment and path-safety invariants
- hook execution behavior and timeout expectations
- Docker/Linux-first operational guidance where relevant

### 4. Agent runner and app-server protocol

Completed in `SPEC` Section 10.

Implemented outcomes:

- launch and handshake contract
- turn lifecycle and event streaming model
- timeout and error mapping behavior
- approval, denial, resume, and user-input-required handling
- full-access override and guardrail-aware protocol behavior

### 5. Tracker contract and tracker writes

Completed in `SPEC` Section 11.

Implemented outcomes:

- generic normalized tracker adapter contract
- explicit read and write responsibilities
- normalization and error-handling rules
- tracker extension tool boundaries

### 6. Prompt construction and context assembly

Completed in `SPEC` Section 12.

Implemented outcomes:

- prompt input model
- rendering and failure semantics
- continuation and retry prompt behavior
- token-efficiency-aware shaping and handoff summary allowance

### 7. Observability, auditability, and control plane

Completed in `SPEC` Section 13.

Implemented outcomes:

- read-only observability vs mutating operator control-plane split
- durable post-run audit artifacts
- runtime snapshots and API/dashboard expectations
- auth expectations for mutating operator actions
- retention and redaction guidance

### 8. Failure model, recovery, and operational safety

Completed in `SPEC` Sections 14 and 15.

Implemented outcomes:

- failure classes and recovery behavior
- restart and retry semantics
- operator intervention points
- filesystem, hook, and secret-handling safety guidance
- Docker/Linux-first safety posture

### 9. Reference algorithms

Completed in `SPEC` Section 16.

Implemented outcomes:

- startup and poll/dispatch algorithms
- reconcile-active-runs behavior
- dispatch and worker-attempt flow
- retry and worker-exit handling including approvals and tracker writes

### 10. Test matrix and conformance

Completed in `SPEC` Sections 17 and 18 and Appendix A.

Implemented outcomes:

- actionable validation matrix
- conformance checklist for future implementations
- SSH worker extension details aligned with the current product model

## Deliverables

Completed deliverables:

- expanded [`SPEC.md`](../../SPEC.md) as the single primary specification
- updated repository docs pointing readers to `SPEC.md` as the primary specification

## Definition Of Done

This backlog is complete because:

- `SPEC.md` now covers the missing normative material from the former v1 draft
- the current Elixir implementation no longer needs the old v1 text as a practical companion spec
- future project work can target `SPEC.md` directly

## Follow-up

Any further work from here is not backlog completion work anymore. It belongs in normal product,
runtime, or documentation maintenance backlogs.
