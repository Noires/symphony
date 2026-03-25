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
  root: "C:\\Users\\dusti\\Sources\\light-archives-symphony"
hooks:
  after_create: |
    git clone --depth 1 git@github-symphony:Noires/light-archives.git .
    cd server && yarn install --frozen-lockfile
    cd ../client && yarn install --frozen-lockfile
    cd ../news && yarn install --frozen-lockfile
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
codex:
  command: '"C:\Users\dusti\.vscode\extensions\openai.chatgpt-26.318.11754-win32-x64\bin\windows-x86_64\codex.exe" app-server'
  approval_policy: never
  thread_sandbox: workspace-write
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
5. Do not start the backend, Redis, MariaDB, Docker Compose, or other local infrastructure for now unless a human explicitly changes this workflow.
6. Prefer code inspection, static changes, and validations that do not require the backend to be running locally.
7. Leave the card ready for `Human Review` once code, validation, and push are complete; Symphony will move it there after a successful run.
8. If review requests changes, move the card to `Rework`.
9. When approved, move the card to `Merging`. Use that run to leave the workspace ready for landing; Symphony will push from `main` to `origin/main` after a successful run and then move the card to `Done`.
10. If you need more information, approval, or missing product context from a human, do not guess. Post a Trello comment headed `## Codex Question` that states:
    - what information is missing
    - why it blocks progress
    - the smallest concrete answer or decision needed
11. When blocked on missing information, also update `## Codex Workpad` to show that you are blocked, move the card to `Human Review`, and stop the run without making speculative changes.
