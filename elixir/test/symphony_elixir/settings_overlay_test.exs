defmodule SymphonyElixir.SettingsOverlayTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.SettingsOverlay

  setup do
    audit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-settings-overlay-#{System.unique_integer([:positive])}"
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

  test "settings overlay applies allowed runtime overrides and persists history" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 2,
      continue_on_active_issue: true,
      guardrails_default_review_mode: "review",
      codex_command: "codex --config shell_environment_policy.inherit=all app-server"
    )

    assert Config.settings!().agent.max_concurrent_agents == 2
    assert Config.settings!().agent.continue_on_active_issue == true
    assert Config.settings!().guardrails.default_review_mode == "review"
    assert Config.settings!().codex.command == "codex --config shell_environment_policy.inherit=all app-server"

    assert {:ok, payload} =
             SettingsOverlay.update_overlay(
               %{
                  "agent.max_concurrent_agents" => "5",
                  "agent.continue_on_active_issue" => "false",
                  "guardrails.default_review_mode" => "deny",
                  "codex.model" => "gpt-5.1-codex-mini",
                  "codex.reasoning_effort" => "high"
                },
                actor: "test",
                reason: "raise throughput ceiling"
              )

    assert payload.overlay.updated_by == "test"
    assert payload.overlay.reason == "raise throughput ceiling"

    assert payload.overlay.changes == %{
             "agent" => %{
               "max_concurrent_agents" => 5,
               "continue_on_active_issue" => false
             },
             "codex" => %{
               "model" => "gpt-5.1-codex-mini",
               "reasoning_effort" => "high"
             },
             "guardrails" => %{"default_review_mode" => "deny"}
           }

    assert Config.settings!().agent.max_concurrent_agents == 5
    assert Config.settings!().agent.continue_on_active_issue == false
    assert Config.settings!().guardrails.default_review_mode == "deny"
    assert Config.settings!().codex.model == "gpt-5.1-codex-mini"
    assert Config.settings!().codex.reasoning_effort == "high"

    assert Config.settings!().codex.command ==
             "codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=high --model gpt-5.1-codex-mini app-server"

    [entry | _rest] = SettingsOverlay.history(5)
    assert entry["action"] == "update"
    assert entry["actor"] == "test"
    assert entry["reason"] == "raise throughput ceiling"
    assert entry["new_values"]["agent.max_concurrent_agents"] == 5
    assert entry["new_values"]["agent.continue_on_active_issue"] == false
    assert entry["new_values"]["codex.model"] == "gpt-5.1-codex-mini"
    assert entry["new_values"]["codex.reasoning_effort"] == "high"
    assert entry["new_values"]["guardrails.default_review_mode"] == "deny"
    assert entry["previous_values"]["agent.max_concurrent_agents"] == nil

    assert {:ok, reset_payload} =
             SettingsOverlay.reset_overlay(
               ["agent.max_concurrent_agents", "agent.continue_on_active_issue"],
               actor: "test",
               reason: "restore workflow defaults"
             )

    assert reset_payload.overlay.changes == %{
             "guardrails" => %{"default_review_mode" => "deny"}
           }

    assert Config.settings!().agent.max_concurrent_agents == 2
    assert Config.settings!().agent.continue_on_active_issue == true
    assert Config.settings!().guardrails.default_review_mode == "deny"
    assert Config.settings!().codex.model == "gpt-5.1-codex-mini"
    assert Config.settings!().codex.reasoning_effort == "high"
  end

  test "settings overlay rejects bootstrap-only and invalid values" do
    assert {:error, {:setting_not_ui_manageable, "tracker.api_token"}} =
             SettingsOverlay.update_overlay(%{"tracker.api_token" => "secret"})

    assert {:error, {:invalid_setting_value, "agent.max_turns", _message}} =
             SettingsOverlay.update_overlay(%{"agent.max_turns" => "0"})
  end
end
