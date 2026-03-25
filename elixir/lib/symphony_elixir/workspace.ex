defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{AuditLog, Config, GitHubAccess, PathSafety, SSH, Shell}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"

  @type worker_host :: String.t() | nil

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host),
           :ok <- validate_workspace_path(workspace, worker_host),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    cond do
      File.dir?(workspace) ->
        {:ok, workspace, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, workspace, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil, Path.basename(workspace))
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    maybe_run_before_remove_hook(workspace, worker_host, Path.basename(workspace))

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id, worker_host) do
      {:ok, workspace} -> remove_tracked_workspace(workspace, worker_host, identifier)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case Config.settings!().worker.ssh_hosts do
      [] ->
        case workspace_path_for_issue(safe_id, nil) do
          {:ok, workspace} -> remove_tracked_workspace(workspace, nil, identifier)
          {:error, _reason} -> :ok
        end

      worker_hosts ->
        Enum.each(worker_hosts, &remove_issue_workspaces(identifier, &1))
    end

    :ok
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run", worker_host)
    end
  end

  @spec run_after_success_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_after_success_hook(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_success do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_success", worker_host)
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    run_after_run_hook_result(workspace, issue_or_identifier, worker_host)
    |> ignore_hook_failure()
  end

  @spec run_after_run_hook_result(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_after_run_hook_result(workspace, issue_or_identifier, worker_host \\ nil)
      when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run", worker_host)
    end
  end

  @spec collect_audit_workspace_metadata(Path.t(), worker_host()) :: {:ok, map()} | {:error, term()}
  def collect_audit_workspace_metadata(workspace, worker_host \\ nil)

  def collect_audit_workspace_metadata(workspace, nil) when is_binary(workspace) do
    cond do
      not File.dir?(workspace) ->
        {:ok, %{"exists" => false, "workspace_path" => workspace}}

      true ->
        metadata = %{
          "exists" => true,
          "workspace_path" => workspace
        }

        case collect_local_git_metadata(workspace) do
          {:ok, git_metadata} -> {:ok, Map.put(metadata, "git", git_metadata)}
          {:error, :not_git_repo} -> {:ok, metadata}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def collect_audit_workspace_metadata(workspace, worker_host)
      when is_binary(workspace) and is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ ! -d \"$workspace\" ]; then",
        "  printf '%s\\t0\\n' '__SYMPHONY_AUDIT_EXISTS__'",
        "  exit 0",
        "fi",
        "printf '%s\\t1\\n' '__SYMPHONY_AUDIT_EXISTS__'",
        "cd \"$workspace\"",
        "if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then",
        "  printf '%s\\t1\\n' '__SYMPHONY_AUDIT_GIT__'",
        "  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)",
        "  head_commit=$(git rev-parse HEAD 2>/dev/null || true)",
        "  head_subject=$(git log -1 --pretty=%s 2>/dev/null || true)",
        "  printf '%s\\t%s\\n' '__SYMPHONY_AUDIT_BRANCH__' \"$branch\"",
        "  printf '%s\\t%s\\n' '__SYMPHONY_AUDIT_HEAD__' \"$head_commit\"",
        "  printf '%s\\t%s\\n' '__SYMPHONY_AUDIT_SUBJECT__' \"$head_subject\"",
        "  git status --porcelain=v1 2>/dev/null | while IFS= read -r line; do",
        "    [ -n \"$line\" ] && printf '%s\\t%s\\n' '__SYMPHONY_AUDIT_STATUS__' \"$line\"",
        "  done",
        remote_diff_preview_script(),
        "else",
        "  printf '%s\\t0\\n' '__SYMPHONY_AUDIT_GIT__'",
        "fi"
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_metadata(output, workspace)

      {:ok, {output, status}} ->
        {:error, {:workspace_metadata_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_path_for_issue(safe_id, nil) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp workspace_path_for_issue(safe_id, worker_host) when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(Config.settings!().workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?, worker_host) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create", worker_host)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, nil, issue_identifier) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            issue_context = %{issue_id: nil, issue_identifier: issue_identifier || Path.basename(workspace)}

            record_cleanup_hook_event(issue_context.issue_identifier, "before_remove_started", "before_remove hook started", %{workspace_path: workspace, worker_host: nil})

            result =
              run_hook(
                command,
                workspace,
                issue_context,
                "before_remove",
                nil
              )

            record_cleanup_hook_result(issue_context.issue_identifier, "before_remove", result, workspace, nil)
            ignore_hook_failure(result)
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host, issue_identifier) when is_binary(worker_host) do
    hooks = Config.settings!().hooks

    case hooks.before_remove do
      nil ->
        :ok

      command ->
        effective_issue_identifier = issue_identifier || Path.basename(workspace)

        record_cleanup_hook_event(effective_issue_identifier, "before_remove_started", "before_remove hook started", %{workspace_path: workspace, worker_host: worker_host})

        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            result =
              handle_hook_command_result(
                {output, status},
                workspace,
                %{issue_id: nil, issue_identifier: effective_issue_identifier},
                "before_remove"
              )

            record_cleanup_hook_result(effective_issue_identifier, "before_remove", result, workspace, worker_host)
            result

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            record_cleanup_hook_result(effective_issue_identifier, "before_remove", {:error, reason}, workspace, worker_host)
            {:error, reason}

          {:error, reason} ->
            record_cleanup_hook_result(effective_issue_identifier, "before_remove", {:error, reason}, workspace, worker_host)
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, nil) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    case Shell.find_local_posix_shell(:sh) do
      nil ->
        Logger.error("Workspace hook shell missing hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local shell=sh")

        {:error, {:workspace_hook_shell_not_found, hook_name, "sh"}}

      shell_path ->
        hook_env = hook_env(issue_context, workspace, nil)

        task =
          Task.async(fn ->
            System.cmd(shell_path, ["-lc", command],
              cd: workspace,
              stderr_to_stdout: true,
              env: hook_env
            )
          end)

        case Task.yield(task, timeout_ms) do
          {:ok, cmd_result} ->
            handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

          nil ->
            Task.shutdown(task, :brutal_kill)

            Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local timeout_ms=#{timeout_ms}")

            {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
        end
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host) when is_binary(worker_host) do
    timeout_ms = Config.settings!().hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, remote_hook_script(command, workspace, issue_context, worker_host), timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace, nil) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp validate_workspace_path(workspace, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp remote_hook_script(command, workspace, issue_context, worker_host)
       when is_binary(command) and is_binary(workspace) and is_map(issue_context) and is_binary(worker_host) do
    [
      hook_env_exports(issue_context, workspace, worker_host),
      "cd #{shell_escape(workspace)}",
      command
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp hook_env(issue_context, workspace, worker_host) when is_map(issue_context) and is_binary(workspace) do
    [
      {"SYMPHONY_ISSUE_ID", Map.get(issue_context, :issue_id) || ""},
      {"SYMPHONY_ISSUE_IDENTIFIER", Map.get(issue_context, :issue_identifier) || ""},
      {"SYMPHONY_ISSUE_STATE", Map.get(issue_context, :issue_state) || ""},
      {"SYMPHONY_WORKSPACE", workspace},
      {"SYMPHONY_WORKER_HOST", worker_host || ""}
    ] ++ GitHubAccess.hook_env_overrides(worker_host)
  end

  defp hook_env_exports(issue_context, workspace, worker_host) do
    hook_env(issue_context, workspace, worker_host)
    |> Enum.map(fn {key, value} -> "export #{key}=#{shell_escape(value)}" end)
    |> Enum.join("\n")
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier, state: state}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_state: state
    }
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      issue_state: nil
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      issue_state: nil
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      issue_state: nil
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end

  defp remove_tracked_workspace(workspace, worker_host, issue_identifier) do
    record_cleanup_hook_event(issue_identifier, "workspace_cleanup_started", "workspace cleanup started", %{workspace_path: workspace, worker_host: worker_host})

    result =
      case worker_host do
        nil -> remove_local_with_identifier(workspace, issue_identifier)
        host -> remove_remote_with_identifier(workspace, host, issue_identifier)
      end

    case result do
      {:ok, _removed} ->
        record_cleanup_hook_event(issue_identifier, "workspace_cleanup_completed", "workspace cleanup completed", %{workspace_path: workspace, worker_host: worker_host})

      {:error, reason, _output} ->
        record_cleanup_hook_event(issue_identifier, "workspace_cleanup_failed", "workspace cleanup failed", %{workspace_path: workspace, worker_host: worker_host, reason: inspect(reason)})
    end

    result
  end

  defp remove_local_with_identifier(workspace, issue_identifier) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace, nil) do
          :ok ->
            maybe_run_before_remove_hook(workspace, nil, issue_identifier)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  defp remove_remote_with_identifier(workspace, worker_host, issue_identifier) do
    maybe_run_before_remove_hook(workspace, worker_host, issue_identifier)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {_output, 0}} ->
        {:ok, []}

      {:ok, {output, status}} ->
        {:error, {:workspace_remove_failed, worker_host, status, output}, ""}

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  defp collect_local_git_metadata(workspace) when is_binary(workspace) do
    with {:ok, _inside_work_tree} <- run_local_git_command(workspace, ["rev-parse", "--is-inside-work-tree"]) do
      branch = local_git_value(workspace, ["rev-parse", "--abbrev-ref", "HEAD"])
      head_commit = local_git_value(workspace, ["rev-parse", "HEAD"])
      head_subject = local_git_value(workspace, ["log", "-1", "--pretty=%s"])
      status_lines = local_git_lines(workspace, ["status", "--porcelain=v1"])
      changed_files = parse_git_status_lines(status_lines)
      diff_files = build_local_diff_preview(workspace, changed_files)

      git_metadata =
        %{
          "branch" => branch,
          "head_commit" => head_commit,
          "head_subject" => head_subject,
          "dirty" => status_lines != [],
          "changed_file_count" => length(status_lines),
          "changed_files" => changed_files,
          "diff_summary" => diff_summary(changed_files, diff_files),
          "diff_files" => diff_files
        }
        |> drop_nil_map_values()

      {:ok, git_metadata}
    else
      {:error, {_status, output}} ->
        if String.contains?(to_string(output || ""), "not a git repository") do
          {:error, :not_git_repo}
        else
          {:error, {:workspace_git_metadata_failed, output}}
        end
    end
  end

  defp run_local_git_command(workspace, args) when is_binary(workspace) and is_list(args) do
    case System.find_executable("git") do
      nil ->
        {:error, {:git_not_found, workspace}}

      git_path ->
        case System.cmd(git_path, args, cd: workspace, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {status, output}}
        end
    end
  end

  defp local_git_value(workspace, args) do
    case run_local_git_command(workspace, args) do
      {:ok, output} -> output |> String.trim() |> blank_to_nil()
      {:error, _reason} -> nil
    end
  end

  defp local_git_lines(workspace, args) do
    case run_local_git_command(workspace, args) do
      {:ok, output} -> String.split(output, ["\r\n", "\n"], trim: true)
      {:error, _reason} -> []
    end
  end

  defp parse_remote_workspace_metadata(output, workspace) do
    lines = String.split(IO.iodata_to_binary(output), ["\r\n", "\n"], trim: true)

    exists? =
      Enum.any?(lines, fn line ->
        String.starts_with?(line, "__SYMPHONY_AUDIT_EXISTS__\t1")
      end)

    git? =
      Enum.any?(lines, fn line ->
        String.starts_with?(line, "__SYMPHONY_AUDIT_GIT__\t1")
      end)

    base = %{"exists" => exists?, "workspace_path" => workspace}

    if not exists? do
      {:ok, base}
    else
      git_metadata =
        if git? do
          status_lines =
            lines
            |> Enum.flat_map(fn line ->
              case String.split(line, "\t", parts: 2) do
                ["__SYMPHONY_AUDIT_STATUS__", status_line] -> [status_line]
                _ -> []
              end
            end)

          changed_files = parse_git_status_lines(status_lines)
          diff_numstats = parse_remote_numstats(lines)
          diff_hunks = parse_remote_hunks(lines)
          diff_files = build_diff_preview(changed_files, diff_numstats, diff_hunks)

          %{
            "branch" => marker_value(lines, "__SYMPHONY_AUDIT_BRANCH__"),
            "head_commit" => marker_value(lines, "__SYMPHONY_AUDIT_HEAD__"),
            "head_subject" => marker_value(lines, "__SYMPHONY_AUDIT_SUBJECT__"),
            "changed_files" => changed_files,
            "diff_summary" => diff_summary(changed_files, diff_files),
            "diff_files" => diff_files
          }
          |> then(fn git_metadata ->
            Map.merge(git_metadata, %{
              "dirty" => status_lines != [],
              "changed_file_count" => length(status_lines)
            })
          end)
          |> drop_nil_map_values()
        else
          nil
        end

      {:ok, if(git_metadata, do: Map.put(base, "git", git_metadata), else: base)}
    end
  end

  defp marker_value(lines, marker) when is_list(lines) and is_binary(marker) do
    Enum.find_value(lines, fn line ->
      case String.split(line, "\t", parts: 2) do
        [^marker, value] -> blank_to_nil(String.trim(value))
        _ -> nil
      end
    end)
  end

  defp parse_git_status_lines(lines) when is_list(lines) do
    lines
    |> Enum.take(Config.settings!().observability.audit_max_list_items)
    |> Enum.map(fn line ->
      status = line |> String.slice(0, 2) |> to_string() |> String.trim()
      path = line |> String.slice(3..-1//1) |> to_string() |> String.trim()

      %{
        "status" => blank_to_nil(status) || "?",
        "path" => path
      }
    end)
    |> Enum.reject(&(is_nil(&1["path"]) or &1["path"] == ""))
  end

  defp parse_git_status_lines(_lines), do: []

  defp build_local_diff_preview(workspace, changed_files) when is_binary(workspace) and is_list(changed_files) do
    if diff_preview_enabled?() do
      numstats =
        workspace
        |> local_git_lines(["diff", "--numstat", "--relative", "HEAD", "--"])
        |> parse_numstat_lines()

      hunks =
        workspace
        |> local_git_lines(["diff", "--unified=0", "--relative", "HEAD", "--"])
        |> parse_diff_hunk_lines()

      build_diff_preview(changed_files, numstats, hunks)
    else
      []
    end
  end

  defp build_local_diff_preview(_workspace, _changed_files), do: []

  defp build_diff_preview(changed_files, diff_numstats, diff_hunks)
       when is_list(changed_files) and is_map(diff_numstats) and is_map(diff_hunks) do
    changed_files
    |> Enum.take(diff_preview_max_files())
    |> Enum.map(fn changed_file ->
      path = Map.get(changed_file, "path")
      numstat = Map.get(diff_numstats, path, %{})
      hunks = diff_hunks |> Map.get(path, []) |> Enum.take(diff_preview_hunks_per_file())

      %{
        "path" => path,
        "status" => Map.get(changed_file, "status"),
        "additions" => Map.get(numstat, "additions"),
        "deletions" => Map.get(numstat, "deletions"),
        "hunks" => hunks
      }
      |> drop_nil_map_values()
    end)
  end

  defp build_diff_preview(_changed_files, _diff_numstats, _diff_hunks), do: []

  defp parse_numstat_lines(lines) when is_list(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      case String.split(line, "\t", parts: 3) do
        [additions, deletions, path] ->
          Map.put(
            acc,
            String.trim(path),
            %{
              "additions" => parse_numstat_count(additions),
              "deletions" => parse_numstat_count(deletions)
            }
            |> drop_nil_map_values()
          )

        _ ->
          acc
      end
    end)
  end

  defp parse_numstat_lines(_lines), do: %{}

  defp parse_diff_hunk_lines(lines) when is_list(lines) do
    {_, hunks} =
      Enum.reduce(lines, {nil, %{}}, fn line, {current_path, acc} ->
        cond do
          String.starts_with?(line, "diff --git ") ->
            {parse_diff_path_line(line), acc}

          String.starts_with?(line, "+++ b/") ->
            {String.replace_prefix(line, "+++ b/", ""), acc}

          String.starts_with?(line, "@@") and is_binary(current_path) ->
            hunk = truncate_diff_line(line)
            {current_path, Map.update(acc, current_path, [hunk], &[hunk | &1])}

          true ->
            {current_path, acc}
        end
      end)

    Enum.into(hunks, %{}, fn {path, headers} -> {path, Enum.reverse(headers)} end)
  end

  defp parse_diff_hunk_lines(_lines), do: %{}

  defp parse_diff_path_line(line) when is_binary(line) do
    case Regex.run(~r/^diff --git a\/(.+) b\/(.+)$/, line) do
      [_, _left, right] -> String.trim(right)
      _ -> nil
    end
  end

  defp parse_diff_path_line(_line), do: nil

  defp parse_numstat_count("-"), do: nil

  defp parse_numstat_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_numstat_count(_value), do: nil

  defp truncate_diff_line(line) when is_binary(line) do
    max_length = diff_preview_max_line_length()

    if String.length(line) > max_length do
      String.slice(line, 0, max_length) <> "..."
    else
      line
    end
  end

  defp diff_summary(changed_files, diff_files) when is_list(changed_files) and is_list(diff_files) do
    changed_count = length(changed_files)

    {additions, deletions} =
      Enum.reduce(diff_files, {0, 0}, fn diff_file, {additions, deletions} ->
        {
          additions + max(Map.get(diff_file, "additions") || 0, 0),
          deletions + max(Map.get(diff_file, "deletions") || 0, 0)
        }
      end)

    cond do
      changed_count == 0 ->
        nil

      additions > 0 or deletions > 0 ->
        "#{changed_count} file(s), +#{additions}/-#{deletions}"

      true ->
        "#{changed_count} file(s)"
    end
  end

  defp diff_summary(_changed_files, _diff_files), do: nil

  defp parse_remote_numstats(lines) when is_list(lines) do
    lines
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "\t", parts: 4) do
        ["__SYMPHONY_AUDIT_NUMSTAT__", path, additions, deletions] ->
          Map.put(
            acc,
            String.trim(path),
            %{
              "additions" => parse_numstat_count(additions),
              "deletions" => parse_numstat_count(deletions)
            }
            |> drop_nil_map_values()
          )

        _ ->
          acc
      end
    end)
  end

  defp parse_remote_numstats(_lines), do: %{}

  defp parse_remote_hunks(lines) when is_list(lines) do
    lines
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "\t", parts: 3) do
        ["__SYMPHONY_AUDIT_HUNK__", path, header] ->
          Map.update(acc, String.trim(path), [truncate_diff_line(header)], &[truncate_diff_line(header) | &1])

        _ ->
          acc
      end
    end)
    |> Enum.into(%{}, fn {path, headers} -> {path, Enum.reverse(headers)} end)
  end

  defp parse_remote_hunks(_lines), do: %{}

  defp remote_diff_preview_script do
    if diff_preview_enabled?() do
      [
        "  git diff --numstat --relative HEAD -- 2>/dev/null | while IFS=$(printf '\\t') read -r additions deletions path; do",
        "    [ -n \"$path\" ] && printf '%s\\t%s\\t%s\\t%s\\n' '__SYMPHONY_AUDIT_NUMSTAT__' \"$path\" \"$additions\" \"$deletions\"",
        "  done",
        "  current_path=''",
        "  git diff --unified=0 --relative HEAD -- 2>/dev/null | while IFS= read -r line; do",
        "    case \"$line\" in",
        "      'diff --git '*) current_path=$(printf '%s' \"$line\" | sed 's/^diff --git a\\/.* b\\///') ;;",
        "      '+++ b/'*) current_path=${line#+++ b/} ;;",
        "      '@@'*) [ -n \"$current_path\" ] && printf '%s\\t%s\\t%s\\n' '__SYMPHONY_AUDIT_HUNK__' \"$current_path\" \"$line\" ;;",
        "    esac",
        "  done"
      ]
      |> Enum.join("\n")
    else
      ""
    end
  end

  defp diff_preview_enabled? do
    Config.settings!().observability.diff_preview_enabled
  end

  defp diff_preview_max_files do
    Config.settings!().observability.diff_preview_max_files
  end

  defp diff_preview_hunks_per_file do
    Config.settings!().observability.diff_preview_hunks_per_file
  end

  defp diff_preview_max_line_length do
    Config.settings!().observability.diff_preview_max_line_length
  end

  defp record_cleanup_hook_event(nil, _event, _summary, _details), do: :ok

  defp record_cleanup_hook_event(issue_identifier, event, summary, details) when is_binary(issue_identifier) do
    AuditLog.record_latest_run_event(issue_identifier, %{
      kind: "workspace",
      event: event,
      summary: summary,
      details: details
    })
  end

  defp record_cleanup_hook_result(issue_identifier, hook_name, :ok, workspace, worker_host) do
    record_cleanup_hook_event(issue_identifier, "#{hook_name}_completed", "#{hook_name} hook completed", %{workspace_path: workspace, worker_host: worker_host})
  end

  defp record_cleanup_hook_result(issue_identifier, hook_name, {:error, reason}, workspace, worker_host) do
    record_cleanup_hook_event(issue_identifier, "#{hook_name}_failed", "#{hook_name} hook failed", %{workspace_path: workspace, worker_host: worker_host, reason: inspect(reason)})
  end

  defp drop_nil_map_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
