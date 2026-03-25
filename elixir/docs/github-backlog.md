# GitHub Integration Backlog

Goal: add first-class GitHub support to Symphony by targeting GitHub Issues backed by a GitHub Projects v2 board.

## Scope

- One GitHub Project v2 per workflow.
- One primary GitHub repository per workflow.
- Issue comments, state reads, state updates, and human-response detection.
- Agent-side GitHub tools for GraphQL and REST.
- Docs and workflow example for GitHub.

Out of scope for this pass:

- PR creation / merge automation as a native GitHub tracker feature.
- Multi-repo project boards.
- Webhook-driven polling replacement.
- GitHub App auth flow.

## Backlog

- [x] Add tracker config support for `tracker.kind: github`.
- [x] Add GitHub runtime validation and environment fallbacks.
- [x] Implement a GitHub client for:
  - Project v2 metadata lookup
  - Project item reads
  - Project item state updates
  - Issue comments
  - Human-response marker detection from issue comments
- [x] Implement `SymphonyElixir.GitHub.Adapter`.
- [x] Wire GitHub into the tracker adapter selector.
- [x] Add GitHub dynamic tools for Codex.
- [x] Add a GitHub workflow example and documentation.
- [x] Add automated tests for config, adapter delegation, client behavior, and dynamic tools.

## Notes

- Use GitHub Projects v2 `Status` as the Symphony workflow state source of truth.
- Use GitHub GraphQL for project metadata and status mutation.
- Use GitHub REST for issue comments.
- Keep the initial model simple: one project owner, one repo, one project number.
