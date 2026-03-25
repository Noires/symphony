defmodule SymphonyElixir.ShellTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Shell

  test "returns the PATH shell on non-windows platforms" do
    find_executable = fn
      "bash" -> "/usr/bin/bash"
      _ -> nil
    end

    assert "/usr/bin/bash" ==
             Shell.find_local_posix_shell(:bash,
               os_type: {:unix, :linux},
               find_executable: find_executable
             )
  end

  test "prefers a Git for Windows sh executable derived from git.exe" do
    find_executable = fn
      "git" -> "C:\\Tools\\Git\\cmd\\git.exe"
      _ -> nil
    end

    file_exists? = fn path ->
      normalize_windows_path(path) == normalize_windows_path("C:\\Tools\\Git\\usr\\bin\\sh.exe")
    end

    assert normalize_windows_path("C:\\Tools\\Git\\usr\\bin\\sh.exe") ==
             normalize_windows_path(
               Shell.find_local_posix_shell(:sh,
                 os_type: {:win32, :nt},
                 find_executable: find_executable,
                 file_exists?: file_exists?
               )
             )
  end

  test "prefers Git for Windows bash over the system WSL launcher" do
    find_executable = fn
      "bash" -> "C:\\Windows\\System32\\bash.exe"
      "git" -> "C:\\Tools\\Git\\cmd\\git.exe"
      _ -> nil
    end

    file_exists? = fn path ->
      normalize_windows_path(path) == normalize_windows_path("C:\\Tools\\Git\\usr\\bin\\bash.exe")
    end

    env_lookup = fn
      "WINDIR" -> "C:\\Windows"
      _ -> nil
    end

    assert normalize_windows_path("C:\\Tools\\Git\\usr\\bin\\bash.exe") ==
             normalize_windows_path(
               Shell.find_local_posix_shell(:bash,
                 os_type: {:win32, :nt},
                 find_executable: find_executable,
                 env_lookup: env_lookup,
                 file_exists?: file_exists?
               )
             )
  end

  test "returns nil when windows only exposes the system bash launcher" do
    find_executable = fn
      "bash" -> "C:\\Windows\\System32\\bash.exe"
      _ -> nil
    end

    env_lookup = fn
      "WINDIR" -> "C:\\Windows"
      _ -> nil
    end

    refute Shell.find_local_posix_shell(:bash,
             os_type: {:win32, :nt},
             find_executable: find_executable,
             env_lookup: env_lookup,
             file_exists?: fn _path -> true end
           )
  end

  test "resolves a simple executable command directly" do
    find_executable = fn
      "codex" -> "C:\\Tools\\codex.exe"
      _ -> nil
    end

    assert {:direct, "C:\\Tools\\codex.exe", ["app-server"]} ==
             Shell.resolve_local_command("codex app-server", find_executable: find_executable)
  end

  test "falls back to shell mode for shell operators" do
    assert {:shell, "FOO=bar codex app-server && echo ready"} ==
             Shell.resolve_local_command("FOO=bar codex app-server && echo ready")
  end

  test "launches discovered non-exe posix scripts through bash argv on windows" do
    find_executable = fn
      "codex-script" -> "C:\\Tools\\codex-script"
      "git" -> "C:\\Tools\\Git\\cmd\\git.exe"
      _ -> nil
    end

    file_exists? = fn path ->
      normalize_windows_path(path) in [
        normalize_windows_path("C:\\Tools\\codex-script"),
        normalize_windows_path("C:\\Tools\\Git\\usr\\bin\\bash.exe")
      ]
    end

    assert {:direct, bash_path, args} =
             Shell.resolve_local_command("codex-script app-server",
               os_type: {:win32, :nt},
               find_executable: find_executable,
               file_exists?: file_exists?
             )

    assert normalize_windows_path(bash_path) ==
             normalize_windows_path("C:\\Tools\\Git\\usr\\bin\\bash.exe")

    assert Enum.take(args, 2) == ["--noprofile", "--norc"]
    assert normalize_windows_script_arg(Enum.at(args, 2)) == normalize_windows_script_arg("C:/Tools/codex-script")
    assert Enum.at(args, 3) == "app-server"
  end

  test "launches explicit non-exe windows script paths through bash argv" do
    command = "C:\\Users\\dusti\\Temp\\fake-codex app-server"
    expected_path = normalize_windows_path("C:\\Users\\dusti\\Temp\\fake-codex")
    expected_bash = normalize_windows_path("C:\\Tools\\Git\\usr\\bin\\bash.exe")

    find_executable = fn
      "git" -> "C:\\Tools\\Git\\cmd\\git.exe"
      _ -> nil
    end

    assert {:direct, bash_path, args} =
             Shell.resolve_local_command(command,
               os_type: {:win32, :nt},
               find_executable: find_executable,
               file_exists?: fn path ->
                 normalize_windows_path(path) in [expected_path, expected_bash]
               end
             )

    assert normalize_windows_path(bash_path) == expected_bash
    assert Enum.take(args, 2) == ["--noprofile", "--norc"]

    assert normalize_windows_script_arg(Enum.at(args, 2)) ==
             normalize_windows_script_arg("C:/Users/dusti/Temp/fake-codex")

    assert Enum.at(args, 3) == "app-server"
  end

  defp normalize_windows_path(path) when is_binary(path) do
    path
    |> Path.expand()
    |> String.replace("/", "\\")
    |> String.downcase()
  end

  defp normalize_windows_script_arg(path) when is_binary(path) do
    path
    |> String.replace("/", "\\")
    |> String.downcase()
  end
end
