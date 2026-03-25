Code.require_file(Path.expand("../test/support/test_support.exs", __DIR__))

defmodule SymphonyElixir.UiVisualServer do
  alias SymphonyElixir.{AuditLog, GitHubAccess, SettingsOverlay, TestSupport, Workflow, WorkflowStore}
  alias SymphonyElixir.Guardrails.{Approvals, Overrides, Rule}
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixirWeb.Endpoint
  alias SymphonyElixirWeb.Presenter
  alias SymphonyElixir.{CodexAuth, Orchestrator}

  @port String.to_integer(System.get_env("UI_VISUAL_PORT") || "4101")
  @snapshot_timeout_ms 50
  @visual_now ~U[2026-03-25 09:30:00Z]
  @operator_token "visual-operator-token"
  @root Path.join(System.tmp_dir!(), "symphony-ui-visual")
  @trace_path Path.join(@root, "ui-visual-server.log")
  @orchestrator_name Module.concat(__MODULE__, StaticFixtureOrchestrator)

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

  def run do
    trace("boot")
    configure_fixture_environment!()
    trace("environment configured")
    seed_fixture_data!()
    trace("fixture data seeded")
    start_fixture_server!()
    trace("fixture server started")

    IO.puts("UI visual server ready at http://127.0.0.1:#{@port}")
    Process.sleep(:infinity)
  end

  defp configure_fixture_environment! do
    File.rm_rf(@root)
    File.mkdir_p!(@root)
    trace("root prepared")

    Application.put_env(:symphony_elixir, :audit_root, Path.join(@root, "audit"))
    Application.put_env(:symphony_elixir, :ui_visual_now, DateTime.to_iso8601(@visual_now))

    workflow_file = Path.join(@root, "WORKFLOW.md")

    TestSupport.write_workflow_file!(workflow_file,
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "visual-token",
      tracker_project_slug: "symphony-visual",
      continue_on_active_issue: false,
      completed_issue_state: "Human Review",
      guardrails_enabled: true,
      guardrails_operator_token: @operator_token,
      observability_enabled: false,
      observability_audit_dashboard_runs: 12,
      observability_issue_rollup_limit: 12
    )

    Workflow.set_workflow_file_path(workflow_file)
    :ok = WorkflowStore.force_reload()
    :ok = TestSupport.stop_default_http_server()
    trace("workflow ready")
  end

  defp seed_fixture_data! do
    seed_runtime_settings!()
    seed_github_access!()
    seed_codex_auth!()
    seed_completed_runs!()
  end

  defp seed_runtime_settings! do
    {:ok, _payload} =
      SettingsOverlay.update_overlay(
        %{
          "agent.max_concurrent_agents" => "6",
          "agent.max_turns" => "24",
          "observability.audit_dashboard_runs" => "12",
          "guardrails.default_review_mode" => "review"
        },
        actor: "ui-visual",
        reason: "Deterministic browser fixture"
      )
  end

  defp seed_github_access! do
    {:ok, _payload} =
      GitHubAccess.update_config(
        %{
          "source_repo_url" => "https://github.com/example/symphony-ops.git",
          "git_author_name" => "Symphony Operator",
          "git_author_email" => "operator@symphony.invalid",
          "git_committer_name" => "Symphony Automation",
          "git_committer_email" => "automation@symphony.invalid"
        },
        actor: "ui-visual",
        reason: "Deterministic browser fixture"
      )

    {:ok, _payload} =
      GitHubAccess.set_token(
        "ghp_visual_fixture_token",
        actor: "ui-visual",
        reason: "Deterministic browser fixture"
      )
  end

  defp seed_codex_auth! do
    :ok = CodexAuth.reset()

    :sys.replace_state(CodexAuth, fn _state ->
      %CodexAuth{
        port: nil,
        pending_line: "",
        phase: "idle",
        status_code: "authenticated",
        authenticated: true,
        status_checked_at: DateTime.to_iso8601(@visual_now),
        status_summary: "Logged in using ChatGPT",
        status_output: ["Logged in using ChatGPT"],
        verification_uri: nil,
        user_code: nil,
        started_at: nil,
        completed_at: nil,
        updated_at: DateTime.to_iso8601(@visual_now),
        exit_status: nil,
        error: nil,
        launch_command: nil,
        cancel_requested: false
      }
    end)
  end

  defp seed_completed_runs! do
    seed_rich_run_pair!()
    seed_expensive_run!()
    seed_cached_run!()
    seed_cheap_run!()
  end

  defp seed_rich_run_pair! do
    issue = %Issue{
      id: "card-44",
      identifier: "TR-44",
      title: "Audit trail",
      state: "In Progress",
      url: "https://tracker.example/TR-44"
    }

    previous_run =
      running_entry(issue, "run-43", ~U[2026-03-25 08:15:00Z],
        session_id: "thread-43",
        turn_count: 3,
        input_tokens: 180,
        cached_input_tokens: 40,
        output_tokens: 32,
        total_tokens: 212
      )

    current_run =
      running_entry(issue, "run-44", ~U[2026-03-25 08:40:00Z],
        session_id: "thread-44",
        turn_count: 6,
        input_tokens: 16_200,
        cached_input_tokens: 2_400,
        output_tokens: 900,
        total_tokens: 17_100,
        worker_host: "worker-eu-1",
        workspace_path: "c:/visual-workspaces/TR-44"
      )

    persist_run!(issue, previous_run,
      ended_at: ~U[2026-03-25 08:23:00Z],
      metadata: %{
        "git" => %{
          "branch" => "feature/tr-44-hardening",
          "head_commit" => "a4d977d804b8af8f2258d66b11997e5fd1f2d111",
          "head_subject" => "Harden approval audit export",
          "changed_file_count" => 2,
          "changed_files" => [
            %{"path" => "lib/symphony/audit_export.ex"},
            %{"path" => "test/audit_export_test.exs"}
          ],
          "diff_summary" => "+84 / -16 across 2 files",
          "diff_files" => [
            %{
              "path" => "lib/symphony/audit_export.ex",
              "additions" => 62,
              "deletions" => 8,
              "hunks" => ["@@ -20,6 +20,33 @@", "@@ -81,7 +108,19 @@"]
            },
            %{
              "path" => "test/audit_export_test.exs",
              "additions" => 22,
              "deletions" => 8,
              "hunks" => ["@@ -14,4 +14,22 @@"]
            }
          ]
        }
      },
      next_action: "tracker_state_updated",
      issue_state_finished: "Human Review",
      transition_to: "Human Review"
    )

    persist_run!(issue, current_run,
      ended_at: ~U[2026-03-25 08:52:00Z],
      metadata: %{
        "git" => %{
          "branch" => "feature/tr-44-hardening",
          "head_commit" => "bbd977d804b8af8f2258d66b11997e5fd1f2d222",
          "head_subject" => "Restructure operator dashboard shell",
          "changed_file_count" => 3,
          "changed_files" => [
            %{"path" => "lib/symphony_web/live/dashboard_live.ex"},
            %{"path" => "lib/symphony_web/live/run_live.ex"},
            %{"path" => "priv/static/dashboard.css"}
          ],
          "diff_summary" => "+214 / -73 across 3 files",
          "diff_files" => [
            %{
              "path" => "lib/symphony_web/live/dashboard_live.ex",
              "additions" => 101,
              "deletions" => 27,
              "hunks" => ["@@ -118,8 +118,44 @@", "@@ -420,7 +456,33 @@"]
            },
            %{
              "path" => "lib/symphony_web/live/run_live.ex",
              "additions" => 58,
              "deletions" => 18,
              "hunks" => ["@@ -70,5 +70,31 @@"]
            },
            %{
              "path" => "priv/static/dashboard.css",
              "additions" => 55,
              "deletions" => 28,
              "hunks" => ["@@ -320,12 +320,53 @@", "@@ -590,10 +631,37 @@"]
            }
          ]
        }
      },
      next_action: "tracker_state_updated",
      issue_state_finished: "Human Review",
      transition_to: "Human Review",
      extra_events: [
        %{
          event: "approval_pending",
          recorded_at: ~U[2026-03-25 08:44:00Z],
          summary: "approval pending operator review",
          details: %{
            "approval_id" => "approval-ui-1",
            "action_type" => "shell_command",
            "risk_level" => "high"
          }
        },
        %{
          event: "guardrail_rule_applied",
          recorded_at: ~U[2026-03-25 08:46:00Z],
          summary: "workflow allow rule matched prior command shape",
          details: %{
            "rule_id" => "rule-ui-workflow",
            "scope" => "workflow"
          }
        }
      ]
    )
  end

  defp seed_expensive_run! do
    issue = %Issue{id: "issue-expensive", identifier: "TR-EXPENSIVE", title: "Expensive run", state: "In Progress", url: "https://tracker.example/TR-EXPENSIVE"}

    run =
      running_entry(issue, "run-expensive", ~U[2026-03-24 16:00:00Z],
        input_tokens: 12_000,
        cached_input_tokens: 300,
        output_tokens: 10,
        total_tokens: 12_010
      )

    persist_run!(issue, run,
      ended_at: ~U[2026-03-24 16:08:00Z],
      metadata: %{
        "git" => %{
          "changed_file_count" => 1,
          "changed_files" => [%{"path" => "lib/expensive.ex"}]
        }
      },
      next_action: "tracker_state_updated",
      issue_state_finished: "Human Review",
      transition_to: "Human Review"
    )
  end

  defp seed_cached_run! do
    issue = %Issue{id: "issue-cached", identifier: "TR-CACHED", title: "Context window heavy", state: "In Progress", url: "https://tracker.example/TR-CACHED"}

    run =
      running_entry(issue, "run-cached", ~U[2026-03-24 16:05:00Z],
        input_tokens: 150,
        cached_input_tokens: 140,
        output_tokens: 10,
        total_tokens: 160
      )

    persist_run!(issue, run,
      ended_at: ~U[2026-03-24 16:13:00Z],
      metadata: %{
        "git" => %{
          "changed_file_count" => 3,
          "changed_files" => [%{"path" => "lib/cached.ex"}]
        }
      },
      next_action: "tracker_state_updated",
      issue_state_finished: "Human Review",
      transition_to: "Human Review"
    )
  end

  defp seed_cheap_run! do
    issue = %Issue{id: "issue-cheap", identifier: "TR-CHEAP", title: "Cheap win", state: "In Progress", url: "https://tracker.example/TR-CHEAP"}

    run =
      running_entry(issue, "run-cheap", ~U[2026-03-24 16:10:00Z],
        input_tokens: 24,
        cached_input_tokens: 6,
        output_tokens: 8,
        total_tokens: 32
      )

    persist_run!(issue, run,
      ended_at: ~U[2026-03-24 16:16:00Z],
      metadata: %{
        "git" => %{
          "changed_file_count" => 2,
          "changed_files" => [
            %{"path" => "lib/cheap.ex"},
            %{"path" => "test/cheap_test.exs"}
          ]
        }
      },
      next_action: "tracker_state_updated",
      issue_state_finished: "Human Review",
      transition_to: "Human Review"
    )
  end

  defp persist_run!(issue, running_entry, opts) do
    :ok =
      AuditLog.start_run(issue,
        run_id: running_entry.run_id,
        started_at: running_entry.started_at,
        retry_attempt: Keyword.get(opts, :retry_attempt, 0)
      )

    :ok =
      AuditLog.record_runtime_info(running_entry, %{
        workspace_path: Map.get(running_entry, :workspace_path),
        worker_host: Map.get(running_entry, :worker_host),
        recorded_at: DateTime.add(running_entry.started_at, 5, :second)
      })

    :ok =
      AuditLog.record_codex_update(running_entry, %{
        event: :notification,
        timestamp: DateTime.add(running_entry.started_at, 45, :second),
        payload: %{
          "method" => "item/reasoning/summaryTextDelta",
          "params" => %{"summaryText" => "reviewing diff and retry pressure"}
        }
      })

    :ok =
      AuditLog.record_workspace_metadata(
        running_entry,
        Keyword.fetch!(opts, :metadata)
        |> Map.put(:recorded_at, DateTime.add(running_entry.started_at, 73, :second))
      )

    Enum.each(Keyword.get(opts, :extra_events, []), fn event ->
      :ok =
        AuditLog.record_run_event(issue.identifier, running_entry.run_id, %{
          event: event.event,
          recorded_at: event.recorded_at,
          summary: event.summary,
          details: event.details
        })
    end)

    :ok =
      AuditLog.finish_run(running_entry, %{
        ended_at: Keyword.fetch!(opts, :ended_at),
        status: "completed",
        next_action: Keyword.fetch!(opts, :next_action),
        issue_state_finished: Keyword.fetch!(opts, :issue_state_finished),
        tracker_transition: %{
          "status" => "ok",
          "from" => issue.state,
          "to" => Keyword.fetch!(opts, :transition_to)
        }
      })
  end

  defp running_entry(issue, run_id, started_at, opts) do
    %{
      run_id: run_id,
      identifier: issue.identifier,
      issue: issue,
      worker_host: Keyword.get(opts, :worker_host),
      workspace_path: Keyword.get(opts, :workspace_path),
      session_id: Keyword.get(opts, :session_id, "thread-#{run_id}"),
      turn_count: Keyword.get(opts, :turn_count, 2),
      started_at: started_at,
      codex_input_tokens: Keyword.fetch!(opts, :input_tokens),
      codex_cached_input_tokens: Keyword.fetch!(opts, :cached_input_tokens),
      codex_output_tokens: Keyword.fetch!(opts, :output_tokens),
      codex_total_tokens: Keyword.fetch!(opts, :total_tokens),
      last_codex_message: %{
        event: :notification,
        message: %{
          "method" => "item/reasoning/summaryTextDelta",
          "params" => %{"summaryText" => "deterministic fixture event"}
        }
      },
      last_codex_timestamp: DateTime.add(started_at, 45, :second)
    }
  end

  defp fixture_snapshot do
    %{
      running: [
        %{
          issue_id: "github-204",
          identifier: "GH-204",
          state: "In Progress",
          worker_host: "worker-eu-1",
          workspace_path: "c:/visual-workspaces/GH-204",
          session_id: "thread-gh-204",
          turn_count: 7,
          last_codex_message: "refining run explorer toolbar",
          last_codex_timestamp: ~U[2026-03-25 09:27:00Z],
          last_codex_event: :notification,
          codex_input_tokens: 3_800,
          codex_cached_input_tokens: 1_400,
          codex_uncached_input_tokens: 2_400,
          codex_output_tokens: 940,
          codex_total_tokens: 4_740,
          started_at: ~U[2026-03-25 09:12:00Z]
        }
      ],
      retrying: [
        %{
          issue_id: "github-302",
          identifier: "GH-302",
          attempt: 2,
          due_in_ms: 240_000,
          error: "GitHub secondary rate limit response",
          worker_host: "worker-us-2",
          workspace_path: "c:/visual-workspaces/GH-302"
        }
      ],
      pending_approvals: fixture_approvals(),
      guardrail_rules: Enum.map(fixture_active_rules(), &Rule.snapshot_entry/1),
      guardrail_overrides: Enum.map(fixture_active_overrides(), &Overrides.snapshot_entry/1),
      codex_totals: %{
        input_tokens: 28_400,
        cached_input_tokens: 10_200,
        uncached_input_tokens: 18_200,
        output_tokens: 3_640,
        total_tokens: 32_040,
        seconds_running: 18_240
      },
      rate_limits: %{
        "primary" => %{"remaining" => 412},
        "secondary" => %{"remaining" => 37}
      }
    }
  end

  defp fixture_approvals do
    [
      %{
        id: "approval-ui-1",
        issue_id: "card-44",
        issue_identifier: "TR-44",
        state: "In Progress",
        issue_state: "In Progress",
        run_id: "run-44",
        session_id: "thread-44",
        worker_host: "worker-eu-1",
        workspace_path: "c:/visual-workspaces/TR-44",
        status: "pending_review",
        requested_at: ~U[2026-03-25 08:44:00Z],
        action_type: "shell_command",
        method: "shell_command",
        summary: "Install audit export dependency inside workspace",
        risk_level: "high",
        reason: "Networked package install requires operator review",
        source: "guardrail_policy",
        fingerprint: "fp-ui-1",
        protocol_request_id: "req-ui-1",
        decision_options: ["allow_once", "allow_for_session", "allow_via_rule", "deny"],
        details: %{
          "command" => "npm install @opentelemetry/sdk-trace-base",
          "wrapped_command" => "npm install @opentelemetry/sdk-trace-base",
          "cwd" => "c:/visual-workspaces/TR-44",
          "file_paths" => ["package.json", "package-lock.json"],
          "sensitive_paths" => [".env"],
          "review_tags" => ["network_access", "package_install"],
          "command_executable" => "npm",
          "shell_wrapper" => "powershell",
          "network_access" => true
        },
        payload: %{
          "command" => ["npm", "install", "@opentelemetry/sdk-trace-base"]
        },
        explanation: %{
          "evaluation" => %{
            "reason" => "Networked package install requires operator review",
            "disposition" => "review"
          },
          "review_tags" => ["network_access", "package_install"]
        }
      },
      %{
        id: "approval-ui-2",
        issue_id: "github-302",
        issue_identifier: "GH-302",
        state: "In Progress",
        issue_state: "In Progress",
        run_id: "run-gh-302",
        session_id: "thread-gh-302",
        worker_host: "worker-us-2",
        workspace_path: "c:/visual-workspaces/GH-302",
        status: "pending_review",
        requested_at: ~U[2026-03-25 09:05:00Z],
        action_type: "file_write",
        method: "shell_command",
        summary: "Write generated migration into protected database folder",
        risk_level: "medium",
        reason: "Protected path requires operator review",
        source: "guardrail_policy",
        fingerprint: "fp-ui-2",
        protocol_request_id: "req-ui-2",
        decision_options: ["allow_once", "allow_for_session", "allow_via_rule", "deny"],
        details: %{
          "cwd" => "c:/visual-workspaces/GH-302",
          "file_paths" => ["priv/repo/migrations/202603250901_add_ui_state.exs"],
          "review_tags" => ["protected_path"],
          "command_executable" => "mix"
        },
        payload: %{
          "target_path" => "priv/repo/migrations/202603250901_add_ui_state.exs"
        },
        explanation: %{
          "evaluation" => %{
            "reason" => "Protected path requires operator review",
            "disposition" => "review"
          },
          "review_tags" => ["protected_path"]
        }
      }
    ]
  end

  defp fixture_active_overrides do
    [
      Overrides.full_access_override(:run, "run-44",
        actor: "ui-visual",
        reason: "Temporary network access while exporting audit bundle",
        created_at: ~U[2026-03-25 08:45:00Z],
        ttl_ms: 3_600_000
      ),
      Overrides.full_access_override(:workflow, "workflow-default",
        actor: "ui-visual",
        reason: "Workflow-wide sandbox relaxation during migration rehearsal",
        created_at: ~U[2026-03-25 07:30:00Z],
        ttl_ms: 7_200_000
      )
    ]
  end

  defp fixture_active_rules do
    approval = rule_fixture_approval()

    [
      Rule.from_approval(approval, "allow_via_rule",
        id: "rule-ui-workflow",
        created_by: "ui-visual",
        created_at: ~U[2026-03-25 08:46:00Z],
        reason: "Persisted allow rule for trusted export workflow"
      ),
      Rule.from_approval(approval, "allow_for_session",
        id: "rule-ui-run",
        created_by: "ui-visual",
        created_at: ~U[2026-03-25 08:47:00Z],
        reason: "Run-scoped approval for audit export",
        scope: "run",
        scope_key: "run-44"
      )
    ]
  end

  defp rule_fixture_approval do
    %Approvals{
      id: "approval-ui-1",
      issue_id: "card-44",
      issue_identifier: "TR-44",
      issue_state: "In Progress",
      run_id: "run-44",
      session_id: "thread-44",
      worker_host: "worker-eu-1",
      workspace_path: "c:/visual-workspaces/TR-44",
      status: "pending_review",
      requested_at: ~U[2026-03-25 08:44:00Z],
      action_type: "shell_command",
      method: "execCommandApproval",
      summary: "Install audit export dependency inside workspace",
      risk_level: "high",
      reason: "Networked package install requires operator review",
      source: "guardrail_policy",
      fingerprint: "fp-ui-1",
      protocol_request_id: "req-ui-1",
      decision_options: ["allow_once", "allow_for_session", "allow_via_rule", "deny"],
      details: %{
        "command" => "npm install @opentelemetry/sdk-trace-base",
        "wrapped_command" => "npm install @opentelemetry/sdk-trace-base",
        "cwd" => "c:/visual-workspaces/TR-44",
        "file_paths" => ["package.json", "package-lock.json"],
        "sensitive_paths" => [".env"],
        "review_tags" => ["network_access", "package_install"],
        "command_executable" => "npm",
        "shell_wrapper" => "powershell",
        "network_access" => true
      },
      payload: %{
        "id" => "req-ui-1",
        "params" => %{
          "command" => ["npm", "install", "@opentelemetry/sdk-trace-base"],
          "cwd" => "c:/visual-workspaces/TR-44",
          "reason" => "Install export dependency"
        }
      }
    }
  end

  defp start_fixture_server! do
    trace("building guardrail state")
    active_rules = fixture_active_rules()
    active_overrides = fixture_active_overrides()

    Enum.each(active_rules, &AuditLog.put_guardrail_rule/1)
    Enum.each(active_overrides, &AuditLog.put_guardrail_override/1)
    trace("guardrail state persisted")

    {:ok, _pid} =
      StaticOrchestrator.start_link(
        name: @orchestrator_name,
        snapshot: fixture_snapshot(),
        refresh: %{
          queued: true,
          coalesced: true,
          requested_at: @visual_now,
          operations: ["visual-fixture"]
        }
      )
    trace("static orchestrator started")
    trace_presenter_payloads!()

    {:ok, _pid} =
      :symphony_elixir
      |> Application.get_env(Endpoint, [])
      |> Keyword.merge(
        server: true,
        http: [ip: {127, 0, 0, 1}, port: @port],
        url: [host: "127.0.0.1"],
        orchestrator: @orchestrator_name,
        snapshot_timeout_ms: @snapshot_timeout_ms,
        secret_key_base: String.duplicate("s", 64)
      )
      |> then(fn endpoint_config ->
        Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
        Endpoint.start_link()
      end)

    trace("endpoint process started")
    wait_for_port!(20)
    trace("http server bound to #{@port}")
  end

  defp wait_for_port!(0), do: raise("fixture server did not bind to port #{@port} in time")

  defp wait_for_port!(attempts) do
    port =
      case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
        {:ok, {_ip, value}} when is_integer(value) -> value
        _ -> nil
      end

    if port == @port do
      :ok
    else
      Process.sleep(200)
      wait_for_port!(attempts - 1)
    end
  end

  defp trace(message) do
    File.write!(@trace_path, message <> "\n", [:append])
  end

  defp trace_presenter_payloads! do
    trace("orchestrator snapshot start")
    _snapshot = Orchestrator.snapshot(@orchestrator_name, @snapshot_timeout_ms)
    trace("orchestrator snapshot ok")

    trace("audit rules start")
    {:ok, _rules} = AuditLog.list_guardrail_rules(active_only: false)
    trace("audit rules ok")

    trace("audit recent runs start")
    {:ok, _runs} = AuditLog.recent_runs()
    trace("audit recent runs ok")

    trace("audit rollups start")
    {:ok, _rollups} = AuditLog.issue_rollups()
    trace("audit rollups ok")

    trace("settings payload start")
    {:ok, _settings} = SettingsOverlay.payload(history_limit: 10)
    trace("settings payload ok")

    trace("github payload start")
    {:ok, _github} = GitHubAccess.payload(history_limit: 10)
    trace("github payload ok")

    trace("codex auth snapshot start")
    _codex_auth = CodexAuth.snapshot()
    trace("codex auth snapshot ok")

    trace("issue payload start")
    {:ok, _issue_payload} = Presenter.issue_payload("TR-44", @orchestrator_name, @snapshot_timeout_ms)
    trace("issue payload ok")

    trace("run page payload start")
    {:ok, _run_payload} = Presenter.run_page_payload("TR-44", "run-44", @orchestrator_name, @snapshot_timeout_ms)
    trace("run page payload ok")

    try do
      _payload = Presenter.state_payload(@orchestrator_name, @snapshot_timeout_ms)
      trace("state payload ok")
    rescue
      exception ->
        trace("state payload failed")
        trace(Exception.format(:error, exception, __STACKTRACE__))
        reraise exception, __STACKTRACE__
    end

    try do
      {:ok, _payload} = Presenter.run_page_payload("TR-44", "run-44", @orchestrator_name, @snapshot_timeout_ms)
      trace("run page payload ok")
    rescue
      exception ->
        trace("run page payload failed")
        trace(Exception.format(:error, exception, __STACKTRACE__))
        reraise exception, __STACKTRACE__
    end
  end
end

SymphonyElixir.UiVisualServer.run()
