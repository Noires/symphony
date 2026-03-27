---
tracker:
  kind: trello
  board_id: $TRELLO_BOARD_ID
  active_states:
    - KI
    - In Progress
    - Rework
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
4. Keep one persistent comment headed `## Codex Workpad` on the card and update it in place. Add a card comment with `POST /cards/{cardId}/actions/comments` and `text`; edit an existing comment action with `PUT /actions/{actionId}` and `text`. If Symphony gives you an existing workpad action id in the prompt, update that action directly instead of listing card actions again.
5. Do not start the backend, Redis, MariaDB, Docker Compose, or other local infrastructure unless a human explicitly changes this workflow.
6. Prefer code inspection, static changes, and validations that do not require the backend to be running locally.
7. If you need more information or approval from a human, post a Trello comment headed `## Codex Question`, update the workpad, move the card to `Human Review`, and stop.
8. A successful implementation or rework run must leave the issue branch pushed and the pull request created or updated; Symphony then moves the card to `Human Review`.
9. If review requests changes, move the card to `Rework`.
10. Human reviewers merge the pull request themselves and move the card to `Done` after merge.
