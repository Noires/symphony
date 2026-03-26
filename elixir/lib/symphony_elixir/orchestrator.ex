defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls the configured tracker and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, AuditLog, Config, GitHubAccess, Guardrails.Approvals, Guardrails.Overrides, Guardrails.Policy, Guardrails.Rule, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @guardrail_action_cooldown_ms 1_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    cached_input_tokens: 0,
    uncached_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      completed_active_states: %{},
      active_issue_observed_at: %{},
      claimed: MapSet.new(),
      pending_approvals: %{},
      guardrail_rules: %{},
      guardrail_overrides: %{workflow: nil, runs: %{}},
      operator_action_recent: %{},
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()
    guardrail_rules = load_guardrail_rules()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      claimed: MapSet.new(),
      pending_approvals: %{},
      guardrail_rules: guardrail_rules,
      guardrail_overrides: Overrides.empty_state(),
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil
    }

    run_terminal_workspace_cleanup()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)

        state =
          state
          |> record_session_completion_totals(running_entry)
          |> expire_run_scoped_guardrails(running_entry)

        session_id = running_entry_session_id(running_entry)

        state =
          case reason do
            {:approval_unsupported_in_container_boundary, details} ->
              Logger.warning("Agent task requested unsupported approval control in container-boundary mode for issue_id=#{issue_id} session_id=#{session_id}; failing run without retry")

              error =
                details
                |> Map.get(:reason, "container-boundary mode does not support Codex approval requests")
                |> to_string()

              finish_run_with_followups(running_entry, %{
                status: "failed",
                next_action: "unsupported_runtime",
                last_error: error,
                issue_state_finished: running_entry.issue.state
              })

              state
              |> complete_issue(running_entry.issue)
              |> release_issue_claim(issue_id)

            :normal ->
              if Config.settings!().agent.continue_on_active_issue do
                finish_run_with_followups(running_entry, %{
                  status: "completed",
                  next_action: "continuation_retry",
                  issue_state_finished: running_entry.issue.state
                })

                Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

                state
                |> complete_issue(running_entry.issue)
                |> schedule_issue_retry(issue_id, 1, %{
                  identifier: running_entry.identifier,
                  delay_type: :continuation,
                  worker_host: Map.get(running_entry, :worker_host),
                  workspace_path: Map.get(running_entry, :workspace_path)
                })
              else
                transition_result = maybe_transition_completed_issue(running_entry.issue)
                log_completed_issue_transition(issue_id, session_id, transition_result)

                finish_run_with_followups(running_entry, %{
                  status: "completed",
                  next_action: completion_next_action(transition_result),
                  issue_state_finished: completion_issue_state(running_entry.issue.state, transition_result),
                  tracker_transition: audit_tracker_transition(running_entry.issue.state, transition_result)
                })

                Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; active-state continuation disabled, holding issue until tracker state changes")

                state
                |> complete_issue(running_entry.issue)
                |> release_issue_claim(issue_id)
              end

            _ ->
              Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}; scheduling retry")

              next_attempt = next_retry_attempt_from_running(running_entry)
              error = "agent exited: #{inspect(reason)}"

              finish_run_with_followups(running_entry, %{
                status: "failed",
                next_action: "retry",
                last_error: error,
                issue_state_finished: running_entry.issue.state
              })

              schedule_issue_retry(state, issue_id, next_attempt, %{
                identifier: running_entry.identifier,
                error: error,
                worker_host: Map.get(running_entry, :worker_host),
                workspace_path: Map.get(running_entry, :workspace_path)
              })
          end

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        AuditLog.record_runtime_info(updated_running_entry, runtime_info)
        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
        AuditLog.record_codex_update(updated_running_entry, update)

        state =
          state
          |> maybe_consume_guardrail_rule(updated_running_entry, update)
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> prune_guardrail_rules()
      |> prune_guardrail_overrides()
      |> reconcile_running_issues()
      |> maybe_reconcile_pending_approval_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      state =
        state
        |> reconcile_completed_active_issue_states(issues)
        |> reconcile_active_issue_observed_at(issues)

      if available_slots(state) > 0 do
        choose_issues(issues, state)
      else
        state
      end
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_trello_api_key} ->
        Logger.error("Trello API key missing in WORKFLOW.md")
        state

      {:error, :missing_trello_api_token} ->
        Logger.error("Trello API token missing in WORKFLOW.md")
        state

      {:error, :missing_trello_board_id} ->
        Logger.error("Trello board ID missing in WORKFLOW.md")
        state

      {:error, :missing_github_api_token} ->
        Logger.error("GitHub API token missing in WORKFLOW.md")
        state

      {:error, :missing_github_owner} ->
        Logger.error("GitHub owner missing in WORKFLOW.md")
        state

      {:error, :missing_github_repo} ->
        Logger.error("GitHub repository missing in WORKFLOW.md")
        state

      {:error, :missing_github_project_number} ->
        Logger.error("GitHub project number missing in WORKFLOW.md")
        state

      {:error, :invalid_github_project_number} ->
        Logger.error("GitHub project number must be a positive integer in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from tracker: #{inspect(reason)}")
        state

      false ->
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp maybe_reconcile_pending_approval_issues(%State{} = state) do
    %{state | pending_approvals: %{}}
  end

  defp clear_pending_approval(%State{} = state, issue_id, reason, opts)
       when is_binary(issue_id) and is_binary(reason) do
    case Map.get(state.pending_approvals, issue_id) do
      %Approvals{} = approval ->
        if Keyword.get(opts, :record_cancellation_audit, true) do
          maybe_record_approval_cancellation_audit(approval, reason)
        end

        updated_approval =
          approval
          |> Approvals.cancel(reason)
          |> then(fn cancelled ->
            if Keyword.get(opts, :persist_status, true), do: AuditLog.put_guardrail_approval(cancelled)
            cancelled
          end)

        if Keyword.get(opts, :cleanup_workspace, false) do
          cleanup_issue_workspace(updated_approval.issue_identifier, updated_approval.worker_host)
        end

        state =
          %{state | pending_approvals: Map.delete(state.pending_approvals, issue_id)}

        if Keyword.get(opts, :release_claim, true) do
          release_issue_claim(state, issue_id)
        else
          state
        end

      _ ->
        if Keyword.get(opts, :release_claim, true), do: release_issue_claim(state, issue_id), else: state
    end
  end

  defp maybe_record_approval_cancellation_audit(%Approvals{issue_identifier: issue_identifier, run_id: run_id} = approval, reason)
       when is_binary(issue_identifier) and is_binary(run_id) and is_binary(reason) do
    AuditLog.record_run_event(issue_identifier, run_id, Approvals.cancellation_audit_event(approval, reason))
  end

  defp maybe_record_approval_cancellation_audit(_approval, _reason), do: :ok

  defp prune_guardrail_rules(%State{} = state) do
    now = DateTime.utc_now()

    rules =
      Enum.reduce(state.guardrail_rules, %{}, fn {rule_id, rule}, acc ->
        if Rule.active?(rule, now) do
          Map.put(acc, rule_id, rule)
        else
          disabled_rule =
            if rule.enabled == true do
              Rule.disable(rule, reason: "expired")
            else
              rule
            end

          AuditLog.put_guardrail_rule(disabled_rule)
          acc
        end
      end)

    %{state | guardrail_rules: rules}
  end

  defp prune_guardrail_overrides(%State{} = state) do
    now = DateTime.utc_now()
    pruned = Overrides.prune(state.guardrail_overrides, now)

    if state.guardrail_overrides.workflow != pruned.workflow do
      persist_guardrail_override_if_present(state.guardrail_overrides.workflow, reason: "expired")
    end

    Enum.each(state.guardrail_overrides.runs, fn {run_id, override} ->
      unless Map.has_key?(pruned.runs, run_id) do
        persist_guardrail_override_if_present(override, reason: "expired")
      end
    end)

    %{state | guardrail_overrides: pruned}
  end

  defp load_guardrail_rules do
    case AuditLog.list_guardrail_rules(active_only: true) do
      {:ok, rules} ->
        Enum.reduce(rules, %{}, fn snapshot, acc ->
          case Rule.from_snapshot(snapshot) do
            %Rule{id: rule_id} = rule when is_binary(rule_id) ->
              Map.put(acc, rule_id, rule)

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp effective_guardrail_rules(%State{} = state, run_id) do
    state.guardrail_rules
    |> Map.values()
    |> Enum.filter(&Rule.applies_to_run?(&1, run_id))
    |> Enum.filter(&Rule.active?/1)
  end

  defp maybe_consume_guardrail_rule(%State{} = state, running_entry, %{event: event, source: "policy_rule", rule_id: rule_id})
       when event in [:approval_auto_approved, "approval_auto_approved"] and is_binary(rule_id) do
    case Map.get(state.guardrail_rules, rule_id) do
      %Rule{} = rule ->
        updated_rule = Rule.consume(rule)

        if updated_rule == rule do
          state
        else
          AuditLog.put_guardrail_rule(updated_rule)
          maybe_record_guardrail_rule_consumed_audit(running_entry, rule, updated_rule)

          rules =
            if Rule.active?(updated_rule) do
              Map.put(state.guardrail_rules, rule_id, updated_rule)
            else
              Map.delete(state.guardrail_rules, rule_id)
            end

          %{state | guardrail_rules: rules}
        end

      _ ->
        state
    end
  end

  defp maybe_consume_guardrail_rule(%State{} = state, _running_entry, _update), do: state

  defp persist_guardrail_override_if_present(override, opts)

  defp persist_guardrail_override_if_present(%Overrides{} = override, opts) do
    override
    |> Overrides.disable(reason: Keyword.get(opts, :reason))
    |> AuditLog.put_guardrail_override()
  end

  defp persist_guardrail_override_if_present(_override, _opts), do: :ok

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, %{
          status: "interrupted",
          next_action: "workspace_cleanup",
          last_error: "issue moved to terminal state: #{issue.state}",
          issue_state_finished: issue.state
        })

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, %{
          status: "interrupted",
          next_action: "stopped",
          last_error: "issue no longer routed to this worker",
          issue_state_finished: issue.state
        })

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, %{
          status: "interrupted",
          next_action: "stopped",
          last_error: "issue moved to non-active state: #{issue.state}",
          issue_state_finished: issue.state
        })
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)

        terminate_running_issue(state_acc, issue_id, false, %{
          status: "interrupted",
          next_action: "stopped",
          last_error: "issue no longer visible during running-state refresh"
        })
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, audit_attrs) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        if is_map(audit_attrs) do
          finish_run_with_followups(running_entry, audit_attrs)
        end

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false, %{
        status: "failed",
        next_action: "retry",
        last_error: "stalled for #{elapsed_ms}ms without codex activity",
        issue_state_finished: running_entry.issue.state
      })
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        error: "stalled for #{elapsed_ms}ms without codex activity"
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, completed_active_states: completed_active_states} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !completed_in_current_active_state?(issue, completed_active_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil, dispatch_metadata \\ %{}) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, dispatch_metadata)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, dispatch_metadata) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host, dispatch_metadata)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host, dispatch_metadata) do
    run_id = Map.get(dispatch_metadata, :run_id) || generate_run_id()
    started_at = DateTime.utc_now()
    timing = build_run_timing(state, issue, attempt, started_at, normalize_dispatch_metadata(dispatch_metadata))
    guardrail_rules = effective_guardrail_rules(state, run_id)
    guardrails_override = nil

    case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
           AgentRunner.run(
             issue,
             recipient,
             attempt: attempt,
             worker_host: worker_host,
             run_id: run_id,
             guardrail_rules: guardrail_rules,
             guardrails_override: guardrails_override,
             full_access_override: guardrails_override
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running_entry = %{
          pid: pid,
          ref: ref,
          run_id: run_id,
          identifier: issue.identifier,
          issue: issue,
          worker_host: worker_host,
          workspace_path: nil,
          session_id: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: nil,
          codex_app_server_pid: nil,
          codex_input_tokens: 0,
          codex_cached_input_tokens: 0,
          codex_uncached_input_tokens: 0,
          codex_output_tokens: 0,
          codex_total_tokens: 0,
          codex_last_reported_input_tokens: 0,
          codex_last_reported_cached_input_tokens: 0,
          codex_last_reported_output_tokens: 0,
          codex_last_reported_total_tokens: 0,
          turn_count: 0,
          guardrail_rule_ids: Enum.map(guardrail_rules, & &1.id),
          guardrails_override: guardrails_override,
          retry_attempt: normalize_retry_attempt(attempt),
          started_at: started_at
        }

        if Map.has_key?(dispatch_metadata, :run_id) do
          AuditLog.resume_run(
            issue,
            run_id,
            approval_id: Map.get(dispatch_metadata, :resume_approval_id),
            decision: Map.get(dispatch_metadata, :decision),
            decision_scope: Map.get(dispatch_metadata, :decision_scope),
            worker_host: worker_host,
            workspace_path: Map.get(dispatch_metadata, :workspace_path),
            resumed_at: started_at
          )
        else
          AuditLog.start_run(issue,
            run_id: run_id,
            retry_attempt: normalize_retry_attempt(attempt),
            worker_host: worker_host,
            started_at: started_at,
            timing: timing
          )
        end

        maybe_record_human_response_audit(issue.identifier, run_id, timing)

        running =
          Map.put(state.running, issue.id, running_entry)

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id)
        }

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, %Issue{id: issue_id} = issue) when is_binary(issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        completed_active_states: maybe_record_completed_active_state(state.completed_active_states, issue),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp complete_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    scheduled_at = DateTime.utc_now()
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            scheduled_at: scheduled_at,
            identifier: identifier,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          scheduled_at: Map.get(retry_entry, :scheduled_at)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], metadata)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp reconcile_completed_active_issue_states(%State{} = state, issues) when is_list(issues) do
    active_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    completed_active_states =
      Enum.reduce(state.completed_active_states, %{}, fn {issue_id, state_name}, acc ->
        if MapSet.member?(active_issue_ids, issue_id) do
          Map.put(acc, issue_id, state_name)
        else
          acc
        end
      end)

    %{state | completed_active_states: completed_active_states}
  end

  defp reconcile_completed_active_issue_states(state, _issues), do: state

  defp reconcile_active_issue_observed_at(%State{} = state, issues) when is_list(issues) do
    now = DateTime.utc_now()

    observed =
      Enum.reduce(issues, %{}, fn
        %Issue{id: issue_id, state: state_name}, acc when is_binary(issue_id) and is_binary(state_name) ->
          normalized_state = normalize_issue_state(state_name)

          observed_at =
            case Map.get(state.active_issue_observed_at, issue_id) do
              %{state: ^normalized_state, observed_at: %DateTime{} = existing} -> existing
              _ -> now
            end

          Map.put(acc, issue_id, %{state: normalized_state, observed_at: observed_at})

        _issue, acc ->
          acc
      end)

    %{state | active_issue_observed_at: observed}
  end

  defp reconcile_active_issue_observed_at(state, _issues), do: state

  defp completed_in_current_active_state?(%Issue{id: issue_id, state: state_name}, completed_active_states)
       when is_binary(issue_id) and is_binary(state_name) and is_map(completed_active_states) do
    Map.get(completed_active_states, issue_id) == normalize_issue_state(state_name)
  end

  defp completed_in_current_active_state?(_issue, _completed_active_states), do: false

  defp maybe_record_completed_active_state(completed_active_states, %Issue{id: issue_id, state: state_name})
       when is_binary(issue_id) and is_binary(state_name) and is_map(completed_active_states) do
    Map.put(completed_active_states, issue_id, normalize_issue_state(state_name))
  end

  defp maybe_record_completed_active_state(completed_active_states, _issue)
       when is_map(completed_active_states),
       do: completed_active_states

  defp maybe_transition_completed_issue(%Issue{id: issue_id, state: current_state})
       when is_binary(issue_id) and is_binary(current_state) do
    case completed_issue_state_for_issue(current_state) do
      target_state when is_binary(target_state) ->
        normalized_target_state = Schema.normalize_issue_state(target_state)

        if Schema.normalize_issue_state(current_state) == normalized_target_state do
          :noop
        else
          case Tracker.update_issue_state(issue_id, target_state) do
            :ok -> {:ok, target_state}
            {:error, reason} -> {:error, target_state, reason}
          end
        end

      _ ->
        :noop
    end
  end

  defp maybe_transition_completed_issue(_issue), do: :noop

  defp completed_issue_state_for_issue(current_state) when is_binary(current_state) do
    agent = Config.settings!().agent
    normalized_current_state = Schema.normalize_issue_state(current_state)

    cond do
      normalized_current_state == "merging" and GitHubAccess.effective_config_value("landing_mode") == "pull_request" ->
        "Human Review"

      true ->
        Map.get(
          agent.completed_issue_state_by_state,
          normalized_current_state,
          agent.completed_issue_state
        )
    end
  end

  defp completed_issue_state_for_issue(_current_state), do: nil

  defp log_completed_issue_transition(issue_id, session_id, {:ok, target_state}) do
    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; moved issue to state=#{target_state}")
  end

  defp log_completed_issue_transition(issue_id, session_id, {:error, target_state, reason}) do
    Logger.warning("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; failed to move issue to state=#{target_state}: #{inspect(reason)}")
  end

  defp log_completed_issue_transition(_issue_id, _session_id, :noop), do: :ok

  defp finish_run_with_followups(running_entry, attrs) when is_map(running_entry) and is_map(attrs) do
    AuditLog.finish_run(running_entry, attrs)
    maybe_publish_trello_run_summary(running_entry, attrs)
  end

  defp finish_run_with_followups(_running_entry, _attrs), do: :ok

  defp maybe_publish_trello_run_summary(_running_entry, %{next_action: "continuation_retry"}), do: :ok

  defp maybe_publish_trello_run_summary(%{issue: %Issue{id: issue_id, identifier: identifier}, run_id: run_id}, _attrs)
       when is_binary(issue_id) and is_binary(identifier) and is_binary(run_id) do
    if trello_run_summary_enabled?() do
      case AuditLog.get_run(identifier, run_id) do
        {:ok, run} ->
          now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

          case Tracker.create_comment(issue_id, AuditLog.render_trello_run_summary(run)) do
            :ok ->
              AuditLog.update_run_summary(identifier, run_id, %{
                "trello_summary" => %{
                  "status" => "posted",
                  "posted_at" => now
                }
              })

            {:error, reason} ->
              Logger.warning("Failed to publish Trello run summary for issue_id=#{issue_id} issue_identifier=#{identifier}: #{inspect(reason)}")

              AuditLog.update_run_summary(identifier, run_id, %{
                "trello_summary" => %{
                  "status" => "failed",
                  "error" => inspect(reason),
                  "attempted_at" => now
                }
              })
          end

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_publish_trello_run_summary(_running_entry, _attrs), do: :ok

  defp trello_run_summary_enabled? do
    settings = Config.settings!()
    settings.tracker.kind == "trello" and settings.observability.trello_run_summary_enabled
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp generate_run_id do
    Ecto.UUID.generate()
  end

  defp completion_next_action({:ok, _target_state}), do: "tracker_state_updated"
  defp completion_next_action({:error, _target_state, _reason}), do: "tracker_state_update_failed"

  defp completion_next_action(:noop) do
    "released"
  end

  defp completion_next_action(_other), do: "released"

  defp completion_issue_state(_current_state, {:ok, target_state}) when is_binary(target_state), do: target_state
  defp completion_issue_state(current_state, _transition_result), do: current_state

  defp audit_tracker_transition(current_state, {:ok, target_state}) do
    %{"status" => "ok", "from" => current_state, "to" => target_state, "error" => nil}
  end

  defp audit_tracker_transition(current_state, {:error, target_state, reason}) do
    %{"status" => "error", "from" => current_state, "to" => target_state, "error" => inspect(reason)}
  end

  defp audit_tracker_transition(current_state, :noop) do
    case completed_issue_state_for_issue(current_state) do
      target_state when is_binary(target_state) ->
        %{"status" => "noop", "from" => current_state, "to" => target_state, "error" => nil}

      _ ->
        nil
    end
  end

  defp audit_tracker_transition(_current_state, _result), do: nil

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp build_run_timing(%State{} = state, %Issue{id: issue_id, identifier: identifier, state: state_name}, attempt, started_at, dispatch_metadata)
       when is_binary(issue_id) and is_binary(identifier) and is_binary(state_name) and is_map(dispatch_metadata) do
    queue_started_at =
      cond do
        is_integer(attempt) and attempt > 0 and match?(%DateTime{}, Map.get(dispatch_metadata, :scheduled_at)) ->
          Map.get(dispatch_metadata, :scheduled_at)

        true ->
          case Map.get(state.active_issue_observed_at, issue_id) do
            %{state: observed_state, observed_at: %DateTime{} = observed_at} ->
              if observed_state == normalize_issue_state(state_name), do: observed_at, else: nil

            _ ->
              nil
          end
      end

    queue_source =
      cond do
        is_integer(attempt) and attempt > 0 and match?(%DateTime{}, Map.get(dispatch_metadata, :scheduled_at)) ->
          "retry_scheduled"

        match?(%DateTime{}, queue_started_at) ->
          "active_state_observed"

        true ->
          nil
      end

    %{}
    |> maybe_put_timing_value("queue_started_at", queue_started_at)
    |> maybe_put_timing_value("queue_wait_ms", duration_ms(queue_started_at, started_at))
    |> maybe_put_timing_string("queue_source", queue_source)
    |> Map.merge(blocked_for_human_timing(issue_id, identifier, state_name, started_at))
    |> case do
      timing when map_size(timing) == 0 -> nil
      timing -> timing
    end
  end

  defp build_run_timing(_state, _issue, _attempt, _started_at, _dispatch_metadata), do: nil

  defp blocked_for_human_timing(issue_id, issue_identifier, current_state, started_at)
       when is_binary(issue_id) and is_binary(issue_identifier) and is_binary(current_state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    with {:ok, %{"run_id" => previous_run_id, "ended_at" => ended_at, "issue_state_finished" => previous_state}} <- AuditLog.latest_run(issue_identifier),
         %DateTime{} = previous_ended_at <- parse_iso8601_datetime(ended_at),
         true <- is_binary(previous_state),
         previous_normalized = normalize_issue_state(previous_state),
         current_normalized = normalize_issue_state(current_state),
         false <- MapSet.member?(active_states, previous_normalized),
         false <- MapSet.member?(terminal_states, previous_normalized),
         true <- MapSet.member?(active_states, current_normalized),
         {:ok, %{} = marker} <-
           Tracker.fetch_human_response_marker(issue_id,
             since: previous_ended_at,
             issue_identifier: issue_identifier,
             previous_state: previous_state,
             current_state: current_state,
             active_states: Config.settings!().tracker.active_states
           ),
         %DateTime{} = human_response_at <- parse_iso8601_datetime(Map.get(marker, "at")),
         true <- DateTime.compare(human_response_at, started_at) in [:lt, :eq] do
      %{
        "blocked_for_human_ms" => duration_ms(previous_ended_at, human_response_at),
        "blocked_started_at" => DateTime.to_iso8601(DateTime.truncate(previous_ended_at, :second)),
        "blocked_resumed_at" => DateTime.to_iso8601(DateTime.truncate(started_at, :second)),
        "blocked_from_run_id" => previous_run_id,
        "human_response_at" => DateTime.to_iso8601(DateTime.truncate(human_response_at, :second)),
        "human_response_marker" => marker,
        "queue_wait_after_human_ms" => duration_ms(human_response_at, started_at)
      }
    else
      {:error, reason} ->
        Logger.debug("Failed to fetch human response marker for #{issue_identifier}: #{inspect(reason)}")
        %{}

      _ ->
        %{}
    end
  end

  defp blocked_for_human_timing(_issue_id, _issue_identifier, _current_state, _started_at), do: %{}

  defp maybe_record_human_response_audit(issue_identifier, run_id, %{} = timing)
       when is_binary(issue_identifier) and is_binary(run_id) do
    maybe_record_human_response_marker_event(issue_identifier, run_id, timing)
    maybe_record_handoff_annotation(issue_identifier, run_id, timing)
    :ok
  end

  defp maybe_record_human_response_audit(_issue_identifier, _run_id, _timing), do: :ok

  defp maybe_record_human_response_marker_event(issue_identifier, run_id, timing) do
    case Map.get(timing, "human_response_marker") do
      %{} = marker ->
        AuditLog.record_run_event(issue_identifier, run_id, %{
          kind: "tracker",
          event: "human_response_detected",
          summary: Map.get(marker, "summary") || "human response detected",
          details: marker
        })

      _ ->
        :ok
    end
  end

  defp maybe_record_handoff_annotation(issue_identifier, run_id, timing) do
    previous_run_id = Map.get(timing, "blocked_from_run_id")
    human_response_at = Map.get(timing, "human_response_at")

    if is_binary(previous_run_id) and is_binary(human_response_at) do
      AuditLog.update_run_summary(issue_identifier, previous_run_id, %{
        "handoff" => %{
          "status" => "responded",
          "responded_at" => human_response_at,
          "response_marker" => Map.get(timing, "human_response_marker"),
          "followup_run_id" => run_id,
          "queue_wait_after_human_ms" => Map.get(timing, "queue_wait_after_human_ms")
        }
      })
    else
      :ok
    end
  end

  defp maybe_put_timing_value(timing, _key, nil), do: timing

  defp maybe_put_timing_value(timing, key, %DateTime{} = value) when is_map(timing) do
    Map.put(timing, key, DateTime.to_iso8601(DateTime.truncate(value, :second)))
  end

  defp maybe_put_timing_value(timing, key, value) when is_map(timing) do
    Map.put(timing, key, value)
  end

  defp maybe_put_timing_string(timing, _key, nil), do: timing

  defp maybe_put_timing_string(timing, key, value) when is_binary(value) and is_map(timing) do
    Map.put(timing, key, value)
  end

  defp normalize_dispatch_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_dispatch_metadata(_metadata), do: %{}

  defp parse_iso8601_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_iso8601_datetime(_value), do: nil

  defp duration_ms(%DateTime{} = started_at, %DateTime{} = ended_at) do
    max(DateTime.diff(ended_at, started_at, :millisecond), 0)
  end

  defp duration_ms(_, _), do: nil

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  defp handle_guardrail_approval_decision(%State{} = state, approval_id, decision, opts)
       when decision in ["allow_once", "allow_for_session", "allow_via_rule", "deny"] do
    if Config.settings!().guardrails.enabled != true do
      {:error, :guardrails_disabled, state}
    else
      case find_pending_approval(state, approval_id) do
        {:ok, issue_id, %Approvals{} = approval} ->
          actor = normalize_operator_value(Keyword.get(opts, :actor))
          reason = normalize_operator_value(Keyword.get(opts, :reason))
          scope = normalize_operator_value(Keyword.get(opts, :scope))

          with {:ok, state} <- register_operator_action(state, {:approval, approval_id}, decision) do
            resolved_approval =
              Approvals.resolve(
                approval,
                decision,
                resolved_by: actor,
                reason: reason,
                decision_scope: scope
              )

            AuditLog.put_guardrail_approval(resolved_approval)
            maybe_record_approval_decision_audit(resolved_approval)

            case decision do
              "deny" ->
                state =
                  state
                  |> clear_pending_approval(issue_id, "operator denied guardrail action",
                    persist_status: false,
                    record_cancellation_audit: false,
                    release_claim: false
                  )
                  |> complete_denied_approval_issue(approval)
                  |> release_issue_claim(issue_id)

                {:ok, %{approval: Approvals.snapshot_entry(resolved_approval)}, state}

              _ ->
                with {:ok, %Issue{} = issue} <- fetch_issue_for_resume(approval),
                     {:ok, state, response} <- apply_approval_resume_decision(state, issue_id, issue, resolved_approval, decision, opts) do
                  {:ok, response, state}
                else
                  {:error, reason} ->
                    stale_approval =
                      resolved_approval
                      |> Approvals.cancel("approval decision stale: #{inspect(reason)}")
                      |> Map.put(:resolution_reason, reason_to_string(reason))

                    AuditLog.put_guardrail_approval(stale_approval)

                    state =
                      clear_pending_approval(state, issue_id, reason_to_string(reason),
                        persist_status: false,
                        record_cancellation_audit: false
                      )

                    {:error, reason, state}
                end
            end
          else
            {:error, reason, state} ->
              {:error, reason, state}
          end

        :error ->
          handle_missing_guardrail_approval_decision(state, approval_id, decision)
      end
    end
  end

  defp disable_guardrail_rule_in_state(%State{} = state, rule_id, opts) do
    if Config.settings!().guardrails.enabled != true do
      {:error, :guardrails_disabled, state}
    else
      case find_guardrail_rule(state, rule_id) do
        {:ok, %Rule{} = rule} ->
          if guardrail_rule_inactive?(rule) do
            {:ok, %{rule: Rule.snapshot_entry(rule), idempotent: true}, state}
          else
            with {:ok, state} <- register_operator_action(state, {:rule, rule_id}, "disable") do
              updated_rule =
                Rule.disable(rule,
                  reason: normalize_operator_value(Keyword.get(opts, :reason)) || "operator disabled rule"
                )

              AuditLog.put_guardrail_rule(updated_rule)
              maybe_record_guardrail_rule_lifecycle_audit(updated_rule, "guardrail_rule_disabled", opts)

              {:ok, %{rule: Rule.snapshot_entry(updated_rule)}, put_guardrail_rule(state, updated_rule)}
            end
          end

        :error ->
          {:error, :rule_not_found, state}
      end
    end
  end

  defp enable_guardrail_rule_in_state(%State{} = state, rule_id, opts) do
    if Config.settings!().guardrails.enabled != true do
      {:error, :guardrails_disabled, state}
    else
      case find_guardrail_rule(state, rule_id) do
        {:ok, %Rule{} = rule} ->
          if Rule.active?(rule) do
            {:ok, %{rule: Rule.snapshot_entry(rule), idempotent: true}, state}
          else
            with {:ok, state} <- register_operator_action(state, {:rule, rule_id}, "enable") do
              updated_rule =
                Rule.enable(rule,
                  reason: normalize_operator_value(Keyword.get(opts, :reason)) || "operator enabled rule"
                )

              AuditLog.put_guardrail_rule(updated_rule)
              maybe_record_guardrail_rule_lifecycle_audit(updated_rule, "guardrail_rule_enabled", opts)

              {:ok, %{rule: Rule.snapshot_entry(updated_rule)}, put_guardrail_rule(state, updated_rule)}
            end
          end

        :error ->
          {:error, :rule_not_found, state}
      end
    end
  end

  defp expire_guardrail_rule_in_state(%State{} = state, rule_id, opts) do
    if Config.settings!().guardrails.enabled != true do
      {:error, :guardrails_disabled, state}
    else
      case find_guardrail_rule(state, rule_id) do
        {:ok, %Rule{} = rule} ->
          if guardrail_rule_inactive?(rule) do
            {:ok, %{rule: Rule.snapshot_entry(rule), idempotent: true}, state}
          else
            with {:ok, state} <- register_operator_action(state, {:rule, rule_id}, "expire") do
              updated_rule =
                Rule.expire(rule,
                  reason: normalize_operator_value(Keyword.get(opts, :reason)) || "operator expired rule"
                )

              AuditLog.put_guardrail_rule(updated_rule)
              maybe_record_guardrail_rule_lifecycle_audit(updated_rule, "guardrail_rule_expired", opts)

              {:ok, %{rule: Rule.snapshot_entry(updated_rule)}, put_guardrail_rule(state, updated_rule)}
            end
          end

        :error ->
          {:error, :rule_not_found, state}
      end
    end
  end

  defp enable_run_full_access_override(%State{} = state, run_id, opts) do
    if Config.settings!().guardrails.enabled != true do
      {:error, :guardrails_disabled, state}
    else
      case Map.get(state.guardrail_overrides.runs, run_id) do
        %Overrides{} = override ->
          if Overrides.active?(override) do
            {:ok, %{override: Overrides.snapshot_entry(override), idempotent: true}, state}
          else
            with {:ok, state} <- register_operator_action(state, {:run_override, run_id}, "enable") do
              override =
                Overrides.full_access_override(:run, run_id,
                  ttl_ms: Config.settings!().guardrails.full_access_run_ttl_ms,
                  reason: normalize_operator_value(Keyword.get(opts, :reason)),
                  actor: normalize_operator_value(Keyword.get(opts, :actor))
                )

              AuditLog.put_guardrail_override(override)
              maybe_record_guardrail_override_lifecycle_audit(override, "guardrail_full_access_enabled", opts)

              state = %{state | guardrail_overrides: %{state.guardrail_overrides | runs: Map.put(state.guardrail_overrides.runs, run_id, override)}}

              case find_pending_approval_by_run_id(state, run_id) do
                {:ok, issue_id, approval} ->
                  resolved_approval =
                    Approvals.resolve(
                      approval,
                      "allow_for_session",
                      resolved_by: normalize_operator_value(Keyword.get(opts, :actor)),
                      reason: normalize_operator_value(Keyword.get(opts, :reason)) || "operator enabled full access for run",
                      decision_scope: "run"
                    )

                  AuditLog.put_guardrail_approval(resolved_approval)
                  maybe_record_approval_decision_audit(resolved_approval)

                  case fetch_issue_for_resume(approval) do
                    {:ok, %Issue{} = issue} ->
                      state =
                        state
                        |> clear_pending_approval(issue_id, "approval resolved by run full access",
                          persist_status: false,
                          record_cancellation_audit: false,
                          release_claim: false
                        )
                        |> resume_issue_after_guardrail_decision(
                          issue_id,
                          issue,
                          approval,
                          "allow_for_session",
                          "run"
                        )

                      {:ok, %{approval: Approvals.snapshot_entry(resolved_approval), override: Overrides.snapshot_entry(override)}, state}

                    {:error, _reason} ->
                      state =
                        clear_pending_approval(state, issue_id, "full access approval became stale",
                          persist_status: false,
                          record_cancellation_audit: false
                        )

                      {:ok, %{override: Overrides.snapshot_entry(override), approval_issue_id: issue_id}, state}
                  end

                :error ->
                  {:ok, %{override: Overrides.snapshot_entry(override)}, state}
              end
            end
          end

        _ ->
          with {:ok, state} <- register_operator_action(state, {:run_override, run_id}, "enable") do
            override =
              Overrides.full_access_override(:run, run_id,
                ttl_ms: Config.settings!().guardrails.full_access_run_ttl_ms,
                reason: normalize_operator_value(Keyword.get(opts, :reason)),
                actor: normalize_operator_value(Keyword.get(opts, :actor))
              )

            AuditLog.put_guardrail_override(override)
            maybe_record_guardrail_override_lifecycle_audit(override, "guardrail_full_access_enabled", opts)

            state = %{state | guardrail_overrides: %{state.guardrail_overrides | runs: Map.put(state.guardrail_overrides.runs, run_id, override)}}

            case find_pending_approval_by_run_id(state, run_id) do
              {:ok, issue_id, approval} ->
                resolved_approval =
                  Approvals.resolve(
                    approval,
                    "allow_for_session",
                    resolved_by: normalize_operator_value(Keyword.get(opts, :actor)),
                    reason: normalize_operator_value(Keyword.get(opts, :reason)) || "operator enabled full access for run",
                    decision_scope: "run"
                  )

                AuditLog.put_guardrail_approval(resolved_approval)
                maybe_record_approval_decision_audit(resolved_approval)

                case fetch_issue_for_resume(approval) do
                  {:ok, %Issue{} = issue} ->
                    state =
                      state
                      |> clear_pending_approval(issue_id, "approval resolved by run full access",
                        persist_status: false,
                        record_cancellation_audit: false,
                        release_claim: false
                      )
                      |> resume_issue_after_guardrail_decision(
                        issue_id,
                        issue,
                        approval,
                        "allow_for_session",
                        "run"
                      )

                    {:ok, %{approval: Approvals.snapshot_entry(resolved_approval), override: Overrides.snapshot_entry(override)}, state}

                  {:error, _reason} ->
                    state =
                      clear_pending_approval(state, issue_id, "full access approval became stale",
                        persist_status: false,
                        record_cancellation_audit: false
                      )

                    {:ok, %{override: Overrides.snapshot_entry(override), approval_issue_id: issue_id}, state}
                end

              :error ->
                {:ok, %{override: Overrides.snapshot_entry(override)}, state}
            end
          end
      end
    end
  end

  defp disable_run_full_access_override(%State{} = state, run_id, opts) do
    if Config.settings!().guardrails.enabled != true do
      {:error, :guardrails_disabled, state}
    else
      case Map.get(state.guardrail_overrides.runs, run_id) do
        %Overrides{} = override ->
          if !Overrides.active?(override) do
            {:ok, %{override: Overrides.snapshot_entry(override), idempotent: true}, state}
          else
            with {:ok, state} <- register_operator_action(state, {:run_override, run_id}, "disable") do
              updated_override =
                Overrides.disable(override,
                  reason: normalize_operator_value(Keyword.get(opts, :reason)) || "operator disabled full access"
                )

              AuditLog.put_guardrail_override(updated_override)
              maybe_record_guardrail_override_lifecycle_audit(updated_override, "guardrail_full_access_disabled", opts)

              state = %{state | guardrail_overrides: %{state.guardrail_overrides | runs: Map.delete(state.guardrail_overrides.runs, run_id)}}
              {:ok, %{override: Overrides.snapshot_entry(updated_override)}, state}
            end
          end

        _ ->
          case find_run_override_snapshot(run_id) do
            {:ok, %Overrides{} = override} ->
              {:ok, %{override: Overrides.snapshot_entry(override), idempotent: true}, state}

            _ ->
              {:error, :override_not_found, state}
          end
      end
    end
  end

  defp enable_workflow_full_access_override(%State{} = state, opts) do
    if Config.settings!().guardrails.enabled != true do
      {{:error, :guardrails_disabled}, state}
    else
      case state.guardrail_overrides.workflow do
        %Overrides{} = override ->
          if Overrides.active?(override) do
            {{:ok, %{override: Overrides.snapshot_entry(override), idempotent: true}}, state}
          else
            case register_operator_action(state, :workflow_override, "enable") do
              {:ok, state} ->
                override =
                  Overrides.full_access_override(:workflow, "workflow",
                    ttl_ms: Config.settings!().guardrails.full_access_workflow_ttl_ms,
                    reason: normalize_operator_value(Keyword.get(opts, :reason)),
                    actor: normalize_operator_value(Keyword.get(opts, :actor))
                  )

                AuditLog.put_guardrail_override(override)
                maybe_record_guardrail_override_lifecycle_audit(override, "guardrail_workflow_full_access_enabled", opts)

                {{:ok, %{override: Overrides.snapshot_entry(override)}}, %{state | guardrail_overrides: %{state.guardrail_overrides | workflow: override}}}

              {:error, reason, state} ->
                {{:error, reason}, state}
            end
          end

        _ ->
          case register_operator_action(state, :workflow_override, "enable") do
            {:ok, state} ->
              override =
                Overrides.full_access_override(:workflow, "workflow",
                  ttl_ms: Config.settings!().guardrails.full_access_workflow_ttl_ms,
                  reason: normalize_operator_value(Keyword.get(opts, :reason)),
                  actor: normalize_operator_value(Keyword.get(opts, :actor))
                )

              AuditLog.put_guardrail_override(override)
              maybe_record_guardrail_override_lifecycle_audit(override, "guardrail_workflow_full_access_enabled", opts)

              {{:ok, %{override: Overrides.snapshot_entry(override)}}, %{state | guardrail_overrides: %{state.guardrail_overrides | workflow: override}}}

            {:error, reason, state} ->
              {{:error, reason}, state}
          end
      end
    end
  end

  defp disable_workflow_full_access_override(%State{} = state, opts) do
    if Config.settings!().guardrails.enabled != true do
      {:error, :guardrails_disabled, state}
    else
      case state.guardrail_overrides.workflow do
        %Overrides{} = override ->
          if !Overrides.active?(override) do
            {:ok, %{override: Overrides.snapshot_entry(override), idempotent: true}, state}
          else
            with {:ok, state} <- register_operator_action(state, :workflow_override, "disable") do
              updated_override =
                Overrides.disable(override,
                  reason: normalize_operator_value(Keyword.get(opts, :reason)) || "operator disabled workflow full access"
                )

              AuditLog.put_guardrail_override(updated_override)
              maybe_record_guardrail_override_lifecycle_audit(updated_override, "guardrail_workflow_full_access_disabled", opts)

              {:ok, %{override: Overrides.snapshot_entry(updated_override)}, %{state | guardrail_overrides: %{state.guardrail_overrides | workflow: nil}}}
            end
          end

        _ ->
          case find_workflow_override_snapshot() do
            {:ok, %Overrides{} = override} ->
              {:ok, %{override: Overrides.snapshot_entry(override), idempotent: true}, state}

            _ ->
              {:error, :override_not_found, state}
          end
      end
    end
  end

  defp explain_guardrail_approval_in_state(%State{} = state, approval_id) when is_binary(approval_id) do
    case find_guardrail_approval_snapshot(state, approval_id) do
      {:ok, %Approvals{} = approval} ->
        override = Overrides.effective_override(state.guardrail_overrides, approval.run_id)
        rules = effective_guardrail_rules(state, approval.run_id)

        explanation =
          Policy.explain_approval_request(
            approval.method || "unknown",
            approval.payload || %{},
            %{
              run_id: approval.run_id,
              session_id: approval.session_id,
              workspace_path: approval.workspace_path,
              full_access_override: override,
              guardrail_rules: rules
            }
          )

        {:ok, %{approval: Approvals.snapshot_entry(approval), explanation: explanation}, state}

      :error ->
        {:error, :approval_not_found, state}
    end
  end

  defp apply_approval_resume_decision(%State{} = state, issue_id, %Issue{} = issue, %Approvals{} = approval, decision, opts) do
    with {:ok, state, rule} <- build_rule_for_approval_decision(state, approval, decision, opts) do
      state =
        state
        |> clear_pending_approval(issue_id, "approval resolved by operator",
          persist_status: false,
          record_cancellation_audit: false,
          release_claim: false
        )
        |> resume_issue_after_guardrail_decision(issue_id, issue, approval, decision, rule && rule.scope)

      {:ok, state,
       %{
         approval: Approvals.snapshot_entry(approval),
         rule: rule && Rule.snapshot_entry(rule)
       }}
    end
  end

  defp build_rule_for_approval_decision(%State{} = state, approval, decision, opts)
       when decision in ["allow_once", "allow_for_session", "allow_via_rule"] do
    scope =
      case decision do
        "allow_via_rule" -> normalize_operator_value(Keyword.get(opts, :scope)) || "workflow"
        _ -> "run"
      end

    rule =
      Rule.from_approval(
        approval,
        decision,
        scope: scope,
        created_by: normalize_operator_value(Keyword.get(opts, :actor)),
        reason: normalize_operator_value(Keyword.get(opts, :reason))
      )

    AuditLog.put_guardrail_rule(rule)
    maybe_record_guardrail_rule_created_audit(approval, rule, decision)

    {:ok, %{state | guardrail_rules: Map.put(state.guardrail_rules, rule.id, rule)}, rule}
  end

  defp build_rule_for_approval_decision(state, _approval, _decision, _opts), do: {:ok, state, nil}

  defp resume_issue_after_guardrail_decision(%State{} = state, issue_id, %Issue{} = issue, %Approvals{} = approval, decision, decision_scope)
       when is_binary(issue_id) and is_binary(decision) do
    dispatch_metadata = %{
      run_id: approval.run_id,
      resume_approval_id: approval.id,
      decision: decision,
      decision_scope: decision_scope,
      workspace_path: approval.workspace_path,
      worker_host: approval.worker_host,
      identifier: approval.issue_identifier
    }

    if dispatch_slots_available?(issue, state) and worker_slots_available?(state, approval.worker_host) do
      dispatch_issue(state, issue, nil, approval.worker_host, dispatch_metadata)
    else
      schedule_issue_retry(
        state,
        issue_id,
        1,
        dispatch_metadata
        |> Map.put(:error, "guardrail approval waiting for capacity")
        |> Map.put(:delay_type, :continuation)
      )
    end
  end

  defp fetch_issue_for_resume(%Approvals{issue_id: issue_id}) when is_binary(issue_id) do
    case Tracker.fetch_issue_states_by_ids([issue_id]) do
      {:ok, [%Issue{} = issue | _]} ->
        if MapSet.member?(active_state_set(), normalize_issue_state(issue.state)) do
          {:ok, issue}
        else
          {:error, {:issue_not_active, issue.state}}
        end

      {:ok, []} ->
        {:error, :issue_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_issue_for_resume(_approval), do: {:error, :issue_not_found}

  defp find_pending_approval(%State{} = state, approval_id) when is_binary(approval_id) do
    Enum.find_value(state.pending_approvals, :error, fn {issue_id, approval} ->
      if approval.id == approval_id, do: {:ok, issue_id, approval}, else: nil
    end)
  end

  defp find_pending_approval_by_run_id(%State{} = state, run_id) when is_binary(run_id) do
    Enum.find_value(state.pending_approvals, :error, fn {issue_id, approval} ->
      if approval.run_id == run_id, do: {:ok, issue_id, approval}, else: nil
    end)
  end

  defp handle_missing_guardrail_approval_decision(%State{} = state, approval_id, decision)
       when is_binary(approval_id) and is_binary(decision) do
    case find_guardrail_approval_snapshot(state, approval_id) do
      {:ok, %Approvals{} = approval} ->
        cond do
          approval.decision == decision and approval.status in ["approved", "denied_by_operator"] ->
            {:ok, %{approval: Approvals.snapshot_entry(approval), idempotent: true}, state}

          is_binary(approval.decision) and approval.decision != decision ->
            {:error, {:approval_already_resolved, approval.decision}, state}

          approval.status == "cancelled" ->
            {:error, :approval_stale, state}

          approval.status in ["pending_review", "denied_by_policy"] ->
            {:error, :approval_stale, state}

          true ->
            {:error, :approval_not_found, state}
        end

      :error ->
        {:error, :approval_not_found, state}
    end
  end

  defp find_guardrail_approval_snapshot(%State{} = state, approval_id) when is_binary(approval_id) do
    case find_pending_approval(state, approval_id) do
      {:ok, _issue_id, %Approvals{} = approval} ->
        {:ok, approval}

      :error ->
        case AuditLog.get_guardrail_approval(approval_id) do
          {:ok, snapshot} ->
            case Approvals.from_snapshot(snapshot) do
              %Approvals{} = approval -> {:ok, approval}
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end

  defp find_guardrail_rule(%State{} = state, rule_id) when is_binary(rule_id) do
    case Map.get(state.guardrail_rules, rule_id) do
      %Rule{} = rule ->
        {:ok, rule}

      _ ->
        case AuditLog.get_guardrail_rule(rule_id) do
          {:ok, snapshot} ->
            case Rule.from_snapshot(snapshot) do
              %Rule{} = rule -> {:ok, rule}
              _ -> :error
            end

          _ ->
            :error
        end
    end
  end

  defp find_run_override_snapshot(run_id) when is_binary(run_id) do
    with {:ok, overrides} <- AuditLog.list_guardrail_overrides(active_only: false),
         %{} = snapshot <-
           Enum.find(overrides, fn snapshot ->
             Map.get(snapshot, "scope") == "run" and Map.get(snapshot, "scope_key") == run_id
           end),
         %Overrides{} = override <- Overrides.from_snapshot(snapshot) do
      {:ok, override}
    else
      _ -> :error
    end
  end

  defp find_workflow_override_snapshot do
    with {:ok, overrides} <- AuditLog.list_guardrail_overrides(active_only: false),
         %{} = snapshot <-
           Enum.find(overrides, fn snapshot ->
             Map.get(snapshot, "scope") == "workflow"
           end),
         %Overrides{} = override <- Overrides.from_snapshot(snapshot) do
      {:ok, override}
    else
      _ -> :error
    end
  end

  defp put_guardrail_rule(%State{} = state, %Rule{id: rule_id} = rule) when is_binary(rule_id) do
    rules =
      if Rule.active?(rule) do
        Map.put(state.guardrail_rules, rule_id, rule)
      else
        Map.delete(state.guardrail_rules, rule_id)
      end

    %{state | guardrail_rules: rules}
  end

  defp guardrail_rule_inactive?(%Rule{} = rule), do: !Rule.active?(rule)
  defp guardrail_rule_inactive?(_rule), do: true

  defp register_operator_action(%State{} = state, resource_key, action_name) do
    now_ms = System.monotonic_time(:millisecond)

    recent =
      state.operator_action_recent
      |> Enum.reject(fn {_key, meta} ->
        now_ms - Map.get(meta, :at_ms, 0) > @guardrail_action_cooldown_ms
      end)
      |> Map.new()

    case Map.get(recent, resource_key) do
      %{action: previous_action, at_ms: at_ms}
      when is_binary(previous_action) and previous_action != action_name and now_ms - at_ms <= @guardrail_action_cooldown_ms ->
        {:error, :operator_action_rate_limited, %{state | operator_action_recent: recent}}

      _ ->
        {:ok,
         %{
           state
           | operator_action_recent: Map.put(recent, resource_key, %{action: action_name, at_ms: now_ms})
         }}
    end
  end

  defp maybe_record_approval_decision_audit(%Approvals{issue_identifier: issue_identifier, run_id: run_id} = approval)
       when is_binary(issue_identifier) and is_binary(run_id) do
    AuditLog.record_run_event(
      issue_identifier,
      run_id,
      Approvals.decision_audit_event(approval),
      %{
        "pending_approval" => Approvals.snapshot_entry(approval)
      }
    )
  end

  defp maybe_record_approval_decision_audit(_approval), do: :ok

  defp maybe_record_guardrail_rule_created_audit(%Approvals{issue_identifier: issue_identifier, run_id: run_id}, %Rule{} = rule, decision)
       when is_binary(issue_identifier) and is_binary(run_id) do
    AuditLog.record_run_event(issue_identifier, run_id, %{
      kind: "guardrail",
      event: "guardrail_rule_created",
      summary: "guardrail rule created from #{decision}",
      details: %{
        "rule" => Rule.snapshot_entry(rule),
        "decision" => decision
      }
    })
  end

  defp maybe_record_guardrail_rule_created_audit(_approval, _rule, _decision), do: :ok

  defp maybe_record_guardrail_rule_lifecycle_audit(%Rule{} = rule, event_name, opts)
       when is_binary(event_name) and is_list(opts) do
    with source_approval_id when is_binary(source_approval_id) <- rule.source_approval_id,
         {:ok, approval_snapshot} <- AuditLog.get_guardrail_approval(source_approval_id),
         %Approvals{} = approval <- Approvals.from_snapshot(approval_snapshot),
         issue_identifier when is_binary(issue_identifier) <- approval.issue_identifier,
         run_id when is_binary(run_id) <- approval.run_id do
      AuditLog.record_run_event(issue_identifier, run_id, %{
        kind: "guardrail",
        event: event_name,
        summary: guardrail_rule_lifecycle_summary(event_name, rule),
        details: %{
          "rule" => Rule.snapshot_entry(rule),
          "actor" => normalize_operator_value(Keyword.get(opts, :actor)),
          "reason" => normalize_operator_value(Keyword.get(opts, :reason))
        }
      })
    else
      _ -> :ok
    end
  end

  defp maybe_record_guardrail_override_lifecycle_audit(%Overrides{} = override, event_name, opts)
       when is_binary(event_name) and is_list(opts) do
    _ = {override, event_name, opts}
    :ok
  end

  defp maybe_record_guardrail_rule_consumed_audit(running_entry, %Rule{} = rule, %Rule{} = updated_rule) do
    AuditLog.record_run_event(running_entry.identifier, running_entry.run_id, %{
      kind: "guardrail",
      event: "guardrail_rule_consumed",
      summary: "guardrail rule matched during run",
      details: %{
        "rule_id" => rule.id,
        "remaining_uses_before" => rule.remaining_uses,
        "remaining_uses_after" => updated_rule.remaining_uses,
        "enabled_after" => updated_rule.enabled
      }
    })
  end

  defp maybe_record_guardrail_rule_consumed_audit(_running_entry, _rule, _updated_rule), do: :ok

  defp guardrail_rule_lifecycle_summary("guardrail_rule_enabled", %Rule{id: rule_id}),
    do: "guardrail rule enabled: #{rule_id}"

  defp guardrail_rule_lifecycle_summary("guardrail_rule_disabled", %Rule{id: rule_id}),
    do: "guardrail rule disabled: #{rule_id}"

  defp guardrail_rule_lifecycle_summary("guardrail_rule_expired", %Rule{id: rule_id}),
    do: "guardrail rule expired: #{rule_id}"

  defp guardrail_rule_lifecycle_summary(_event_name, %Rule{id: rule_id}),
    do: "guardrail rule updated: #{rule_id}"

  defp complete_denied_approval_issue(%State{} = state, %Approvals{issue_id: issue_id, issue_state: issue_state})
       when is_binary(issue_id) and is_binary(issue_state) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        completed_active_states: Map.put(state.completed_active_states, issue_id, normalize_issue_state(issue_state)),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp complete_denied_approval_issue(%State{} = state, %Approvals{issue_id: issue_id})
       when is_binary(issue_id),
       do: complete_issue(state, issue_id)

  defp complete_denied_approval_issue(%State{} = state, _approval), do: state

  defp expire_run_scoped_guardrails(%State{} = state, %{run_id: run_id})
       when is_binary(run_id) do
    rules =
      Enum.reduce(state.guardrail_rules, %{}, fn {rule_id, rule}, acc ->
        if rule.scope == "run" and rule.scope_key == run_id do
          AuditLog.put_guardrail_rule(Rule.disable(rule, reason: "run ended"))
          acc
        else
          Map.put(acc, rule_id, rule)
        end
      end)

    overrides =
      case Map.get(state.guardrail_overrides.runs, run_id) do
        %Overrides{} = override ->
          AuditLog.put_guardrail_override(Overrides.disable(override, reason: "run ended"))
          %{state.guardrail_overrides | runs: Map.delete(state.guardrail_overrides.runs, run_id)}

        _ ->
          state.guardrail_overrides
      end

    %{state | guardrail_rules: rules, guardrail_overrides: overrides}
  end

  defp expire_run_scoped_guardrails(%State{} = state, _running_entry), do: state

  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)

  defp normalize_operator_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_operator_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_operator_value()
  defp normalize_operator_value(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_operator_value(_value), do: nil

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec decide_guardrail_approval(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide_guardrail_approval(approval_id, decision, opts \\ []) do
    decide_guardrail_approval(__MODULE__, approval_id, decision, opts)
  end

  @spec decide_guardrail_approval(GenServer.server(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def decide_guardrail_approval(server, approval_id, decision, opts)
      when is_binary(approval_id) and is_binary(decision) do
    _ = {server, approval_id, decision, opts}
    {:error, :approval_controls_unsupported}
  end

  @spec disable_guardrail_rule(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_guardrail_rule(rule_id, opts \\ []) do
    disable_guardrail_rule(__MODULE__, rule_id, opts)
  end

  @spec disable_guardrail_rule(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_guardrail_rule(server, rule_id, opts) when is_binary(rule_id) do
    if Process.whereis(server) do
      GenServer.call(server, {:disable_guardrail_rule, rule_id, opts}, 30_000)
    else
      {:error, :unavailable}
    end
  end

  @spec enable_guardrail_rule(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_guardrail_rule(rule_id, opts \\ []) do
    enable_guardrail_rule(__MODULE__, rule_id, opts)
  end

  @spec enable_guardrail_rule(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_guardrail_rule(server, rule_id, opts) when is_binary(rule_id) do
    if Process.whereis(server) do
      GenServer.call(server, {:enable_guardrail_rule, rule_id, opts}, 30_000)
    else
      {:error, :unavailable}
    end
  end

  @spec expire_guardrail_rule(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def expire_guardrail_rule(rule_id, opts \\ []) do
    expire_guardrail_rule(__MODULE__, rule_id, opts)
  end

  @spec expire_guardrail_rule(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def expire_guardrail_rule(server, rule_id, opts) when is_binary(rule_id) do
    if Process.whereis(server) do
      GenServer.call(server, {:expire_guardrail_rule, rule_id, opts}, 30_000)
    else
      {:error, :unavailable}
    end
  end

  @spec explain_guardrail_approval(String.t()) :: {:ok, map()} | {:error, term()}
  def explain_guardrail_approval(approval_id) do
    explain_guardrail_approval(__MODULE__, approval_id)
  end

  @spec explain_guardrail_approval(GenServer.server(), String.t()) :: {:ok, map()} | {:error, term()}
  def explain_guardrail_approval(server, approval_id) when is_binary(approval_id) do
    _ = {server, approval_id}
    {:error, :approval_controls_unsupported}
  end

  @spec enable_full_access_for_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_full_access_for_run(run_id, opts \\ []) do
    enable_full_access_for_run(__MODULE__, run_id, opts)
  end

  @spec enable_full_access_for_run(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_full_access_for_run(server, run_id, opts) when is_binary(run_id) do
    _ = {server, run_id, opts}
    {:error, :approval_controls_unsupported}
  end

  @spec disable_full_access_for_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_full_access_for_run(run_id, opts \\ []) do
    disable_full_access_for_run(__MODULE__, run_id, opts)
  end

  @spec disable_full_access_for_run(GenServer.server(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_full_access_for_run(server, run_id, opts) when is_binary(run_id) do
    _ = {server, run_id, opts}
    {:error, :approval_controls_unsupported}
  end

  @spec enable_full_access_for_workflow(keyword()) :: {:ok, map()} | {:error, term()}
  def enable_full_access_for_workflow(opts \\ []) do
    enable_full_access_for_workflow(__MODULE__, opts)
  end

  @spec enable_full_access_for_workflow(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def enable_full_access_for_workflow(server, opts) do
    _ = {server, opts}
    {:error, :approval_controls_unsupported}
  end

  @spec disable_full_access_for_workflow(keyword()) :: {:ok, map()} | {:error, term()}
  def disable_full_access_for_workflow(opts \\ []) do
    disable_full_access_for_workflow(__MODULE__, opts)
  end

  @spec disable_full_access_for_workflow(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def disable_full_access_for_workflow(server, opts) do
    _ = {server, opts}
    {:error, :approval_controls_unsupported}
  end

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_cached_input_tokens: Map.get(metadata, :codex_cached_input_tokens, 0),
          codex_uncached_input_tokens: Map.get(metadata, :codex_uncached_input_tokens, 0),
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    pending_approvals =
      state.pending_approvals
      |> Enum.map(fn {issue_id, approval} ->
        approval
        |> Approvals.snapshot_entry()
        |> Map.put(:issue_id, issue_id)
      end)

    guardrail_rules =
      state.guardrail_rules
      |> Map.values()
      |> Enum.filter(&Rule.active?/1)
      |> Enum.map(&Rule.snapshot_entry/1)

    guardrail_overrides =
      state.guardrail_overrides
      |> Overrides.active_entries(now)
      |> Enum.map(&Overrides.snapshot_entry/1)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       pending_approvals: pending_approvals,
       guardrail_rules: guardrail_rules,
       guardrail_overrides: guardrail_overrides,
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call({:decide_guardrail_approval, approval_id, decision, opts}, _from, state) do
    if Config.approval_controls_supported?() do
      case handle_guardrail_approval_decision(state, approval_id, decision, opts) do
        {:ok, response, state} ->
          notify_dashboard()
          {:reply, {:ok, response}, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :approval_controls_unsupported}, state}
    end
  end

  def handle_call({:disable_guardrail_rule, rule_id, opts}, _from, state) do
    case disable_guardrail_rule_in_state(state, rule_id, opts) do
      {:ok, response, state} ->
        notify_dashboard()
        {:reply, {:ok, response}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enable_guardrail_rule, rule_id, opts}, _from, state) do
    case enable_guardrail_rule_in_state(state, rule_id, opts) do
      {:ok, response, state} ->
        notify_dashboard()
        {:reply, {:ok, response}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:expire_guardrail_rule, rule_id, opts}, _from, state) do
    case expire_guardrail_rule_in_state(state, rule_id, opts) do
      {:ok, response, state} ->
        notify_dashboard()
        {:reply, {:ok, response}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:explain_guardrail_approval, approval_id}, _from, state) do
    if Config.approval_controls_supported?() do
      case explain_guardrail_approval_in_state(state, approval_id) do
        {:ok, response, state} ->
          {:reply, {:ok, response}, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :approval_controls_unsupported}, state}
    end
  end

  def handle_call({:enable_full_access_for_run, run_id, opts}, _from, state) do
    if Config.approval_controls_supported?() do
      case enable_run_full_access_override(state, run_id, opts) do
        {:ok, response, state} ->
          notify_dashboard()
          {:reply, {:ok, response}, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :approval_controls_unsupported}, state}
    end
  end

  def handle_call({:disable_full_access_for_run, run_id, opts}, _from, state) do
    if Config.approval_controls_supported?() do
      case disable_run_full_access_override(state, run_id, opts) do
        {:ok, response, state} ->
          notify_dashboard()
          {:reply, {:ok, response}, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :approval_controls_unsupported}, state}
    end
  end

  def handle_call({:enable_full_access_for_workflow, opts}, _from, state) do
    if Config.approval_controls_supported?() do
      case enable_workflow_full_access_override(state, opts) do
        {{:ok, response}, state} ->
          notify_dashboard()
          {:reply, {:ok, response}, state}

        {{:error, reason}, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :approval_controls_unsupported}, state}
    end
  end

  def handle_call({:disable_full_access_for_workflow, opts}, _from, state) do
    if Config.approval_controls_supported?() do
      case disable_workflow_full_access_override(state, opts) do
        {:ok, response, state} ->
          notify_dashboard()
          {:reply, {:ok, response}, state}

        {:error, reason, state} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :approval_controls_unsupported}, state}
    end
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_cached_input_tokens = Map.get(running_entry, :codex_cached_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_cached_input = Map.get(running_entry, :codex_last_reported_cached_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    next_input_tokens = codex_input_tokens + token_delta.input_tokens
    next_cached_input_tokens = codex_cached_input_tokens + token_delta.cached_input_tokens

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: next_input_tokens,
        codex_cached_input_tokens: next_cached_input_tokens,
        codex_uncached_input_tokens: max(next_input_tokens - next_cached_input_tokens, 0),
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_cached_input_tokens: max(last_reported_cached_input, token_delta.cached_input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens

    cached_input_tokens =
      Map.get(codex_totals, :cached_input_tokens, 0) + Map.get(token_delta, :cached_input_tokens, 0)

    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      cached_input_tokens: max(0, cached_input_tokens),
      uncached_input_tokens: max(0, input_tokens - cached_input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :cached_input,
        usage,
        :codex_last_reported_cached_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, cached_input, output, total] ->
      %{
        input_tokens: input.delta,
        cached_input_tokens: cached_input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        cached_input_reported: cached_input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :cached_input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :cachedInputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "cached_input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "cachedInputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :cached_input),
    do:
      payload_get(usage, [
        "cached_input_tokens",
        :cached_input_tokens,
        "cachedInputTokens",
        :cachedInputTokens,
        "cached_input",
        :cached_input
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
