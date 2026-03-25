# Guardrails

Symphony can run in an operator-supervised mode where risky Codex actions pause for review instead of
failing the run or auto-approving everything.

## What guarded mode does

When guarded mode is enabled:

- Codex turns still default to a workspace-scoped sandbox
- risky approval requests become pending operator decisions
- operators can decide `allow_once`, `allow_for_session`, `allow_via_rule`, or `deny`
- operators can enable or disable full access:
  - for one run
  - workflow-wide
- operators can explain pending approvals before deciding
- operators can enable, disable, or expire persisted rules
- approvals, rules, and overrides are persisted under the audit backend

Current operator controls are available in:

- the dashboard at `/`
- the run detail page at `/runs/:issue_identifier/:run_id`
- JSON endpoints under `/api/v1/guardrails/*`

## Required workflow config

Add a `guardrails` section and stop forcing `approval_policy: never`.

```yaml
guardrails:
  enabled: true
  operator_token: $SYMPHONY_OPERATOR_TOKEN
  default_review_mode: review
  builtin_rule_preset: safe
  full_access_run_ttl_ms: 3600000
  full_access_workflow_ttl_ms: 28800000

codex:
  command: codex app-server
  approval_policy: on-request
  thread_sandbox: workspace-write
```

Recommended environment variable:

```bash
export SYMPHONY_OPERATOR_TOKEN=replace-me
```

## Operator decisions

Pending approvals appear in the dashboard with enough context to decide:

- issue identifier
- action summary
- approval method
- risk level
- fingerprint
- workspace path
- shell wrapper / network / sensitive-path hints when available

The dashboard approval inbox can be filtered by:

- issue identifier
- action type
- risk level
- worker host
- free-text query across summary, fingerprint, command, and path details

Available decisions:

- `allow_once`
- `allow_for_session`
- `allow_via_rule`
- `deny`

`allow_via_rule` creates a persisted rule from the approval fingerprint.

## Full access mode

Full access is an explicit operator override.

Behavior:

- enables network for the affected run or workflow
- switches the run to full-access sandbox settings
- is visible in the dashboard
- is persisted in audit storage
- run-level full access expires automatically when the run ends
- workflow-wide full access stays active until disabled or expired

## API examples

List pending approvals:

```bash
curl http://127.0.0.1:4000/api/v1/guardrails/approvals
```

Filter approvals:

```bash
curl "http://127.0.0.1:4000/api/v1/guardrails/approvals?issue_identifier=TR-44&risk_level=high&q=git%20push"
```

Approve once:

```bash
curl -X POST \
  -H "x-operator-token: $SYMPHONY_OPERATOR_TOKEN" \
  -d "decision=allow_once" \
  http://127.0.0.1:4000/api/v1/guardrails/approvals/approval-123/decide
```

Create an always-allow rule:

```bash
curl -X POST \
  -H "x-operator-token: $SYMPHONY_OPERATOR_TOKEN" \
  -d "decision=allow_via_rule" \
  -d "scope=workflow" \
  http://127.0.0.1:4000/api/v1/guardrails/approvals/approval-123/decide
```

Enable workflow-wide full access:

```bash
curl -X POST \
  -H "x-operator-token: $SYMPHONY_OPERATOR_TOKEN" \
  http://127.0.0.1:4000/api/v1/guardrails/overrides/workflow/enable
```

Disable a rule:

```bash
curl -X POST \
  -H "x-operator-token: $SYMPHONY_OPERATOR_TOKEN" \
  http://127.0.0.1:4000/api/v1/guardrails/rules/rule-123/disable
```

Explain a pending approval:

```bash
curl http://127.0.0.1:4000/api/v1/guardrails/approvals/approval-123/explain
```

Enable a persisted rule again:

```bash
curl -X POST \
  -H "x-operator-token: $SYMPHONY_OPERATOR_TOKEN" \
  http://127.0.0.1:4000/api/v1/guardrails/rules/rule-123/enable
```

Expire a rule immediately:

```bash
curl -X POST \
  -H "x-operator-token: $SYMPHONY_OPERATOR_TOKEN" \
  http://127.0.0.1:4000/api/v1/guardrails/rules/rule-123/expire
```

List only workflow-scoped rules:

```bash
curl "http://127.0.0.1:4000/api/v1/guardrails/rules?scope=workflow&active_only=true"
```

List active run overrides:

```bash
curl "http://127.0.0.1:4000/api/v1/guardrails/overrides?scope=run"
```

## Audit storage

Guardrail artifacts are stored under the same audit root as run summaries:

- `audit/guardrails/approvals/*.json`
- `audit/guardrails/rules/*.json`
- `audit/guardrails/overrides/*.json`

Run-linked guardrail events are also written into the normal per-run `events.jsonl` stream.
