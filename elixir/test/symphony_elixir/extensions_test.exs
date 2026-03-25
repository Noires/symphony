defmodule SymphonyElixir.ExtensionsTest do
  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyElixir.GitHub.Adapter, as: GitHubAdapter
  alias SymphonyElixir.Linear.Adapter, as: LinearAdapter
  alias SymphonyElixir.Trello.Adapter, as: TrelloAdapter
  alias SymphonyElixir.{AuditLog, CodexAuth}
  alias SymphonyElixir.Tracker.Memory

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FakeLinearClient do
    def fetch_candidate_issues do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def graphql(query, variables) do
      send(self(), {:graphql_called, query, variables})

      case Process.get({__MODULE__, :graphql_results}) do
        [result | rest] ->
          Process.put({__MODULE__, :graphql_results}, rest)
          result

        _ ->
          Process.get({__MODULE__, :graphql_result})
      end
    end
  end

  defmodule FakeTrelloClient do
    defp notify(message) do
      recipient = Application.get_env(:symphony_elixir, :trello_client_test_recipient, self())
      send(recipient, message)
    end

    def fetch_candidate_issues do
      notify(:trello_fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      notify({:trello_fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      notify({:trello_fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def create_comment(issue_id, body) do
      notify({:trello_create_comment_called, issue_id, body})

      case Process.get({__MODULE__, :create_comment_result}) do
        nil -> {:ok, %{"id" => "comment-1"}}
        result -> result
      end
    end

    def update_issue_state(issue_id, state_name) do
      notify({:trello_update_issue_state_called, issue_id, state_name})

      case Process.get({__MODULE__, :update_issue_state_result}) do
        nil -> {:ok, %{"idList" => "list-1"}}
        result -> result
      end
    end

    def fetch_human_response_marker(issue_id, opts \\ []) do
      notify({:trello_fetch_human_response_marker_called, issue_id, opts})

      case Process.get({__MODULE__, :human_response_marker_result}) do
        nil -> {:ok, nil}
        result -> result
      end
    end
  end

  defmodule FakeGitHubClient do
    defp notify(message) do
      recipient = Application.get_env(:symphony_elixir, :github_client_test_recipient, self())
      send(recipient, message)
    end

    def fetch_candidate_issues do
      notify(:github_fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      notify({:github_fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      notify({:github_fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def create_comment(issue_id, body) do
      notify({:github_create_comment_called, issue_id, body})

      case Process.get({__MODULE__, :create_comment_result}) do
        nil -> {:ok, %{"id" => "comment-1"}}
        result -> result
      end
    end

    def update_issue_state(issue_id, state_name) do
      notify({:github_update_issue_state_called, issue_id, state_name})

      case Process.get({__MODULE__, :update_issue_state_result}) do
        nil -> {:ok, %{"id" => issue_id}}
        result -> result
      end
    end

    def fetch_human_response_marker(issue_id, opts \\ []) do
      notify({:github_fetch_human_response_marker_called, issue_id, opts})

      case Process.get({__MODULE__, :human_response_marker_result}) do
        nil -> {:ok, nil}
        result -> result
      end
    end
  end

  defmodule SlowOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, :ok, opts)
    end

    def init(:ok), do: {:ok, :ok}

    def handle_call(:snapshot, _from, state) do
      Process.sleep(25)
      {:reply, %{}, state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, Keyword.get(state, :refresh, :unavailable), state}
    end
  end

  setup do
    linear_client_module = Application.get_env(:symphony_elixir, :linear_client_module)
    trello_client_module = Application.get_env(:symphony_elixir, :trello_client_module)
    trello_client_test_recipient = Application.get_env(:symphony_elixir, :trello_client_test_recipient)
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)
    github_client_test_recipient = Application.get_env(:symphony_elixir, :github_client_test_recipient)

    on_exit(fn ->
      if is_nil(linear_client_module) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, linear_client_module)
      end

      if is_nil(trello_client_module) do
        Application.delete_env(:symphony_elixir, :trello_client_module)
      else
        Application.put_env(:symphony_elixir, :trello_client_module, trello_client_module)
      end

      if is_nil(trello_client_test_recipient) do
        Application.delete_env(:symphony_elixir, :trello_client_test_recipient)
      else
        Application.put_env(:symphony_elixir, :trello_client_test_recipient, trello_client_test_recipient)
      end

      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end

      if is_nil(github_client_test_recipient) do
        Application.delete_env(:symphony_elixir, :github_client_test_recipient)
      else
        Application.put_env(:symphony_elixir, :github_client_test_recipient, github_client_test_recipient)
      end
    end)

    :ok
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  setup do
    audit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-#{System.unique_integer([:positive])}"
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

  test "workflow store reloads changes, keeps last good workflow, and falls back when stopped" do
    ensure_workflow_store_running()
    assert {:ok, %{prompt: "You are an agent for this repository."}} = Workflow.current()

    write_workflow_file!(Workflow.workflow_file_path(), prompt: "Second prompt")
    send(WorkflowStore, :poll)

    assert_eventually(fn ->
      match?({:ok, %{prompt: "Second prompt"}}, Workflow.current())
    end)

    File.write!(Workflow.workflow_file_path(), "---\ntracker: [\n---\nBroken prompt\n")
    assert {:error, _reason} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second prompt"}} = Workflow.current()

    third_workflow = Path.join(Path.dirname(Workflow.workflow_file_path()), "THIRD_WORKFLOW.md")
    write_workflow_file!(third_workflow, prompt: "Third prompt")
    Workflow.set_workflow_file_path(third_workflow)
    assert {:ok, %{prompt: "Third prompt"}} = Workflow.current()

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)
    assert {:ok, %{prompt: "Third prompt"}} = WorkflowStore.current()
    assert :ok = WorkflowStore.force_reload()
    assert {:ok, _pid} = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)
  end

  test "workflow store init stops on missing workflow file" do
    missing_path = Path.join(Path.dirname(Workflow.workflow_file_path()), "MISSING_WORKFLOW.md")
    Workflow.set_workflow_file_path(missing_path)

    assert {:stop, {:missing_workflow_file, ^missing_path, :enoent}} = WorkflowStore.init([])
  end

  test "workflow store start_link and poll callback cover missing-file error paths" do
    ensure_workflow_store_running()
    existing_path = Workflow.workflow_file_path()
    manual_path = Path.join(Path.dirname(existing_path), "MANUAL_WORKFLOW.md")
    missing_path = Path.join(Path.dirname(existing_path), "MANUAL_MISSING_WORKFLOW.md")

    assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, WorkflowStore)

    Workflow.set_workflow_file_path(missing_path)

    assert {:error, {:missing_workflow_file, ^missing_path, :enoent}} =
             WorkflowStore.force_reload()

    write_workflow_file!(manual_path, prompt: "Manual workflow prompt")
    Workflow.set_workflow_file_path(manual_path)

    assert {:ok, manual_pid} = WorkflowStore.start_link()
    assert Process.alive?(manual_pid)

    state = :sys.get_state(manual_pid)
    File.write!(manual_path, "---\ntracker: [\n---\nBroken prompt\n")
    assert {:noreply, returned_state} = WorkflowStore.handle_info(:poll, state)
    assert returned_state.workflow.prompt == "Manual workflow prompt"
    refute returned_state.stamp == nil
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(missing_path)
    assert {:noreply, path_error_state} = WorkflowStore.handle_info(:poll, returned_state)
    assert path_error_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Workflow.set_workflow_file_path(manual_path)
    File.rm!(manual_path)
    assert {:noreply, removed_state} = WorkflowStore.handle_info(:poll, path_error_state)
    assert removed_state.workflow.prompt == "Manual workflow prompt"
    assert_receive :poll, 1_100

    Process.exit(manual_pid, :normal)
    restart_result = Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore)

    assert match?({:ok, _pid}, restart_result) or
             match?({:error, {:already_started, _pid}}, restart_result)

    Workflow.set_workflow_file_path(existing_path)
    WorkflowStore.force_reload()
  end

  test "tracker delegates to memory, linear, and trello adapters" do
    issue = %Issue{id: "issue-1", identifier: "MT-1", state: "In Progress"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue, %{id: "ignored"}])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory")

    assert Config.settings!().tracker.kind == "memory"
    assert SymphonyElixir.Tracker.adapter() == Memory
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_candidate_issues()
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issues_by_states([" in progress ", 42])
    assert {:ok, [^issue]} = SymphonyElixir.Tracker.fetch_issue_states_by_ids(["issue-1"])
    assert :ok = SymphonyElixir.Tracker.create_comment("issue-1", "comment")
    assert :ok = SymphonyElixir.Tracker.update_issue_state("issue-1", "Done")
    assert_receive {:memory_tracker_comment, "issue-1", "comment"}
    assert_receive {:memory_tracker_state_update, "issue-1", "Done"}
    assert {:ok, nil} = SymphonyElixir.Tracker.fetch_human_response_marker("issue-1")

    Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    assert :ok = Memory.create_comment("issue-1", "quiet")
    assert :ok = Memory.update_issue_state("issue-1", "Quiet")

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear")
    assert SymphonyElixir.Tracker.adapter() == LinearAdapter
    assert {:ok, nil} = SymphonyElixir.Tracker.fetch_human_response_marker("issue-1")

    Application.put_env(:symphony_elixir, :trello_client_module, FakeTrelloClient)
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "trello",
      tracker_endpoint: "https://api.trello.com/1",
      tracker_api_key: "trello-key",
      tracker_api_access_token: "trello-token",
      tracker_board_id: "board-1",
      tracker_project_slug: nil
    )

    assert SymphonyElixir.Tracker.adapter() == TrelloAdapter
    assert {:ok, nil} = SymphonyElixir.Tracker.fetch_human_response_marker("card-1")

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

    assert SymphonyElixir.Tracker.adapter() == GitHubAdapter
    assert {:ok, nil} = SymphonyElixir.Tracker.fetch_human_response_marker("item-1")
  end

  test "linear adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :linear_client_module, FakeLinearClient)

    assert {:ok, [:candidate]} = LinearAdapter.fetch_candidate_issues()
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = LinearAdapter.fetch_issues_by_states(["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = LinearAdapter.fetch_issue_states_by_ids(["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
    )

    assert :ok = LinearAdapter.create_comment("issue-1", "hello")
    assert_receive {:graphql_called, create_comment_query, %{body: "hello", issueId: "issue-1"}}
    assert create_comment_query =~ "commentCreate"

    Process.put(
      {FakeLinearClient, :graphql_result},
      {:ok, %{"data" => %{"commentCreate" => %{"success" => false}}}}
    )

    assert {:error, :comment_create_failed} =
             LinearAdapter.create_comment("issue-1", "broken")

    Process.put({FakeLinearClient, :graphql_result}, {:error, :boom})

    assert {:error, :boom} = LinearAdapter.create_comment("issue-1", "boom")

    Process.put({FakeLinearClient, :graphql_result}, {:ok, %{"data" => %{}}})
    assert {:error, :comment_create_failed} = LinearAdapter.create_comment("issue-1", "weird")

    Process.put({FakeLinearClient, :graphql_result}, :unexpected)
    assert {:error, :comment_create_failed} = LinearAdapter.create_comment("issue-1", "odd")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => true}}}}
      ]
    )

    assert :ok = LinearAdapter.update_issue_state("issue-1", "Done")
    assert_receive {:graphql_called, state_lookup_query, %{issueId: "issue-1", stateName: "Done"}}
    assert state_lookup_query =~ "states"

    assert_receive {:graphql_called, update_issue_query, %{issueId: "issue-1", stateId: "state-1"}}

    assert update_issue_query =~ "issueUpdate"

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{"issueUpdate" => %{"success" => false}}}}
      ]
    )

    assert {:error, :issue_update_failed} =
             LinearAdapter.update_issue_state("issue-1", "Broken")

    Process.put({FakeLinearClient, :graphql_results}, [{:error, :boom}])

    assert {:error, :boom} = LinearAdapter.update_issue_state("issue-1", "Boom")

    Process.put({FakeLinearClient, :graphql_results}, [{:ok, %{"data" => %{}}}])
    assert {:error, :state_not_found} = LinearAdapter.update_issue_state("issue-1", "Missing")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        {:ok, %{"data" => %{}}}
      ]
    )

    assert {:error, :issue_update_failed} = LinearAdapter.update_issue_state("issue-1", "Weird")

    Process.put(
      {FakeLinearClient, :graphql_results},
      [
        {:ok,
         %{
           "data" => %{
             "issue" => %{"team" => %{"states" => %{"nodes" => [%{"id" => "state-1"}]}}}
           }
         }},
        :unexpected
      ]
    )

    assert {:error, :issue_update_failed} = LinearAdapter.update_issue_state("issue-1", "Odd")
  end

  test "trello adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :trello_client_module, FakeTrelloClient)

    assert {:ok, [:candidate]} = TrelloAdapter.fetch_candidate_issues()
    assert_receive :trello_fetch_candidate_issues_called

    assert {:ok, ["KI"]} = TrelloAdapter.fetch_issues_by_states(["KI"])
    assert_receive {:trello_fetch_issues_by_states_called, ["KI"]}

    assert {:ok, ["card-1"]} = TrelloAdapter.fetch_issue_states_by_ids(["card-1"])
    assert_receive {:trello_fetch_issue_states_by_ids_called, ["card-1"]}

    Process.put({FakeTrelloClient, :create_comment_result}, {:ok, %{"id" => "comment-1"}})
    assert :ok = TrelloAdapter.create_comment("card-1", "hello")
    assert_receive {:trello_create_comment_called, "card-1", "hello"}

    Process.put({FakeTrelloClient, :create_comment_result}, {:ok, %{"type" => "commentCard"}})
    assert :ok = TrelloAdapter.create_comment("card-1", "hello-again")

    Process.put({FakeTrelloClient, :create_comment_result}, {:ok, %{}})
    assert {:error, :comment_create_failed} = TrelloAdapter.create_comment("card-1", "broken")

    Process.put({FakeTrelloClient, :create_comment_result}, {:error, :boom})
    assert {:error, :boom} = TrelloAdapter.create_comment("card-1", "boom")

    Process.put({FakeTrelloClient, :update_issue_state_result}, {:ok, %{"idList" => "list-2"}})
    assert :ok = TrelloAdapter.update_issue_state("card-1", "Human Review")
    assert_receive {:trello_update_issue_state_called, "card-1", "Human Review"}

    Process.put({FakeTrelloClient, :update_issue_state_result}, {:ok, %{}})

    assert {:error, :issue_update_failed} =
             TrelloAdapter.update_issue_state("card-1", "Done")

    Process.put({FakeTrelloClient, :update_issue_state_result}, {:error, :state_not_found})

    assert {:error, :state_not_found} =
             TrelloAdapter.update_issue_state("card-1", "Missing")

    Process.put({FakeTrelloClient, :human_response_marker_result}, {:ok, %{"kind" => "comment"}})
    assert {:ok, %{"kind" => "comment"}} = TrelloAdapter.fetch_human_response_marker("card-1", since: ~U[2026-03-24 12:00:00Z])
    assert_receive {:trello_fetch_human_response_marker_called, "card-1", marker_opts}
    assert Keyword.has_key?(marker_opts, :since)
  end

  test "github adapter delegates reads and validates mutation responses" do
    Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
    Application.put_env(:symphony_elixir, :github_client_test_recipient, self())

    assert {:ok, [:candidate]} = GitHubAdapter.fetch_candidate_issues()
    assert_receive :github_fetch_candidate_issues_called

    assert {:ok, ["KI"]} = GitHubAdapter.fetch_issues_by_states(["KI"])
    assert_receive {:github_fetch_issues_by_states_called, ["KI"]}

    assert {:ok, ["item-1"]} = GitHubAdapter.fetch_issue_states_by_ids(["item-1"])
    assert_receive {:github_fetch_issue_states_by_ids_called, ["item-1"]}

    Process.put({FakeGitHubClient, :create_comment_result}, {:ok, %{"id" => "comment-1"}})
    assert :ok = GitHubAdapter.create_comment("item-1", "hello")
    assert_receive {:github_create_comment_called, "item-1", "hello"}

    Process.put({FakeGitHubClient, :create_comment_result}, {:ok, %{}})
    assert {:error, :comment_create_failed} = GitHubAdapter.create_comment("item-1", "broken")

    Process.put({FakeGitHubClient, :create_comment_result}, {:error, :boom})
    assert {:error, :boom} = GitHubAdapter.create_comment("item-1", "boom")

    Process.put({FakeGitHubClient, :update_issue_state_result}, {:ok, %{"id" => "item-1"}})
    assert :ok = GitHubAdapter.update_issue_state("item-1", "Human Review")
    assert_receive {:github_update_issue_state_called, "item-1", "Human Review"}

    Process.put({FakeGitHubClient, :update_issue_state_result}, {:ok, %{}})
    assert {:error, :issue_update_failed} = GitHubAdapter.update_issue_state("item-1", "Done")

    Process.put({FakeGitHubClient, :update_issue_state_result}, {:error, :state_not_found})
    assert {:error, :state_not_found} = GitHubAdapter.update_issue_state("item-1", "Missing")

    Process.put({FakeGitHubClient, :human_response_marker_result}, {:ok, %{"kind" => "comment"}})
    assert {:ok, %{"kind" => "comment"}} = GitHubAdapter.fetch_human_response_marker("item-1", since: ~U[2026-03-24 12:00:00Z])
    assert_receive {:github_fetch_human_response_marker_called, "item-1", marker_opts}
    assert Keyword.has_key?(marker_opts, :since)
  end

  test "phoenix observability api preserves state, issue, and refresh responses" do
    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :ObservabilityApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll", "reconcile"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    conn = get(build_conn(), "/api/v1/state")
    state_payload = json_response(conn, 200)

    assert state_payload == %{
             "generated_at" => state_payload["generated_at"],
             "storage_backend" => "flat_files",
             "counts" => %{
               "running" => 1,
               "pending_approvals" => 0,
               "retrying" => 1,
               "guardrail_rules" => 0,
               "active_guardrail_rules" => 0,
               "active_overrides" => 0,
               "completed_runs" => 0,
               "issue_rollups" => 0,
               "expensive_runs" => 0,
               "cheap_wins" => 0
             },
             "running" => [
               %{
                 "issue_id" => "issue-http",
                 "issue_identifier" => "MT-HTTP",
                 "state" => "In Progress",
                 "worker_host" => nil,
                 "workspace_path" => nil,
                 "session_id" => "thread-http",
                 "turn_count" => 7,
                 "last_event" => "notification",
                 "last_message" => "rendered",
                 "started_at" => state_payload["running"] |> List.first() |> Map.fetch!("started_at"),
                 "last_event_at" => nil,
                 "tokens" => %{
                   "input_tokens" => 4,
                   "cached_input_tokens" => 1,
                   "uncached_input_tokens" => 3,
                   "output_tokens" => 8,
                   "total_tokens" => 12
                 }
               }
             ],
             "retrying" => [
               %{
                 "issue_id" => "issue-retry",
                 "issue_identifier" => "MT-RETRY",
                 "attempt" => 2,
                 "due_at" => state_payload["retrying"] |> List.first() |> Map.fetch!("due_at"),
                 "error" => "boom",
                 "worker_host" => nil,
                 "workspace_path" => nil
               }
             ],
             "pending_approvals" => [],
             "guardrail_rules" => [],
             "guardrail_overrides" => [],
             "completed_runs" => [],
             "expensive_runs" => [],
             "cheap_wins" => [],
             "issue_rollups" => [],
             "settings_overlay" => %{
               "version" => 1,
               "updated_at" => nil,
               "updated_by" => nil,
               "reason" => nil,
               "changes" => %{}
             },
             "settings" => state_payload["settings"],
             "settings_history" => [],
             "settings_error" => nil,
             "github_access" => %{
               "generated_at" => state_payload["github_access"]["generated_at"],
               "config" => %{
                 "version" => 1,
                 "updated_at" => nil,
                 "updated_by" => nil,
                 "reason" => nil,
                 "values" => %{}
               },
               "settings" => state_payload["github_access"]["settings"],
               "token" => %{
                 "configured" => false,
                 "source" => "none",
                 "source_label" => "None",
                 "updated_at" => nil,
                 "updated_by" => nil,
                 "reason" => nil,
                 "cleared_at" => nil,
                 "cleared_by" => nil,
                 "clear_reason" => nil
               },
               "history" => []
             },
             "github_access_error" => nil,
             "codex_auth" => %{
               "phase" => "idle",
               "authenticated" => false,
               "status_code" => "unknown",
               "status_summary" => "status unknown",
               "status_checked_at" => nil,
               "verification_uri" => nil,
               "user_code" => nil,
               "started_at" => nil,
               "completed_at" => nil,
               "updated_at" => state_payload["codex_auth"]["updated_at"],
               "exit_status" => nil,
               "error" => nil,
               "launch_command" => nil,
               "in_progress" => false,
               "output_lines" => []
             },
             "codex_totals" => %{
               "input_tokens" => 4,
               "cached_input_tokens" => 1,
               "uncached_input_tokens" => 3,
               "output_tokens" => 8,
               "total_tokens" => 12,
               "seconds_running" => 42.5
             },
             "rate_limits" => %{"primary" => %{"remaining" => 11}}
           }

    conn = get(build_conn(), "/api/v1/MT-HTTP")
    issue_payload = json_response(conn, 200)

    assert issue_payload == %{
             "issue_identifier" => "MT-HTTP",
             "issue_id" => "issue-http",
             "storage_backend" => "flat_files",
             "status" => "running",
             "workspace" => %{
               "path" => Path.join(Config.settings!().workspace.root, "MT-HTTP"),
               "host" => nil
             },
             "attempts" => %{"restart_count" => 0, "current_retry_attempt" => 0},
             "running" => %{
               "worker_host" => nil,
               "workspace_path" => nil,
               "session_id" => "thread-http",
               "turn_count" => 7,
               "state" => "In Progress",
               "started_at" => issue_payload["running"]["started_at"],
               "last_event" => "notification",
               "last_message" => "rendered",
               "last_event_at" => nil,
               "tokens" => %{
                 "input_tokens" => 4,
                 "cached_input_tokens" => 1,
                 "uncached_input_tokens" => 3,
                 "output_tokens" => 8,
                 "total_tokens" => 12
               }
             },
             "retry" => nil,
             "pending_approval" => nil,
             "logs" => %{"codex_session_logs" => []},
             "recent_events" => [],
             "last_error" => nil,
             "latest_run" => nil,
             "rollup" => nil,
             "runs" => [],
             "tracked" => %{}
           }

    conn = get(build_conn(), "/api/v1/MT-RETRY")

    assert %{"status" => "retrying", "retry" => %{"attempt" => 2, "error" => "boom"}} =
             json_response(conn, 200)

    conn = get(build_conn(), "/api/v1/MT-MISSING")

    assert json_response(conn, 404) == %{
             "error" => %{"code" => "issue_not_found", "message" => "Issue not found"}
           }

    conn = post(build_conn(), "/api/v1/refresh", %{})

    assert %{"queued" => true, "coalesced" => false, "operations" => ["poll", "reconcile"]} =
             json_response(conn, 202)
  end

  test "phoenix observability api exposes UI-managed runtime settings and operator updates" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 2,
      observability_audit_dashboard_runs: 6,
      guardrails_operator_token: "settings-token"
    )

    orchestrator_name = Module.concat(__MODULE__, :SettingsOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    settings_payload = json_response(get(build_conn(), "/api/v1/settings"), 200)

    assert get_in(settings_payload, ["overlay", "changes"]) == %{}

    assert Enum.any?(settings_payload["settings"], fn setting ->
             setting["path"] == "agent.max_concurrent_agents" and
               setting["effective_value"] == 2 and
               setting["source"] == "workflow"
           end)

    updated_payload =
      json_response(
        post(build_conn(), "/api/v1/settings", %{
          "operator_token" => "settings-token",
          "changes" => %{
            "agent.max_concurrent_agents" => "3",
            "observability.audit_dashboard_runs" => "12"
          }
        }),
        200
      )

    assert get_in(updated_payload, ["overlay", "changes", "agent", "max_concurrent_agents"]) == 3
    assert get_in(updated_payload, ["overlay", "changes", "observability", "audit_dashboard_runs"]) == 12
    assert Config.settings!().agent.max_concurrent_agents == 3
    assert Config.settings!().observability.audit_dashboard_runs == 12

    overlay_payload = json_response(get(build_conn(), "/api/v1/settings/overlay"), 200)
    assert get_in(overlay_payload, ["changes", "agent", "max_concurrent_agents"]) == 3

    history_payload = json_response(get(build_conn(), "/api/v1/settings/history"), 200)
    assert get_in(history_payload, ["history", Access.at(0), "action"]) == "update"

    reset_payload =
      json_response(
        post(build_conn(), "/api/v1/settings/reset", %{
          "operator_token" => "settings-token",
          "paths" => ["agent.max_concurrent_agents"]
        }),
        200
      )

    assert get_in(reset_payload, ["overlay", "changes", "observability", "audit_dashboard_runs"]) == 12
    assert Config.settings!().agent.max_concurrent_agents == 2

    assert json_response(
             post(build_conn(), "/api/v1/settings", %{
               "operator_token" => "wrong-token",
               "changes" => %{"agent.max_concurrent_agents" => "4"}
             }),
             403
           ) == %{
             "error" => %{
               "code" => "operator_token_invalid",
               "message" => "Operator token is invalid"
             }
           }
  end

  test "phoenix observability api exposes Codex device auth status and operator controls" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-codex-auth-api-#{System.unique_integer([:positive])}"
      )

    previous_command = Application.get_env(:symphony_elixir, :codex_auth_command)
    previous_cwd = Application.get_env(:symphony_elixir, :codex_auth_cwd)
    previous_marker = System.get_env("FAKE_CODEX_AUTH_MARKER")
    previous_finish = System.get_env("FAKE_CODEX_AUTH_FINISH_FILE")

    on_exit(fn ->
      CodexAuth.reset()

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
      File.rm_rf(test_root)
    end)

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
        echo "Open https://auth.example.test/device and enter code ZXCV-BNMM"

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
    :ok = CodexAuth.reset()

    write_workflow_file!(Workflow.workflow_file_path(), guardrails_operator_token: "codex-auth-token")

    orchestrator_name = Module.concat(__MODULE__, :CodexAuthApiOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    refreshed_payload =
      json_response(post(build_conn(), "/api/v1/codex/auth/refresh", %{}), 200)

    assert get_in(refreshed_payload, ["codex_auth", "status_code"]) == "not_authenticated"

    started_payload =
      json_response(
        post(build_conn(), "/api/v1/codex/auth/device/start", %{"operator_token" => "codex-auth-token"}),
        200
      )

    assert get_in(started_payload, ["codex_auth", "in_progress"]) == true

    assert_eventually(
      fn ->
        payload = json_response(get(build_conn(), "/api/v1/codex/auth"), 200)
        get_in(payload, ["codex_auth", "user_code"]) == "ZXCV-BNMM"
      end,
      80
    )

    cancelled_payload =
      json_response(
        post(build_conn(), "/api/v1/codex/auth/device/cancel", %{"operator_token" => "codex-auth-token"}),
        200
      )

    assert get_in(cancelled_payload, ["codex_auth", "phase"]) == "cancelled"
  end

  test "phoenix observability api exposes persisted completed run history" do
    issue = %Issue{
      id: "card-44",
      identifier: "TR-44",
      title: "Audit trail",
      state: "In Progress",
      url: "https://trello.example/TR-44"
    }

    started_at = ~U[2026-03-24 12:00:00Z]
    event_at = ~U[2026-03-24 12:00:15Z]

    running_entry = %{
      run_id: "run-44",
      identifier: "TR-44",
      issue: issue,
      worker_host: nil,
      workspace_path: "c:/workspaces/TR-44",
      session_id: "thread-44",
      turn_count: 2,
      started_at: started_at,
      codex_input_tokens: 21,
      codex_cached_input_tokens: 9,
      codex_output_tokens: 8,
      codex_total_tokens: 29,
      last_codex_message: %{
        event: :notification,
        message: %{
          "method" => "item/reasoning/summaryTextDelta",
          "params" => %{"summaryText" => "compare retry paths"}
        }
      },
      last_codex_timestamp: event_at
    }

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-44",
               started_at: started_at,
               retry_attempt: 1
             )

    assert :ok =
             AuditLog.record_runtime_info(running_entry, %{workspace_path: "c:/workspaces/TR-44"})

    assert :ok =
             AuditLog.record_codex_update(running_entry, %{
               event: :notification,
               timestamp: event_at,
               payload: %{
                 "method" => "item/reasoning/textDelta",
                 "params" => %{
                   "delta" => "private chain of thought",
                   "api_token" => "should-not-leak"
                 }
               }
             })

    assert :ok =
             AuditLog.finish_run(running_entry, %{
               status: "completed",
               next_action: "tracker_state_updated",
               issue_state_finished: "Human Review",
               tracker_transition: %{
                 "status" => "ok",
                 "from" => "In Progress",
                 "to" => "Human Review"
               }
             })

    audit_only_orchestrator = Module.concat(__MODULE__, :AuditOnlyOrchestrator)
    start_test_endpoint(orchestrator: audit_only_orchestrator, snapshot_timeout_ms: 50)

    issue_payload = json_response(get(build_conn(), "/api/v1/TR-44"), 200)

    assert issue_payload["status"] == "completed"
    assert issue_payload["workspace"]["path"] == "c:/workspaces/TR-44"
    assert issue_payload["latest_run"]["run_id"] == "run-44"
    assert issue_payload["latest_run"]["status"] == "completed"
    assert issue_payload["latest_run"]["tracker_transition"]["to"] == "Human Review"
    assert length(issue_payload["runs"]) == 1
    assert Enum.any?(issue_payload["logs"]["codex_session_logs"], &(&1["event"] == "run_completed"))
    assert Enum.any?(issue_payload["recent_events"], &(&1["event"] == "run_completed"))

    runs_payload = json_response(get(build_conn(), "/api/v1/TR-44/runs"), 200)
    assert get_in(runs_payload, ["runs", Access.at(0), "run_id"]) == "run-44"

    run_payload = json_response(get(build_conn(), "/api/v1/TR-44/runs/run-44"), 200)
    assert run_payload["storage_backend"] == "flat_files"
    assert run_payload["rollup"]["issue_identifier"] == "TR-44"
    assert run_payload["run"]["turn_count"] == 2
    assert get_in(run_payload, ["run", "tokens", "cached_input_tokens"]) == 9
    assert get_in(run_payload, ["run", "tokens", "uncached_input_tokens"]) == 12

    reasoning_event =
      Enum.find(run_payload["logs"]["codex_session_logs"], &(&1["event"] == "notification"))

    assert reasoning_event["details"]["method"] == "item/reasoning/textDelta"
    assert reasoning_event["details"]["note"] == "reasoning text omitted from persisted audit log"

    run_page_html = html_response(get(build_conn(), "/runs/TR-44/run-44"), 200)
    assert run_page_html =~ "Persisted audit run"
    assert run_page_html =~ "Issue efficiency"
    assert run_page_html =~ "Diff preview"
    assert run_page_html =~ "Event timeline"
    assert run_page_html =~ "Audit bundle"

    export_conn = get(build_conn(), "/api/v1/TR-44/export")
    assert export_conn.status == 200
    assert Plug.Conn.get_resp_header(export_conn, "content-disposition") != []
    assert is_binary(export_conn.resp_body)

    rollups_payload = json_response(get(build_conn(), "/api/v1/rollups"), 200)
    assert rollups_payload["storage_backend"] == "flat_files"
    assert get_in(rollups_payload, ["rollups", Access.at(0), "issue_identifier"]) == "TR-44"
  end

  test "trello workflow publishes a standardized run summary comment after completion" do
    Application.put_env(:symphony_elixir, :trello_client_module, FakeTrelloClient)
    Application.put_env(:symphony_elixir, :trello_client_test_recipient, self())

    issue = %Issue{
      id: "card-summary-1",
      identifier: "TR-SUMMARY",
      title: "Post Trello summary",
      state: "In Progress",
      url: "https://trello.example/TR-SUMMARY"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "trello",
      tracker_endpoint: "https://api.trello.com/1",
      tracker_api_key: "trello-key",
      tracker_api_access_token: "trello-token",
      tracker_board_id: "board-1",
      tracker_project_slug: nil,
      continue_on_active_issue: false,
      completed_issue_state: "Human Review",
      observability_trello_run_summary_enabled: true
    )

    orchestrator_name = Module.concat(__MODULE__, :TrelloSummaryOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    started_at = DateTime.utc_now()

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      run_id: "run-summary-1",
      identifier: "TR-SUMMARY",
      issue: issue,
      session_id: "thread-summary-1",
      turn_count: 1,
      codex_input_tokens: 5,
      codex_output_tokens: 3,
      codex_total_tokens: 8,
      last_codex_message: "finished",
      last_codex_timestamp: started_at,
      started_at: started_at
    }

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-summary-1",
               started_at: started_at,
               retry_attempt: 1,
               timing: %{"queue_wait_ms" => 1_000}
             )

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue.id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, running_entry.ref, :process, self(), :normal})

    assert_receive {:trello_update_issue_state_called, "card-summary-1", "Human Review"}, 1_000
    assert_receive {:trello_create_comment_called, "card-summary-1", body}, 1_000
    assert body =~ "## Codex Summary"
    assert body =~ "Status: `completed`"

    assert_eventually(fn ->
      assert {:ok, run} = AuditLog.get_run("TR-SUMMARY", "run-summary-1")
      get_in(run, ["trello_summary", "status"]) == "posted"
    end)
  end

  test "phoenix observability api exposes github access config and write-only token controls" do
    write_workflow_file!(Workflow.workflow_file_path(),
      guardrails_operator_token: "github-access-token"
    )

    orchestrator_name = Module.concat(__MODULE__, :GitHubAccessOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    payload = json_response(get(build_conn(), "/api/v1/github"), 200)

    assert Enum.any?(payload["settings"], fn setting ->
             setting["path"] == "source_repo_url" and setting["effective_value"] != nil
           end)

    updated_payload =
      json_response(
        post(build_conn(), "/api/v1/github/config", %{
          "operator_token" => "github-access-token",
          "changes" => %{
            "source_repo_url" => "https://github.com/example/api-updated.git",
            "git_author_name" => "API Operator"
          }
        }),
        200
      )

    assert Enum.any?(updated_payload["settings"], fn setting ->
             setting["path"] == "source_repo_url" and
               setting["effective_value"] == "https://github.com/example/api-updated.git" and
               setting["source"] == "ui_override"
           end)

    token_payload =
      json_response(
        post(build_conn(), "/api/v1/github/token", %{
          "operator_token" => "github-access-token",
          "token" => "ui-api-token"
        }),
        200
      )

    assert get_in(token_payload, ["token", "configured"]) == true
    assert get_in(token_payload, ["token", "source"]) == "ui_secret"
    refute inspect(token_payload) =~ "ui-api-token"

    cleared_payload =
      json_response(
        post(build_conn(), "/api/v1/github/token/clear", %{
          "operator_token" => "github-access-token"
        }),
        200
      )

    assert get_in(cleared_payload, ["token", "configured"]) == false

    assert json_response(
             post(build_conn(), "/api/v1/github/config", %{
               "operator_token" => "wrong-token",
               "changes" => %{"git_author_name" => "nope"}
             }),
             403
           ) == %{
             "error" => %{
               "code" => "operator_token_invalid",
               "message" => "Operator token is invalid"
             }
           }
  end

  test "phoenix observability api preserves 405, 404, and unavailable behavior" do
    unavailable_orchestrator = Module.concat(__MODULE__, :UnavailableOrchestrator)
    start_test_endpoint(orchestrator: unavailable_orchestrator, snapshot_timeout_ms: 5)

    assert json_response(post(build_conn(), "/api/v1/state", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/api/v1/refresh"), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(post(build_conn(), "/api/v1/MT-1", %{}), 405) ==
             %{"error" => %{"code" => "method_not_allowed", "message" => "Method not allowed"}}

    assert json_response(get(build_conn(), "/unknown"), 404) ==
             %{"error" => %{"code" => "not_found", "message" => "Route not found"}}

    state_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert state_payload ==
             %{
               "generated_at" => state_payload["generated_at"],
               "error" => %{"code" => "snapshot_unavailable", "message" => "Snapshot unavailable"}
             }

    assert json_response(post(build_conn(), "/api/v1/refresh", %{}), 503) ==
             %{
               "error" => %{
                 "code" => "orchestrator_unavailable",
                 "message" => "Orchestrator is unavailable"
               }
             }
  end

  test "phoenix observability api preserves snapshot timeout behavior" do
    timeout_orchestrator = Module.concat(__MODULE__, :TimeoutOrchestrator)
    {:ok, _pid} = SlowOrchestrator.start_link(name: timeout_orchestrator)
    start_test_endpoint(orchestrator: timeout_orchestrator, snapshot_timeout_ms: 1)

    timeout_payload = json_response(get(build_conn(), "/api/v1/state"), 200)

    assert timeout_payload ==
             %{
               "generated_at" => timeout_payload["generated_at"],
               "error" => %{"code" => "snapshot_timeout", "message" => "Snapshot timed out"}
             }
  end

  test "dashboard bootstraps liveview from embedded static assets" do
    orchestrator_name = Module.concat(__MODULE__, :AssetOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: false,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    html = html_response(get(build_conn(), "/"), 200)
    assert html =~ "/dashboard.css"
    assert html =~ "/vendor/phoenix_html/phoenix_html.js"
    assert html =~ "/vendor/phoenix/phoenix.js"
    assert html =~ "/vendor/phoenix_live_view/phoenix_live_view.js"
    refute html =~ "/assets/app.js"
    refute html =~ "<style>"

    dashboard_css = response(get(build_conn(), "/dashboard.css"), 200)
    assert dashboard_css =~ ":root {"
    assert dashboard_css =~ ".status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-live"
    assert dashboard_css =~ "[data-phx-main].phx-connected .status-badge-offline"

    phoenix_html_js = response(get(build_conn(), "/vendor/phoenix_html/phoenix_html.js"), 200)
    assert phoenix_html_js =~ "phoenix.link.click"

    phoenix_js = response(get(build_conn(), "/vendor/phoenix/phoenix.js"), 200)
    assert phoenix_js =~ "var Phoenix = (() => {"

    live_view_js =
      response(get(build_conn(), "/vendor/phoenix_live_view/phoenix_live_view.js"), 200)

    assert live_view_js =~ "var LiveView = (() => {"
  end

  test "dashboard liveview renders and refreshes over pubsub" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardOrchestrator)
    snapshot = static_snapshot()

    {:ok, orchestrator_pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: snapshot,
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Dashboard"
    assert html =~ "MT-HTTP"
    assert html =~ "MT-RETRY"
    assert html =~ "rendered"
    assert html =~ "Runtime"
    assert html =~ "Live"
    assert html =~ "Offline"
    assert html =~ "Copy ID"
    assert html =~ "Codex update"
    assert html =~ "Running sessions"
    assert html =~ "Retry queue"
    refute html =~ "data-runtime-clock="
    refute html =~ "setInterval(refreshRuntimeClocks"
    refute html =~ "Refresh now"
    refute html =~ "Transport"
    refute html =~ "UI-managed settings"
    refute html =~ "Approval Control"
    assert html =~ "status-badge-live"
    assert html =~ "status-badge-offline"

    updated_snapshot =
      put_in(snapshot.running, [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 8,
          last_codex_event: :notification,
          last_codex_message: %{
            event: :notification,
            message: %{
              payload: %{
                "method" => "codex/event/agent_message_content_delta",
                "params" => %{
                  "msg" => %{
                    "content" => "structured update"
                  }
                }
              }
            }
          },
          last_codex_timestamp: DateTime.utc_now(),
          codex_input_tokens: 10,
          codex_output_tokens: 12,
          codex_total_tokens: 22,
          started_at: DateTime.utc_now()
        }
      ])

    :sys.replace_state(orchestrator_pid, fn state ->
      Keyword.put(state, :snapshot, updated_snapshot)
    end)

    StatusDashboard.notify_update()

    assert_eventually(fn ->
      render(view) =~ "agent message content streaming: structured update"
    end)
  end

  test "dashboard liveview splits overview, approvals, settings, and runs into dedicated pages" do
    orchestrator_name = Module.concat(__MODULE__, :DashboardPagesOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, _overview_view, overview_html} = live(build_conn(), "/")
    assert overview_html =~ "Operations Dashboard"
    assert overview_html =~ "Running sessions"
    assert overview_html =~ "Retry queue"
    refute overview_html =~ "UI-managed settings"

    {:ok, _approvals_view, approvals_html} = live(build_conn(), "/approvals")
    assert approvals_html =~ "Approval Control"
    assert approvals_html =~ "Pending approvals"
    assert approvals_html =~ "Active overrides"
    assert approvals_html =~ "Guardrail rules"
    refute approvals_html =~ "UI-managed settings"

    {:ok, _settings_view, settings_html} = live(build_conn(), "/settings")
    assert settings_html =~ "Runtime Settings"
    assert settings_html =~ "GitHub workspace access"
    assert settings_html =~ "Write-only token"
    assert settings_html =~ "UI-managed settings"
    assert settings_html =~ "Recent changes"
    refute settings_html =~ "Expensive runs"

    {:ok, _runs_view, runs_html} = live(build_conn(), "/runs")
    assert runs_html =~ "Run Intelligence"
    assert runs_html =~ "Expensive runs"
    assert runs_html =~ "Cheap wins"
    assert runs_html =~ "Recent completed runs"
    assert runs_html =~ "Issue efficiency"
    refute runs_html =~ "UI-managed settings"
  end

  test "dashboard liveview can edit UI-managed runtime settings with operator token" do
    write_workflow_file!(Workflow.workflow_file_path(),
      max_concurrent_agents: 2,
      observability_audit_dashboard_runs: 6,
      guardrails_operator_token: "dash-settings-token"
    )

    orchestrator_name = Module.concat(__MODULE__, :DashboardSettingsOrchestrator)

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: orchestrator_name,
        snapshot: static_snapshot(),
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: DateTime.utc_now(),
          operations: ["poll"]
        }
      )

    start_test_endpoint(orchestrator: orchestrator_name, snapshot_timeout_ms: 50)

    {:ok, view, html} = live(build_conn(), "/settings")
    assert html =~ "Device login"
    assert html =~ "GitHub workspace access"
    assert html =~ "UI-managed settings"
    assert html =~ "Recent changes"

    render_change(view, "update_operator_token", %{"operator_token" => "dash-settings-token"})

    updated_html =
      render_submit(view, "update_runtime_setting", %{
        "path" => "agent.max_concurrent_agents",
        "value" => "4"
      })

    assert updated_html =~ "agent.max_concurrent_agents"

    assert_eventually(fn -> Config.settings!().agent.max_concurrent_agents == 4 end)
    assert render(view) =~ "UI override"

    reset_html =
      render_click(view, "reset_runtime_setting", %{
        "path" => "agent.max_concurrent_agents"
      })

    assert reset_html =~ "agent.max_concurrent_agents"

    assert_eventually(fn -> Config.settings!().agent.max_concurrent_agents == 2 end)

    github_html =
      render_submit(view, "update_github_access_setting", %{
        "path" => "source_repo_url",
        "value" => "https://github.com/example/updated-repo.git"
      })

    assert github_html =~ "GitHub workspace access"

    assert_eventually(fn ->
      {:ok, payload} = SymphonyElixir.GitHubAccess.payload()

      Enum.find(payload.settings, &(&1.path == "source_repo_url")).effective_value ==
        "https://github.com/example/updated-repo.git"
    end)

    token_html =
      render_submit(view, "set_github_access_token", %{
        "token" => "github-ui-token"
      })

    assert token_html =~ "Write-only token"

    assert_eventually(fn ->
      {:ok, payload} = SymphonyElixir.GitHubAccess.payload()
      payload.token.configured == true and payload.token.source == "ui_secret"
    end)
  end

  test "dashboard liveview renders an unavailable state without crashing" do
    start_test_endpoint(
      orchestrator: Module.concat(__MODULE__, :MissingDashboardOrchestrator),
      snapshot_timeout_ms: 5
    )

    {:ok, _view, html} = live(build_conn(), "/")
    assert html =~ "Snapshot unavailable"
    assert html =~ "snapshot_unavailable"
  end

  test "http server serves embedded assets, accepts form posts, and rejects invalid hosts" do
    spec = HttpServer.child_spec(port: 0)
    assert spec.id == HttpServer
    assert spec.start == {HttpServer, :start_link, [[port: 0]]}

    assert :ignore = HttpServer.start_link(port: nil)
    assert HttpServer.bound_port() == nil

    snapshot = static_snapshot()
    orchestrator_name = Module.concat(__MODULE__, :BoundPortOrchestrator)

    refresh = %{
      queued: true,
      coalesced: false,
      requested_at: DateTime.utc_now(),
      operations: ["poll"]
    }

    server_opts = [
      host: "127.0.0.1",
      port: 0,
      orchestrator: orchestrator_name,
      snapshot_timeout_ms: 50
    ]

    start_supervised!({StaticOrchestrator, name: orchestrator_name, snapshot: snapshot, refresh: refresh})

    start_supervised!({HttpServer, server_opts})

    port = wait_for_bound_port()
    assert port == HttpServer.bound_port()

    response = Req.get!("http://127.0.0.1:#{port}/api/v1/state")
    assert response.status == 200

    assert response.body["counts"] == %{
             "running" => 1,
             "pending_approvals" => 0,
             "retrying" => 1,
             "guardrail_rules" => 0,
             "active_guardrail_rules" => 0,
             "active_overrides" => 0,
             "completed_runs" => 0,
             "issue_rollups" => 0,
             "expensive_runs" => 0,
             "cheap_wins" => 0
           }

    dashboard_css = Req.get!("http://127.0.0.1:#{port}/dashboard.css")
    assert dashboard_css.status == 200
    assert dashboard_css.body =~ ":root {"

    phoenix_js = Req.get!("http://127.0.0.1:#{port}/vendor/phoenix/phoenix.js")
    assert phoenix_js.status == 200
    assert phoenix_js.body =~ "var Phoenix = (() => {"

    refresh_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/refresh",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert refresh_response.status == 202
    assert refresh_response.body["queued"] == true

    method_not_allowed_response =
      Req.post!("http://127.0.0.1:#{port}/api/v1/state",
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        body: ""
      )

    assert method_not_allowed_response.status == 405
    assert method_not_allowed_response.body["error"]["code"] == "method_not_allowed"

    assert {:error, _reason} = HttpServer.start_link(host: "bad host", port: 0)
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp static_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-http",
          identifier: "MT-HTTP",
          state: "In Progress",
          session_id: "thread-http",
          turn_count: 7,
          codex_app_server_pid: nil,
          last_codex_message: "rendered",
          last_codex_timestamp: nil,
          last_codex_event: :notification,
          codex_input_tokens: 4,
          codex_cached_input_tokens: 1,
          codex_uncached_input_tokens: 3,
          codex_output_tokens: 8,
          codex_total_tokens: 12,
          started_at: DateTime.utc_now()
        }
      ],
      retrying: [
        %{
          issue_id: "issue-retry",
          identifier: "MT-RETRY",
          attempt: 2,
          due_in_ms: 2_000,
          error: "boom"
        }
      ],
      codex_totals: %{
        input_tokens: 4,
        cached_input_tokens: 1,
        uncached_input_tokens: 3,
        output_tokens: 8,
        total_tokens: 12,
        seconds_running: 42.5
      },
      rate_limits: %{"primary" => %{"remaining" => 11}}
    }
  end

  defp wait_for_bound_port do
    assert_eventually(fn ->
      is_integer(HttpServer.bound_port())
    end)

    HttpServer.bound_port()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not met in time")

  defp ensure_workflow_store_running do
    if Process.whereis(WorkflowStore) do
      :ok
    else
      case Supervisor.restart_child(SymphonyElixir.Supervisor, WorkflowStore) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
