---
tracker:
  kind: trello
  board_id: $TRELLO_BOARD_ID
  active_states:
    - KI
    - In Progress
    - Rework
    - Merging
  terminal_states:
    - Done
    - Cancelled
workspace:
  root: /workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github-symphony:Noires/light-archives.git .
    cd server && yarn install --frozen-lockfile
    cd ../client && yarn install --frozen-lockfile
    cd ../news && yarn install --frozen-lockfile
agent:
  max_concurrent_agents: 1
  max_turns: 20
  continue_on_active_issue: false
  completed_issue_state: Human Review
  completed_issue_state_by_state:
    Merging: Done
codex:
  command: codex app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
guardrails:
  enabled: true
  operator_token: $SYMPHONY_OPERATOR_TOKEN
  default_review_mode: review
  builtin_rule_preset: safe
  full_access_run_ttl_ms: 3600000
  full_access_workflow_ttl_ms: 28800000
---

You are working on a Trello card `{{ issue.identifier }}`.

Card context:
- Title: {{ issue.title }}
- Current list: {{ issue.state }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Rules:

1. Use the injected `trello_api` tool for Trello reads and writes.
2. Treat the current list name as the workflow state.
3. `KI` is the intake list. Move the card to `In Progress` before implementation work starts.
4. Keep one persistent comment headed `## Codex Workpad` on the card and update it in place.
5. Do not start the backend, Redis, MariaDB, Docker Compose, or other local infrastructure unless a human explicitly changes this workflow.
6. Prefer code inspection, static changes, and validations that do not require the backend to be running locally.
7. If you need more information or approval from a human, post a Trello comment headed `## Codex Question`, update the workpad, move the card to `Human Review`, and stop.
8. Leave the card ready for `Human Review` once code, validation, and push are complete; Symphony will move it there after a successful run.
9. If review requests changes, move the card to `Rework`.
10. When approved, move the card to `Merging`. Use that run to leave the workspace ready for landing; Symphony will push from `main` to `origin/main` after a successful run and then move the card to `Done`.
