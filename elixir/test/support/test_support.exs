defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.AppServer
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Linear.Client
      alias SymphonyElixir.Linear.Issue
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          install_fake_executable!: 3,
          path_separator: 0,
          prepend_to_path: 1,
          prepend_to_path: 2,
          symlinks_supported?: 0,
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          shell_path: 1,
          stop_default_http_server: 0
        ]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Workflow.clear_workflow_file_path()
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
          Application.delete_env(:symphony_elixir, :memory_tracker_human_response_markers)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def path_separator do
    if match?({:win32, _}, :os.type()), do: ";", else: ":"
  end

  def prepend_to_path(entry, current_path \\ System.get_env("PATH"))

  def prepend_to_path(entry, current_path) when is_binary(entry) do
    [entry, current_path || ""]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(path_separator())
  end

  def install_fake_executable!(dir, name, script)
      when is_binary(dir) and is_binary(name) and is_binary(script) do
    executable_path = Path.join(dir, name)

    File.mkdir_p!(dir)
    File.write!(executable_path, script)
    File.chmod!(executable_path, 0o755)

    if match?({:win32, _}, :os.type()) do
      sh_path =
        SymphonyElixir.Shell.find_local_posix_shell(:sh) ||
          raise "sh not found for fake executable wrapper"

      wrapper_path = executable_path <> ".cmd"

      File.write!(
        wrapper_path,
        [
          "@echo off",
          "\"#{Path.expand(sh_path)}\" \"#{Path.expand(executable_path)}\" %*"
        ]
        |> Enum.join("\r\n")
      )
    end

    executable_path
  end

  def symlinks_supported? do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-symlink-support-#{System.unique_integer([:positive])}"
      )

    target = Path.join(test_root, "target")
    link = Path.join(test_root, "link")

    try do
      File.mkdir_p!(target)

      case File.ln_s(target, link) do
        :ok -> true
        {:error, _reason} -> false
      end
    after
      File.rm_rf(test_root)
    end
  end

  def shell_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> shell_escape()
  end

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
           {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_api_access_token: nil,
          tracker_project_slug: "project",
          tracker_board_id: nil,
          tracker_owner: nil,
          tracker_repo: nil,
          tracker_project_number: nil,
          tracker_status_field_name: "Status",
          tracker_assignee: nil,
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          continue_on_active_issue: true,
          max_issue_description_prompt_chars: nil,
          include_full_issue_description_in_prompt: true,
          handoff_summary_enabled: false,
          completed_issue_state: nil,
          completed_issue_state_by_state: %{},
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          codex_command: "codex app-server",
          codex_approval_policy: %{reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}},
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          guardrails_enabled: false,
          guardrails_operator_token: nil,
          guardrails_default_review_mode: "review",
          guardrails_builtin_rule_preset: "safe",
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_success: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          observability_audit_enabled: true,
          observability_audit_storage_backend: "flat_files",
          observability_audit_runs_per_issue: 20,
          observability_audit_dashboard_runs: 8,
          observability_issue_rollup_limit: 8,
          observability_audit_event_limit: 200,
          observability_audit_max_string_length: 4_000,
          observability_audit_max_list_items: 50,
          observability_diff_preview_enabled: true,
          observability_diff_preview_max_files: 10,
          observability_diff_preview_hunks_per_file: 3,
          observability_diff_preview_max_line_length: 240,
          observability_audit_redact_keys: ["api_key", "api_token", "token", "secret", "password", "authorization", "cookie", "auth"],
          observability_audit_store_reasoning_text: false,
          observability_trello_run_summary_enabled: true,
          observability_tracker_summary_template: nil,
          observability_expensive_run_uncached_input_threshold: 8_000,
          observability_expensive_run_tokens_per_changed_file_threshold: 4_000,
          observability_expensive_run_retry_attempt_threshold: 2,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)

    tracker_api_key =
      if Keyword.has_key?(overrides, :tracker_api_key) do
        Keyword.get(config, :tracker_api_key)
      else
        Keyword.get(config, :tracker_api_token)
      end

    tracker_api_access_token = Keyword.get(config, :tracker_api_access_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_board_id = Keyword.get(config, :tracker_board_id)
    tracker_owner = Keyword.get(config, :tracker_owner)
    tracker_repo = Keyword.get(config, :tracker_repo)
    tracker_project_number = Keyword.get(config, :tracker_project_number)
    tracker_status_field_name = Keyword.get(config, :tracker_status_field_name)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    continue_on_active_issue = Keyword.get(config, :continue_on_active_issue)
    max_issue_description_prompt_chars = Keyword.get(config, :max_issue_description_prompt_chars)
    include_full_issue_description_in_prompt = Keyword.get(config, :include_full_issue_description_in_prompt)
    handoff_summary_enabled = Keyword.get(config, :handoff_summary_enabled)
    completed_issue_state = Keyword.get(config, :completed_issue_state)
    completed_issue_state_by_state = Keyword.get(config, :completed_issue_state_by_state)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    guardrails_enabled = Keyword.get(config, :guardrails_enabled)
    guardrails_operator_token = Keyword.get(config, :guardrails_operator_token)
    guardrails_default_review_mode = Keyword.get(config, :guardrails_default_review_mode)
    guardrails_builtin_rule_preset = Keyword.get(config, :guardrails_builtin_rule_preset)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_success = Keyword.get(config, :hook_after_success)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    observability_audit_enabled = Keyword.get(config, :observability_audit_enabled)
    observability_audit_storage_backend = Keyword.get(config, :observability_audit_storage_backend)
    observability_audit_runs_per_issue = Keyword.get(config, :observability_audit_runs_per_issue)
    observability_audit_dashboard_runs = Keyword.get(config, :observability_audit_dashboard_runs)
    observability_issue_rollup_limit = Keyword.get(config, :observability_issue_rollup_limit)
    observability_audit_event_limit = Keyword.get(config, :observability_audit_event_limit)
    observability_audit_max_string_length = Keyword.get(config, :observability_audit_max_string_length)
    observability_audit_max_list_items = Keyword.get(config, :observability_audit_max_list_items)
    observability_diff_preview_enabled = Keyword.get(config, :observability_diff_preview_enabled)
    observability_diff_preview_max_files = Keyword.get(config, :observability_diff_preview_max_files)
    observability_diff_preview_hunks_per_file = Keyword.get(config, :observability_diff_preview_hunks_per_file)
    observability_diff_preview_max_line_length = Keyword.get(config, :observability_diff_preview_max_line_length)
    observability_audit_redact_keys = Keyword.get(config, :observability_audit_redact_keys)
    observability_audit_store_reasoning_text = Keyword.get(config, :observability_audit_store_reasoning_text)
    observability_trello_run_summary_enabled = Keyword.get(config, :observability_trello_run_summary_enabled)
    observability_tracker_summary_template = Keyword.get(config, :observability_tracker_summary_template)
    observability_expensive_run_uncached_input_threshold = Keyword.get(config, :observability_expensive_run_uncached_input_threshold)
    observability_expensive_run_tokens_per_changed_file_threshold = Keyword.get(config, :observability_expensive_run_tokens_per_changed_file_threshold)
    observability_expensive_run_retry_attempt_threshold = Keyword.get(config, :observability_expensive_run_retry_attempt_threshold)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_key)}",
        "  api_token: #{yaml_value(tracker_api_access_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  board_id: #{yaml_value(tracker_board_id)}",
        "  owner: #{yaml_value(tracker_owner)}",
        "  repo: #{yaml_value(tracker_repo)}",
        "  project_number: #{yaml_value(tracker_project_number)}",
        "  status_field_name: #{yaml_value(tracker_status_field_name)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  continue_on_active_issue: #{yaml_value(continue_on_active_issue)}",
        "  max_issue_description_prompt_chars: #{yaml_value(max_issue_description_prompt_chars)}",
        "  include_full_issue_description_in_prompt: #{yaml_value(include_full_issue_description_in_prompt)}",
        "  handoff_summary_enabled: #{yaml_value(handoff_summary_enabled)}",
        "  completed_issue_state: #{yaml_value(completed_issue_state)}",
        "  completed_issue_state_by_state: #{yaml_value(completed_issue_state_by_state)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        guardrails_yaml(
          guardrails_enabled,
          guardrails_operator_token,
          guardrails_default_review_mode,
          guardrails_builtin_rule_preset
        ),
        hooks_yaml(hook_after_create, hook_before_run, hook_after_success, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(
          observability_enabled,
          observability_refresh_ms,
          observability_render_interval_ms,
          observability_audit_enabled,
          observability_audit_storage_backend,
          observability_audit_runs_per_issue,
          observability_audit_dashboard_runs,
          observability_issue_rollup_limit,
          observability_audit_event_limit,
          observability_audit_max_string_length,
          observability_audit_max_list_items,
          observability_diff_preview_enabled,
          observability_diff_preview_max_files,
          observability_diff_preview_hunks_per_file,
          observability_diff_preview_max_line_length,
          observability_audit_redact_keys,
          observability_audit_store_reasoning_text,
          observability_trello_run_summary_enabled,
          observability_tracker_summary_template,
          observability_expensive_run_uncached_input_threshold,
          observability_expensive_run_tokens_per_changed_file_threshold,
          observability_expensive_run_retry_attempt_threshold
        ),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "''") <> "'"
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_success, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_success", hook_after_success),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp guardrails_yaml(enabled, operator_token, default_review_mode, builtin_rule_preset) do
    [
      "guardrails:",
      "  enabled: #{yaml_value(enabled)}",
      "  operator_token: #{yaml_value(operator_token)}",
      "  default_review_mode: #{yaml_value(default_review_mode)}",
      "  builtin_rule_preset: #{yaml_value(builtin_rule_preset)}"
    ]
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(
         enabled,
         refresh_ms,
         render_interval_ms,
         audit_enabled,
         audit_storage_backend,
         audit_runs_per_issue,
         audit_dashboard_runs,
         issue_rollup_limit,
         audit_event_limit,
         audit_max_string_length,
         audit_max_list_items,
         diff_preview_enabled,
         diff_preview_max_files,
         diff_preview_hunks_per_file,
         diff_preview_max_line_length,
         audit_redact_keys,
         audit_store_reasoning_text,
         trello_run_summary_enabled,
         tracker_summary_template,
         expensive_run_uncached_input_threshold,
         expensive_run_tokens_per_changed_file_threshold,
         expensive_run_retry_attempt_threshold
       ) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}",
      "  audit_enabled: #{yaml_value(audit_enabled)}",
      "  audit_storage_backend: #{yaml_value(audit_storage_backend)}",
      "  audit_runs_per_issue: #{yaml_value(audit_runs_per_issue)}",
      "  audit_dashboard_runs: #{yaml_value(audit_dashboard_runs)}",
      "  issue_rollup_limit: #{yaml_value(issue_rollup_limit)}",
      "  audit_event_limit: #{yaml_value(audit_event_limit)}",
      "  audit_max_string_length: #{yaml_value(audit_max_string_length)}",
      "  audit_max_list_items: #{yaml_value(audit_max_list_items)}",
      "  diff_preview_enabled: #{yaml_value(diff_preview_enabled)}",
      "  diff_preview_max_files: #{yaml_value(diff_preview_max_files)}",
      "  diff_preview_hunks_per_file: #{yaml_value(diff_preview_hunks_per_file)}",
      "  diff_preview_max_line_length: #{yaml_value(diff_preview_max_line_length)}",
      "  audit_redact_keys: #{yaml_value(audit_redact_keys)}",
      "  audit_store_reasoning_text: #{yaml_value(audit_store_reasoning_text)}",
      "  trello_run_summary_enabled: #{yaml_value(trello_run_summary_enabled)}",
      "  tracker_summary_template: #{yaml_value(tracker_summary_template)}",
      "  expensive_run_uncached_input_threshold: #{yaml_value(expensive_run_uncached_input_threshold)}",
      "  expensive_run_tokens_per_changed_file_threshold: #{yaml_value(expensive_run_tokens_per_changed_file_threshold)}",
      "  expensive_run_retry_attempt_threshold: #{yaml_value(expensive_run_retry_attempt_threshold)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
