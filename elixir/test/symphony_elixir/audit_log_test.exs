defmodule SymphonyElixir.AuditLogTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AuditLog
  alias SymphonyElixir.Linear.Issue

  setup do
    audit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-log-test-#{System.unique_integer([:positive])}"
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
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  test "audit log persists summaries and redacts reasoning text deltas" do
    issue = %Issue{
      id: "card-1",
      identifier: "TR-101",
      title: "Audit trail",
      state: "In Progress",
      url: "https://trello.example/TR-101"
    }

    started_at = ~U[2026-03-24 10:00:00Z]
    event_at = ~U[2026-03-24 10:00:10Z]

    running_entry = %{
      run_id: "run-101",
      identifier: "TR-101",
      issue: issue,
      worker_host: "local",
      workspace_path: "c:/workspaces/TR-101",
      session_id: "thread-101",
      turn_count: 1,
      started_at: started_at,
      codex_input_tokens: 9,
      codex_cached_input_tokens: 3,
      codex_output_tokens: 4,
      codex_total_tokens: 13,
      last_codex_message: %{
        event: :notification,
        message: %{
          "method" => "item/reasoning/summaryTextDelta",
          "params" => %{"summaryText" => "comparing retry strategies"}
        }
      },
      last_codex_timestamp: event_at
    }

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-101",
               started_at: started_at,
               retry_attempt: 2,
               timing: %{"queue_wait_ms" => 5_000, "queue_source" => "active_state_observed"}
             )

    assert :ok = AuditLog.record_runtime_info(running_entry, %{workspace_path: "c:/workspaces/TR-101"})

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

    assert {:ok, [run]} = AuditLog.list_runs("TR-101")
    assert run["status"] == "completed"
    assert run["retry_attempt"] == 2
    assert run["workspace_path"] == "c:/workspaces/TR-101"
    assert run["session_id"] == "thread-101"
    assert run["turn_count"] == 1
    assert run["tokens"]["total_tokens"] == 13
    assert run["tokens"]["cached_input_tokens"] == 3
    assert run["tokens"]["uncached_input_tokens"] == 6
    assert run["tracker_transition"]["to"] == "Human Review"
    assert run["timing"]["queue_wait_ms"] == 5_000
    assert run["efficiency"]["classification"] == "expensive"
    assert run["efficiency"]["primary_label"] == "Retry overhead"
    assert run["efficiency"]["flags"] == ["high_retry_overhead"]

    assert {:ok, events} = AuditLog.get_run_events("TR-101", "run-101")
    assert Enum.any?(events, &(&1["event"] == "run_completed"))

    reasoning_event = Enum.find(events, &(&1["event"] == "notification"))
    assert reasoning_event["details"]["method"] == "item/reasoning/textDelta"
    assert reasoning_event["details"]["note"] == "reasoning text omitted from persisted audit log"
  end

  test "audit log honors workflow-configured truncation, redaction, and retention settings" do
    write_workflow_file!(Workflow.workflow_file_path(),
      observability_audit_runs_per_issue: 2,
      observability_audit_max_string_length: 10,
      observability_audit_max_list_items: 1,
      observability_audit_redact_keys: ["custom_secret"],
      observability_audit_store_reasoning_text: true
    )

    issue = %Issue{id: "card-2", identifier: "TR-102", title: "Retention", state: "In Progress"}
    started_at = ~U[2026-03-24 11:00:00Z]

    for index <- 1..3 do
      run_id = "run-#{index}"

      running_entry = %{
        run_id: run_id,
        identifier: "TR-102",
        issue: issue,
        started_at: DateTime.add(started_at, index, :second),
        codex_input_tokens: index,
        codex_output_tokens: index,
        codex_total_tokens: index * 2,
        turn_count: index
      }

      assert :ok =
               AuditLog.start_run(issue,
                 run_id: run_id,
                 started_at: DateTime.add(started_at, index, :second),
                 retry_attempt: index
               )

      assert :ok =
               AuditLog.record_run_event("TR-102", run_id, %{
                 kind: "audit",
                 event: "custom_event",
                 summary: "custom audit event",
                 details: %{
                   custom_secret: "sensitive-value",
                   payload: "0123456789abcdef",
                   files: ["alpha", "beta"],
                   reasoning: %{
                     method: "item/reasoning/textDelta",
                     text: "kept because config enables it"
                   }
                 }
               })

      assert :ok = AuditLog.finish_run(running_entry, %{status: "completed"})
    end

    assert {:ok, runs} = AuditLog.list_runs("TR-102")
    assert Enum.map(runs, & &1["run_id"]) == ["run-3", "run-2"]
    assert {:error, :not_found} = AuditLog.get_run("TR-102", "run-1")

    assert {:ok, events} = AuditLog.get_run_events("TR-102", "run-3")
    custom_event = Enum.find(events, &(&1["event"] == "custom_event"))

    assert custom_event["details"]["custom_secret"] == "[REDACTED]"
    assert custom_event["details"]["payload"] == "0123456789... [truncated 6 chars]"
    assert custom_event["details"]["files"] == ["alpha", %{"truncated_items" => 1}]

    assert get_in(custom_event, ["details", "reasoning", "text"]) ==
             "kept becau... [truncated 20 chars]"
  end

  test "audit log exports a ticket bundle and renders a trello-facing summary" do
    issue = %Issue{
      id: "card-export",
      identifier: "TR-EXPORT",
      title: "Export bundle",
      state: "Rework",
      url: "https://trello.example/TR-EXPORT"
    }

    started_at = ~U[2026-03-24 11:30:00Z]

    running_entry = %{
      run_id: "run-export",
      identifier: "TR-EXPORT",
      issue: issue,
      started_at: started_at,
      turn_count: 1,
      codex_input_tokens: 11,
      codex_output_tokens: 7,
      codex_total_tokens: 18
    }

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-export",
               started_at: started_at,
               retry_attempt: 1,
               timing: %{
                 "queue_wait_ms" => 15_000,
                 "blocked_for_human_ms" => 90_000,
                 "queue_source" => "active_state_observed"
               }
             )

    assert :ok =
             AuditLog.update_run_summary("TR-EXPORT", "run-export", %{
               "workspace_metadata" => %{
                 "git" => %{
                   "branch" => "main",
                   "head_commit" => "abcdef1234567890",
                   "head_subject" => "Refine audit export flow",
                   "changed_file_count" => 2,
                   "changed_files" => [
                     %{"path" => "README.md"},
                     %{"path" => "lib/symphony_elixir/audit_log.ex"}
                   ]
                 }
               },
               "hook_results" => %{
                 "before_run" => %{"status" => "ok"},
                 "after_success" => %{"status" => "ok"}
               }
             })

    assert :ok =
             AuditLog.finish_run(running_entry, %{
               status: "completed",
               next_action: "tracker_state_updated",
               issue_state_finished: "Human Review",
               tracker_transition: %{
                 "status" => "ok",
                 "from" => "Rework",
                 "to" => "Human Review"
               }
             })

    assert {:ok, run} = AuditLog.get_run("TR-EXPORT", "run-export")
    summary_comment = AuditLog.render_trello_run_summary(run)

    assert summary_comment =~ "## Codex Summary"
    assert summary_comment =~ "Queue wait: 15s"
    assert summary_comment =~ "Human wait: 1m 30s"
    assert summary_comment =~ "Changed files: README.md, lib/symphony_elixir/audit_log.ex"

    assert {:ok, %{path: bundle_path, run_count: 1}} = AuditLog.export_issue_bundle("TR-EXPORT")
    assert File.exists?(bundle_path)

    extract_dir =
      Path.join(
        System.tmp_dir!(),
        "symphony-audit-bundle-extract-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(extract_dir) end)
    File.mkdir_p!(extract_dir)
    assert {:ok, _files} = :zip.extract(String.to_charlist(bundle_path), cwd: String.to_charlist(extract_dir))

    manifest =
      extract_dir
      |> Path.join("manifest.json")
      |> File.read!()
      |> Jason.decode!()

    assert manifest["issue_identifier"] == "TR-EXPORT"
    assert manifest["storage_backend"] == "flat_files"
    assert manifest["run_count"] == 1
    assert File.exists?(Path.join(extract_dir, "runs/run-export/summary.json"))
    assert File.exists?(Path.join(extract_dir, "runs/run-export/events.jsonl"))

    issue_payload =
      extract_dir
      |> Path.join("issue.json")
      |> File.read!()
      |> Jason.decode!()

    assert issue_payload["rollup"]["issue_identifier"] == "TR-EXPORT"
  end

  test "audit log computes issue rollups and renders configurable tracker summaries" do
    write_workflow_file!(Workflow.workflow_file_path(),
      observability_tracker_summary_template:
        "## Audit Summary | Issue: {{ issue.identifier }} | Status: {{ summary.status }} | Runtime: {{ timing.duration_human }} | Tokens: {{ tokens.total_tokens }}"
    )

    issue = %Issue{
      id: "card-rollup",
      identifier: "TR-ROLLUP",
      title: "Rollup coverage",
      state: "Human Review"
    }

    first_started_at = ~U[2026-03-24 14:00:00Z]
    second_started_at = ~U[2026-03-24 14:10:00Z]

    first_run = %{
      run_id: "run-rollup-1",
      identifier: "TR-ROLLUP",
      issue: issue,
      started_at: first_started_at,
      turn_count: 1,
      retry_attempt: 0,
      codex_input_tokens: 8,
      codex_cached_input_tokens: 4,
      codex_output_tokens: 4,
      codex_total_tokens: 12
    }

    second_run = %{
      run_id: "run-rollup-2",
      identifier: "TR-ROLLUP",
      issue: %{issue | state: "Done"},
      started_at: second_started_at,
      turn_count: 2,
      retry_attempt: 1,
      codex_input_tokens: 10,
      codex_cached_input_tokens: 2,
      codex_output_tokens: 5,
      codex_total_tokens: 15
    }

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-rollup-1",
               started_at: first_started_at,
               timing: %{
                 "queue_wait_ms" => 10_000,
                 "blocked_for_human_ms" => 120_000,
                 "human_response_marker" => %{"kind" => "comment", "at" => "2026-03-24T14:02:00Z"}
               }
             )

    assert :ok =
             AuditLog.finish_run(first_run, %{
               status: "completed",
               ended_at: ~U[2026-03-24 14:03:00Z],
               issue_state_finished: "Human Review"
             })

    assert :ok =
             AuditLog.start_run(%{issue | state: "Merging"},
               run_id: "run-rollup-2",
               started_at: second_started_at,
               retry_attempt: 1,
               timing: %{"queue_wait_ms" => 5_000}
             )

    assert :ok =
             AuditLog.finish_run(second_run, %{
               status: "completed",
               ended_at: ~U[2026-03-24 14:12:00Z],
               issue_state_finished: "Done"
             })

    assert {:ok, rollup} = AuditLog.issue_rollup("TR-ROLLUP")
    assert rollup["run_count"] == 2
    assert rollup["retry_runs"] == 1
    assert rollup["total_retry_attempts"] == 1
    assert rollup["handoff_count"] == 1
    assert rollup["merge_run_count"] == 1
    assert rollup["total_tokens"] == 27
    assert rollup["total_cached_input_tokens"] == 6
    assert rollup["total_uncached_input_tokens"] == 12
    assert rollup["avg_uncached_input_tokens_per_run"] == 6
    assert rollup["avg_duration_ms"] == 150_000
    assert rollup["avg_queue_wait_ms"] == 7_500
    assert rollup["avg_handoff_latency_ms"] == 120_000
    assert rollup["avg_merge_latency_ms"] == 120_000
    assert rollup["classification"] == "normal"
    assert rollup["primary_label"] == "Normal"
    assert rollup["flags"] == []
    assert rollup["expensive_runs"] == 0
    assert rollup["cheap_win_runs"] == 0

    assert {:ok, run} = AuditLog.get_run("TR-ROLLUP", "run-rollup-2")
    summary_comment = AuditLog.render_tracker_run_summary(run)
    assert summary_comment =~ "## Audit Summary"
    assert summary_comment =~ "Issue: TR-ROLLUP"
    assert summary_comment =~ "Status: completed"
    assert summary_comment =~ "Tokens: 15"
  end

  test "audit log classifies expensive, cached-heavy, and cheap-win runs" do
    write_workflow_file!(Workflow.workflow_file_path(),
      observability_expensive_run_uncached_input_threshold: 100,
      observability_expensive_run_tokens_per_changed_file_threshold: 60,
      observability_expensive_run_retry_attempt_threshold: 1
    )

    expensive_issue = %Issue{id: "card-expensive", identifier: "TR-EXPENSIVE", title: "Expensive run", state: "In Progress"}
    cached_issue = %Issue{id: "card-cached", identifier: "TR-CACHED", title: "Cached-heavy run", state: "In Progress"}
    cheap_issue = %Issue{id: "card-cheap", identifier: "TR-CHEAP", title: "Cheap win", state: "In Progress"}

    expensive_run = %{
      run_id: "run-expensive",
      identifier: "TR-EXPENSIVE",
      issue: expensive_issue,
      started_at: ~U[2026-03-24 16:00:00Z],
      codex_input_tokens: 150,
      codex_cached_input_tokens: 20,
      codex_output_tokens: 15,
      codex_total_tokens: 165
    }

    cached_run = %{
      run_id: "run-cached",
      identifier: "TR-CACHED",
      issue: cached_issue,
      started_at: ~U[2026-03-24 16:05:00Z],
      codex_input_tokens: 150,
      codex_cached_input_tokens: 140,
      codex_output_tokens: 10,
      codex_total_tokens: 160
    }

    cheap_run = %{
      run_id: "run-cheap",
      identifier: "TR-CHEAP",
      issue: cheap_issue,
      started_at: ~U[2026-03-24 16:10:00Z],
      codex_input_tokens: 24,
      codex_cached_input_tokens: 6,
      codex_output_tokens: 8,
      codex_total_tokens: 32
    }

    assert :ok = AuditLog.start_run(expensive_issue, run_id: "run-expensive", started_at: expensive_run.started_at)

    assert :ok =
             AuditLog.record_workspace_metadata(expensive_run, %{
               "git" => %{"changed_file_count" => 1, "changed_files" => [%{"path" => "lib/expensive.ex"}]}
             })

    assert :ok = AuditLog.finish_run(expensive_run, %{status: "completed"})

    assert :ok = AuditLog.start_run(cached_issue, run_id: "run-cached", started_at: cached_run.started_at)

    assert :ok =
             AuditLog.record_workspace_metadata(cached_run, %{
               "git" => %{"changed_file_count" => 3, "changed_files" => [%{"path" => "lib/cached.ex"}]}
             })

    assert :ok = AuditLog.finish_run(cached_run, %{status: "completed"})

    assert :ok = AuditLog.start_run(cheap_issue, run_id: "run-cheap", started_at: cheap_run.started_at)

    assert :ok =
             AuditLog.record_workspace_metadata(cheap_run, %{
               "git" => %{
                 "changed_file_count" => 2,
                 "changed_files" => [%{"path" => "lib/cheap.ex"}, %{"path" => "test/cheap_test.exs"}]
               }
             })

    assert :ok = AuditLog.finish_run(cheap_run, %{status: "completed"})

    assert {:ok, expensive_summary} = AuditLog.get_run("TR-EXPENSIVE", "run-expensive")
    assert expensive_summary["efficiency"]["classification"] == "expensive"
    assert expensive_summary["efficiency"]["primary_label"] == "High uncached / low output"
    assert "high_uncached_input" in expensive_summary["efficiency"]["flags"]
    assert "high_tokens_per_changed_file" in expensive_summary["efficiency"]["flags"]

    assert {:ok, cached_summary} = AuditLog.get_run("TR-CACHED", "run-cached")
    assert cached_summary["efficiency"]["classification"] == "context_window_heavy"
    assert cached_summary["efficiency"]["primary_label"] == "Context-window heavy"
    assert cached_summary["efficiency"]["flags"] == ["context_window_heavy"]

    assert {:ok, cheap_summary} = AuditLog.get_run("TR-CHEAP", "run-cheap")
    assert cheap_summary["efficiency"]["classification"] == "cheap_win"
    assert cheap_summary["efficiency"]["primary_label"] == "Cheap win"
    assert cheap_summary["efficiency"]["flags"] == []
  end

  test "orchestrator persists a completed run summary on normal worker exit" do
    issue = %Issue{id: "issue-audit-complete", identifier: "MT-AUDIT", state: "In Progress"}
    issue_id = issue.id

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue])
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      continue_on_active_issue: false,
      completed_issue_state: "Human Review"
    )

    orchestrator_name = Module.concat(__MODULE__, :AuditCompletionOrchestrator)
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
      run_id: "run-audit-complete",
      identifier: "MT-AUDIT",
      issue: issue,
      session_id: "thread-audit",
      turn_count: 1,
      codex_input_tokens: 3,
      codex_output_tokens: 2,
      codex_total_tokens: 5,
      last_codex_message: "completed",
      last_codex_timestamp: started_at,
      started_at: started_at
    }

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-audit-complete",
               started_at: started_at,
               retry_attempt: 1
             )

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
    end)

    send(pid, {:DOWN, running_entry.ref, :process, self(), :normal})

    assert_receive {:memory_tracker_state_update, ^issue_id, "Human Review"}
    Process.sleep(50)

    assert {:ok, [run]} = AuditLog.list_runs("MT-AUDIT")
    assert run["status"] == "completed"
    assert run["next_action"] == "tracker_state_updated"
    assert run["tracker_transition"]["to"] == "Human Review"
    assert run["last_error"] == nil
  end

  test "workspace cleanup events are appended to the latest run" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-audit-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workspace_root = Path.join(test_root, "workspaces")
    hook_marker = Path.join(test_root, "before-remove.log")

    File.mkdir_p!(workspace_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_remove: "printf 'cleanup\\n' > #{shell_path(hook_marker)}"
    )

    issue = %Issue{id: "cleanup-1", identifier: "TR-CLEANUP", title: "Cleanup", state: "Done"}

    workspace_path = Path.join(workspace_root, "TR-CLEANUP")
    File.mkdir_p!(workspace_path)
    File.write!(Path.join(workspace_path, "README.md"), "cleanup")

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-cleanup",
               started_at: ~U[2026-03-24 12:30:00Z],
               retry_attempt: 1
             )

    assert :ok = Workspace.remove_issue_workspaces("TR-CLEANUP")

    assert File.read!(hook_marker) == "cleanup\n"
    assert {:ok, events} = AuditLog.get_run_events("TR-CLEANUP", "run-cleanup")
    assert Enum.any?(events, &(&1["event"] == "workspace_cleanup_started"))
    assert Enum.any?(events, &(&1["event"] == "before_remove_started"))
    assert Enum.any?(events, &(&1["event"] == "before_remove_completed"))
    assert Enum.any?(events, &(&1["event"] == "workspace_cleanup_completed"))
    refute File.exists?(workspace_path)
  end

  @tag timeout: 120_000
  test "agent runner records hook results and workspace git metadata into the run summary" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-audit-runner-hooks-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(test_root) end)

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    sh_binary = SymphonyElixir.Shell.find_local_posix_shell(:sh) || raise "sh not found"
    normalized_codex_binary = String.replace(Path.expand(codex_binary), "\\", "/")

    File.mkdir_p!(workspace_root)

    File.write!(codex_binary, """
    #!/bin/sh
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-hooks"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-hooks"}}}'
          printf '%s\\n' '{"method":"turn/completed"}'
          ;;
      esac
    done
    """)

    File.chmod!(codex_binary, 0o755)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      continue_on_active_issue: false,
      codex_command: "\"#{sh_binary}\" \"#{normalized_codex_binary}\" app-server",
      hook_after_create: """
      git init -b main .
      git config user.name 'Test User'
      git config user.email 'test@example.com'
      printf 'initial\\n' > README.md
      git add README.md
      git commit -m 'initial'
      """,
      hook_before_run: "printf 'before\\n' > before.txt",
      hook_after_success: "printf 'after\\n' >> README.md",
      hook_after_run: "printf 'after-run\\n' > after-run.txt"
    )

    issue = %Issue{
      id: "audit-hooks-1",
      identifier: "TR-HOOKS",
      title: "Hooks",
      description: "Capture audit hook metadata",
      state: "In Progress",
      url: "https://example.test/TR-HOOKS"
    }

    assert :ok =
             AuditLog.start_run(issue,
               run_id: "run-hooks",
               started_at: ~U[2026-03-24 13:00:00Z],
               retry_attempt: 1
             )

    assert :ok = AgentRunner.run(issue, nil, continue_on_active_issue: false, run_id: "run-hooks")

    assert {:ok, run} = AuditLog.get_run("TR-HOOKS", "run-hooks")
    assert run["hook_results"]["before_run"]["status"] == "ok"
    assert run["hook_results"]["after_success"]["status"] == "ok"
    assert run["hook_results"]["after_run"]["status"] == "ok"
    assert run["workspace_metadata"]["git"]["dirty"] == true
    assert run["workspace_metadata"]["git"]["changed_file_count"] >= 2
    assert run["workspace_metadata"]["git"]["diff_summary"] =~ "file(s)"
    assert is_list(run["workspace_metadata"]["git"]["diff_files"])
    assert run["workspace_metadata"]["git"]["diff_files"] != []

    changed_paths =
      run["workspace_metadata"]["git"]["changed_files"]
      |> Enum.map(& &1["path"])

    assert "README.md" in changed_paths
    assert "after-run.txt" in changed_paths

    diff_paths =
      run["workspace_metadata"]["git"]["diff_files"]
      |> Enum.map(& &1["path"])

    assert "README.md" in diff_paths
  end
end
