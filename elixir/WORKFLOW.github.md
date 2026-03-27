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
  terminal_states:
    - Done
    - Cancelled
workspace:
  root: ~/symphony-workspaces
hooks:
  after_create: |
    git clone --depth 1 git@github.com:your-org/your-repo.git .
    git_dir="$(git rev-parse --git-dir)"
    mkdir -p "$git_dir/hooks"

    cat > "$git_dir/hooks/pre-push" <<'EOF'
    #!/usr/bin/env bash
    set -eu

    while read -r local_ref local_sha remote_ref remote_sha; do
      if [ "$remote_ref" = "refs/heads/main" ]; then
        echo "Refusing push to origin/main from a Symphony workspace; human reviewers merge pull requests outside the workspace" >&2
        exit 1
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
    current_branch="$(git branch --show-current 2>/dev/null || true)"

    if [ "$current_branch" = "$issue_branch" ]; then
      :
    elif git show-ref --verify --quiet "refs/heads/$issue_branch"; then
      git checkout "$issue_branch"
    elif [ "$current_branch" = "main" ] || [ -z "$current_branch" ]; then
      git checkout -b "$issue_branch"
    else
      echo "Refusing run from branch '$current_branch'; expected '$issue_branch'" >&2
      exit 25
    fi

    current_branch="$(git branch --show-current)"

    if [ "$current_branch" != "$issue_branch" ]; then
      echo "Refusing run from branch '$current_branch'; expected '$issue_branch'" >&2
      exit 26
    fi
  after_success: |
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

    if [ "$current_branch" != "$issue_branch" ]; then
      echo "Refusing PR publication from branch '$current_branch'; expected '$issue_branch'" >&2
      exit 21
    fi

    if [ -n "$(git status --porcelain)" ]; then
      echo "Refusing PR publication with dirty working tree" >&2
      git status --short >&2
      exit 22
    fi

    git fetch origin main
    ahead_count="$(git rev-list --count origin/main..HEAD)"

    git push -u origin "$issue_branch"
    export SYMPHONY_GITHUB_PR_BRANCH="$issue_branch"
    export SYMPHONY_GITHUB_AHEAD_COUNT="$ahead_count"

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
    ahead_count = int(os.environ.get("SYMPHONY_GITHUB_AHEAD_COUNT", "0") or "0")

    if not token or not owner or not repo or not branch:
        print("Missing GitHub API context for PR publication", file=sys.stderr)
        sys.exit(29)

    base_url = f"https://api.github.com/repos/{owner}/{repo}"
    title = f"{issue_identifier}: Symphony PR"
    body = (
        f"Automated Symphony PR for `{issue_identifier}`.\n\n"
        f"- Source branch: `{branch}`\n"
        f"- Base branch: `main`\n"
        f"- Merge owner: human reviewer"
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
        elif ahead_count > 0:
            request("POST", f"{base_url}/pulls", {**payload, "head": branch})
        else:
            print("No commits ahead of origin/main; skipping PR creation", file=sys.stderr)
    except urllib.error.HTTPError as exc:
        print(exc.read().decode("utf-8", "replace"), file=sys.stderr)
        sys.exit(31)
    PY
agent:
  max_concurrent_agents: 1
  max_turns: 20
  continue_on_active_issue: false
  completed_issue_state: Human Review
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
6. Keep all implementation work on the provisioned issue branch. Never push `main` or use `git push ... HEAD:main` from the workspace.
7. A successful implementation or rework run must leave the issue branch pushed and the pull request created or updated; Symphony then moves the issue to `Human Review`.
8. If review requests changes, move the issue to `Rework`.
9. Human reviewers merge the pull request themselves and move the issue to `Done` after merge.
