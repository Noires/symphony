defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single tracker issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{AuditLog, Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    try do
      case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
        :ok ->
          :ok

        {:error, {:approval_unsupported_in_container_boundary, details}} ->
          exit({:approval_unsupported_in_container_boundary, details})

        {:error, reason} ->
          Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
          raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
      end
    catch
      :exit, {:approval_unsupported_in_container_boundary, details} ->
        Logger.warning("Agent run hit unsupported approval request in container-boundary mode for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} details=#{inspect(details)}")

        :erlang.raise(:exit, {:approval_unsupported_in_container_boundary, details}, __STACKTRACE__)

      kind, reason ->
        Logger.error(
          "Agent runner crashed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} kind=#{inspect(kind)} reason=#{inspect(reason)} stacktrace=#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")
    run_id = Keyword.get(opts, :run_id)

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <-
                 observed_hook(run_id, issue, "before_run", fn ->
                   Workspace.run_before_run_hook(workspace, issue, worker_host)
                 end),
               :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host),
               :ok <-
                 observed_hook(run_id, issue, "after_success", fn ->
                   Workspace.run_after_success_hook(workspace, issue, worker_host)
                 end) do
            :ok
          end
        after
          observed_after_run_hook(run_id, issue, workspace, worker_host)
          record_workspace_metadata(run_id, issue, workspace, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)

    continue_on_active_issue =
      Keyword.get(opts, :continue_on_active_issue, Config.settings!().agent.continue_on_active_issue)

    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <-
           AppServer.start_session(
             workspace,
             worker_host: worker_host,
             guardrail_rules: Keyword.get(opts, :guardrail_rules, []),
             guardrails_override: Keyword.get(opts, :guardrails_override),
             full_access_override: Keyword.get(opts, :full_access_override)
           ) do
      try do
        do_run_codex_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          continue_on_active_issue,
          1,
          max_turns
        )
      after
        AppServer.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         continue_on_active_issue,
         turn_number,
         max_turns
       ) do
    prompt_result = build_turn_prompt_result(issue, opts, turn_number, max_turns)
    prompt = Map.fetch!(prompt_result, :prompt)
    maybe_record_prompt_rendered(Keyword.get(opts, :run_id), issue, prompt_result, turn_number)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue),
             run_id: Keyword.get(opts, :run_id)
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

      if continue_on_active_issue do
        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              continue_on_active_issue,
              turn_number + 1,
              max_turns
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
      else
        Logger.info("Active-state continuation disabled for #{issue_context(issue)}; returning after completed turn=#{turn_number}/#{max_turns}")

        :ok
      end
    end
  end

  defp build_turn_prompt_result(issue, opts, 1, _max_turns) do
    PromptBuilder.build_prompt_result(issue, opts)
  end

  defp build_turn_prompt_result(_issue, _opts, turn_number, max_turns) do
    prompt = """
    Continuation guidance:

    - The previous Codex turn completed normally, but the tracker issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """

    %{
      prompt: prompt,
      metadata: %{
        "rendered_prompt_chars" => byte_size(prompt)
      }
    }
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp maybe_record_prompt_rendered(run_id, %Issue{identifier: identifier}, %{prompt: prompt, metadata: metadata}, turn_number)
       when is_binary(run_id) and is_binary(identifier) and is_binary(prompt) and is_map(metadata) and is_integer(turn_number) do
    summary_updates =
      if turn_number == 1 do
        %{
          "prompt_shape" => metadata,
          "continuation_turn_count" => 0
        }
      else
        %{
          "continuation_turn_count" => max(turn_number - 1, 0)
        }
      end

    AuditLog.record_run_event(
      identifier,
      run_id,
      %{
        kind: "prompt",
        event: if(turn_number == 1, do: "initial_prompt_rendered", else: "continuation_prompt_rendered"),
        summary:
          if(
            turn_number == 1,
            do: "initial prompt rendered (#{byte_size(prompt)} chars)",
            else: "continuation prompt rendered for turn #{turn_number} (#{byte_size(prompt)} chars)"
          ),
        details: %{
          turn_number: turn_number,
          prompt_chars: byte_size(prompt),
          prompt_shape: metadata
        }
      },
      summary_updates
    )
  end

  defp maybe_record_prompt_rendered(_run_id, _issue, _prompt_result, _turn_number), do: :ok

  defp observed_after_run_hook(run_id, issue, workspace, worker_host) do
    observed_hook(run_id, issue, "after_run", fn ->
      Workspace.run_after_run_hook_result(workspace, issue, worker_host)
    end)
  end

  defp record_workspace_metadata(run_id, %Issue{identifier: identifier} = issue, workspace, worker_host)
       when is_binary(run_id) and is_binary(identifier) and is_binary(workspace) do
    case Workspace.collect_audit_workspace_metadata(workspace, worker_host) do
      {:ok, metadata} ->
        running_entry = workspace_metadata_entry(run_id, issue, workspace, worker_host)
        AuditLog.record_workspace_metadata(running_entry, metadata)

      {:error, reason} ->
        AuditLog.record_run_event(identifier, run_id, %{
          kind: "workspace",
          event: "workspace_metadata_failed",
          summary: "workspace metadata capture failed",
          details: %{
            reason: inspect(reason),
            workspace_path: workspace,
            worker_host: worker_host
          }
        })
    end
  end

  defp record_workspace_metadata(_run_id, _issue, _workspace, _worker_host), do: :ok

  defp observed_hook(run_id, %Issue{identifier: identifier}, hook_name, fun)
       when is_binary(run_id) and is_binary(identifier) and is_binary(hook_name) and is_function(fun, 0) do
    started_at = DateTime.utc_now()

    AuditLog.record_run_event(identifier, run_id, %{
      kind: "hook",
      event: "#{hook_name}_started",
      recorded_at: started_at,
      summary: "#{hook_name} hook started",
      details: %{hook: hook_name}
    })

    result = fun.()
    finished_at = DateTime.utc_now()
    duration_ms = max(DateTime.diff(finished_at, started_at, :millisecond), 0)

    case result do
      :ok ->
        AuditLog.record_run_event(
          identifier,
          run_id,
          %{
            kind: "hook",
            event: "#{hook_name}_completed",
            recorded_at: finished_at,
            summary: "#{hook_name} hook completed",
            details: %{hook: hook_name, duration_ms: duration_ms}
          },
          %{
            "hook_results" => %{
              hook_name => %{
                "status" => "ok",
                "duration_ms" => duration_ms,
                "finished_at" => DateTime.to_iso8601(DateTime.truncate(finished_at, :millisecond))
              }
            }
          }
        )

      {:error, reason} ->
        AuditLog.record_run_event(
          identifier,
          run_id,
          %{
            kind: "hook",
            event: "#{hook_name}_failed",
            recorded_at: finished_at,
            summary: "#{hook_name} hook failed",
            details: %{hook: hook_name, duration_ms: duration_ms, reason: inspect(reason)}
          },
          %{
            "hook_results" => %{
              hook_name => %{
                "status" => "error",
                "duration_ms" => duration_ms,
                "finished_at" => DateTime.to_iso8601(DateTime.truncate(finished_at, :millisecond)),
                "error" => inspect(reason)
              }
            }
          }
        )
    end

    result
  end

  defp observed_hook(_run_id, _issue, _hook_name, fun) when is_function(fun, 0), do: fun.()

  defp workspace_metadata_entry(run_id, issue, workspace, worker_host) do
    %{
      run_id: run_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: worker_host,
      workspace_path: workspace,
      session_id: nil,
      turn_count: 0,
      started_at: DateTime.utc_now(),
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0
    }
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
