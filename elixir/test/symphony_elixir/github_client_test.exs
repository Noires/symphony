defmodule SymphonyElixir.GitHub.ClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.Linear.Issue

  test "fetch_candidate_issues reads GitHub project items and normalizes issues" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_key: nil,
      tracker_api_access_token: "github-token",
      tracker_project_slug: nil,
      tracker_board_id: nil,
      tracker_owner: "octo-org",
      tracker_repo: "symphony",
      tracker_project_number: "7",
      tracker_active_states: ["KI", "In Progress"]
    )

    request_fun = fn request_opts ->
      query = get_in(request_opts, [:json, "query"])

      cond do
        String.contains?(query, "SymphonyGitHubProjectContext") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_project_1",
                     "title" => "Automation",
                     "fields" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTSSF_status",
                           "name" => "Status",
                           "options" => [
                             %{"id" => "opt_ki", "name" => "KI"},
                             %{"id" => "opt_progress", "name" => "In Progress"},
                             %{"id" => "opt_done", "name" => "Done"}
                           ]
                         }
                       ]
                     }
                   }
                 },
                 "user" => nil
               }
             }
           }}

        String.contains?(query, "SymphonyGitHubProjectItems") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "items" => %{
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil},
                     "nodes" => [
                       %{
                         "id" => "PVTI_1",
                         "fieldValues" => %{
                           "nodes" => [
                             %{
                               "name" => "KI",
                               "field" => %{"id" => "PVTSSF_status", "name" => "Status"}
                             }
                           ]
                         },
                         "content" => %{
                           "__typename" => "Issue",
                           "id" => "I_kw_1",
                           "number" => 44,
                           "title" => "Build GitHub adapter",
                           "body" => "Implement GitHub tracker support",
                           "url" => "https://github.com/octo-org/symphony/issues/44",
                           "state" => "OPEN",
                           "createdAt" => "2026-03-24T10:00:00Z",
                           "updatedAt" => "2026-03-24T10:05:00Z",
                           "labels" => %{"nodes" => [%{"name" => "backend"}]},
                           "assignees" => %{"nodes" => [%{"id" => "U_1", "login" => "octocat"}]},
                           "repository" => %{"name" => "symphony", "owner" => %{"login" => "octo-org"}}
                         }
                       },
                       %{
                         "id" => "PVTI_2",
                         "fieldValues" => %{
                           "nodes" => [
                             %{
                               "name" => "KI",
                               "field" => %{"id" => "PVTSSF_status", "name" => "Status"}
                             }
                           ]
                         },
                         "content" => %{
                           "__typename" => "Issue",
                           "id" => "I_kw_2",
                           "number" => 45,
                           "title" => "Wrong repo",
                           "body" => "Ignore me",
                           "url" => "https://github.com/octo-org/other/issues/45",
                           "state" => "OPEN",
                           "createdAt" => "2026-03-24T10:00:00Z",
                           "updatedAt" => "2026-03-24T10:05:00Z",
                           "labels" => %{"nodes" => []},
                           "assignees" => %{"nodes" => []},
                           "repository" => %{"name" => "other", "owner" => %{"login" => "octo-org"}}
                         }
                       }
                     ]
                   }
                 }
               }
             }
           }}

        true ->
          flunk("unexpected request: #{inspect(request_opts)}")
      end
    end

    assert {:ok, [%Issue{} = issue]} = Client.fetch_candidate_issues(request_fun: request_fun)
    assert issue.id == "PVTI_1"
    assert issue.identifier == "GH-44"
    assert issue.state == "KI"
    assert issue.labels == ["backend"]
    assert issue.assigned_to_worker == true
  end

  test "update_issue_state resolves the status field option and updates the project item" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_key: nil,
      tracker_api_access_token: "github-token",
      tracker_project_slug: nil,
      tracker_board_id: nil,
      tracker_owner: "octo-org",
      tracker_repo: "symphony",
      tracker_project_number: "7"
    )

    test_pid = self()

    request_fun = fn request_opts ->
      query = get_in(request_opts, [:json, "query"])
      variables = get_in(request_opts, [:json, "variables"])
      send(test_pid, {:request_sent, query, variables})

      cond do
        String.contains?(query, "SymphonyGitHubProjectContext") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_project_1",
                     "title" => "Automation",
                     "fields" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTSSF_status",
                           "name" => "Status",
                           "options" => [
                             %{"id" => "opt_progress", "name" => "In Progress"},
                             %{"id" => "opt_review", "name" => "Human Review"}
                           ]
                         }
                       ]
                     }
                   }
                 },
                 "user" => nil
               }
             }
           }}

        String.contains?(query, "SymphonyGitHubUpdateProjectItemState") ->
          assert variables == %{
                   projectId: "PVT_project_1",
                   itemId: "PVTI_1",
                   fieldId: "PVTSSF_status",
                   optionId: "opt_review"
                 }

          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "updateProjectV2ItemFieldValue" => %{
                   "projectV2Item" => %{"id" => "PVTI_1"}
                 }
               }
             }
           }}

        true ->
          flunk("unexpected request: #{inspect(request_opts)}")
      end
    end

    assert {:ok, %{"id" => "PVTI_1"}} =
             Client.update_issue_state("PVTI_1", "Human Review", request_fun: request_fun)
  end

  test "create_comment and fetch_human_response_marker use the GitHub issue comment endpoint" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_endpoint: "https://api.github.com",
      tracker_api_key: nil,
      tracker_api_access_token: "github-token",
      tracker_project_slug: nil,
      tracker_board_id: nil,
      tracker_owner: "octo-org",
      tracker_repo: "symphony",
      tracker_project_number: "7"
    )

    request_fun = fn request_opts ->
      query = get_in(request_opts, [:json, "query"])

      cond do
        is_binary(query) and String.contains?(query, "SymphonyGitHubProjectItemCommentTarget") ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "content" => %{
                     "__typename" => "Issue",
                     "number" => 44,
                     "repository" => %{"name" => "symphony", "owner" => %{"login" => "octo-org"}}
                   }
                 }
               }
             }
           }}

        request_opts[:method] == :post ->
          assert request_opts[:url] == "https://api.github.com/repos/octo-org/symphony/issues/44/comments"
          assert request_opts[:json] == %{"body" => "Need clarification"}
          {:ok, %{status: 201, body: %{"id" => 501}}}

        request_opts[:method] == :get ->
          assert request_opts[:url] == "https://api.github.com/repos/octo-org/symphony/issues/44/comments"

          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "body" => "## Codex Question\nNeed more detail",
                 "created_at" => "2026-03-24T12:00:00Z",
                 "user" => %{"login" => "codex-bot", "type" => "Bot"}
               },
               %{
                 "body" => "Use the existing issue sidebar component.",
                 "created_at" => "2026-03-24T12:05:00Z",
                 "user" => %{"login" => "maintainer", "type" => "User"}
               }
             ]
           }}

        true ->
          flunk("unexpected request: #{inspect(request_opts)}")
      end
    end

    assert {:ok, %{"id" => 501}} =
             Client.create_comment("PVTI_1", "Need clarification", request_fun: request_fun)

    assert {:ok, marker} =
             Client.fetch_human_response_marker("PVTI_1",
               since: ~U[2026-03-24 12:00:00Z],
               request_fun: request_fun
             )

    assert marker["kind"] == "comment"
    assert marker["author"] == "maintainer"
    assert marker["summary"] == "human comment added on GitHub issue"
    assert marker["comment_excerpt"] =~ "existing issue sidebar component"
  end
end
