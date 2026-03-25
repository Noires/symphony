# Post-Run Auditability Backlog

This backlog covers the full post-run auditability roadmap for Symphony's tracker-driven runs.

## Completed

- Persist one summary file per run with outcome, timing, tokens, workspace, tracker transition, and last Codex activity.
- Persist one append-only event log per run so completed tickets still have a durable audit trail after the worker exits.
- Expose completed run history and per-run logs through the observability API.
- Keep issue-level API payloads useful after completion by loading the latest persisted run when nothing is live anymore.
- Omit raw reasoning text deltas from persisted logs by default while still storing reasoning summaries when Codex emits them.
- Add retention controls and pruning for old run artifacts.
- Add payload-size limits and configurable redaction/truncation rules under `observability`.
- Surface recent completed runs directly in the LiveView dashboard instead of JSON-only access.
- Add workspace git metadata and changed-file summaries to completed runs.
- Record hook execution results explicitly for `before_run`, `after_success`, `after_run`, `before_remove`, and workspace cleanup.
- Add a richer dashboard drill-down for one completed run instead of linking only to JSON.
- Capture queue wait and blocked-for-human timing so efficiency discussions are based on end-to-end latency, not just Codex runtime.
- Add first-class Trello-facing end-of-run summaries generated from persisted run data.
- Add export/bundle tooling for one ticket's audit artifacts.
- Add per-run diff excerpts and file-level change previews in the drill-down view without storing full patches by default.
- Add a compact issue-level efficiency rollup in the dashboard and API using persisted runs.
- Base blocked-for-human timing on explicit tracker markers instead of inferred state transitions where tracker support exists.
- Add configurable tracker-summary templates so Trello comments can be tuned per workflow.
- Add retry, handoff, and merge-latency aggregates across runs for ongoing efficiency tracking.
- Add diff-aware summarization based on actual repo comparisons instead of just workspace status snapshots.
- Make the flat-file audit backend an explicit, surfaced product decision via `observability.audit_storage_backend`, while keeping room for a future backend if multi-host aggregation or long retention becomes a hard requirement.

## Outcome

- Post-run auditability is now durable, queryable, exportable, and visible in both API and dashboard flows.
- The supported storage backend is explicitly `flat_files`; changing that would now be a deliberate follow-up project instead of an implied TODO.
