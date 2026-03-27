# GitHub Integration

Symphony can run against GitHub Issues backed by a GitHub Projects v2 board by setting `tracker.kind: github` in `WORKFLOW.md`.

## Required config

```yaml
tracker:
  kind: github
  endpoint: https://api.github.com
  api_token: $GITHUB_TOKEN
  owner: your-org
  repo: your-repo
  project_number: $GITHUB_PROJECT_NUMBER
  status_field_name: Status
  active_states:
    - KI
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Cancelled
```

Notes:

- `tracker.owner` is the owner of the GitHub Project v2 and the repository for this first pass.
- `tracker.repo` is the primary repository Symphony should work against.
- `tracker.project_number` is the visible project number from the GitHub project URL.
- `tracker.status_field_name` defaults to `Status`.
- The runtime exposes `github_graphql` and `github_api` dynamic tools when `tracker.kind: github`.

## Recommended project statuses

Minimum recommended setup:

1. `Backlog`
2. `KI`
3. `In Progress`
4. `Human Review`
5. `Rework`
6. `Done`
7. `Cancelled`

Recommended meanings:

- `Backlog`: parking lot for work that should not be picked up yet.
- `KI`: intake queue for issues that Symphony may claim.
- `In Progress`: active implementation.
- `Human Review`: waiting for human review, unblock input, or human merge of the already-open PR. Keep this state out of `active_states`.
- `Rework`: follow-up work after review feedback.
- `Done`: terminal success state.
- `Cancelled`: terminal non-success state.

## Suggested state mapping

- Active states: `KI`, `In Progress`, `Rework`
- Non-active states: `Backlog`, `Human Review`
- Terminal states: `Done`, `Cancelled`

## Recommended auth

Use a fine-grained personal access token in `GITHUB_TOKEN` with access to:

- the target repository issues
- the target GitHub Project v2
