# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

> [!WARNING]
> Symphony is an engineering preview for testing in trusted environments.

## What Symphony Does

Symphony is a tracker-driven orchestration service that:

- polls supported issue trackers for active work
- creates deterministic per-issue workspaces
- runs coding agents inside those workspaces
- exposes operator-facing observability and control surfaces
- preserves durable run history and audit artifacts

The Elixir implementation supports:

- Linear
- Trello
- GitHub Projects v2

It also includes a Docker/Linux-first runtime, dashboard and API surfaces, guardrails and approval
flows, runtime settings overlays, device-auth support for Codex, and post-run audit/export
capabilities.

## Choose Your Path

Symphony works best in codebases that have already adopted
[harness engineering](https://openai.com/index/harness-engineering/). It is the next step:
managing work that needs to get done instead of manually supervising coding-agent sessions.

### Option 1. Build from the spec

Use the active, product-aligned specification in [`SPEC.md`](SPEC.md) if you want to implement
Symphony in another language or adapt the architecture to your environment:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use the Elixir implementation

Use [`elixir/README.md`](elixir/README.md) for the Elixir/OTP implementation and setup
instructions. The recommended path is Docker on a Linux container runtime; host-local runs remain
available mainly for development and debugging.

You can also ask your favorite coding agent to set it up for your repository:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

Useful starting points:

- [`SPEC.md`](SPEC.md) for the product contract
- [`elixir/README.md`](elixir/README.md) for setup and runtime guidance
- [`elixir/docs/trello.md`](elixir/docs/trello.md) for Trello workflow setup
- [`elixir/docs/github.md`](elixir/docs/github.md) for GitHub Projects v2 setup
- [`elixir/docs/guardrails.md`](elixir/docs/guardrails.md) for guarded operator mode

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
