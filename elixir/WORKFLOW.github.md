---
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
    - Merging
  terminal_states:
    - Done
    - Cancelled
workspace:
  root: ~/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 1
  max_turns: 20
  continue_on_active_issue: false
  completed_issue_state: Human Review
  completed_issue_state_by_state:
    Merging: Done
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a GitHub issue `{{ issue.identifier }}`.

Issue context:
- Title: {{ issue.title }}
- Current project status: {{ issue.state }}
- URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Rules:

1. Use `github_graphql` for GitHub Projects v2 reads and mutations.
2. Use `github_api` for GitHub REST endpoints when you need issue comments or other repository API calls.
3. Treat the GitHub Project v2 `Status` field as the workflow state.
4. Move the issue to `In Progress` before implementation work starts.
5. If you need more information, leave a concise issue comment explaining what is missing and move the issue to `Human Review`.
6. Move the issue to `Human Review` when code and validation are complete.
7. If review requests changes, move the issue to `Rework`.
8. When approved, move the issue to `Merging`.
