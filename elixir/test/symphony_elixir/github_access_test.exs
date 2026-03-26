defmodule SymphonyElixir.GitHubAccessTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Config, GitHubAccess, Workspace}

  setup do
    audit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-access-#{System.unique_integer([:positive])}"
      )

    previous_audit_root = Application.get_env(:symphony_elixir, :audit_root)
    previous_repo_url = System.get_env("SYMPHONY_SOURCE_REPO_URL")
    previous_github_token = System.get_env("GITHUB_TOKEN")
    previous_author_name = System.get_env("GIT_AUTHOR_NAME")
    previous_author_email = System.get_env("GIT_AUTHOR_EMAIL")
    previous_committer_name = System.get_env("GIT_COMMITTER_NAME")
    previous_committer_email = System.get_env("GIT_COMMITTER_EMAIL")
    previous_landing_mode = System.get_env("SYMPHONY_GITHUB_LANDING_MODE")

    Application.put_env(:symphony_elixir, :audit_root, audit_root)

    on_exit(fn ->
      if is_nil(previous_audit_root) do
        Application.delete_env(:symphony_elixir, :audit_root)
      else
        Application.put_env(:symphony_elixir, :audit_root, previous_audit_root)
      end

      restore_env("SYMPHONY_SOURCE_REPO_URL", previous_repo_url)
      restore_env("GITHUB_TOKEN", previous_github_token)
      restore_env("GIT_AUTHOR_NAME", previous_author_name)
      restore_env("GIT_AUTHOR_EMAIL", previous_author_email)
      restore_env("GIT_COMMITTER_NAME", previous_committer_name)
      restore_env("GIT_COMMITTER_EMAIL", previous_committer_email)
      restore_env("SYMPHONY_GITHUB_LANDING_MODE", previous_landing_mode)

      File.rm_rf(audit_root)
    end)

    :ok
  end

  test "github access persists config, keeps token write-only, and can back the github tracker" do
    System.put_env("SYMPHONY_SOURCE_REPO_URL", "https://github.com/env/original.git")
    System.put_env("GITHUB_TOKEN", "env-github-token")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_access_token: nil,
      tracker_project_slug: nil,
      tracker_board_id: nil,
      tracker_owner: "octo-org",
      tracker_repo: "symphony",
      tracker_project_number: "7"
    )

    assert Config.settings!().tracker.api_token == "env-github-token"

    assert {:ok, payload} =
             GitHubAccess.update_config(
               %{
                 "source_repo_url" => "https://github.com/example/updated.git",
                 "git_author_name" => "Operator Name",
                 "git_author_email" => "operator@example.com",
                 "landing_mode" => "pull_request"
               },
               actor: "test",
               reason: "switch repository"
             )

    assert Enum.find(payload.settings, &(&1.path == "source_repo_url")).effective_value ==
             "https://github.com/example/updated.git"

    assert Enum.find(payload.settings, &(&1.path == "landing_mode")).effective_value ==
             "pull_request"

    assert payload.token.configured == true
    assert payload.token.source == "env"
    assert payload.token.source_label == "Environment"
    assert payload.token.updated_at == nil
    assert payload.token.cleared_at == nil

    assert {:ok, payload} =
             GitHubAccess.set_token(
               "ui-github-token",
               actor: "test",
               reason: "store dashboard token"
             )

    assert payload.token.configured == true
    assert payload.token.source == "ui_secret"
    refute Map.has_key?(payload.token, :token)
    refute payload.history |> List.first() |> inspect() =~ "ui-github-token"
    assert File.read!(GitHubAccess.token_file_path()) == "ui-github-token"

    assert Config.settings!().tracker.api_token == "ui-github-token"

    assert {:ok, payload} =
             GitHubAccess.clear_token(
               actor: "test",
               reason: "remove dashboard token"
             )

    assert payload.token.configured == true
    assert payload.token.source == "env"
    assert payload.token.source_label == "Environment"
    assert payload.token.updated_at == nil
    assert payload.token.cleared_at == nil
    assert Config.settings!().tracker.api_token == "env-github-token"
  end

  test "workspace hooks receive github access overrides and a local token file" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-github-access-workspaces-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: """
        printf '%s\n' "$SYMPHONY_SOURCE_REPO_URL" > github-access.txt
        printf '%s\n' "$GIT_AUTHOR_NAME" >> github-access.txt
        printf '%s\n' "$GIT_AUTHOR_EMAIL" >> github-access.txt
        printf '%s\n' "$GIT_COMMITTER_NAME" >> github-access.txt
        printf '%s\n' "$GIT_COMMITTER_EMAIL" >> github-access.txt
        printf '%s\n' "$SYMPHONY_GITHUB_LANDING_MODE" >> github-access.txt
        printf '%s\n' "$SYMPHONY_GITHUB_TOKEN_FILE" >> github-access.txt
        """
      )

      assert {:ok, _payload} =
               GitHubAccess.update_config(
                 %{
                   "source_repo_url" => "https://github.com/example/workspace.git",
                   "git_author_name" => "Workspace Author",
                   "git_author_email" => "workspace@author.invalid",
                   "git_committer_name" => "Workspace Committer",
                   "git_committer_email" => "workspace@committer.invalid",
                   "landing_mode" => "pull_request"
                 },
                 actor: "test"
               )

      assert {:ok, _payload} = GitHubAccess.set_token("workspace-ui-token", actor: "test")

      assert {:ok, workspace} = Workspace.create_for_issue("GH-UI-1")

      lines =
        workspace
        |> Path.join("github-access.txt")
        |> File.read!()
        |> String.split(["\r\n", "\n"], trim: true)

      assert lines == [
               "https://github.com/example/workspace.git",
               "Workspace Author",
               "workspace@author.invalid",
               "Workspace Committer",
               "workspace@committer.invalid",
               "pull_request",
               GitHubAccess.token_file_path()
             ]
    after
      File.rm_rf(workspace_root)
    end
  end
end
