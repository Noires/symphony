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
    git_dir="$(git rev-parse --git-dir)"
    mkdir -p "$git_dir/hooks" "$git_dir/symphony"

    cat > "$git_dir/hooks/pre-push" <<'EOF'
    #!/usr/bin/env bash
    set -eu

    git_dir="$(git rev-parse --git-dir)"
    state_dir="$git_dir/symphony"
    current_branch="$(git branch --show-current 2>/dev/null || true)"
    current_state=""

    if [ -f "$state_dir/issue_state" ]; then
      IFS= read -r current_state < "$state_dir/issue_state" || true
    fi

    while read -r local_ref local_sha remote_ref remote_sha; do
      if [ "$remote_ref" = "refs/heads/main" ]; then
        if [ ! -f "$state_dir/run_active" ] || [ "$current_state" != "Merging" ] || [ "$current_branch" != "main" ]; then
          echo "Refusing push to origin/main outside an active Merging run from local main" >&2
          echo "state=${current_state:-unknown} branch=${current_branch:-detached}" >&2
          exit 1
        fi
      fi
    done
    EOF

    chmod +x "$git_dir/hooks/pre-push"
  before_run: |
    git config --global --add safe.directory "$PWD"

    branch_suffix="$(
      printf '%s' "${SYMPHONY_ISSUE_IDENTIFIER:-issue}" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cs 'a-z0-9._-' '-'
    )"
    branch_suffix="${branch_suffix#-}"
    branch_suffix="${branch_suffix%-}"

    if [ -z "$branch_suffix" ]; then
      branch_suffix="issue"
    fi

    issue_branch="symphony/${branch_suffix}"
    current_branch="$(git branch --show-current)"
    git_dir="$(git rev-parse --git-dir)"
    state_dir="$git_dir/symphony"

    mkdir -p "$state_dir"
    printf '%s\n' "$SYMPHONY_ISSUE_STATE" > "$state_dir/issue_state"
    printf '%s\n' "$issue_branch" > "$state_dir/issue_branch"
    : > "$state_dir/run_active"

    if [ "$SYMPHONY_ISSUE_STATE" = "Merging" ]; then
      if [ "$current_branch" != "main" ] && [ "$current_branch" != "$issue_branch" ]; then
        echo "Refusing merging run from branch '$current_branch'; expected '$issue_branch' or 'main'" >&2
        exit 24
      fi
    else
      if [ "$current_branch" = "$issue_branch" ]; then
        :
      elif git show-ref --verify --quiet "refs/heads/$issue_branch"; then
        git checkout "$issue_branch"
      elif [ "$current_branch" = "main" ] || [ -z "$current_branch" ]; then
        git checkout -b "$issue_branch"
      else
        echo "Refusing non-merging run from branch '$current_branch'; expected '$issue_branch'" >&2
        exit 25
      fi

      current_branch="$(git branch --show-current)"

      if [ "$current_branch" != "$issue_branch" ]; then
        echo "Refusing non-merging run from branch '$current_branch'; expected '$issue_branch'" >&2
        exit 26
      fi
    fi
  after_run: |
    git_dir="$(git rev-parse --git-dir)"
    rm -f "$git_dir/symphony/run_active" "$git_dir/symphony/issue_state"
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
6. Before `Merging`, keep all implementation work on the provisioned issue branch. Never push `main` or use `git push ... HEAD:main` outside a `Merging` run.
7. Move the issue to `Human Review` when code, validation, and branch push are complete.
8. If review requests changes, move the issue to `Rework`.
9. When approved, move the issue to `Merging`. Only in that run may you land the issue branch onto local `main` and push `origin/main`.
