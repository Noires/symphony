defmodule SymphonyElixir.SSH do
  @moduledoc false

  alias SymphonyElixir.Shell

  @spec run(String.t(), String.t(), keyword()) :: {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      args = ssh_args(host, command)

      case windows_script_or_cmd_invocation(executable, args) do
        {:ok, invocation_executable, invocation_args} ->
          {:ok, System.cmd(invocation_executable, invocation_args, opts)}

        :error ->
          {:ok, System.cmd(executable, args, opts)}
      end
    end
  end

  @spec start_port(String.t(), String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start_port(host, command, opts \\ []) when is_binary(host) and is_binary(command) do
    with {:ok, executable} <- ssh_executable() do
      line_bytes = Keyword.get(opts, :line)
      args = ssh_args(host, command)

      port_opts =
        case windows_script_or_cmd_invocation(executable, args) do
          {:ok, invocation_executable, invocation_args} ->
            {
              invocation_executable,
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                args: Enum.map(invocation_args, &String.to_charlist/1)
              ]
            }

          :error ->
            {
              executable,
              [
                :binary,
                :exit_status,
                :stderr_to_stdout,
                args: Enum.map(args, &String.to_charlist/1)
              ]
            }
        end

      {spawn_executable, port_opts} = port_opts
      port_opts = maybe_put_line_option(port_opts, line_bytes)

      {:ok, Port.open({:spawn_executable, String.to_charlist(spawn_executable)}, port_opts)}
    end
  end

  @spec remote_shell_command(String.t()) :: String.t()
  def remote_shell_command(command) when is_binary(command) do
    "bash -lc " <> shell_escape(command)
  end

  defp ssh_executable do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      executable -> {:ok, executable}
    end
  end

  defp ssh_args(host, command) do
    %{destination: destination, port: port} = parse_target(host)

    []
    |> maybe_put_config()
    |> Kernel.++(["-T"])
    |> maybe_put_port(port)
    |> Kernel.++([destination, remote_shell_command(command)])
  end

  defp maybe_put_line_option(port_opts, nil), do: port_opts
  defp maybe_put_line_option(port_opts, line_bytes), do: Keyword.put(port_opts, :line, line_bytes)

  defp maybe_put_config(args) do
    case System.get_env("SYMPHONY_SSH_CONFIG") do
      config_path when is_binary(config_path) and config_path != "" ->
        args ++ ["-F", config_path]

      _ ->
        args
    end
  end

  defp maybe_put_port(args, nil), do: args
  defp maybe_put_port(args, port), do: args ++ ["-p", port]

  defp parse_target(target) when is_binary(target) do
    trimmed_target = String.trim(target)

    # OpenSSH does not interpret bare "host:port" as "host + port"; it treats the
    # whole value as a hostname and leaves the port at 22. We split that shorthand
    # here so worker config can use "localhost:2222" without requiring ssh:// URIs.
    case Regex.run(~r/^(.*):(\d+)$/, trimmed_target, capture: :all_but_first) do
      [destination, port] ->
        if valid_port_destination?(destination) do
          %{destination: destination, port: port}
        else
          %{destination: trimmed_target, port: nil}
        end

      _ ->
        %{destination: trimmed_target, port: nil}
    end
  end

  defp valid_port_destination?(destination) when is_binary(destination) do
    destination != "" and
      (not String.contains?(destination, ":") or bracketed_host?(destination))
  end

  defp bracketed_host?(destination) when is_binary(destination) do
    # IPv6 literals contain ":" already, so we only accept additional ":port"
    # parsing when the host is explicitly bracketed, e.g. "[::1]:2222".
    String.contains?(destination, "[") and String.contains?(destination, "]")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp windows_script_or_cmd_invocation(executable, args) when is_binary(executable) and is_list(args) do
    if match?({:win32, _}, :os.type()) and String.downcase(Path.extname(executable)) in [".cmd", ".bat"] do
      script_path = Path.rootname(executable)

      cond do
        File.exists?(script_path) ->
          sh_path = Shell.find_local_posix_shell(:sh) || raise "sh not found"
          {:ok, sh_path, [script_path | args]}

        true ->
          {:ok, System.find_executable("cmd") || "cmd.exe", ["/d", "/s", "/c", cmd_command_line(executable, args)]}
      end
    else
      :error
    end
  end

  defp cmd_command_line(executable, args) do
    [executable | Enum.map(args, &cmd_escape/1)]
    |> Enum.join(" ")
  end

  defp cmd_escape(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  end
end
