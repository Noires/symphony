# Trello Integration

Symphony can run against a Trello board by setting `tracker.kind: trello` in `WORKFLOW.md`.

## Required config

```yaml
tracker:
  kind: trello
  endpoint: https://api.trello.com/1
  api_key: $TRELLO_API_KEY
  api_token: $TRELLO_API_TOKEN
  board_id: $TRELLO_BOARD_ID
  active_states:
    - KI
    - In Progress
    - Rework
  terminal_states:
    - Done
    - Cancelled
```

Notes:

- `tracker.board_id` is the Trello board ID Symphony should watch.
- `tracker.board_id` also falls back to `TRELLO_BOARD_ID` when unset.
- `tracker.active_states` and `tracker.terminal_states` are matched against Trello list names.
- The runtime exposes a `trello_api` dynamic tool when `tracker.kind: trello`.
- Trello list names should be unique on the watched board, because Symphony resolves state transitions by list name.
- Symphony auto-loads `.env` from the same directory as the active `WORKFLOW.md`, but
  already-exported process environment variables still win.

## Recommended board columns

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
- `KI`: intake queue for cards that Symphony may claim.
- `In Progress`: active implementation.
- `Human Review`: waiting for human review, unblock input, or human merge of the already-open PR. Keep this list out of `active_states`.
- `Rework`: follow-up work after review feedback.
- `Done`: terminal success state. With PR landing, a human typically moves the card here after the PR is merged.
- `Cancelled`: terminal non-success state.

## Suggested state mapping

- Active lists: `KI`, `In Progress`, `Rework`
- Non-active lists: `Backlog`, `Human Review`
- Terminal lists: `Done`, `Cancelled`

This matches the existing Symphony control flow:

- `KI` is the Trello equivalent of a dispatchable queue.
- `Human Review` should pause automation rather than trigger new turns, including while an attached PR waits for human review or merge.
- `Rework` remains active so Symphony can continue the loop when a card re-enters automation.
