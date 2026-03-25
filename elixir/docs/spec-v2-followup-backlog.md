# SPEC v2 Follow-up Backlog

Status: Completed

This backlog covered the remaining practical follow-up work after the
[`spec-v2-conformance-review.md`](./spec-v2-conformance-review.md).

It did not reopen the `SPEC-v2` migration itself.

The current Elixir implementation was already broadly aligned with `SPEC`. This backlog tracked
the last practical follow-up items needed to close the partial gaps identified in the conformance
review.

## Objective

Close the three remaining partial-alignment areas identified in the conformance review:

1. generic write-only secret handling
2. prompt render error contract
3. explicit spec-to-test conformance traceability

That work is now complete.

## Completed work

### 1. Prompt error contract

Completed in:

- [`prompt_builder.ex`](../lib/symphony_elixir/prompt_builder.ex)
- [`core_test.exs`](../test/symphony_elixir/core_test.exs)

Outcome:

- prompt parse failures remain explicitly typed as `template_parse_error`
- prompt render failures are now explicitly typed as `template_render_error`
- workflow availability failures remain distinct as `workflow_unavailable`

### 2. Generic write-only secret handling

Completed in:

- [`secret_store.ex`](../lib/symphony_elixir/secret_store.ex)
- [`github_access.ex`](../lib/symphony_elixir/github_access.ex)
- [`secret_store_test.exs`](../test/symphony_elixir/secret_store_test.exs)

Outcome:

- the runtime now has a reusable write-only secret subsystem
- GitHub token handling now uses the shared secret subsystem
- secret metadata remains visible without echoing secret values

### 3. Explicit spec-to-test conformance mapping

Completed in:

- [`spec-v2-test-matrix.md`](./spec-v2-test-matrix.md)

Outcome:

- maintainers now have a concrete map from major `SPEC-v2` areas to the validating test files

## Definition of done

This backlog is complete because:

- the prompt error contract is explicit for both parse and render failures
- GitHub token storage now uses a reusable write-only secret subsystem
- `SPEC` now has an explicit spec-to-test traceability document
- the conformance review no longer lists these three items as open partial gaps
