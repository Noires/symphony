defmodule SymphonyElixir.AuditLog do
  @moduledoc """
  Persists per-run audit summaries and event logs for post-run inspection.
  """

  require Logger

  alias SymphonyElixir.{Config, Guardrails.Approvals, Guardrails.Overrides, Guardrails.Rule, LogFile, StatusDashboard}
  alias SymphonyElixir.Linear.Issue

  @default_run_limit 20
  @default_dashboard_runs 8
  @default_issue_rollup_limit 8
  @default_event_limit 200
  @default_max_string_length 4_000
  @default_max_list_items 50
  @default_redact_keys ["api_key", "api_token", "token", "secret", "password", "authorization", "cookie", "auth"]
  @default_storage_backend "flat_files"
  @default_expensive_run_uncached_input_threshold 8_000
  @default_expensive_run_tokens_per_changed_file_threshold 4_000
  @default_expensive_run_retry_attempt_threshold 2
  @redacted_value "[REDACTED]"
  @template_render_opts [strict_variables: true, strict_filters: true]

  @spec start_run(Issue.t(), keyword()) :: :ok
  def start_run(%Issue{} = issue, opts \\ []) do
    if audit_enabled?() do
      with {:ok, run_id} <- fetch_run_id(opts),
           started_at <- Keyword.get(opts, :started_at, DateTime.utc_now()) do
        timing =
          opts
          |> Keyword.get(:timing, %{})
          |> sanitize_optional_map()

        summary =
          base_summary(
            issue,
            run_id,
            started_at,
            Keyword.get(opts, :retry_attempt, 0),
            Keyword.get(opts, :worker_host),
            Keyword.get(opts, :workspace_path),
            timing
          )

        event = %{
          "kind" => "run_lifecycle",
          "event" => "run_started",
          "recorded_at" => iso8601(started_at),
          "summary" => "run started",
          "details" => %{
            "issue_state" => issue.state,
            "retry_attempt" => summary["retry_attempt"],
            "worker_host" => summary["worker_host"],
            "workspace_path" => summary["workspace_path"]
          }
        }

        persist_update(run_context(issue.identifier, run_id), summary, event, replace?: true)
      else
        :error ->
          :ok
      end
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("start run", issue.identifier, exception)
      :ok
  end

  @spec resume_run(Issue.t(), String.t(), keyword()) :: :ok
  def resume_run(%Issue{} = issue, run_id, opts \\ []) when is_binary(run_id) do
    if audit_enabled?() do
      resumed_at = Keyword.get(opts, :resumed_at, DateTime.utc_now())

      summary_updates =
        %{
          "status" => "running",
          "next_action" => nil,
          "last_error" => nil,
          "resumed_at" => iso8601(resumed_at),
          "worker_host" => Keyword.get(opts, :worker_host),
          "workspace_path" => Keyword.get(opts, :workspace_path),
          "pending_approval" => nil
        }
        |> drop_nil_map_values()

      event = %{
        "kind" => "run_lifecycle",
        "event" => "run_resumed_after_approval",
        "recorded_at" => iso8601(resumed_at),
        "summary" => "run resumed after operator approval",
        "details" =>
          sanitize_value(%{
            "issue_state" => issue.state,
            "approval_id" => Keyword.get(opts, :approval_id),
            "decision" => Keyword.get(opts, :decision),
            "decision_scope" => Keyword.get(opts, :decision_scope)
          })
      }

      persist_update(run_context(issue.identifier, run_id), summary_updates, event)
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("resume run", issue.identifier, exception)
      :ok
  end

  @spec record_runtime_info(map(), map()) :: :ok
  def record_runtime_info(running_entry, runtime_info) when is_map(runtime_info) do
    if audit_enabled?() do
      with {:ok, context} <- run_context_from_entry(running_entry) do
        recorded_at = Map.get(runtime_info, :recorded_at) || Map.get(runtime_info, "recorded_at") || DateTime.utc_now()

        summary_updates =
          %{
            "worker_host" => runtime_value(runtime_info[:worker_host]),
            "workspace_path" => runtime_value(runtime_info[:workspace_path])
          }
          |> drop_nil_map_values()

        event =
          if summary_updates == %{} do
            nil
          else
            %{
              "kind" => "worker_runtime",
              "event" => "runtime_updated",
              "recorded_at" => iso8601(recorded_at),
              "summary" => runtime_update_summary(summary_updates),
              "details" => sanitize_value(summary_updates)
            }
          end

        persist_update(context, summary_updates, event)
      else
        :error -> :ok
      end
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("record runtime info", Map.get(running_entry, :identifier), exception)
      :ok
  end

  @spec record_codex_update(map(), map()) :: :ok
  def record_codex_update(running_entry, update) when is_map(running_entry) and is_map(update) do
    if audit_enabled?() do
      with {:ok, context} <- run_context_from_entry(running_entry) do
        summary_updates =
          %{
            "worker_host" => runtime_value(Map.get(running_entry, :worker_host)),
            "workspace_path" => runtime_value(Map.get(running_entry, :workspace_path)),
            "session_id" => runtime_value(Map.get(running_entry, :session_id)),
            "turn_count" => Map.get(running_entry, :turn_count, 0),
            "continuation_turn_count" => max(Map.get(running_entry, :turn_count, 0) - 1, 0),
            "tokens" => %{
              "input_tokens" => Map.get(running_entry, :codex_input_tokens, 0),
              "cached_input_tokens" => Map.get(running_entry, :codex_cached_input_tokens, 0),
              "uncached_input_tokens" => uncached_input_tokens(running_entry),
              "output_tokens" => Map.get(running_entry, :codex_output_tokens, 0),
              "total_tokens" => Map.get(running_entry, :codex_total_tokens, 0)
            }
          }
          |> drop_nil_map_values()

        event = %{
          "kind" => "codex",
          "event" => event_name(Map.get(update, :event)),
          "recorded_at" => iso8601(Map.get(update, :timestamp) || DateTime.utc_now()),
          "summary" => codex_event_summary(running_entry, update),
          "session_id" => runtime_value(Map.get(running_entry, :session_id) || Map.get(update, :session_id)),
          "details" => sanitize_event_details(update)
        }

        persist_update(context, summary_updates, event)
      else
        :error -> :ok
      end
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("record codex update", Map.get(running_entry, :identifier), exception)
      :ok
  end

  @spec record_workspace_metadata(map(), map()) :: :ok
  def record_workspace_metadata(running_entry, metadata) when is_map(running_entry) and is_map(metadata) do
    if audit_enabled?() do
      with {:ok, context} <- run_context_from_entry(running_entry) do
        recorded_at = Map.get(metadata, :recorded_at) || Map.get(metadata, "recorded_at") || DateTime.utc_now()
        metadata = Map.drop(metadata, [:recorded_at, "recorded_at"])
        sanitized_metadata = sanitize_value(metadata)

        summary_updates =
          %{
            "workspace_metadata" => sanitized_metadata
          }
          |> drop_nil_map_values()

        event = %{
          "kind" => "workspace",
          "event" => "workspace_metadata_captured",
          "recorded_at" => iso8601(recorded_at),
          "summary" => workspace_metadata_summary(metadata),
          "details" => sanitized_metadata
        }

        persist_update(context, summary_updates, event)
      else
        :error -> :ok
      end
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("record workspace metadata", Map.get(running_entry, :identifier), exception)
      :ok
  end

  @spec record_run_event(String.t(), String.t(), map(), map()) :: :ok
  def record_run_event(issue_identifier, run_id, event_attrs, summary_updates \\ %{})
      when is_binary(issue_identifier) and is_binary(run_id) and is_map(event_attrs) and is_map(summary_updates) do
    if audit_enabled?() do
      event =
        %{
          "kind" => event_kind(event_attrs),
          "event" => event_name(Map.get(event_attrs, :event) || Map.get(event_attrs, "event")),
          "recorded_at" => iso8601(Map.get(event_attrs, :recorded_at) || Map.get(event_attrs, "recorded_at") || DateTime.utc_now()),
          "summary" => Map.get(event_attrs, :summary) || Map.get(event_attrs, "summary"),
          "details" => sanitize_value(Map.get(event_attrs, :details) || Map.get(event_attrs, "details") || %{})
        }
        |> maybe_put_event_session_id(Map.get(event_attrs, :session_id) || Map.get(event_attrs, "session_id"))
        |> drop_nil_map_values()

      persist_update(run_context(issue_identifier, run_id), summary_updates, event)
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("record run event", issue_identifier, exception)
      :ok
  end

  @spec record_latest_run_event(String.t(), map(), map()) :: :ok
  def record_latest_run_event(issue_identifier, event_attrs, summary_updates \\ %{})
      when is_binary(issue_identifier) and is_map(event_attrs) and is_map(summary_updates) do
    if audit_enabled?() do
      case latest_run(issue_identifier) do
        {:ok, %{"run_id" => run_id}} -> record_run_event(issue_identifier, run_id, event_attrs, summary_updates)
        _ -> :ok
      end
    else
      :ok
    end
  end

  @spec update_run_summary(String.t(), String.t(), map()) :: :ok
  def update_run_summary(issue_identifier, run_id, updates)
      when is_binary(issue_identifier) and is_binary(run_id) and is_map(updates) do
    if audit_enabled?() do
      persist_update(run_context(issue_identifier, run_id), updates, nil)
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("update run summary", issue_identifier, exception)
      :ok
  end

  @spec finish_run(map(), map()) :: :ok
  def finish_run(running_entry, attrs \\ %{}) when is_map(running_entry) and is_map(attrs) do
    if audit_enabled?() do
      with {:ok, context} <- run_context_from_entry(running_entry) do
        ended_at = Map.get(attrs, :ended_at, DateTime.utc_now())
        status = attrs |> Map.get(:status, "completed") |> to_string()
        next_action = attrs |> Map.get(:next_action) |> normalize_optional_string()
        last_error = attrs |> Map.get(:last_error) |> normalize_optional_string()
        issue = Map.get(running_entry, :issue)

        issue_state_finished =
          attrs
          |> Map.get(:issue_state_finished)
          |> normalize_optional_string()
          |> case do
            nil -> normalize_optional_string(issue && issue.state)
            value -> value
          end

        tracker_transition =
          attrs
          |> Map.get(:tracker_transition)
          |> normalize_tracker_transition()

        summary_updates =
          %{
            "status" => status,
            "next_action" => next_action,
            "last_error" => last_error,
            "ended_at" => iso8601(ended_at),
            "duration_ms" => duration_ms(Map.get(running_entry, :started_at), ended_at),
            "issue_state_finished" => issue_state_finished,
            "worker_host" => runtime_value(Map.get(running_entry, :worker_host)),
            "workspace_path" => runtime_value(Map.get(running_entry, :workspace_path)),
            "session_id" => runtime_value(Map.get(running_entry, :session_id)),
            "turn_count" => Map.get(running_entry, :turn_count, 0),
            "continuation_turn_count" => max(Map.get(running_entry, :turn_count, 0) - 1, 0),
            "tokens" => %{
              "input_tokens" => Map.get(running_entry, :codex_input_tokens, 0),
              "cached_input_tokens" => Map.get(running_entry, :codex_cached_input_tokens, 0),
              "uncached_input_tokens" => uncached_input_tokens(running_entry),
              "output_tokens" => Map.get(running_entry, :codex_output_tokens, 0),
              "total_tokens" => Map.get(running_entry, :codex_total_tokens, 0)
            },
            "tracker_transition" => tracker_transition
          }
          |> drop_nil_map_values()

        event = %{
          "kind" => "run_lifecycle",
          "event" => terminal_event_name(status),
          "recorded_at" => iso8601(ended_at),
          "summary" => terminal_summary(status, next_action, last_error),
          "details" =>
            sanitize_value(%{
              "status" => status,
              "next_action" => next_action,
              "last_error" => last_error,
              "tracker_transition" => tracker_transition,
              "issue_state_finished" => issue_state_finished
            })
        }

        persist_update(context, summary_updates, event)
        prune_issue_runs(context.issue_identifier)
      else
        :error -> :ok
      end
    else
      :ok
    end
  rescue
    exception ->
      log_persist_exception("finish run", Map.get(running_entry, :identifier), exception)
      :ok
  end

  @spec list_runs(String.t(), keyword()) :: {:ok, [map()]}
  def list_runs(issue_identifier, opts \\ [])

  def list_runs(issue_identifier, opts) when is_binary(issue_identifier) do
    if audit_enabled?() do
      limit = positive_limit(opts[:limit], configured_run_limit())

      runs =
        issue_identifier
        |> issue_runs_root()
        |> Path.join("*/summary.json")
        |> Path.wildcard()
        |> Enum.map(&read_summary_file/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&run_sort_key/1, :desc)
        |> Enum.take(limit)

      {:ok, runs}
    else
      {:ok, []}
    end
  end

  def list_runs(_issue_identifier, _opts), do: {:ok, []}

  @spec recent_runs(integer() | nil) :: {:ok, [map()]}
  def recent_runs(limit \\ nil) do
    if audit_enabled?() do
      normalized_limit = positive_limit(limit, configured_dashboard_runs())

      runs =
        audit_root()
        |> Path.join("issues/*/runs/*/summary.json")
        |> Path.wildcard()
        |> Enum.map(&read_summary_file/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&(Map.get(&1, "status") == "running"))
        |> Enum.sort_by(&run_sort_key/1, :desc)
        |> Enum.take(normalized_limit)

      {:ok, runs}
    else
      {:ok, []}
    end
  end

  @spec issue_rollups(integer() | nil) :: {:ok, [map()]}
  def issue_rollups(limit \\ nil) do
    if audit_enabled?() do
      normalized_limit = positive_limit(limit, configured_issue_rollup_limit())

      rollups =
        audit_root()
        |> Path.join("issues/*/runs/*/summary.json")
        |> Path.wildcard()
        |> Enum.map(&read_summary_file/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.group_by(&Map.get(&1, "issue_identifier"))
        |> Enum.map(fn {issue_identifier, runs} -> build_issue_rollup(issue_identifier, runs) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&rollup_sort_key/1, :desc)
        |> Enum.take(normalized_limit)

      {:ok, rollups}
    else
      {:ok, []}
    end
  end

  @spec issue_rollup(String.t()) :: {:ok, map() | nil}
  def issue_rollup(issue_identifier) when is_binary(issue_identifier) do
    if audit_enabled?() do
      case list_runs(issue_identifier, limit: configured_run_limit()) do
        {:ok, []} -> {:ok, nil}
        {:ok, runs} -> {:ok, build_issue_rollup(issue_identifier, runs)}
      end
    else
      {:ok, nil}
    end
  end

  @spec latest_run(String.t()) :: {:ok, map() | nil}
  def latest_run(issue_identifier) when is_binary(issue_identifier) do
    case list_runs(issue_identifier, limit: 1) do
      {:ok, [run | _]} -> {:ok, run}
      {:ok, []} -> {:ok, nil}
    end
  end

  @spec prompt_handoff(String.t(), keyword()) :: {:ok, map() | nil}
  def prompt_handoff(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    current_run_id = Keyword.get(opts, :current_run_id)

    with {:ok, runs} <- list_runs(issue_identifier, limit: configured_run_limit()) do
      handoff =
        runs
        |> Enum.reject(&(Map.get(&1, "run_id") == current_run_id))
        |> Enum.reject(&(Map.get(&1, "status") == "running"))
        |> List.first()
        |> build_prompt_handoff()

      {:ok, handoff}
    end
  end

  @spec get_run(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_run(issue_identifier, run_id) when is_binary(issue_identifier) and is_binary(run_id) do
    if audit_enabled?() do
      case read_summary_file(summary_path(issue_identifier, run_id)) do
        nil -> {:error, :not_found}
        run -> {:ok, run}
      end
    else
      {:error, :not_found}
    end
  end

  def get_run(_issue_identifier, _run_id), do: {:error, :not_found}

  @spec get_run_events(String.t(), String.t(), keyword()) :: {:ok, [map()]}
  def get_run_events(issue_identifier, run_id, opts \\ [])

  def get_run_events(issue_identifier, run_id, opts)
      when is_binary(issue_identifier) and is_binary(run_id) do
    if audit_enabled?() do
      limit = positive_limit(opts[:limit], configured_event_limit())
      path = events_path(issue_identifier, run_id)

      events =
        if File.regular?(path) do
          path
          |> File.stream!([], :line)
          |> Enum.map(&decode_event_line/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.take(-limit)
        else
          []
        end

      {:ok, events}
    else
      {:ok, []}
    end
  rescue
    exception ->
      Logger.warning("Failed to read audit events for #{issue_identifier}/#{run_id}: #{Exception.message(exception)}")
      {:ok, []}
  end

  def get_run_events(_issue_identifier, _run_id, _opts), do: {:ok, []}

  @spec export_issue_bundle(String.t(), keyword()) ::
          {:ok, %{path: Path.t(), filename: String.t(), issue_identifier: String.t(), run_count: non_neg_integer()}}
          | {:error, :issue_not_found | term()}
  def export_issue_bundle(issue_identifier, opts \\ []) when is_binary(issue_identifier) do
    if audit_enabled?() do
      with {:ok, runs} <- list_runs(issue_identifier, limit: configured_run_limit()),
           false <- runs == [] do
        export_root = Keyword.get(opts, :output_dir, Path.join(audit_root(), "exports"))
        :ok = File.mkdir_p(export_root)

        filename = Keyword.get(opts, :filename, default_bundle_filename(issue_identifier))
        path = Path.expand(Keyword.get(opts, :output_path, Path.join(export_root, filename)))

        manifest = issue_bundle_manifest(issue_identifier, runs)
        issue_rollup = build_issue_rollup(issue_identifier, runs)

        entries =
          [
            {"manifest.json", Jason.encode_to_iodata!(manifest, pretty: true)},
            {"issue.json", Jason.encode_to_iodata!(%{"issue_identifier" => issue_identifier, "rollup" => issue_rollup, "runs" => runs}, pretty: true)}
          ] ++ issue_bundle_run_entries(issue_identifier, runs)

        case :zip.create(String.to_charlist(filename), zip_entries(entries), [:memory]) do
          {:ok, {_archive_name, zip_binary}} ->
            :ok = File.write(path, zip_binary)

            {:ok,
             %{
               path: path,
               filename: filename,
               issue_identifier: issue_identifier,
               run_count: length(runs)
             }}

          {:error, reason} ->
            {:error, reason}
        end
      else
        true -> {:error, :issue_not_found}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :issue_not_found}
    end
  rescue
    exception ->
      Logger.warning("Failed to export audit bundle for #{issue_identifier}: #{Exception.message(exception)}")
      {:error, {:bundle_export_failed, Exception.message(exception)}}
  end

  @spec render_tracker_run_summary(map()) :: String.t()
  def render_tracker_run_summary(run) when is_map(run) do
    case configured_tracker_summary_template() do
      template when is_binary(template) ->
        render_configured_tracker_summary(run, template)

      _ ->
        default_tracker_run_summary(run)
    end
  end

  @spec render_trello_run_summary(map()) :: String.t()
  def render_trello_run_summary(run) when is_map(run) do
    render_tracker_run_summary(run)
  end

  @spec list_guardrail_approvals(keyword()) :: {:ok, [map()]}
  def list_guardrail_approvals(opts \\ []) do
    statuses = normalize_status_filter(Keyword.get(opts, :statuses))

    approvals =
      guardrail_approvals_root()
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&read_guardrail_json_file/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn approval ->
        statuses == [] or Map.get(approval, "status") in statuses
      end)
      |> Enum.sort_by(
        fn approval ->
          {Map.get(approval, "requested_at") || Map.get(approval, "resolved_at"), Map.get(approval, "id")}
        end,
        :desc
      )

    {:ok, approvals}
  end

  @spec get_guardrail_approval(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_guardrail_approval(approval_id) when is_binary(approval_id) do
    case read_guardrail_json_file(guardrail_approval_path(approval_id)) do
      %{} = approval -> {:ok, approval}
      _ -> {:error, :not_found}
    end
  end

  def get_guardrail_approval(_approval_id), do: {:error, :not_found}

  @spec put_guardrail_approval(Approvals.t()) :: :ok
  def put_guardrail_approval(%Approvals{} = approval) do
    write_guardrail_entry(guardrail_approval_path(approval.id), Approvals.snapshot_entry(approval))
  end

  @spec list_guardrail_rules(keyword()) :: {:ok, [map()]}
  def list_guardrail_rules(opts \\ []) do
    active_only = Keyword.get(opts, :active_only, false)
    now = DateTime.utc_now()

    rules =
      guardrail_rules_root()
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&read_guardrail_json_file/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn snapshot ->
        if active_only do
          case Rule.from_snapshot(snapshot) do
            %Rule{} = rule -> Rule.active?(rule, now)
            _ -> false
          end
        else
          true
        end
      end)
      |> Enum.sort_by(fn rule -> {Map.get(rule, "created_at"), Map.get(rule, "id")} end, :desc)

    {:ok, rules}
  end

  @spec get_guardrail_rule(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_guardrail_rule(rule_id) when is_binary(rule_id) do
    case read_guardrail_json_file(guardrail_rule_path(rule_id)) do
      %{} = rule -> {:ok, rule}
      _ -> {:error, :not_found}
    end
  end

  def get_guardrail_rule(_rule_id), do: {:error, :not_found}

  @spec put_guardrail_rule(Rule.t()) :: :ok
  def put_guardrail_rule(%Rule{} = rule) do
    write_guardrail_entry(guardrail_rule_path(rule.id), Rule.snapshot_entry(rule))
  end

  @spec list_guardrail_overrides(keyword()) :: {:ok, [map()]}
  def list_guardrail_overrides(opts \\ []) do
    active_only = Keyword.get(opts, :active_only, false)
    now = DateTime.utc_now()

    overrides =
      guardrail_overrides_root()
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&read_guardrail_json_file/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn snapshot ->
        if active_only do
          case Overrides.from_snapshot(snapshot) do
            %Overrides{} = override -> Overrides.active?(override, now)
            _ -> false
          end
        else
          true
        end
      end)
      |> Enum.sort_by(fn override -> {Map.get(override, "created_at"), Map.get(override, "id")} end, :desc)

    {:ok, overrides}
  end

  @spec get_guardrail_override(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_guardrail_override(override_id) when is_binary(override_id) do
    case read_guardrail_json_file(guardrail_override_path(override_id)) do
      %{} = override -> {:ok, override}
      _ -> {:error, :not_found}
    end
  end

  def get_guardrail_override(_override_id), do: {:error, :not_found}

  @spec put_guardrail_override(Overrides.override()) :: :ok
  def put_guardrail_override(%Overrides{} = override) do
    write_guardrail_entry(guardrail_override_path(override.id), Overrides.snapshot_entry(override))
  end

  @spec storage_backend() :: String.t()
  def storage_backend do
    configured_storage_backend()
  end

  defp default_tracker_run_summary(run) do
    run_id = Map.get(run, "run_id") || "n/a"
    status = Map.get(run, "status") || "completed"
    started_state = Map.get(run, "issue_state_started")
    finished_state = Map.get(run, "issue_state_finished")
    next_action = Map.get(run, "next_action")
    last_error = Map.get(run, "last_error")
    duration = human_duration(Map.get(run, "duration_ms"))
    queue_wait = run |> Map.get("timing", %{}) |> Map.get("queue_wait_ms") |> human_duration()
    blocked_for_human = run |> Map.get("timing", %{}) |> Map.get("blocked_for_human_ms") |> human_duration()
    turn_count = Map.get(run, "turn_count")
    tokens = Map.get(run, "tokens") || %{}
    tracker_transition = Map.get(run, "tracker_transition") || %{}
    changed_files = changed_files_label(run)
    git_label = run_git_label(run)
    hook_results = hook_results_label(Map.get(run, "hook_results"))
    last_message = normalize_optional_string(Map.get(run, "last_message"))

    [
      "## Codex Summary",
      "",
      "- Run: `#{run_id}`",
      "- Status: `#{status}`",
      "- Tracker state: #{summary_state_transition(started_state, finished_state, tracker_transition)}",
      "- Runtime: #{duration}",
      "- Queue wait: #{queue_wait}",
      blocked_for_human && "- Human wait: #{blocked_for_human}",
      is_integer(turn_count) && "- Turns: #{turn_count}",
      "- Tokens: #{tokens_label(tokens)}",
      changed_files && "- Changed files: #{changed_files}",
      git_label && "- Git: #{git_label}",
      hook_results && "- Hooks: #{hook_results}",
      next_action && "- Next action: `#{next_action}`",
      last_message && "- Final summary: #{last_message}",
      last_error && "- Error: `#{last_error}`"
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp render_configured_tracker_summary(run, template) when is_binary(template) do
    rendered =
      template
      |> Solid.parse!()
      |> Solid.render!(tracker_summary_context(run), @template_render_opts)
      |> IO.iodata_to_binary()
      |> String.trim()

    if rendered == "" do
      default_tracker_run_summary(run)
    else
      rendered
    end
  rescue
    exception ->
      Logger.warning("Failed to render configured tracker summary template: #{Exception.message(exception)}")
      default_tracker_run_summary(run)
  end

  @spec audit_root() :: Path.t()
  def audit_root do
    case Application.get_env(:symphony_elixir, :audit_root) do
      path when is_binary(path) and path != "" ->
        Path.expand(path)

      _ ->
        Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
        |> Path.expand()
        |> Path.dirname()
        |> Path.join("audit")
    end
  end

  defp fetch_run_id(opts) do
    case Keyword.get(opts, :run_id) do
      run_id when is_binary(run_id) and run_id != "" -> {:ok, run_id}
      _ -> :error
    end
  end

  defp base_summary(issue, run_id, started_at, retry_attempt, worker_host, workspace_path, timing) do
    started_at_iso = iso8601(started_at)

    %{
      "run_id" => run_id,
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "title" => issue.title,
      "url" => issue.url,
      "status" => "running",
      "next_action" => nil,
      "last_error" => nil,
      "started_at" => started_at_iso,
      "ended_at" => nil,
      "duration_ms" => nil,
      "issue_state_started" => issue.state,
      "issue_state_finished" => issue.state,
      "worker_host" => runtime_value(worker_host),
      "workspace_path" => runtime_value(workspace_path),
      "session_id" => nil,
      "turn_count" => 0,
      "continuation_turn_count" => 0,
      "retry_attempt" => normalize_retry_attempt(retry_attempt),
      "event_count" => 0,
      "last_event" => nil,
      "last_message" => nil,
      "last_event_at" => nil,
      "timing" => timing,
      "hook_results" => %{},
      "workspace_metadata" => nil,
      "tokens" => %{
        "input_tokens" => 0,
        "cached_input_tokens" => 0,
        "uncached_input_tokens" => 0,
        "output_tokens" => 0,
        "total_tokens" => 0
      },
      "tracker_transition" => nil,
      "updated_at" => started_at_iso
    }
  end

  defp run_context_from_entry(%{identifier: issue_identifier, run_id: run_id})
       when is_binary(issue_identifier) and issue_identifier != "" and is_binary(run_id) and run_id != "" do
    {:ok, run_context(issue_identifier, run_id)}
  end

  defp run_context_from_entry(_entry), do: :error

  defp run_context(issue_identifier, run_id) do
    %{issue_identifier: issue_identifier, run_id: run_id}
  end

  defp persist_update(%{issue_identifier: issue_identifier, run_id: run_id} = context, summary_updates, event, opts \\ []) do
    replace? = Keyword.get(opts, :replace?, false)
    run_dir = run_dir(issue_identifier, run_id)
    :ok = File.mkdir_p(run_dir)

    if is_map(event) do
      line = Jason.encode!(event) <> "\n"
      :ok = File.write(events_path(issue_identifier, run_id), line, [:append])
    end

    current_summary =
      if replace? do
        %{}
      else
        read_summary_file(summary_path(issue_identifier, run_id)) || %{}
      end

    summary =
      current_summary
      |> deep_merge(sanitize_value(summary_updates))
      |> apply_event_to_summary(event)
      |> derive_summary_metrics()
      |> ensure_identity_fields(context)

    :ok = File.write(summary_path(issue_identifier, run_id), Jason.encode_to_iodata!(summary, pretty: true))
  rescue
    exception ->
      log_persist_exception("persist audit update", issue_identifier, exception)
      :ok
  end

  defp apply_event_to_summary(summary, %{"event" => event, "summary" => event_summary, "recorded_at" => recorded_at}) do
    summary
    |> Map.update("event_count", 1, fn value -> (value || 0) + 1 end)
    |> Map.put("last_event", event)
    |> Map.put("last_message", event_summary)
    |> Map.put("last_event_at", recorded_at)
    |> Map.put("updated_at", recorded_at)
  end

  defp apply_event_to_summary(summary, _event) do
    Map.put(summary, "updated_at", iso8601(DateTime.utc_now()))
  end

  defp derive_summary_metrics(summary) when is_map(summary) do
    tokens =
      summary
      |> Map.get("tokens", %{})
      |> normalize_tokens()

    prompt_shape =
      summary
      |> Map.get("prompt_shape")
      |> normalize_prompt_shape()

    efficiency = efficiency_metrics(summary, tokens)

    summary
    |> Map.put("tokens", tokens)
    |> maybe_put("prompt_shape", prompt_shape)
    |> Map.put("efficiency", efficiency)
  end

  defp derive_summary_metrics(summary), do: summary

  defp write_guardrail_entry(path, payload) when is_binary(path) and is_map(payload) do
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.write(path, Jason.encode_to_iodata!(sanitize_value(payload), pretty: true))
  rescue
    exception ->
      Logger.warning("Failed to persist guardrail entry #{path}: #{Exception.message(exception)}")
      :ok
  end

  defp normalize_status_filter(nil), do: []

  defp normalize_status_filter(statuses) when is_list(statuses) do
    statuses
    |> Enum.map(&normalize_optional_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_status_filter(status) do
    case normalize_optional_string(status) do
      nil -> []
      value -> [value]
    end
  end

  defp ensure_identity_fields(summary, %{issue_identifier: issue_identifier, run_id: run_id}) do
    summary
    |> Map.put_new("issue_identifier", issue_identifier)
    |> Map.put_new("run_id", run_id)
  end

  defp terminal_event_name("completed"), do: "run_completed"
  defp terminal_event_name("failed"), do: "run_failed"
  defp terminal_event_name("interrupted"), do: "run_interrupted"
  defp terminal_event_name(status), do: "run_" <> status

  defp terminal_summary(status, next_action, nil) when is_binary(next_action),
    do: "#{status} (next: #{next_action})"

  defp terminal_summary(status, _next_action, last_error) when is_binary(last_error),
    do: "#{status}: #{last_error}"

  defp terminal_summary(status, next_action, _last_error) when is_binary(next_action),
    do: "#{status} (next: #{next_action})"

  defp terminal_summary(status, _next_action, _last_error), do: status

  defp runtime_update_summary(summary_updates) do
    workspace = Map.get(summary_updates, "workspace_path")
    worker_host = Map.get(summary_updates, "worker_host")

    cond do
      is_binary(workspace) and is_binary(worker_host) ->
        "workspace ready on #{worker_host}"

      is_binary(workspace) ->
        "workspace ready"

      is_binary(worker_host) ->
        "worker host updated to #{worker_host}"

      true ->
        "runtime updated"
    end
  end

  defp codex_event_summary(running_entry, update) do
    running_entry
    |> Map.get(:last_codex_message)
    |> case do
      nil ->
        StatusDashboard.humanize_codex_message(%{
          event: update[:event],
          message: update[:payload] || update[:details] || update
        })

      message ->
        StatusDashboard.humanize_codex_message(message)
    end
  end

  defp workspace_metadata_summary(metadata) when is_map(metadata) do
    git = Map.get(metadata, "git") || Map.get(metadata, :git)
    changed_files = Map.get(git || %{}, "changed_files") || Map.get(git || %{}, :changed_files) || []
    changed_file_count = Map.get(git || %{}, "changed_file_count") || Map.get(git || %{}, :changed_file_count) || length(changed_files)
    head_commit = Map.get(git || %{}, "head_commit") || Map.get(git || %{}, :head_commit)

    cond do
      is_integer(changed_file_count) and changed_file_count > 0 and is_binary(head_commit) ->
        "workspace metadata captured (#{changed_file_count} changed files, head #{String.slice(head_commit, 0, 8)})"

      is_integer(changed_file_count) and changed_file_count > 0 ->
        "workspace metadata captured (#{changed_file_count} changed files)"

      is_binary(head_commit) ->
        "workspace metadata captured (head #{String.slice(head_commit, 0, 8)})"

      true ->
        "workspace metadata captured"
    end
  end

  defp workspace_metadata_summary(_metadata), do: "workspace metadata captured"

  defp sanitize_event_details(update) do
    payload = Map.get(update, :payload) || Map.get(update, "payload")

    case event_method(payload) do
      "item/reasoning/textDelta" ->
        if store_reasoning_text?() do
          update
          |> Map.drop([:timestamp, "timestamp", :raw, "raw"])
          |> sanitize_value()
        else
          %{
            "method" => "item/reasoning/textDelta",
            "note" => "reasoning text omitted from persisted audit log"
          }
        end

      _ ->
        update
        |> Map.drop([:timestamp, "timestamp", :raw, "raw"])
        |> sanitize_value()
    end
  end

  defp event_method(payload) when is_map(payload) do
    Map.get(payload, "method") || Map.get(payload, :method)
  end

  defp event_method(_payload), do: nil

  defp normalize_tracker_transition(nil), do: nil

  defp normalize_tracker_transition(transition) when is_map(transition) do
    transition
    |> sanitize_value()
    |> drop_nil_map_values()
    |> case do
      %{} = normalized when map_size(normalized) == 0 -> nil
      normalized -> normalized
    end
  end

  defp normalize_tracker_transition(_transition), do: nil

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp runtime_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp runtime_value(value), do: value

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = ended_at) do
    max(DateTime.diff(ended_at, started_at, :millisecond), 0)
  end

  defp duration_ms(_, _), do: nil

  defp event_name(event) when is_atom(event), do: Atom.to_string(event)
  defp event_name(event) when is_binary(event), do: event
  defp event_name(event), do: inspect(event)

  defp event_kind(event_attrs) when is_map(event_attrs) do
    Map.get(event_attrs, :kind) || Map.get(event_attrs, "kind") || "audit"
  end

  defp maybe_put_event_session_id(event, session_id) when is_binary(session_id) and session_id != "" do
    Map.put(event, "session_id", session_id)
  end

  defp maybe_put_event_session_id(event, _session_id), do: event

  defp positive_limit(limit, _fallback) when is_integer(limit) and limit > 0, do: limit
  defp positive_limit(_limit, fallback), do: fallback

  defp read_summary_file(path) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, payload} <- File.read(path),
         {:ok, summary} <- Jason.decode(payload),
         true <- is_map(summary) do
      summary
    else
      _ -> nil
    end
  rescue
    exception ->
      Logger.warning("Failed to read audit summary #{path}: #{Exception.message(exception)}")
      nil
  end

  defp read_guardrail_json_file(path) when is_binary(path) do
    with true <- File.regular?(path),
         {:ok, payload} <- File.read(path),
         {:ok, entry} <- Jason.decode(payload),
         true <- is_map(entry) do
      entry
    else
      _ -> nil
    end
  rescue
    exception ->
      Logger.warning("Failed to read guardrail audit entry #{path}: #{Exception.message(exception)}")
      nil
  end

  defp decode_event_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, payload} when is_map(payload) -> payload
      _ -> nil
    end
  end

  defp issue_runs_root(issue_identifier) do
    audit_root()
    |> Path.join("issues")
    |> Path.join(issue_identifier_segment(issue_identifier))
    |> Path.join("runs")
  end

  defp run_dir(issue_identifier, run_id) do
    Path.join(issue_runs_root(issue_identifier), run_id)
  end

  defp summary_path(issue_identifier, run_id) do
    Path.join(run_dir(issue_identifier, run_id), "summary.json")
  end

  defp events_path(issue_identifier, run_id) do
    Path.join(run_dir(issue_identifier, run_id), "events.jsonl")
  end

  defp guardrails_root do
    Path.join(audit_root(), "guardrails")
  end

  defp guardrail_approvals_root do
    Path.join(guardrails_root(), "approvals")
  end

  defp guardrail_rules_root do
    Path.join(guardrails_root(), "rules")
  end

  defp guardrail_overrides_root do
    Path.join(guardrails_root(), "overrides")
  end

  defp guardrail_approval_path(approval_id) when is_binary(approval_id) do
    Path.join(guardrail_approvals_root(), "#{approval_id}.json")
  end

  defp guardrail_rule_path(rule_id) when is_binary(rule_id) do
    Path.join(guardrail_rules_root(), "#{rule_id}.json")
  end

  defp guardrail_override_path(override_id) when is_binary(override_id) do
    Path.join(guardrail_overrides_root(), "#{override_id}.json")
  end

  defp issue_identifier_segment(issue_identifier) do
    sanitized =
      issue_identifier
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.trim("_")
      |> case do
        "" -> "issue"
        value -> value
      end

    hash =
      issue_identifier
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{sanitized}-#{hash}"
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp sanitize_value(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, nested}, acc ->
      normalized_key = to_string(key)

      normalized_value =
        if sensitive_key?(normalized_key) do
          @redacted_value
        else
          sanitize_value(nested)
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp sanitize_value(value) when is_list(value) do
    max_items = configured_max_list_items()

    value
    |> Enum.take(max_items)
    |> Enum.map(&sanitize_value/1)
    |> maybe_append_list_truncation(length(value), max_items)
  end

  defp sanitize_value(value) when is_binary(value) do
    value
    |> sanitize_string()
    |> truncate_string()
  end

  defp sanitize_value(value) when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
    do: value

  defp sanitize_value(value), do: inspect(value, pretty: false, limit: 20) |> truncate_string()

  defp sanitize_string(value) when is_binary(value) do
    value
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> String.trim()
  end

  defp truncate_string(value) when is_binary(value) do
    max_length = configured_max_string_length()

    if String.length(value) > max_length do
      truncated = String.slice(value, 0, max_length)
      "#{truncated}... [truncated #{String.length(value) - max_length} chars]"
    else
      value
    end
  end

  defp maybe_append_list_truncation(list, original_length, max_items) when original_length > max_items do
    list ++ [%{"truncated_items" => original_length - max_items}]
  end

  defp maybe_append_list_truncation(list, _original_length, _max_items), do: list

  defp sensitive_key?(key) when is_binary(key) do
    normalized_key =
      key
      |> String.trim()
      |> Macro.underscore()
      |> String.downcase()

    key_segments =
      normalized_key
      |> String.split(~r/[^a-z0-9]+/, trim: true)

    Enum.any?(configured_redact_keys(), fn redact_key ->
      normalized_redact_key = String.downcase(redact_key)

      normalized_key == normalized_redact_key or normalized_redact_key in key_segments
    end)
  end

  defp sensitive_key?(_key), do: false

  defp drop_nil_map_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp prune_issue_runs(issue_identifier) when is_binary(issue_identifier) do
    keep = configured_run_limit()

    issue_identifier
    |> issue_runs_root()
    |> Path.join("*/summary.json")
    |> Path.wildcard()
    |> Enum.map(fn summary_file ->
      run = read_summary_file(summary_file)
      {summary_file, run}
    end)
    |> Enum.reject(fn {_summary_file, run} -> is_nil(run) end)
    |> Enum.sort_by(fn {_summary_file, run} -> run_sort_key(run) end, :desc)
    |> Enum.drop(keep)
    |> Enum.each(fn {summary_file, _run} ->
      summary_file |> Path.dirname() |> File.rm_rf()
    end)

    :ok
  rescue
    exception ->
      Logger.warning("Failed to prune audit runs for #{issue_identifier}: #{Exception.message(exception)}")
      :ok
  end

  defp prune_issue_runs(_issue_identifier), do: :ok

  defp run_sort_key(run) when is_map(run) do
    {Map.get(run, "ended_at") || Map.get(run, "updated_at") || Map.get(run, "started_at"), Map.get(run, "run_id")}
  end

  defp sanitize_optional_map(%{} = value) do
    value
    |> sanitize_value()
    |> drop_nil_map_values()
    |> case do
      %{} = sanitized when map_size(sanitized) == 0 -> nil
      sanitized -> sanitized
    end
  end

  defp sanitize_optional_map(_value), do: nil

  defp issue_bundle_manifest(issue_identifier, runs) do
    %{
      "issue_identifier" => issue_identifier,
      "exported_at" => iso8601(DateTime.utc_now()),
      "storage_backend" => configured_storage_backend(),
      "run_count" => length(runs),
      "runs" =>
        Enum.map(runs, fn run ->
          %{
            "run_id" => Map.get(run, "run_id"),
            "status" => Map.get(run, "status"),
            "started_at" => Map.get(run, "started_at"),
            "ended_at" => Map.get(run, "ended_at"),
            "event_count" => Map.get(run, "event_count"),
            "summary_path" => "runs/#{Map.get(run, "run_id")}/summary.json",
            "events_path" => "runs/#{Map.get(run, "run_id")}/events.jsonl"
          }
        end)
    }
  end

  defp issue_bundle_run_entries(issue_identifier, runs) when is_list(runs) do
    Enum.flat_map(runs, fn run ->
      run_id = Map.get(run, "run_id")

      case run_id do
        run_id when is_binary(run_id) ->
          summary_payload = File.read!(summary_path(issue_identifier, run_id))
          events_payload = if File.regular?(events_path(issue_identifier, run_id)), do: File.read!(events_path(issue_identifier, run_id)), else: ""

          [
            {"runs/#{run_id}/summary.json", summary_payload},
            {"runs/#{run_id}/events.jsonl", events_payload}
          ]

        _ ->
          []
      end
    end)
  end

  defp zip_entries(entries) when is_list(entries) do
    Enum.map(entries, fn {name, contents} ->
      {String.to_charlist(name), IO.iodata_to_binary(contents)}
    end)
  end

  defp default_bundle_filename(issue_identifier) do
    timestamp =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z]+/, "-")

    safe_issue =
      issue_identifier
      |> String.replace(~r/[^0-9A-Za-z._-]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "issue"
        value -> value
      end

    "#{safe_issue}-audit-#{timestamp}.zip"
  end

  defp run_git_label(run) when is_map(run) do
    git = get_in(run, ["workspace_metadata", "git"]) || %{}
    branch = Map.get(git, "branch")
    head_commit = Map.get(git, "head_commit")

    cond do
      is_binary(branch) and is_binary(head_commit) ->
        "#{branch} @ #{String.slice(head_commit, 0, 8)}"

      is_binary(branch) ->
        branch

      is_binary(head_commit) ->
        String.slice(head_commit, 0, 8)

      true ->
        nil
    end
  end

  defp changed_files_label(run) when is_map(run) do
    git = get_in(run, ["workspace_metadata", "git"]) || %{}
    changed_files = Map.get(git, "changed_files") || []
    changed_file_count = Map.get(git, "changed_file_count") || length(changed_files)

    paths =
      changed_files
      |> Enum.flat_map(fn
        %{"path" => path} when is_binary(path) -> [path]
        _ -> []
      end)
      |> Enum.take(5)

    cond do
      changed_file_count == 0 ->
        nil

      paths == [] ->
        "#{changed_file_count} file(s)"

      changed_file_count > length(paths) ->
        "#{Enum.join(paths, ", ")} (+#{changed_file_count - length(paths)} more)"

      true ->
        Enum.join(paths, ", ")
    end
  end

  defp changed_files_label(_run), do: nil

  defp hook_results_label(hook_results) when is_map(hook_results) do
    labels =
      hook_results
      |> Enum.flat_map(fn {hook_name, result} ->
        status =
          case result do
            %{"status" => value} when is_binary(value) -> value
            %{status: value} when is_binary(value) -> value
            _ -> nil
          end

        if is_binary(status), do: ["#{hook_name}=#{status}"], else: []
      end)

    case labels do
      [] -> nil
      values -> Enum.join(values, ", ")
    end
  end

  defp hook_results_label(_hook_results), do: nil

  defp tokens_label(tokens) when is_map(tokens) do
    total = Map.get(tokens, "total_tokens") || 0
    input = Map.get(tokens, "input_tokens") || 0
    cached = Map.get(tokens, "cached_input_tokens") || 0
    uncached = Map.get(tokens, "uncached_input_tokens") || max(input - cached, 0)
    output = Map.get(tokens, "output_tokens") || 0
    "#{total} total (in #{input} / cached #{cached} / uncached #{uncached} / out #{output})"
  end

  defp tokens_label(_tokens), do: "0 total (in 0 / cached 0 / uncached 0 / out 0)"

  defp normalize_tokens(tokens) when is_map(tokens) do
    input = integer_or_zero(Map.get(tokens, "input_tokens"))
    cached = integer_or_zero(Map.get(tokens, "cached_input_tokens"))
    output = integer_or_zero(Map.get(tokens, "output_tokens"))
    total = integer_or_zero(Map.get(tokens, "total_tokens"))
    normalized_cached = min(cached, input)

    %{
      "input_tokens" => input,
      "cached_input_tokens" => normalized_cached,
      "uncached_input_tokens" => max(input - normalized_cached, 0),
      "output_tokens" => output,
      "total_tokens" => total
    }
    |> Map.put("label", nil)
    |> then(fn normalized -> Map.put(normalized, "label", tokens_label(normalized)) end)
  end

  defp normalize_tokens(_tokens), do: normalize_tokens(%{})

  defp normalize_prompt_shape(prompt_shape) when is_map(prompt_shape) do
    prompt_shape
    |> Map.take([
      "tracker_payload_chars",
      "workflow_prompt_chars",
      "rendered_prompt_chars",
      "base_rendered_prompt_chars",
      "issue_description_chars",
      "issue_prompt_description_chars",
      "issue_description_truncated",
      "issue_description_truncated_chars",
      "included_previous_run_handoff",
      "previous_run_id",
      "previous_run_handoff_chars"
    ])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_prompt_shape(_prompt_shape), do: nil

  defp efficiency_metrics(summary, tokens) when is_map(summary) and is_map(tokens) do
    changed_file_count = latest_changed_file_count(summary)
    duration_ms = Map.get(summary, "duration_ms")
    input = Map.get(tokens, "input_tokens") || 0
    cached = Map.get(tokens, "cached_input_tokens") || 0
    uncached = Map.get(tokens, "uncached_input_tokens") || 0
    total = Map.get(tokens, "total_tokens") || 0
    retry_count = retry_attempt(summary)
    tokens_per_changed_file = ratio_or_nil(total, changed_file_count)
    uncached_per_changed_file = ratio_or_nil(uncached, changed_file_count)

    flags =
      efficiency_flags(%{
        changed_file_count: changed_file_count,
        input_tokens: input,
        cached_input_tokens: cached,
        uncached_input_tokens: uncached,
        total_tokens: total,
        retry_attempt: retry_count,
        tokens_per_changed_file: tokens_per_changed_file,
        uncached_input_tokens_per_changed_file: uncached_per_changed_file,
        status: Map.get(summary, "status"),
        issue_state_started: Map.get(summary, "issue_state_started")
      })

    classification =
      efficiency_classification(%{
        changed_file_count: changed_file_count,
        retry_attempt: retry_count,
        uncached_input_tokens: uncached,
        tokens_per_changed_file: tokens_per_changed_file,
        flags: flags,
        status: Map.get(summary, "status")
      })

    %{
      "changed_file_count" => changed_file_count,
      "tokens_per_changed_file" => tokens_per_changed_file,
      "uncached_input_tokens_per_changed_file" => uncached_per_changed_file,
      "tokens_per_minute" => ratio_or_nil(total * 60_000, duration_ms),
      "cached_input_share_pct" => ratio_or_nil(cached * 100, input),
      "classification" => classification,
      "primary_label" => efficiency_primary_label(classification, flags),
      "flags" => flags
    }
  end

  defp efficiency_metrics(_summary, _tokens), do: %{}

  defp ratio_or_nil(_numerator, value) when value in [nil, 0], do: nil

  defp ratio_or_nil(numerator, denominator)
       when is_integer(numerator) and numerator >= 0 and is_integer(denominator) and denominator > 0 do
    numerator
    |> Kernel./(denominator)
    |> Float.round(2)
  end

  defp ratio_or_nil(_numerator, _denominator), do: nil

  defp integer_or_zero(value) when is_integer(value) and value >= 0, do: value
  defp integer_or_zero(_value), do: 0

  defp maybe_put(map, _key, nil) when is_map(map), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)

  defp uncached_input_tokens(%{} = running_entry) do
    input = Map.get(running_entry, :codex_input_tokens, 0)
    cached = Map.get(running_entry, :codex_cached_input_tokens, 0)
    max(input - cached, 0)
  end

  defp uncached_input_tokens(_running_entry), do: 0

  defp summary_state_transition(started_state, finished_state, tracker_transition) do
    transition_to =
      case tracker_transition do
        %{"to" => value} when is_binary(value) -> value
        _ -> nil
      end

    cond do
      is_binary(started_state) and is_binary(transition_to) ->
        "#{started_state} -> #{transition_to}"

      is_binary(started_state) and is_binary(finished_state) and started_state != finished_state ->
        "#{started_state} -> #{finished_state}"

      is_binary(finished_state) ->
        finished_state

      is_binary(started_state) ->
        started_state

      true ->
        "n/a"
    end
  end

  defp human_duration(value) when is_integer(value) and value >= 0 do
    total_seconds = div(value, 1_000)
    hours = div(total_seconds, 3_600)
    minutes = div(rem(total_seconds, 3_600), 60)
    seconds = rem(total_seconds, 60)

    cond do
      hours > 0 -> "#{hours}h #{minutes}m #{seconds}s"
      minutes > 0 -> "#{minutes}m #{seconds}s"
      true -> "#{seconds}s"
    end
  end

  defp human_duration(_value), do: "n/a"

  defp tracker_summary_context(run) when is_map(run) do
    timing = Map.get(run, "timing") || %{}
    git = get_in(run, ["workspace_metadata", "git"]) || %{}

    %{
      "run" => to_solid_value(run),
      "issue" => %{
        "id" => Map.get(run, "issue_id"),
        "identifier" => Map.get(run, "issue_identifier"),
        "title" => Map.get(run, "title"),
        "url" => Map.get(run, "url"),
        "state_started" => Map.get(run, "issue_state_started"),
        "state_finished" => Map.get(run, "issue_state_finished")
      },
      "timing" => %{
        "duration_ms" => Map.get(run, "duration_ms"),
        "duration_human" => human_duration(Map.get(run, "duration_ms")),
        "queue_wait_ms" => Map.get(timing, "queue_wait_ms"),
        "queue_wait_human" => human_duration(Map.get(timing, "queue_wait_ms")),
        "blocked_for_human_ms" => Map.get(timing, "blocked_for_human_ms"),
        "blocked_for_human_human" => human_duration(Map.get(timing, "blocked_for_human_ms")),
        "queue_wait_after_human_ms" => Map.get(timing, "queue_wait_after_human_ms"),
        "queue_wait_after_human_human" => human_duration(Map.get(timing, "queue_wait_after_human_ms")),
        "queue_source" => Map.get(timing, "queue_source"),
        "human_response_at" => Map.get(timing, "human_response_at"),
        "human_response_marker" => to_solid_value(Map.get(timing, "human_response_marker"))
      },
      "tokens" => %{
        "input_tokens" => get_in(run, ["tokens", "input_tokens"]) || 0,
        "cached_input_tokens" => get_in(run, ["tokens", "cached_input_tokens"]) || 0,
        "uncached_input_tokens" => get_in(run, ["tokens", "uncached_input_tokens"]) || 0,
        "output_tokens" => get_in(run, ["tokens", "output_tokens"]) || 0,
        "total_tokens" => get_in(run, ["tokens", "total_tokens"]) || 0,
        "label" => tokens_label(Map.get(run, "tokens") || %{})
      },
      "prompt_shape" => %{
        "tracker_payload_chars" => get_in(run, ["prompt_shape", "tracker_payload_chars"]),
        "workflow_prompt_chars" => get_in(run, ["prompt_shape", "workflow_prompt_chars"]),
        "rendered_prompt_chars" => get_in(run, ["prompt_shape", "rendered_prompt_chars"]),
        "issue_description_chars" => get_in(run, ["prompt_shape", "issue_description_chars"]),
        "issue_prompt_description_chars" => get_in(run, ["prompt_shape", "issue_prompt_description_chars"]),
        "issue_description_truncated" => get_in(run, ["prompt_shape", "issue_description_truncated"]),
        "issue_description_truncated_chars" => get_in(run, ["prompt_shape", "issue_description_truncated_chars"]),
        "previous_run_id" => get_in(run, ["prompt_shape", "previous_run_id"]),
        "previous_run_handoff_chars" => get_in(run, ["prompt_shape", "previous_run_handoff_chars"]),
        "included_previous_run_handoff" => get_in(run, ["prompt_shape", "included_previous_run_handoff"])
      },
      "efficiency" => %{
        "changed_file_count" => get_in(run, ["efficiency", "changed_file_count"]),
        "tokens_per_changed_file" => get_in(run, ["efficiency", "tokens_per_changed_file"]),
        "uncached_input_tokens_per_changed_file" => get_in(run, ["efficiency", "uncached_input_tokens_per_changed_file"]),
        "tokens_per_minute" => get_in(run, ["efficiency", "tokens_per_minute"]),
        "cached_input_share_pct" => get_in(run, ["efficiency", "cached_input_share_pct"]),
        "classification" => get_in(run, ["efficiency", "classification"]),
        "primary_label" => get_in(run, ["efficiency", "primary_label"]),
        "flags" => get_in(run, ["efficiency", "flags"]) || []
      },
      "git" => %{
        "branch" => Map.get(git, "branch"),
        "head_commit" => Map.get(git, "head_commit"),
        "head_subject" => Map.get(git, "head_subject"),
        "label" => run_git_label(run),
        "changed_files_label" => changed_files_label(run),
        "diff_summary" => Map.get(git, "diff_summary"),
        "diff_files" => to_solid_value(Map.get(git, "diff_files") || [])
      },
      "hooks" => %{
        "label" => hook_results_label(Map.get(run, "hook_results")),
        "results" => to_solid_value(Map.get(run, "hook_results") || %{})
      },
      "summary" => %{
        "run_id" => Map.get(run, "run_id"),
        "status" => Map.get(run, "status"),
        "tracker_state" => summary_state_transition(Map.get(run, "issue_state_started"), Map.get(run, "issue_state_finished"), Map.get(run, "tracker_transition") || %{}),
        "runtime" => human_duration(Map.get(run, "duration_ms")),
        "queue_wait" => human_duration(Map.get(timing, "queue_wait_ms")),
        "human_wait" => human_duration(Map.get(timing, "blocked_for_human_ms")),
        "turn_count" => Map.get(run, "turn_count"),
        "continuation_turn_count" => Map.get(run, "continuation_turn_count"),
        "tokens" => tokens_label(Map.get(run, "tokens") || %{}),
        "changed_files" => changed_files_label(run),
        "git" => run_git_label(run),
        "hooks" => hook_results_label(Map.get(run, "hook_results")),
        "next_action" => Map.get(run, "next_action"),
        "last_message" => Map.get(run, "last_message"),
        "last_error" => Map.get(run, "last_error")
      }
    }
  end

  defp audit_enabled? do
    observability_setting(:audit_enabled, true)
  end

  defp configured_storage_backend do
    observability_setting(:audit_storage_backend, @default_storage_backend)
  end

  defp store_reasoning_text? do
    observability_setting(:audit_store_reasoning_text, false)
  end

  defp configured_run_limit do
    observability_setting(:audit_runs_per_issue, @default_run_limit)
  end

  defp configured_dashboard_runs do
    observability_setting(:audit_dashboard_runs, @default_dashboard_runs)
  end

  defp configured_issue_rollup_limit do
    observability_setting(:issue_rollup_limit, @default_issue_rollup_limit)
  end

  defp configured_event_limit do
    observability_setting(:audit_event_limit, @default_event_limit)
  end

  defp configured_max_string_length do
    observability_setting(:audit_max_string_length, @default_max_string_length)
  end

  defp configured_max_list_items do
    observability_setting(:audit_max_list_items, @default_max_list_items)
  end

  defp configured_redact_keys do
    observability_setting(:audit_redact_keys, @default_redact_keys)
  end

  defp configured_tracker_summary_template do
    observability_setting(:tracker_summary_template, nil)
  end

  defp configured_expensive_run_uncached_input_threshold do
    observability_setting(
      :expensive_run_uncached_input_threshold,
      @default_expensive_run_uncached_input_threshold
    )
  end

  defp configured_expensive_run_tokens_per_changed_file_threshold do
    observability_setting(
      :expensive_run_tokens_per_changed_file_threshold,
      @default_expensive_run_tokens_per_changed_file_threshold
    )
  end

  defp configured_expensive_run_retry_attempt_threshold do
    observability_setting(
      :expensive_run_retry_attempt_threshold,
      @default_expensive_run_retry_attempt_threshold
    )
  end

  defp observability_setting(field, fallback) do
    try do
      case Config.settings!().observability do
        %{^field => value} when not is_nil(value) -> value
        _ -> fallback
      end
    rescue
      _ -> fallback
    end
  end

  defp log_persist_exception(action, issue_identifier, exception) do
    Logger.warning("Failed to #{action} for #{inspect(issue_identifier)}: #{Exception.message(exception)}")
  end

  defp build_issue_rollup(issue_identifier, runs) when is_binary(issue_identifier) and is_list(runs) do
    sorted_runs = Enum.sort_by(runs, &run_sort_key/1, :desc)
    latest = List.first(sorted_runs)

    if is_map(latest) do
      durations = numeric_field_values(sorted_runs, &Map.get(&1, "duration_ms"))
      queue_waits = numeric_field_values(sorted_runs, &get_in(&1, ["timing", "queue_wait_ms"]))
      handoff_latencies = numeric_field_values(sorted_runs, &get_in(&1, ["timing", "blocked_for_human_ms"]))
      merge_latencies = merge_latency_values(sorted_runs)
      cached_inputs = numeric_field_values(sorted_runs, &get_in(&1, ["tokens", "cached_input_tokens"]))
      uncached_inputs = numeric_field_values(sorted_runs, &get_in(&1, ["tokens", "uncached_input_tokens"]))

      tokens_per_changed_file =
        sorted_runs
        |> Enum.map(&get_in(&1, ["efficiency", "tokens_per_changed_file"]))
        |> Enum.filter(&is_number/1)

      uncached_per_changed_file =
        sorted_runs
        |> Enum.map(&get_in(&1, ["efficiency", "uncached_input_tokens_per_changed_file"]))
        |> Enum.filter(&is_number/1)

      classifications =
        sorted_runs
        |> Enum.map(&get_in(&1, ["efficiency", "classification"]))
        |> Enum.filter(&is_binary/1)

      expensive_runs = Enum.count(classifications, &(&1 == "expensive"))
      cheap_win_runs = Enum.count(classifications, &(&1 == "cheap_win"))
      context_window_heavy_runs = Enum.count(classifications, &(&1 == "context_window_heavy"))
      total_retry_attempts = Enum.reduce(sorted_runs, 0, &(retry_attempt(&1) + &2))

      flags =
        issue_rollup_flags(sorted_runs, %{
          total_retry_attempts: total_retry_attempts,
          avg_uncached_input_tokens_per_changed_file: average_number_or_nil(uncached_per_changed_file),
          expensive_runs: expensive_runs
        })

      classification = issue_rollup_classification(flags, expensive_runs, cheap_win_runs, context_window_heavy_runs)

      %{
        "issue_identifier" => issue_identifier,
        "issue_id" => Map.get(latest, "issue_id"),
        "title" => Map.get(latest, "title"),
        "latest_run_id" => Map.get(latest, "run_id"),
        "latest_status" => Map.get(latest, "status"),
        "latest_state" => Map.get(latest, "issue_state_finished") || Map.get(latest, "issue_state_started"),
        "latest_ended_at" => Map.get(latest, "ended_at") || Map.get(latest, "updated_at") || Map.get(latest, "started_at"),
        "run_count" => length(sorted_runs),
        "completed_runs" => count_runs_by_status(sorted_runs, "completed"),
        "failed_runs" => count_runs_by_status(sorted_runs, "failed"),
        "interrupted_runs" => count_runs_by_status(sorted_runs, "interrupted"),
        "retry_runs" => Enum.count(sorted_runs, &(retry_attempt(&1) > 0)),
        "total_retry_attempts" => total_retry_attempts,
        "total_tokens" => Enum.reduce(sorted_runs, 0, &(token_total(&1) + &2)),
        "total_cached_input_tokens" => Enum.sum(cached_inputs),
        "total_uncached_input_tokens" => Enum.sum(uncached_inputs),
        "avg_uncached_input_tokens_per_run" => average_or_nil(uncached_inputs),
        "avg_tokens_per_changed_file" => average_number_or_nil(tokens_per_changed_file),
        "avg_uncached_input_tokens_per_changed_file" => average_number_or_nil(uncached_per_changed_file),
        "expensive_runs" => expensive_runs,
        "cheap_win_runs" => cheap_win_runs,
        "context_window_heavy_runs" => context_window_heavy_runs,
        "avg_duration_ms" => average_or_nil(durations),
        "avg_queue_wait_ms" => average_or_nil(queue_waits),
        "handoff_count" => length(handoff_latencies),
        "avg_handoff_latency_ms" => average_or_nil(handoff_latencies),
        "merge_run_count" => length(merge_latencies),
        "avg_merge_latency_ms" => average_or_nil(merge_latencies),
        "changed_file_count_latest" => latest_changed_file_count(latest),
        "classification" => classification,
        "primary_label" => issue_rollup_primary_label(classification, flags),
        "flags" => flags,
        "storage_backend" => configured_storage_backend()
      }
    end
  end

  defp build_issue_rollup(_issue_identifier, _runs), do: nil

  defp rollup_sort_key(rollup) when is_map(rollup) do
    {Map.get(rollup, "latest_ended_at"), Map.get(rollup, "latest_run_id"), Map.get(rollup, "issue_identifier")}
  end

  defp count_runs_by_status(runs, status) when is_list(runs) and is_binary(status) do
    Enum.count(runs, &(Map.get(&1, "status") == status))
  end

  defp retry_attempt(run) when is_map(run) do
    case Map.get(run, "retry_attempt") do
      value when is_integer(value) and value > 0 -> value
      _ -> 0
    end
  end

  defp token_total(run) when is_map(run) do
    case get_in(run, ["tokens", "total_tokens"]) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp average_number_or_nil([]), do: nil

  defp average_number_or_nil(values) when is_list(values) do
    values
    |> Enum.sum()
    |> Kernel./(length(values))
    |> Float.round(2)
  end

  defp numeric_field_values(runs, extractor) when is_list(runs) and is_function(extractor, 1) do
    runs
    |> Enum.map(extractor)
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
  end

  defp average_or_nil([]), do: nil

  defp average_or_nil(values) when is_list(values) do
    values
    |> Enum.sum()
    |> Kernel./(length(values))
    |> round()
  end

  defp merge_latency_values(runs) when is_list(runs) do
    Enum.flat_map(runs, fn run ->
      started_state =
        run
        |> Map.get("issue_state_started")
        |> normalize_optional_string()

      duration = Map.get(run, "duration_ms")

      if (started_state && String.downcase(started_state) == "merging" && is_integer(duration)) and duration >= 0 do
        [duration]
      else
        []
      end
    end)
  end

  defp latest_changed_file_count(run) when is_map(run) do
    case get_in(run, ["workspace_metadata", "git", "changed_file_count"]) do
      value when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp efficiency_flags(metrics) when is_map(metrics) do
    uncached_threshold = configured_expensive_run_uncached_input_threshold()
    tokens_per_changed_file_threshold = configured_expensive_run_tokens_per_changed_file_threshold()
    retry_attempt_threshold = configured_expensive_run_retry_attempt_threshold()
    changed_file_count = Map.get(metrics, :changed_file_count, 0)
    uncached = Map.get(metrics, :uncached_input_tokens, 0)
    total = Map.get(metrics, :total_tokens, 0)
    cached = Map.get(metrics, :cached_input_tokens, 0)
    retry_attempt = Map.get(metrics, :retry_attempt, 0)
    tokens_per_changed_file = Map.get(metrics, :tokens_per_changed_file)
    started_state = normalize_optional_string(Map.get(metrics, :issue_state_started))

    []
    |> maybe_add_flag(uncached >= uncached_threshold, "high_uncached_input")
    |> maybe_add_flag(
      is_number(tokens_per_changed_file) and
        tokens_per_changed_file >= tokens_per_changed_file_threshold,
      "high_tokens_per_changed_file"
    )
    |> maybe_add_flag(retry_attempt >= retry_attempt_threshold, "high_retry_overhead")
    |> maybe_add_flag(
      changed_file_count <= 1 and uncached >= max(div(uncached_threshold, 2), 1),
      "high_uncached_input_low_change_yield"
    )
    |> maybe_add_flag(
      total >= uncached_threshold and cached > uncached and uncached < uncached_threshold,
      "context_window_heavy"
    )
    |> maybe_add_flag(
      started_state == "rework" and
        (uncached >= uncached_threshold or
           (is_number(tokens_per_changed_file) and
              tokens_per_changed_file >= tokens_per_changed_file_threshold)),
      "expensive_rework_loop"
    )
  end

  defp efficiency_classification(metrics) when is_map(metrics) do
    flags = Map.get(metrics, :flags, [])
    changed_file_count = Map.get(metrics, :changed_file_count, 0)
    retry_attempt = Map.get(metrics, :retry_attempt, 0)
    uncached = Map.get(metrics, :uncached_input_tokens, 0)
    tokens_per_changed_file = Map.get(metrics, :tokens_per_changed_file)
    uncached_threshold = configured_expensive_run_uncached_input_threshold()
    tokens_per_changed_file_threshold = configured_expensive_run_tokens_per_changed_file_threshold()

    cheap_win? =
      Map.get(metrics, :status) == "completed" and changed_file_count > 0 and retry_attempt == 0 and
        uncached <= max(div(uncached_threshold, 3), 500) and
        is_number(tokens_per_changed_file) and
        tokens_per_changed_file <= Float.round(tokens_per_changed_file_threshold / 3, 2)

    cond do
      Enum.any?(flags, &(&1 in expensive_efficiency_flags())) -> "expensive"
      "context_window_heavy" in flags -> "context_window_heavy"
      cheap_win? -> "cheap_win"
      true -> "normal"
    end
  end

  defp efficiency_primary_label("cheap_win", _flags), do: "Cheap win"
  defp efficiency_primary_label("context_window_heavy", _flags), do: "Context-window heavy"

  defp efficiency_primary_label(_classification, flags) when is_list(flags) do
    cond do
      "high_uncached_input_low_change_yield" in flags -> "High uncached / low output"
      "high_uncached_input" in flags -> "High uncached input"
      "high_tokens_per_changed_file" in flags -> "High tokens / file"
      "high_retry_overhead" in flags -> "Retry overhead"
      "expensive_rework_loop" in flags -> "Expensive rework loop"
      true -> "Normal"
    end
  end

  defp expensive_efficiency_flags do
    [
      "high_uncached_input",
      "high_tokens_per_changed_file",
      "high_retry_overhead",
      "high_uncached_input_low_change_yield",
      "expensive_rework_loop"
    ]
  end

  defp issue_rollup_flags(sorted_runs, metrics) when is_list(sorted_runs) and is_map(metrics) do
    retry_attempt_threshold = configured_expensive_run_retry_attempt_threshold()
    uncached_threshold = configured_expensive_run_uncached_input_threshold()

    expensive_rework_loops =
      Enum.count(sorted_runs, fn run ->
        get_in(run, ["efficiency", "classification"]) == "expensive" and
          normalize_optional_string(Map.get(run, "issue_state_started")) == "rework"
      end)

    []
    |> maybe_add_flag(
      Map.get(metrics, :total_retry_attempts, 0) >= retry_attempt_threshold,
      "high_retry_overhead"
    )
    |> maybe_add_flag(
      is_number(Map.get(metrics, :avg_uncached_input_tokens_per_changed_file)) and
        Map.get(metrics, :avg_uncached_input_tokens_per_changed_file) >=
          Float.round(uncached_threshold / 2, 2),
      "high_uncached_input_low_change_yield"
    )
    |> maybe_add_flag(expensive_rework_loops >= 2, "repeated_expensive_rework_loops")
  end

  defp issue_rollup_classification(flags, expensive_runs, cheap_win_runs, context_window_heavy_runs)
       when is_list(flags) do
    cond do
      flags != [] or expensive_runs > 0 -> "needs_attention"
      context_window_heavy_runs > 0 and cheap_win_runs == 0 -> "context_window_heavy"
      cheap_win_runs > 0 and context_window_heavy_runs == 0 -> "cheap_wins"
      true -> "normal"
    end
  end

  defp issue_rollup_primary_label("needs_attention", flags) when is_list(flags) do
    cond do
      "repeated_expensive_rework_loops" in flags -> "Expensive rework loop"
      "high_uncached_input_low_change_yield" in flags -> "High uncached / low output"
      "high_retry_overhead" in flags -> "Retry overhead"
      true -> "Needs attention"
    end
  end

  defp issue_rollup_primary_label("context_window_heavy", _flags), do: "Context-window heavy"
  defp issue_rollup_primary_label("cheap_wins", _flags), do: "Cheap wins"
  defp issue_rollup_primary_label(_classification, _flags), do: "Normal"

  defp maybe_add_flag(flags, true, flag) when is_list(flags) and is_binary(flag), do: flags ++ [flag]
  defp maybe_add_flag(flags, _condition, _flag) when is_list(flags), do: flags

  defp build_prompt_handoff(nil), do: nil

  defp build_prompt_handoff(run) when is_map(run) do
    lines =
      [
        "- Previous run: #{Map.get(run, "run_id") || "n/a"}",
        "- Status: #{Map.get(run, "status") || "n/a"}",
        "- Tracker state: #{summary_state_transition(Map.get(run, "issue_state_started"), Map.get(run, "issue_state_finished"), Map.get(run, "tracker_transition") || %{}) || "n/a"}",
        "- Changed files: #{changed_files_label(run) || "none"}",
        "- Validation/hooks: #{hook_results_label(Map.get(run, "hook_results")) || "n/a"}",
        "- Tokens: #{tokens_label(Map.get(run, "tokens") || %{})}",
        "- Next action: #{Map.get(run, "next_action") || "n/a"}",
        "- Last error: #{Map.get(run, "last_error") || "none"}"
      ]

    text =
      lines
      |> Enum.reject(&String.ends_with?(&1, "n/a"))
      |> Enum.join("\n")

    if text == "" do
      nil
    else
      %{
        run_id: Map.get(run, "run_id"),
        text: text,
        changed_file_count: latest_changed_file_count(run),
        status: Map.get(run, "status")
      }
    end
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_value()
  defp to_solid_value(value) when is_map(value), do: Map.new(value, fn {key, nested} -> {to_string(key), to_solid_value(nested)} end)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value
end
