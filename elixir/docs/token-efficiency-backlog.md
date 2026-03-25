# Token Efficiency Backlog

This backlog covers the work needed to make Symphony measurably more token-efficient and easier to
reason about from both product and operator perspectives.

## Scope

The goal is not only to reduce token usage, but to make token usage understandable enough that
"efficient" and "wasteful" have operational meaning.

This backlog covers:

- better token accounting and reporting
- better measurement of cached vs uncached context
- prompt and workflow changes that reduce repeated context spend
- better run-to-run continuity so rework cycles do not rediscover the same repository state
- dashboard and API surfaces that let operators spot expensive patterns

## Current gaps

- The runtime exposes `input_tokens`, `output_tokens`, and `total_tokens`, but not
  `cached_input_tokens`, so a high total does not cleanly map to poor efficiency.
- Persisted runs do not currently show enough "prompt cost shape" information to explain why one run
  was expensive and another was cheap.
- Fresh runs still restart from the full workflow prompt and tracker context.
- Rework or follow-up runs do not get a compact system-generated handoff summary.
- Dashboard rollups show totals, but not practical ratios such as tokens per changed file or tokens
  per successful run.
- Operators have no first-class alerting for "this run is unusually expensive for what it changed."

## Product decisions

- Measurement comes before optimization. We should not aggressively trim prompts before we can
  distinguish true waste from normal context-window behavior.
- `cached_input_tokens` should be surfaced alongside raw input/output/total numbers wherever the
  upstream protocol provides enough information.
- "Efficiency" should be reported as ratios and outcomes, not only raw token totals.
- Prompt reductions must preserve reliability. We should prefer structured handoff summaries and
  tracker-aware context trimming over blind prompt shortening.
- Workflow authors should be able to opt into stricter prompt compaction later, but V1 should not
  silently change existing task instructions.

## Metrics model

Per run, Symphony should eventually expose:

- `input_tokens`
- `cached_input_tokens`
- `uncached_input_tokens`
- `output_tokens`
- `total_tokens`
- `turn_count`
- `duration_ms`
- `queue_wait_ms`
- `changed_file_count`
- `successful_tracker_transition`
- `prompt_chars`
- `issue_description_chars`
- `workflow_prompt_chars`
- `continuation_turn_count`

Derived efficiency metrics:

- tokens per changed file
- uncached input tokens per changed file
- tokens per successful run
- tokens per review cycle
- tokens per minute of runtime
- tokens per merge completion
- retry token overhead

## Architecture overview

The work should land in four layers:

- accounting
  - extract and persist richer token fields from Codex events
- prompt shaping
  - reduce repeated prompt material and tracker/body overhead
- continuity
  - feed compact previous-run handoff context into follow-up runs
- observability
  - show token efficiency in dashboard, run detail, and issue rollups

## Proposed implementation phases

### Phase 1: Truthful accounting

- Status: done
- extend token extraction to capture `cached_input_tokens` where available
- persist prompt-shape metadata per run:
  - workflow prompt size
  - rendered prompt size
  - issue body size
  - continuation turn count
- distinguish:
  - total input
  - cached input
  - uncached input
- add API fields so this data is visible outside raw event inspection

### Phase 2: Better cost attribution

- Status: done
- add run-summary fields for:
  - prompt size
  - tracker payload size
  - changed-file count
  - retry attempt count
- add issue rollup metrics:
  - total cached input
  - total uncached input
  - avg uncached input per run
  - avg tokens per changed file
- add dashboard labels that separate:
  - "high total because of context window"
  - "high uncached input"

### Phase 3: Prompt compaction

- Status: done
- add prompt-shaping helpers in the prompt builder
- trim or summarize very long issue descriptions before rendering them into the first-turn prompt
- support a configurable maximum issue-body size for prompt inclusion
- optionally include only the most useful tracker context in V1:
  - title
  - identifier
  - normalized state
  - compact description summary
- keep the full tracker body available in tools or audit if needed, but not always in the base prompt

### Phase 4: Run-to-run continuity

- Status: done
- generate a compact handoff summary when a run ends:
  - what changed
  - what remains
  - what validation already ran
  - where the agent got blocked
- feed that handoff into the next run for:
  - `Rework`
  - resumed guarded approvals
  - follow-up active-state runs if continuation is enabled again later
- avoid rediscovering obvious repo state from scratch when the same workspace is reused

### Phase 5: Efficiency surfaces

- Status: done
- show cached vs uncached input in dashboard metrics
- add "expensive runs" and "cheap wins" slices to the dashboard
- extend run detail with:
  - prompt-cost section
  - cached/uncached split
  - tokens per changed file
- extend issue rollups with efficiency flags:
  - high retry overhead
  - high uncached input with low code output
  - repeated expensive rework loops

### Phase 6: Controls and safeguards

- Status: done
- add workflow config for prompt compaction limits
- add optional issue-description truncation/summarization limits
- add alerts or badges when runs exceed configurable thresholds:
  - uncached input budget
  - tokens per changed file
  - retries above threshold
- keep thresholds advisory first; do not hard-fail runs in V1

## Candidate config additions

Possible future workflow knobs:

- `observability.token_efficiency_enabled`
- `agent.max_issue_description_prompt_chars`
- `agent.include_full_issue_description_in_prompt`
- `agent.handoff_summary_enabled`
- `observability.expensive_run_uncached_input_threshold`
- `observability.expensive_run_tokens_per_changed_file_threshold`

These should be added only when the underlying behavior is implemented, not preemptively.

## Edge cases

- Upstream token payload includes `total_tokens` but not cached input:
  - keep reporting available data, mark cached split as unavailable
- A run changes zero files but is still valid:
  - ratios like tokens per changed file should not divide by zero; show `n/a`
- Very short runs with huge context windows:
  - avoid calling them inefficient based on total tokens alone
- Rework runs that intentionally revisit many files:
  - compare against changed-file count and retry context before flagging waste
- Prompt truncation removes essential product detail:
  - keep truncation conservative and auditable
- Guardrail pauses split a run awkwardly:
  - handoff continuity should preserve the same run context where possible

## Acceptance criteria

This backlog is done when:

- Symphony surfaces cached vs uncached input wherever the data exists
- per-run summaries show enough prompt-shape metadata to explain large token usage
- dashboard and run detail show at least one actionable efficiency ratio, not only totals
- follow-up runs can consume a compact previous-run handoff summary
- long ticket descriptions no longer automatically bloat the base prompt without limits
- operators can identify expensive runs from the dashboard without reading raw logs

## Suggested implementation order

1. Truthful accounting and persisted token-shape metadata
2. Dashboard/API surfacing for cached vs uncached input
3. Run handoff summaries for follow-up work
4. Prompt compaction controls for issue descriptions
5. Efficiency ratios and expensive-run flags
6. Advisory thresholds and workflow controls

## Current progress

Implemented in the current codebase:

- cached vs uncached input accounting in live runtime totals and persisted run summaries
- prompt-shape metadata for first-turn prompts
- optional prompt compaction via `agent.max_issue_description_prompt_chars`
- optional prompt continuity via `agent.handoff_summary_enabled`
- issue-rollup metrics for uncached input and tokens-per-changed-file
- dashboard and run-detail surfacing for the new token-efficiency fields
- tracker payload size attribution beyond description/prompt sizing
- advisory thresholds for uncached input, tokens per changed file, and retry overhead
- persisted efficiency classifications and flags on runs and issue rollups
- dashboard slices for expensive runs and cheap wins
- run-detail posture badges and issue-rollup efficiency signals

Remaining backlog items: none
