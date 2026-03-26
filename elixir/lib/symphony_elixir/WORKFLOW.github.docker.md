---
tracker:
  kind: github
  endpoint: https://api.github.com
  api_token: $GITHUB_TOKEN
  owner: $GITHUB_OWNER
  repo: $GITHUB_REPO
  project_number: $GITHUB_PROJECT_NUMBER
  assignee: me
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
  root: /workspaces
hooks:
  after_create: |
    repo_url="${SYMPHONY_SOURCE_REPO_URL:-https://github.com/your-org/your-repo.git}"
    git clone --depth 1 "$repo_url" .

    git config user.name "${GIT_AUTHOR_NAME:-Symphony}"
    git config user.email "${GIT_AUTHOR_EMAIL:-symphony@local.invalid}"
  after_success: |
    if [ "$SYMPHONY_ISSUE_STATE" = "Merging" ]; then
      git config --global --add safe.directory "$PWD"

      current_branch="$(git branch --show-current)"
      if [ "$current_branch" != "main" ]; then
        echo "Refusing automatic landing from branch '$current_branch'; expected 'main'" >&2
        exit 21
      fi

      if [ -n "$(git status --porcelain)" ]; then
        echo "Refusing automatic landing with dirty working tree" >&2
        git status --short >&2
        exit 22
      fi

      git fetch origin main

      ahead_count="$(git rev-list --count origin/main..HEAD)"
      behind_count="$(git rev-list --count HEAD..origin/main)"

      if [ "$behind_count" -ne 0 ]; then
        echo "Refusing automatic landing: local main is behind origin/main by $behind_count commit(s)" >&2
        exit 23
      fi

      if [ "$ahead_count" -gt 0 ]; then
        git push origin HEAD:main
      fi
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 20
  continue_on_active_issue: false
  completed_issue_state: Human Review
  completed_issue_state_by_state:
    Merging: Done
guardrails:
  operator_token: $SYMPHONY_OPERATOR_TOKEN
codex:
  command: codex app-server
server:
  host: 0.0.0.0
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

This Docker workflow uses the container as the execution boundary. Do not rely on Codex approval or full-access controls inside the run; use workflow state changes such as `Human Review` and `Merging` instead.

Rules:

1. Use `github_graphql` for GitHub Projects v2 reads and mutations.
2. Use `github_api` for GitHub REST endpoints when you need issue comments or repository API calls.
3. Treat the GitHub Project v2 `Status` field as the workflow state.
4. Move the issue to `In Progress` before implementation work starts.
5. Keep issue comments concise and operational.
6. Do not start the backend, Docker Compose, databases, or other local infrastructure unless a human explicitly changes this workflow.
7. Prefer code inspection, static changes, and validations that do not require backend services to be running locally.
8. Leave the issue ready for `Human Review` once code, validation, and push are complete; Symphony will move it there after a successful run.
9. If review requests changes, move the issue to `Rework`.
10. When approved, move the issue to `Merging`. Use that run to leave the workspace ready for landing; Symphony will push from `main` to `origin/main` after a successful run and then move the issue to `Done`.
11. If you need more information, approval, or missing product context from a human, do not guess. Leave an issue comment headed `## Codex Question` that states:
    - what information is missing
    - why it blocks progress
    - the smallest concrete answer or decision needed
12. When blocked on missing information, also leave a concise status comment, move the issue to `Human Review`, and stop the run without making speculative changes.
