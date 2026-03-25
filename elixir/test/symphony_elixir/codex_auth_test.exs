defmodule SymphonyElixir.CodexAuthTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CodexAuth

  setup do
    previous_command = Application.get_env(:symphony_elixir, :codex_auth_command)
    previous_cwd = Application.get_env(:symphony_elixir, :codex_auth_cwd)
    previous_marker = System.get_env("FAKE_CODEX_AUTH_MARKER")
    previous_finish = System.get_env("FAKE_CODEX_AUTH_FINISH_FILE")

    on_exit(fn ->
      if is_nil(previous_command) do
        Application.delete_env(:symphony_elixir, :codex_auth_command)
      else
        Application.put_env(:symphony_elixir, :codex_auth_command, previous_command)
      end

      if is_nil(previous_cwd) do
        Application.delete_env(:symphony_elixir, :codex_auth_cwd)
      else
        Application.put_env(:symphony_elixir, :codex_auth_cwd, previous_cwd)
      end

      restore_env("FAKE_CODEX_AUTH_MARKER", previous_marker)
      restore_env("FAKE_CODEX_AUTH_FINISH_FILE", previous_finish)
    end)

    :ok
  end

  test "device auth flow exposes code/url and finishes authenticated" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-codex-auth-#{System.unique_integer([:positive])}"
      )

    server = Module.concat(__MODULE__, "Server#{System.unique_integer([:positive])}")

    try do
      marker_file = Path.join(test_root, "auth.marker")
      finish_file = Path.join(test_root, "auth.finish")

      fake_codex =
        install_fake_executable!(test_root, "fake-codex", """
        #!/bin/sh
        marker="${FAKE_CODEX_AUTH_MARKER:-}"
        finish_file="${FAKE_CODEX_AUTH_FINISH_FILE:-}"

        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          if [ -n "$marker" ] && [ -f "$marker" ]; then
            echo "Logged in as dashboard@test.invalid"
            exit 0
          else
            echo "Not logged in"
            exit 1
          fi
        fi

        if [ "$1" = "login" ] && [ "$2" = "--device-auth" ]; then
          echo "Open https://auth.example.test/device and enter code ABCD-EFGH"

          while [ ! -f "$finish_file" ]; do
            :
          done

          : > "$marker"
          echo "Authentication complete"
          exit 0
        fi

        echo "unexpected args: $*" >&2
        exit 2
        """)

      System.put_env("FAKE_CODEX_AUTH_MARKER", marker_file)
      System.put_env("FAKE_CODEX_AUTH_FINISH_FILE", finish_file)
      Application.put_env(:symphony_elixir, :codex_auth_command, fake_codex)
      Application.put_env(:symphony_elixir, :codex_auth_cwd, test_root)

      start_supervised!({CodexAuth, name: server, auto_refresh?: false})

      assert {:ok, status_payload} = CodexAuth.refresh_status(server)
      assert status_payload.status_code == "not_authenticated"
      assert status_payload.authenticated == false

      assert {:ok, start_payload} = CodexAuth.start_device_auth(server)
      assert start_payload.in_progress == true

      assert_eventually(fn ->
        snapshot = CodexAuth.snapshot(server)

        snapshot.user_code == "ABCD-EFGH" and
          snapshot.verification_uri == "https://auth.example.test/device"
      end)

      File.write!(marker_file, "done")
      File.write!(finish_file, "done")

      assert_eventually(fn ->
        snapshot = CodexAuth.snapshot(server)
        snapshot.in_progress == false and snapshot.authenticated == true and snapshot.phase == "authenticated"
      end)

      final_snapshot = CodexAuth.snapshot(server)
      assert final_snapshot.status_code == "authenticated"
      assert Enum.any?(final_snapshot.output_lines, &String.contains?(&1, "Authentication complete"))
    after
      File.rm_rf(test_root)
    end
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")
end
