defmodule SymphonyElixir.SecretStoreTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SecretStore

  setup do
    audit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-secret-store-#{System.unique_integer([:positive])}"
      )

    previous_audit_root = Application.get_env(:symphony_elixir, :audit_root)
    Application.put_env(:symphony_elixir, :audit_root, audit_root)

    on_exit(fn ->
      if is_nil(previous_audit_root) do
        Application.delete_env(:symphony_elixir, :audit_root)
      else
        Application.put_env(:symphony_elixir, :audit_root, previous_audit_root)
      end

      File.rm_rf(audit_root)
    end)

    :ok
  end

  test "set/get/clear preserve write-only behavior through metadata and file storage" do
    assert {:ok, entry} = SecretStore.get("github.token")
    assert entry.configured == false
    assert entry.source == "none"
    assert entry.value == nil

    assert {:ok, entry} =
             SecretStore.set(
               "github.token",
               "ui-secret-token",
               actor: "test",
               reason: "store token"
             )

    assert entry.configured == true
    assert entry.source == "ui_secret"
    assert entry.value == "ui-secret-token"
    assert entry.updated_by == "test"
    assert entry.reason == "store token"
    assert File.read!(SecretStore.file_path("github.token")) == "ui-secret-token"

    assert {:ok, entry} =
             SecretStore.clear(
               "github.token",
               actor: "test",
               reason: "clear token"
             )

    assert entry.configured == false
    assert entry.source == "none"
    assert entry.value == nil
    assert entry.cleared_by == "test"
    assert entry.clear_reason == "clear token"
    refute File.exists?(SecretStore.file_path("github.token"))
  end

  test "rejects invalid keys and blank values" do
    assert {:error, :invalid_secret_key} = SecretStore.get("")
    assert {:error, :invalid_secret_key} = SecretStore.set("bad key", "value")
    assert {:error, {:invalid_secret_value, _}} = SecretStore.set("github.token", "   ")
  end
end
