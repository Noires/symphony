defmodule SymphonyElixir.Shell do
  @moduledoc false

  @type local_posix_shell :: :bash | :sh
  @type local_command_resolution :: {:direct, String.t(), [String.t()]} | {:shell, String.t()}

  @spec find_local_posix_shell(local_posix_shell(), keyword()) :: String.t() | nil
  def find_local_posix_shell(shell_name, opts \\ []) when shell_name in [:bash, :sh] do
    os_type = Keyword.get(opts, :os_type, :os.type())
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)
    env_lookup = Keyword.get(opts, :env_lookup, &System.get_env/1)
    file_exists? = Keyword.get(opts, :file_exists?, &File.exists?/1)

    case os_type do
      {:win32, _} ->
        find_windows_posix_shell(shell_name, find_executable, env_lookup, file_exists?)

      _ ->
        find_executable.(Atom.to_string(shell_name))
    end
  end

  @spec resolve_local_command(String.t(), keyword()) :: local_command_resolution()
  def resolve_local_command(command, opts \\ []) when is_binary(command) do
    os_type = Keyword.get(opts, :os_type, :os.type())
    split_argv = Keyword.get(opts, :split_argv, &OptionParser.split/1)
    find_executable = Keyword.get(opts, :find_executable, &System.find_executable/1)
    env_lookup = Keyword.get(opts, :env_lookup, &System.get_env/1)
    file_exists? = Keyword.get(opts, :file_exists?, &File.exists?/1)

    if requires_shell?(command) do
      {:shell, command}
    else
      case split_argv.(command) do
        [executable | args] ->
          case resolve_local_executable(executable, find_executable, file_exists?) do
            nil ->
              {:shell, command}

            resolved_executable ->
              resolve_launch_command(
                resolved_executable,
                args,
                os_type,
                find_executable,
                env_lookup,
                file_exists?
              )
          end

        _ ->
          {:shell, command}
      end
    end
  rescue
    _ ->
      {:shell, command}
  end

  defp resolve_launch_command(
         resolved_executable,
         args,
         os_type,
         find_executable,
         env_lookup,
         file_exists?
       ) do
    cond do
      direct_launch_supported?(resolved_executable, os_type) ->
        {:direct, resolved_executable, args}

      true ->
        case maybe_wrap_windows_posix_script(
               resolved_executable,
               args,
               os_type,
               find_executable,
               env_lookup,
               file_exists?
             ) do
          {:ok, launcher, launcher_args} ->
            {:direct, launcher, launcher_args}

          :error ->
            {:shell, shell_command_for_executable(resolved_executable, args, os_type)}
        end
    end
  end

  defp find_windows_posix_shell(shell_name, find_executable, env_lookup, file_exists?) do
    executable_name = Atom.to_string(shell_name) <> ".exe"

    git_sibling_candidates(executable_name, find_executable)
    |> Kernel.++(program_files_candidates(executable_name, env_lookup))
    |> Kernel.++([find_executable.(Atom.to_string(shell_name))])
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.reject(&windows_launcher?(&1, env_lookup))
    |> Enum.find(file_exists?)
  end

  defp git_sibling_candidates(executable_name, find_executable) do
    case find_executable.("git") do
      nil ->
        []

      git_path ->
        git_root =
          git_path
          |> Path.dirname()
          |> Path.join("..")
          |> Path.expand()

        [
          Path.join([git_root, "usr", "bin", executable_name]),
          Path.join([git_root, "bin", executable_name])
        ]
    end
  end

  defp program_files_candidates(executable_name, env_lookup) do
    ["ProgramFiles", "ProgramFiles(x86)"]
    |> Enum.map(env_lookup)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn program_files ->
      git_root = Path.join(program_files, "Git")

      [
        Path.join([git_root, "usr", "bin", executable_name]),
        Path.join([git_root, "bin", executable_name])
      ]
    end)
  end

  defp windows_launcher?(path, env_lookup) when is_binary(path) do
    normalized_path = normalize_windows_path(path)
    normalized_windir = normalize_windows_path(env_lookup.("WINDIR") || "C:\\Windows")

    String.ends_with?(normalized_path, "\\bash.exe") and
      String.starts_with?(normalized_path, normalized_windir <> "\\system32\\")
  end

  defp normalize_windows_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("/", "\\")
    |> String.downcase()
  end

  defp requires_shell?(command) when is_binary(command) do
    trimmed = String.trim(command)

    trimmed == "" or
      String.contains?(trimmed, ["&&", "||", "|", ";", "\n", "\r", ">", "<", "`", "$("]) or
      Regex.match?(~r/^\s*[A-Za-z_][A-Za-z0-9_]*=/, trimmed)
  end

  defp resolve_local_executable(executable, find_executable, file_exists?) when is_binary(executable) do
    cond do
      executable == "" ->
        nil

      String.contains?(executable, ["/", "\\"]) ->
        candidate = Path.expand(executable)
        if file_exists?.(candidate), do: candidate, else: nil

      true ->
        find_executable.(executable) || find_executable.(executable <> ".exe")
    end
  end

  defp direct_launch_supported?(path, {:win32, _}) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in [".exe", ".com"]))
  end

  defp direct_launch_supported?(path, _os_type) when is_binary(path), do: true

  defp maybe_wrap_windows_posix_script(
         executable,
         args,
         {:win32, _} = os_type,
         find_executable,
         env_lookup,
         file_exists?
       )
       when is_binary(executable) and is_list(args) do
    if windows_posix_script?(executable) do
      case find_local_posix_shell(:bash,
             os_type: os_type,
             find_executable: find_executable,
             env_lookup: env_lookup,
             file_exists?: file_exists?
           ) do
        nil ->
          :error

        bash_path ->
          {:ok, bash_path, ["--noprofile", "--norc", normalize_posix_argv_path(executable) | args]}
      end
    else
      :error
    end
  end

  defp maybe_wrap_windows_posix_script(
         _executable,
         _args,
         _os_type,
         _find_executable,
         _env_lookup,
         _file_exists?
       ) do
    :error
  end

  defp windows_posix_script?(path) when is_binary(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in ["", ".sh", ".bash"]))
  end

  defp shell_command_for_executable(executable, args, {:win32, _}) when is_binary(executable) do
    [normalize_posix_shell_path(executable) | Enum.map(args, &shell_escape/1)]
    |> Enum.join(" ")
  end

  defp shell_command_for_executable(executable, args, _os_type) when is_binary(executable) do
    [shell_escape(executable) | Enum.map(args, &shell_escape/1)]
    |> Enum.join(" ")
  end

  defp normalize_posix_shell_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
    |> shell_escape()
  end

  defp normalize_posix_argv_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("\\", "/")
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
