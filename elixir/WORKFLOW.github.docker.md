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
  after_success: |
    if [ "$SYMPHONY_ISSUE_STATE" = "Merging" ]; then
      git config --global --add safe.directory "$PWD"

      git_dir="$(git rev-parse --git-dir)"
      state_dir="$git_dir/symphony"
      issue_branch=""
      landing_mode="${SYMPHONY_GITHUB_LANDING_MODE:-direct_merge}"
      if [ -f "$state_dir/issue_branch" ]; then
        IFS= read -r issue_branch < "$state_dir/issue_branch" || true
      fi

      current_branch="$(git branch --show-current)"
      if [ "$current_branch" != "main" ] && [ "$current_branch" != "$issue_branch" ]; then
        echo "Refusing automatic landing from branch '$current_branch'; expected '$issue_branch' or 'main'" >&2
        exit 21
      fi

      if [ -n "$(git status --porcelain)" ]; then
        echo "Refusing automatic landing with dirty working tree" >&2
        git status --short >&2
        exit 22
      fi

      case "$landing_mode" in
        direct_merge)
          git fetch origin main

          if ! git show-ref --verify --quiet refs/heads/main; then
            git checkout -b main --track origin/main
          elif [ "$current_branch" != "main" ]; then
            git checkout main
          fi

          local_main_ahead="$(git rev-list --count origin/main..main)"
          local_main_behind="$(git rev-list --count main..origin/main)"

          if [ "$local_main_ahead" -ne 0 ]; then
            echo "Refusing automatic landing: local main is ahead of origin/main by $local_main_ahead commit(s) before merge" >&2
            exit 27
          fi

          if [ "$local_main_behind" -ne 0 ]; then
            git merge --ff-only origin/main
          fi

          if [ -n "$issue_branch" ] && [ "$issue_branch" != "main" ]; then
            if ! git show-ref --verify --quiet "refs/heads/$issue_branch"; then
              echo "Refusing automatic landing: missing issue branch '$issue_branch'" >&2
              exit 28
            fi

            git merge --no-edit "$issue_branch"
          fi

          ahead_count="$(git rev-list --count origin/main..HEAD)"
          behind_count="$(git rev-list --count HEAD..origin/main)"

          if [ "$behind_count" -ne 0 ]; then
            echo "Refusing automatic landing: local main is behind origin/main by $behind_count commit(s)" >&2
            exit 23
          fi

          if [ "$ahead_count" -gt 0 ]; then
            git push origin HEAD:main
          fi
          ;;

        pull_request)
          if [ -z "$issue_branch" ] || [ "$issue_branch" = "main" ]; then
            echo "Refusing PR landing without a non-main issue branch" >&2
            exit 28
          fi

          if ! git show-ref --verify --quiet "refs/heads/$issue_branch"; then
            echo "Refusing PR landing: missing issue branch '$issue_branch'" >&2
            exit 28
          fi

          git push -u origin "$issue_branch"

          export SYMPHONY_GITHUB_PR_BRANCH="$issue_branch"

          python3 <<'PY'
          import json
          import os
          import sys
          import urllib.error
          import urllib.parse
          import urllib.request

          token = os.environ.get("GITHUB_TOKEN", "").strip()
          owner = os.environ.get("GITHUB_OWNER", "").strip()
          repo = os.environ.get("GITHUB_REPO", "").strip()
          issue_identifier = os.environ.get("SYMPHONY_ISSUE_IDENTIFIER", "").strip() or "Issue"
          branch = os.environ.get("SYMPHONY_GITHUB_PR_BRANCH", "").strip()

          if not token or not owner or not repo or not branch:
              print("Missing GitHub API context for PR landing", file=sys.stderr)
              sys.exit(29)

          base_url = f"https://api.github.com/repos/{owner}/{repo}"
          title = f"{issue_identifier}: Symphony landing PR"
          body = (
              f"Automated Symphony PR for `{issue_identifier}`.\n\n"
              f"- Source branch: `{branch}`\n"
              f"- Base branch: `main`\n"
              f"- Landing mode: `pull_request`"
          )

          headers = {
              "Authorization": f"Bearer {token}",
              "Accept": "application/vnd.github+json",
              "Content-Type": "application/json",
              "User-Agent": "symphony-after-success-hook",
          }

          def request(method, url, payload=None):
              data = None if payload is None else json.dumps(payload).encode("utf-8")
              req = urllib.request.Request(url, data=data, headers=headers, method=method)
              with urllib.request.urlopen(req) as response:
                  return json.loads(response.read().decode("utf-8"))

          query = urllib.parse.urlencode({"state": "open", "head": f"{owner}:{branch}", "base": "main"})

          try:
              pulls = request("GET", f"{base_url}/pulls?{query}")
          except urllib.error.HTTPError as exc:
              print(exc.read().decode("utf-8", "replace"), file=sys.stderr)
              sys.exit(30)

          payload = {"title": title, "body": body, "base": "main"}

          try:
              if pulls:
                  request("PATCH", f"{base_url}/pulls/{pulls[0]['number']}", payload)
              else:
                  request("POST", f"{base_url}/pulls", {**payload, "head": branch})
          except urllib.error.HTTPError as exc:
              print(exc.read().decode("utf-8", "replace"), file=sys.stderr)
              sys.exit(31)
          PY
          ;;

        *)
          echo "Unsupported GitHub landing mode '$landing_mode'" >&2
          exit 29
          ;;
      esac
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
8. Before `Merging`, keep all implementation work on the provisioned issue branch. Never push `main` or use `git push ... HEAD:main` outside a `Merging` run.
9. Leave the issue ready for `Human Review` once code, validation, and branch push are complete; Symphony will move it there after a successful run.
10. If review requests changes, move the issue to `Rework`.
11. When approved, move the issue to `Merging`. Use that run to verify the issue branch is ready to land and leave the working tree clean; Symphony will either merge the provisioned issue branch onto local `main` and push `main`, or create/update a pull request from the issue branch to `main`, depending on the configured GitHub landing mode.
12. If you need more information, approval, or missing product context from a human, do not guess. Leave an issue comment headed `## Codex Question` that states:
    - what information is missing
    - why it blocks progress
    - the smallest concrete answer or decision needed
13. When blocked on missing information, also leave a concise status comment, move the issue to `Human Review`, and stop the run without making speculative changes.
