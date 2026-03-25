defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{AuditLog, CodexAuth, Config, GitHubAccess, Orchestrator, SettingsOverlay, StatusDashboard}
  alias SymphonyElixir.Guardrails.{Overrides, Policy, Rule}

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = current_time() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        pending_approvals = Map.get(snapshot, :pending_approvals, [])
        active_guardrail_rules = Map.get(snapshot, :guardrail_rules, [])
        guardrail_overrides = Map.get(snapshot, :guardrail_overrides, [])

        all_guardrail_rules =
          case AuditLog.list_guardrail_rules(active_only: false) do
            {:ok, rules} -> rules
            _ -> []
          end

        completed_runs =
          case AuditLog.recent_runs() do
            {:ok, runs} -> runs
            _ -> []
          end

        issue_rollups =
          case AuditLog.issue_rollups() do
            {:ok, rollups} -> rollups
            _ -> []
          end

        expensive_runs = expensive_runs_slice(completed_runs)
        cheap_wins = cheap_wins_slice(completed_runs)
        settings_payload = settings_payload()
        github_access_payload = github_access_payload()
        codex_auth = CodexAuth.snapshot()

        %{
          generated_at: generated_at,
          storage_backend: AuditLog.storage_backend(),
          counts: %{
            running: length(snapshot.running),
            pending_approvals: length(pending_approvals),
            retrying: length(snapshot.retrying),
            guardrail_rules: length(all_guardrail_rules),
            active_guardrail_rules: length(active_guardrail_rules),
            active_overrides: length(guardrail_overrides),
            completed_runs: length(completed_runs),
            issue_rollups: length(issue_rollups),
            expensive_runs: length(expensive_runs),
            cheap_wins: length(cheap_wins)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          pending_approvals:
            Enum.map(
              pending_approvals,
              &pending_approval_payload(&1, active_guardrail_rules, guardrail_overrides)
            ),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          guardrail_rules: Enum.map(all_guardrail_rules, &guardrail_rule_payload/1),
          guardrail_overrides: Enum.map(guardrail_overrides, &guardrail_override_payload/1),
          completed_runs: completed_runs,
          expensive_runs: expensive_runs,
          cheap_wins: cheap_wins,
          issue_rollups: issue_rollups,
          settings_overlay: settings_payload.overlay,
          settings: settings_payload.settings,
          settings_history: settings_payload.settings_history,
          settings_error: settings_payload.error,
          github_access: github_access_payload.payload,
          github_access_error: github_access_payload.error,
          codex_auth: codex_auth,
          codex_totals: snapshot.codex_totals,
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    snapshot =
      case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
        %{} = snapshot -> snapshot
        _ -> %{running: [], pending_approvals: [], retrying: []}
      end

    running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
    pending_approval = Enum.find(Map.get(snapshot, :pending_approvals, []), &(&1.issue_identifier == issue_identifier))
    retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
    audit_runs = audit_runs(issue_identifier)

    if is_nil(running) and is_nil(pending_approval) and is_nil(retry) and audit_runs == [] do
      {:error, :issue_not_found}
    else
      {:ok,
       issue_payload_body(
         issue_identifier,
         running,
         pending_approval,
         retry,
         audit_runs,
         Map.get(snapshot, :guardrail_rules, []),
         Map.get(snapshot, :guardrail_overrides, [])
       )}
    end
  end

  @spec issue_runs_payload(String.t()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_runs_payload(issue_identifier) when is_binary(issue_identifier) do
    runs = audit_runs(issue_identifier)

    if runs == [] do
      {:error, :issue_not_found}
    else
      {:ok, %{issue_identifier: issue_identifier, runs: runs}}
    end
  end

  @spec issue_rollups_payload() :: map()
  def issue_rollups_payload do
    rollups =
      case AuditLog.issue_rollups() do
        {:ok, values} -> values
        _ -> []
      end

    %{
      storage_backend: AuditLog.storage_backend(),
      rollups: rollups
    }
  end

  @spec run_payload(String.t(), String.t()) :: {:ok, map()} | {:error, :issue_not_found}
  def run_payload(issue_identifier, run_id) when is_binary(issue_identifier) and is_binary(run_id) do
    with {:ok, run} <- AuditLog.get_run(issue_identifier, run_id) do
      rollup =
        case AuditLog.issue_rollup(issue_identifier) do
          {:ok, value} -> value
          _ -> nil
        end

      {:ok,
       %{
         issue_identifier: issue_identifier,
         storage_backend: AuditLog.storage_backend(),
         rollup: rollup,
         run: run,
         logs: %{
           codex_session_logs: run_events(issue_identifier, run_id)
         }
       }}
    else
      {:error, :not_found} ->
        {:error, :issue_not_found}
    end
  end

  @spec run_page_payload(String.t(), String.t()) :: {:ok, map()} | {:error, :issue_not_found}
  def run_page_payload(issue_identifier, run_id) when is_binary(issue_identifier) and is_binary(run_id) do
    with {:ok, run} <- AuditLog.get_run(issue_identifier, run_id),
         {:ok, events} <- AuditLog.get_run_events(issue_identifier, run_id),
         {:ok, runs} <- AuditLog.list_runs(issue_identifier, limit: 50) do
      {previous_run, next_run} = adjacent_runs(runs, run_id)

      {:ok,
       %{
         issue_identifier: issue_identifier,
         storage_backend: AuditLog.storage_backend(),
         issue_rollup:
           case AuditLog.issue_rollup(issue_identifier) do
             {:ok, value} -> value
             _ -> nil
           end,
         run: run,
         events: events,
         previous_run: previous_run,
         next_run: next_run,
         urls: %{
           dashboard: "/",
           issue_json: "/api/v1/#{issue_identifier}",
           run_json: "/api/v1/#{issue_identifier}/runs/#{run_id}",
           export_bundle: "/api/v1/#{issue_identifier}/export"
         }
       }}
    else
      {:error, :not_found} ->
        {:error, :issue_not_found}
    end
  end

  @spec run_page_payload(String.t(), String.t(), GenServer.name(), timeout()) ::
          {:ok, map()} | {:error, :issue_not_found}
  def run_page_payload(issue_identifier, run_id, orchestrator, snapshot_timeout_ms)
      when is_binary(issue_identifier) and is_binary(run_id) do
    with {:ok, payload} <- run_page_payload(issue_identifier, run_id) do
      snapshot =
        case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
          %{} = snapshot -> snapshot
          _ -> %{guardrail_overrides: [], guardrail_rules: []}
        end

      live_issue =
        case issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) do
          {:ok, issue_payload} -> issue_payload
          _ -> nil
        end

      active_overrides =
        snapshot
        |> Map.get(:guardrail_overrides, [])
        |> Enum.map(&guardrail_override_payload/1)
        |> Enum.filter(fn override ->
          override_scope = Map.get(override, :scope) || Map.get(override, "scope")
          scope_key = Map.get(override, :scope_key) || Map.get(override, "scope_key")
          override_scope == "workflow" or scope_key == run_id
        end)

      active_rules =
        snapshot
        |> Map.get(:guardrail_rules, [])
        |> Enum.map(&guardrail_rule_payload/1)
        |> Enum.filter(fn rule ->
          rule_scope = Map.get(rule, :scope) || Map.get(rule, "scope")
          scope_key = Map.get(rule, :scope_key) || Map.get(rule, "scope_key")
          rule_scope in ["workflow", "repository"] or scope_key == run_id
        end)

      {:ok,
       Map.merge(payload, %{
         live_issue: live_issue,
         pending_approval: live_issue && live_issue.pending_approval,
         active_overrides: active_overrides,
         active_rules: active_rules
       })}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  defp issue_payload_body(issue_identifier, running, pending_approval, retry, audit_runs, active_guardrail_rules, guardrail_overrides) do
    latest_run = List.first(audit_runs)
    session_logs = latest_run_logs(issue_identifier, latest_run)

    rollup =
      case AuditLog.issue_rollup(issue_identifier) do
        {:ok, value} -> value
        _ -> nil
      end

    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, pending_approval, retry, latest_run),
      storage_backend: AuditLog.storage_backend(),
      status: issue_status(running, pending_approval, retry, latest_run),
      workspace: %{
        path: workspace_path(issue_identifier, running, pending_approval, retry, latest_run),
        host: workspace_host(running, pending_approval, retry, latest_run)
      },
      attempts: %{
        restart_count: restart_count(retry, latest_run),
        current_retry_attempt: retry_attempt(retry, latest_run)
      },
      running: running && running_issue_payload(running),
      pending_approval:
        pending_approval &&
          pending_approval_payload(pending_approval, active_guardrail_rules, guardrail_overrides),
      retry: retry && retry_issue_payload(retry),
      logs: %{
        codex_session_logs: session_logs
      },
      recent_events: recent_events_payload(running, session_logs),
      last_error:
        (retry && retry.error) ||
          pending_approval_error(pending_approval) ||
          (latest_run && latest_run["last_error"]),
      latest_run: latest_run,
      rollup: rollup,
      runs: audit_runs,
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, pending_approval, retry, latest_run),
    do:
      (running && running.issue_id) ||
        (pending_approval && pending_approval.issue_id) ||
        (retry && retry.issue_id) ||
        (latest_run && latest_run["issue_id"])

  defp restart_count(retry, latest_run), do: max(retry_attempt(retry, latest_run) - 1, 0)
  defp retry_attempt(nil, nil), do: 0
  defp retry_attempt(nil, latest_run), do: (latest_run && latest_run["retry_attempt"]) || 0
  defp retry_attempt(retry, _latest_run), do: retry.attempt || 0

  defp issue_status(running, _pending_approval, _retry, _latest_run) when not is_nil(running), do: "running"
  defp issue_status(nil, pending_approval, _retry, _latest_run) when not is_nil(pending_approval), do: "awaiting_approval"
  defp issue_status(nil, nil, retry, _latest_run) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, nil, nil), do: "unknown"
  defp issue_status(nil, nil, nil, latest_run), do: latest_run["status"] || "completed"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      turn_count: Map.get(entry, :turn_count, 0),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: %{
        input_tokens: entry.codex_input_tokens,
        cached_input_tokens: Map.get(entry, :codex_cached_input_tokens, 0),
        uncached_input_tokens: Map.get(entry, :codex_uncached_input_tokens, 0),
        output_tokens: entry.codex_output_tokens,
        total_tokens: entry.codex_total_tokens
      }
    }
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: %{
        input_tokens: running.codex_input_tokens,
        cached_input_tokens: Map.get(running, :codex_cached_input_tokens, 0),
        uncached_input_tokens: Map.get(running, :codex_uncached_input_tokens, 0),
        output_tokens: running.codex_output_tokens,
        total_tokens: running.codex_total_tokens
      }
    }
  end

  defp pending_approval_payload(pending_approval, active_guardrail_rules, guardrail_overrides) do
    base = %{
      id: pending_approval.id,
      issue_id: pending_approval.issue_id,
      issue_identifier: pending_approval.issue_identifier,
      run_id: pending_approval.run_id,
      worker_host: Map.get(pending_approval, :worker_host),
      workspace_path: Map.get(pending_approval, :workspace_path),
      session_id: pending_approval.session_id,
      state: Map.get(pending_approval, :issue_state) || Map.get(pending_approval, :state),
      status: pending_approval.status,
      requested_at: pending_approval.requested_at,
      action_type: pending_approval.action_type,
      method: pending_approval.method,
      summary: pending_approval.summary,
      risk_level: pending_approval.risk_level,
      reason: pending_approval.reason,
      source: pending_approval.source,
      fingerprint: pending_approval.fingerprint,
      protocol_request_id: pending_approval.protocol_request_id,
      decision_options: pending_approval.decision_options,
      details: pending_approval.details,
      payload: Map.get(pending_approval, :payload),
      review_tags: Map.get(pending_approval.details || %{}, "review_tags") || []
    }
    explanation =
      Map.get(pending_approval, :explanation) ||
        Map.get(pending_approval, "explanation") ||
        pending_approval_explanation(base, active_guardrail_rules, guardrail_overrides)

    Map.put(base, :explanation, explanation)
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp pending_approval_error(%{status: "denied_by_policy", reason: reason}) when is_binary(reason), do: reason
  defp pending_approval_error(_pending_approval), do: nil

  defp guardrail_override_payload(override) when is_map(override), do: override

  defp guardrail_rule_payload(%Rule{} = rule) do
    rule
    |> Rule.snapshot_entry()
    |> Map.put(:active, Rule.active?(rule))
    |> Map.put(:lifecycle_state, guardrail_rule_lifecycle(rule))
    |> Map.put(:description, Rule.describe(rule))
  end

  defp guardrail_rule_payload(rule) when is_map(rule) do
    case Rule.from_snapshot(rule) do
      %Rule{} = parsed ->
        parsed
        |> Rule.snapshot_entry()
        |> Map.put(:active, Rule.active?(parsed))
        |> Map.put(:lifecycle_state, guardrail_rule_lifecycle(parsed))
        |> Map.put(:description, Rule.describe(parsed))

      _ ->
        rule
        |> Map.put(:active, false)
        |> Map.put(:lifecycle_state, "unknown")
        |> Map.put(:description, Map.get(rule, "description") || "guardrail rule")
    end
  end

  defp workspace_path(issue_identifier, running, pending_approval, retry, latest_run) do
    (running && Map.get(running, :workspace_path)) ||
      (pending_approval && Map.get(pending_approval, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (latest_run && latest_run["workspace_path"]) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, pending_approval, retry, latest_run) do
    (running && Map.get(running, :worker_host)) ||
      (pending_approval && Map.get(pending_approval, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (latest_run && latest_run["worker_host"])
  end

  defp recent_events_payload(_running, session_logs) when is_list(session_logs) and session_logs != [] do
    session_logs
    |> Enum.take(-5)
    |> Enum.map(fn event ->
      %{
        at: event["recorded_at"],
        event: event["event"],
        message: event["summary"]
      }
    end)
  end

  defp recent_events_payload(running, _session_logs) when not is_nil(running) do
    [
      %{
        at: iso8601(running.last_codex_timestamp),
        event: running.last_codex_event,
        message: summarize_message(running.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp recent_events_payload(_running, _session_logs), do: []

  defp latest_run_logs(_issue_identifier, nil), do: []

  defp latest_run_logs(issue_identifier, %{"run_id" => run_id}) when is_binary(run_id) do
    run_events(issue_identifier, run_id)
  end

  defp latest_run_logs(_issue_identifier, _latest_run), do: []

  defp run_events(issue_identifier, run_id) do
    case AuditLog.get_run_events(issue_identifier, run_id) do
      {:ok, events} -> events
      _ -> []
    end
  end

  defp audit_runs(issue_identifier) do
    case AuditLog.list_runs(issue_identifier, limit: 10) do
      {:ok, runs} -> runs
      _ -> []
    end
  end

  defp adjacent_runs(runs, run_id) when is_list(runs) and is_binary(run_id) do
    case Enum.find_index(runs, &(Map.get(&1, "run_id") == run_id)) do
      nil ->
        {nil, nil}

      index ->
        {Enum.at(runs, index + 1), Enum.at(runs, index - 1)}
    end
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp expensive_runs_slice(completed_runs) when is_list(completed_runs) do
    completed_runs
    |> Enum.filter(&(get_in(&1, ["efficiency", "classification"]) == "expensive"))
    |> Enum.sort_by(&expensive_run_sort_key/1)
    |> Enum.take(5)
  end

  defp expensive_runs_slice(_completed_runs), do: []

  defp cheap_wins_slice(completed_runs) when is_list(completed_runs) do
    completed_runs
    |> Enum.filter(&(get_in(&1, ["efficiency", "classification"]) == "cheap_win"))
    |> Enum.sort_by(&cheap_win_sort_key/1)
    |> Enum.take(5)
  end

  defp cheap_wins_slice(_completed_runs), do: []

  defp expensive_run_sort_key(run) when is_map(run) do
    uncached = get_in(run, ["tokens", "uncached_input_tokens"]) || 0
    tokens_per_changed_file = get_in(run, ["efficiency", "tokens_per_changed_file"]) || 0
    retry_attempt = Map.get(run, "retry_attempt") || 0
    ended_at = Map.get(run, "ended_at") || ""
    {-uncached, -round(tokens_per_changed_file * 100), -retry_attempt, ended_at}
  end

  defp cheap_win_sort_key(run) when is_map(run) do
    changed_file_count = get_in(run, ["efficiency", "changed_file_count"]) || 0
    total_tokens = get_in(run, ["tokens", "total_tokens"]) || 0
    ended_at = Map.get(run, "ended_at") || ""
    {-changed_file_count, total_tokens, ended_at}
  end

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    current_time()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp settings_payload do
    case SettingsOverlay.payload(history_limit: 10) do
      {:ok, payload} ->
        %{
          overlay: Map.get(payload, :overlay),
          settings: Map.get(payload, :settings, []),
          settings_history: Map.get(payload, :settings_history, []),
          error: nil
        }

      {:error, reason} ->
        %{
          overlay: %{changes: %{}},
          settings: [],
          settings_history: [],
          error: inspect(reason)
        }
    end
  end

  defp github_access_payload do
    case GitHubAccess.payload(history_limit: 10) do
      {:ok, payload} ->
        %{
          payload: payload,
          error: nil
        }

      {:error, reason} ->
        %{
          payload: %{
            generated_at: nil,
            config: %{values: %{}},
            settings: [],
            token: %{},
            history: []
          },
          error: inspect(reason)
        }
    end
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp pending_approval_explanation(pending_approval, active_guardrail_rules, guardrail_overrides)
       when is_map(pending_approval) do
    method = Map.get(pending_approval, :method) || Map.get(pending_approval, "method")
    payload = Map.get(pending_approval, :payload) || Map.get(pending_approval, "payload") || %{}
    run_id = Map.get(pending_approval, :run_id) || Map.get(pending_approval, "run_id")
    session_id = Map.get(pending_approval, :session_id) || Map.get(pending_approval, "session_id")
    workspace_path = Map.get(pending_approval, :workspace_path) || Map.get(pending_approval, "workspace_path")

    effective_rules =
      active_guardrail_rules
      |> Enum.flat_map(fn rule ->
        case Rule.from_snapshot(rule) do
          %Rule{} = parsed ->
            if Rule.applies_to_run?(parsed, run_id) and Rule.active?(parsed) do
              [parsed]
            else
              []
            end

          _ ->
            []
        end
      end)

    effective_override =
      guardrail_overrides
      |> Enum.flat_map(fn override ->
        case Overrides.from_snapshot(override) do
          %Overrides{} = parsed ->
            if Overrides.active?(parsed), do: [parsed], else: []

          _ ->
            []
        end
      end)
      |> effective_override_for_run(run_id)

    Policy.explain_approval_request(
      method || "unknown",
      payload,
      %{
        run_id: run_id,
        session_id: session_id,
        workspace_path: workspace_path,
        full_access_override: effective_override,
        guardrail_rules: effective_rules
      }
    )
  end

  defp pending_approval_explanation(_pending_approval, _active_guardrail_rules, _guardrail_overrides), do: %{}

  defp effective_override_for_run(overrides, run_id) when is_list(overrides) do
    Enum.find(overrides, fn
      %Overrides{scope: "run", scope_key: ^run_id} -> true
      _ -> false
    end) ||
      Enum.find(overrides, fn
        %Overrides{scope: "workflow"} -> true
        _ -> false
      end)
  end

  defp guardrail_rule_lifecycle(%Rule{} = rule) do
    now = current_time()

    cond do
      Rule.active?(rule) -> "active"
      match?(%DateTime{}, rule.expires_at) and DateTime.compare(rule.expires_at, now) != :gt -> "expired"
      rule.enabled == false -> "disabled"
      true -> "inactive"
    end
  end

  defp current_time do
    case Application.get_env(:symphony_elixir, :ui_visual_now) do
      %DateTime{} = value ->
        value

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, parsed, _offset} -> parsed
          _ -> DateTime.utc_now()
        end

      _ ->
        DateTime.utc_now()
    end
  end
end
