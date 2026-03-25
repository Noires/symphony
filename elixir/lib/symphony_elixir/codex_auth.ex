defmodule SymphonyElixir.CodexAuth do
  @moduledoc """
  Runtime helper for Codex authentication status and device-code login flows.
  """

  use GenServer

  alias SymphonyElixir.{Config, Shell, StatusDashboard}

  @port_line_bytes 1_048_576
  @max_output_lines 16
  defstruct [
    :port,
    :pending_line,
    :phase,
    :status_code,
    :authenticated,
    :status_checked_at,
    :status_summary,
    :status_output,
    :verification_uri,
    :user_code,
    :started_at,
    :completed_at,
    :updated_at,
    :exit_status,
    :error,
    :launch_command,
    :cancel_requested
  ]

  @type t :: %__MODULE__{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec snapshot(GenServer.name()) :: map()
  def snapshot(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(server, :snapshot)
      _ -> default_payload()
    end
  end

  @spec refresh_status(GenServer.name()) :: {:ok, map()} | {:error, term()}
  def refresh_status(server \\ __MODULE__) do
    safe_call(server, :refresh_status, 15_000)
  end

  @spec start_device_auth(GenServer.name()) :: {:ok, map()} | {:error, term()}
  def start_device_auth(server \\ __MODULE__) do
    safe_call(server, :start_device_auth, 15_000)
  end

  @spec cancel_device_auth(GenServer.name()) :: {:ok, map()} | {:error, term()}
  def cancel_device_auth(server \\ __MODULE__) do
    safe_call(server, :cancel_device_auth, 15_000)
  end

  @doc false
  @spec reset(GenServer.name()) :: :ok | {:error, term()}
  def reset(server \\ __MODULE__) do
    safe_call(server, :reset, 15_000)
  end

  @impl true
  def init(opts) do
    state = default_state()

    if auto_refresh?(opts) do
      send(self(), :refresh_status)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, payload(state), state}
  end

  def handle_call(:refresh_status, _from, %{port: port} = state) when is_port(port) do
    {:reply, {:ok, payload(state)}, state}
  end

  def handle_call(:refresh_status, _from, state) do
    new_state = probe_status(state)
    {:reply, {:ok, payload(new_state)}, new_state}
  end

  def handle_call(:start_device_auth, _from, %{port: port} = state) when is_port(port) do
    {:reply, {:error, :device_auth_in_progress}, state}
  end

  def handle_call(:start_device_auth, _from, state) do
    case start_device_auth_port() do
      {:ok, port, launch_command} ->
        new_state = %{
          state
          | port: port,
            pending_line: "",
            phase: "awaiting_confirmation",
            verification_uri: nil,
            user_code: nil,
            started_at: now_iso8601(),
            completed_at: nil,
            updated_at: now_iso8601(),
            exit_status: nil,
            error: nil,
            launch_command: launch_command,
            cancel_requested: false,
            status_output: []
        }

        StatusDashboard.notify_update()
        {:reply, {:ok, payload(new_state)}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, fail_without_port(state, reason)}
    end
  end

  def handle_call(:cancel_device_auth, _from, %{port: nil} = state) do
    {:reply, {:error, :device_auth_not_running}, state}
  end

  def handle_call(:cancel_device_auth, _from, %{port: port} = state) do
    Port.close(port)

    new_state = %{
      state
      | port: nil,
        pending_line: "",
        phase: "cancelled",
        completed_at: now_iso8601(),
        updated_at: now_iso8601(),
        exit_status: nil,
        error: "device auth cancelled by operator",
        cancel_requested: true
    }

    StatusDashboard.notify_update()
    {:reply, {:ok, payload(new_state)}, new_state}
  end

  def handle_call(:reset, _from, %{port: port} = _state) when is_port(port) do
    Port.close(port)
    new_state = default_state()
    StatusDashboard.notify_update()
    {:reply, :ok, new_state}
  end

  def handle_call(:reset, _from, _state) do
    new_state = default_state()
    StatusDashboard.notify_update()
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:refresh_status, state) do
    {:noreply, probe_status(state)}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    new_state =
      state
      |> flush_pending_line()
      |> consume_output_line(to_string(line))

    {:noreply, new_state}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | pending_line: state.pending_line <> to_string(chunk), updated_at: now_iso8601()}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    finished_state =
      state
      |> flush_pending_line()
      |> finish_flow(status)

    {:noreply, finished_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp auto_refresh?(opts) do
    case Keyword.fetch(opts, :auto_refresh?) do
      {:ok, value} -> value
      :error -> not test_env?()
    end
  end

  defp test_env? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() == :test
      rescue
        _ -> false
      end
    else
      false
    end
  end

  defp start_device_auth_port do
    with {:ok, resolution} <- command_resolution(),
         {:ok, port, launch_command} <- open_port_for_device_auth(resolution) do
      {:ok, port, launch_command}
    end
  end

  defp probe_status(state) do
    new_state =
      case run_codex_command(["login", "status"]) do
        {:ok, output, 0} ->
          %{
            state
            | authenticated: true,
              status_code: "authenticated",
              status_summary: summarize_status_output(output, "authenticated"),
              status_output: merge_output_lines(state.status_output, output),
              status_checked_at: now_iso8601(),
              updated_at: now_iso8601()
          }

        {:ok, output, status} when is_integer(status) ->
          %{
            state
            | authenticated: false,
              status_code: status_code_for_output(output),
              status_summary: summarize_status_output(output, "not authenticated"),
              status_output: merge_output_lines(state.status_output, output),
              status_checked_at: now_iso8601(),
              updated_at: now_iso8601()
          }

        {:error, reason} ->
          %{
            state
            | authenticated: false,
              status_code: "unavailable",
              status_summary: "status unavailable",
              status_output: trim_output_lines([inspect(reason)]),
              status_checked_at: now_iso8601(),
              updated_at: now_iso8601()
          }
      end

    StatusDashboard.notify_update()
    new_state
  end

  defp run_codex_command(extra_args) when is_list(extra_args) do
    with {:ok, resolution} <- command_resolution() do
      case resolution do
        {:direct, executable, args} ->
          {output, status} =
            System.cmd(
              executable,
              args ++ extra_args,
              stderr_to_stdout: true,
              cd: command_cwd(),
              env: [{"NO_COLOR", "1"}]
            )

          {:ok, output, status}

        {:shell, command} ->
          executable = Shell.find_local_posix_shell(:bash)

          if is_nil(executable) do
            {:error, :bash_not_found}
          else
            shell_command =
              [command | Enum.map(extra_args, &shell_escape/1)]
              |> Enum.join(" ")

            {output, status} =
              System.cmd(
                executable,
                ["-lc", shell_command],
                stderr_to_stdout: true,
                cd: command_cwd(),
                env: [{"NO_COLOR", "1"}]
              )

            {:ok, output, status}
          end
      end
    end
  rescue
    error in [ArgumentError, RuntimeError] -> {:error, Exception.message(error)}
  end

  defp command_resolution do
    case resolved_command_spec() do
      nil -> {:error, :codex_command_not_configured}
      command_spec -> {:ok, Shell.resolve_local_command(command_spec)}
    end
  end

  defp resolved_command_spec do
    Application.get_env(:symphony_elixir, :codex_auth_command) ||
      case codex_command_from_settings() do
        nil -> System.find_executable("codex") || "codex"
        command -> command
      end
  end

  defp codex_command_from_settings do
    case Config.settings!().codex.command do
      command when is_binary(command) ->
        case OptionParser.split(command) do
          [executable | _rest] -> executable
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp command_cwd do
    Application.get_env(:symphony_elixir, :codex_auth_cwd) || File.cwd!()
  end

  defp open_port_for_device_auth({:direct, executable, args}) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: Enum.map(args ++ ["login", "--device-auth"], &String.to_charlist/1),
          cd: String.to_charlist(command_cwd()),
          line: @port_line_bytes
        ]
      )

    {:ok, port, "#{executable} #{Enum.join(args ++ ["login", "--device-auth"], " ")}"}
  end

  defp open_port_for_device_auth({:shell, command}) do
    executable = Shell.find_local_posix_shell(:bash)

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      shell_command = command <> " login --device-auth"

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(shell_command)],
            cd: String.to_charlist(command_cwd()),
            line: @port_line_bytes
          ]
        )

      {:ok, port, shell_command}
    end
  end

  defp fail_without_port(state, reason) do
    new_state = %{
      state
      | phase: "failed",
        error: humanize_error(reason),
        completed_at: now_iso8601(),
        updated_at: now_iso8601(),
        exit_status: nil
    }

    StatusDashboard.notify_update()
    new_state
  end

  defp flush_pending_line(%{pending_line: ""} = state), do: state

  defp flush_pending_line(%{pending_line: pending_line} = state) do
    state
    |> Map.put(:pending_line, "")
    |> consume_output_line(pending_line)
  end

  defp consume_output_line(state, line) when is_binary(line) do
    cleaned_line = clean_line(line)
    output_lines = trim_output_lines(state.status_output ++ [cleaned_line])
    verification_uri = state.verification_uri || extract_verification_uri(cleaned_line)
    user_code = state.user_code || extract_user_code(cleaned_line)

    new_state = %{
      state
      | status_output: output_lines,
        verification_uri: verification_uri,
        user_code: user_code,
        updated_at: now_iso8601(),
        phase: if(verification_uri || user_code, do: "awaiting_confirmation", else: state.phase)
    }

    StatusDashboard.notify_update()
    new_state
  end

  defp finish_flow(state, status) do
    base_state = %{
      state
      | port: nil,
        pending_line: "",
        completed_at: now_iso8601(),
        updated_at: now_iso8601(),
        exit_status: status
    }

    new_state =
      cond do
        state.cancel_requested ->
          %{
            base_state
            | phase: "cancelled",
              cancel_requested: false,
              error: "device auth cancelled by operator"
          }

        status == 0 ->
          status_state = probe_status(base_state)

          %{
            status_state
            | phase: if(status_state.authenticated, do: "authenticated", else: "completed"),
              error: nil,
              cancel_requested: false
          }

        true ->
          %{
            base_state
            | phase: "failed",
              cancel_requested: false,
              authenticated: false,
              error: build_flow_error(base_state.status_output, status)
          }
      end

    StatusDashboard.notify_update()
    new_state
  end

  defp payload(state) do
    %{
      phase: state.phase,
      authenticated: state.authenticated,
      status_code: state.status_code,
      status_summary: state.status_summary,
      status_checked_at: state.status_checked_at,
      verification_uri: state.verification_uri,
      user_code: state.user_code,
      started_at: state.started_at,
      completed_at: state.completed_at,
      updated_at: state.updated_at,
      exit_status: state.exit_status,
      error: state.error,
      launch_command: state.launch_command,
      in_progress: is_port(state.port),
      output_lines: state.status_output
    }
  end

  defp default_payload do
    %{
      phase: "unavailable",
      authenticated: false,
      status_code: "unavailable",
      status_summary: "Codex auth service is unavailable",
      status_checked_at: nil,
      verification_uri: nil,
      user_code: nil,
      started_at: nil,
      completed_at: nil,
      updated_at: now_iso8601(),
      exit_status: nil,
      error: "Codex auth service is unavailable",
      launch_command: nil,
      in_progress: false,
      output_lines: []
    }
  end

  defp default_state do
    %__MODULE__{
      port: nil,
      pending_line: "",
      phase: "idle",
      status_code: "unknown",
      authenticated: false,
      status_checked_at: nil,
      status_summary: "status unknown",
      status_output: [],
      verification_uri: nil,
      user_code: nil,
      started_at: nil,
      completed_at: nil,
      updated_at: now_iso8601(),
      exit_status: nil,
      error: nil,
      launch_command: nil,
      cancel_requested: false
    }
  end

  defp output_lines(output) when is_binary(output) do
    output
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&clean_line/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp merge_output_lines(existing, output) when is_list(existing) and is_binary(output) do
    case output_lines(output) do
      [] -> trim_output_lines(existing)
      parsed when existing == [] -> trim_output_lines(parsed)
      parsed -> trim_output_lines(existing ++ parsed)
    end
  end

  defp trim_output_lines(lines) when is_list(lines) do
    lines
    |> Enum.take(-@max_output_lines)
  end

  defp extract_verification_uri(line) when is_binary(line) do
    case Regex.run(~r/https?:\/\/\S+/i, line) do
      [url] -> String.trim_trailing(url, ".")
      _ -> nil
    end
  end

  defp extract_user_code(line) when is_binary(line) do
    cond do
      match = Regex.run(~r/(?:enter|code|device code)[^A-Z0-9]*([A-Z0-9]{4}(?:-[A-Z0-9]{4,})+)/i, line) ->
        Enum.at(match, 1)

      match = Regex.run(~r/\b([A-Z0-9]{4}(?:-[A-Z0-9]{4,})+)\b/, line) ->
        Enum.at(match, 1)

      true ->
        nil
    end
  end

  defp summarize_status_output(output, fallback) when is_binary(output) do
    output
    |> output_lines()
    |> List.first()
    |> case do
      nil -> fallback
      line -> line
    end
  end

  defp status_code_for_output(output) when is_binary(output) do
    normalized = String.downcase(output)

    cond do
      String.contains?(normalized, "not logged") -> "not_authenticated"
      String.contains?(normalized, "not authenticated") -> "not_authenticated"
      String.contains?(normalized, "command not found") -> "unavailable"
      String.contains?(normalized, "not recognized") -> "unavailable"
      true -> "not_authenticated"
    end
  end

  defp build_flow_error(lines, status) when is_list(lines) do
    case List.last(lines) do
      nil -> "device auth exited with status #{status}"
      line -> "#{line} (exit #{status})"
    end
  end

  defp clean_line(line) when is_binary(line) do
    line
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
    |> String.to_charlist()
    |> Enum.reject(fn char -> char < 32 and char not in [9, 10, 13] end)
    |> to_string()
    |> String.trim()
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp humanize_error(:codex_command_not_configured), do: "Codex command is not configured."
  defp humanize_error(:bash_not_found), do: "bash is required to launch the configured Codex command."
  defp humanize_error(reason) when is_binary(reason), do: reason
  defp humanize_error(reason), do: inspect(reason)

  defp safe_call(server, message, timeout) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> GenServer.call(server, message, timeout)
      _ -> {:error, :unavailable}
    end
  end

  defp now_iso8601 do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
