defmodule SymphonyElixirWeb.RunLive do
  @moduledoc """
  HTML drill-down for one persisted audit run.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.{DashboardComponents, Endpoint, Presenter}

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:payload, load_payload(params))
     |> assign(:operator_token, "")
     |> assign(:operator_authenticated, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, assign(socket, :payload, load_payload(params))}
  end

  @impl true
  def handle_event("update_operator_token", %{"operator_token" => token}, socket) do
    {:noreply,
     socket
     |> assign(:operator_token, token)
     |> assign(:operator_authenticated, valid_operator_token?(token))}
  end

  def handle_event("guardrail_decide", %{"approval_id" => approval_id, "decision" => decision} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.decide_guardrail_approval(
             orchestrator(),
             approval_id,
             decision,
             actor: "run_live",
             reason: blank_to_nil(params["reason"]),
             scope: blank_to_nil(params["scope"])
           ) do
      {:noreply,
       socket
       |> assign(:payload, reload_payload(socket.assigns.payload))
       |> put_flash(:info, success_message_for_decision(decision))}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("enable_run_full_access", %{"run_id" => run_id} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.enable_full_access_for_run(
             orchestrator(),
             run_id,
             actor: "run_live",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply,
       socket
       |> assign(:payload, reload_payload(socket.assigns.payload))
       |> put_flash(:info, "Run full access enabled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("enable_guardrail_rule", %{"rule_id" => rule_id} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.enable_guardrail_rule(
             orchestrator(),
             rule_id,
             actor: "run_live",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply,
       socket
       |> assign(:payload, reload_payload(socket.assigns.payload))
       |> put_flash(:info, "Guardrail rule enabled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("disable_guardrail_rule", %{"rule_id" => rule_id} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.disable_guardrail_rule(
             orchestrator(),
             rule_id,
             actor: "run_live",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply,
       socket
       |> assign(:payload, reload_payload(socket.assigns.payload))
       |> put_flash(:info, "Guardrail rule disabled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("expire_guardrail_rule", %{"rule_id" => rule_id} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.expire_guardrail_rule(
             orchestrator(),
             rule_id,
             actor: "run_live",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply,
       socket
       |> assign(:payload, reload_payload(socket.assigns.payload))
       |> put_flash(:info, "Guardrail rule expired.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("disable_run_full_access", %{"run_id" => run_id} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.disable_full_access_for_run(
             orchestrator(),
             run_id,
             actor: "run_live",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply,
       socket
       |> assign(:payload, reload_payload(socket.assigns.payload))
       |> put_flash(:info, "Run full access disabled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("disable_workflow_full_access", params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.disable_full_access_for_workflow(
             orchestrator(),
             actor: "run_live",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply,
       socket
       |> assign(:payload, reload_payload(socket.assigns.payload))
       |> put_flash(:info, "Workflow full access disabled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="app-shell">
      <DashboardComponents.app_header
        page={%{title: "Run Detail"}}
        operator_authenticated={@operator_authenticated}
        operator_token_configured={operator_token_configured?()}
        nav_items={run_navigation_items()}
        utility_items={run_utility_items(@payload)}
      />

      <section class="dashboard-shell">
      <%= if @payload[:error] do %>
          <DashboardComponents.page_header
            eyebrow="Persisted audit run"
            title="Run unavailable"
            copy={"#{@payload.error.code}: #{@payload.error.message}"}
            status_label="Unavailable"
            status_class="state-badge state-badge-danger"
          >
            <:actions>
              <a class="secondary-button" href="/runs">Back to runs</a>
              <a class="secondary-button" href="/">Dashboard</a>
            </:actions>
          </DashboardComponents.page_header>

          <DashboardComponents.section_frame
            kicker="Recovery"
            title="Snapshot unavailable"
            copy="The persisted run or its surrounding issue context could not be loaded."
          >
            <DashboardComponents.empty_state
              title="Run detail is unavailable"
              copy="Try again after the audit store refreshes, or return to the run explorer."
              action_label="Open runs"
              action_href="/runs"
            />
          </DashboardComponents.section_frame>
      <% else %>
        <% run = @payload.run %>
        <DashboardComponents.page_header
          eyebrow="Persisted audit run"
          title={"#{@payload.issue_identifier} / #{run["run_id"]}"}
          copy={"Started #{run["started_at"] || "n/a"} and ended #{run["ended_at"] || "n/a"}."}
          status_label={run["status"] || "completed"}
          status_class={state_badge_class(run["status"] || "completed")}
        >
          <:meta>
            <DashboardComponents.key_value_list
              items={[
                %{label: "Started", value: run["started_at"] || "n/a"},
                %{label: "Ended", value: run["ended_at"] || "n/a"},
                %{label: "Storage", value: @payload.storage_backend || "n/a"},
                %{label: "Efficiency", value: efficiency_label(run)}
              ]}
            />
          </:meta>
          <:actions>
            <a class="secondary-button" href="/runs">Back to runs</a>
            <a class="secondary-button" href={@payload.urls.run_json}>Run JSON</a>
            <a class="secondary-button" href={@payload.urls.export_bundle}>Audit bundle</a>
          </:actions>
        </DashboardComponents.page_header>

        <DashboardComponents.metric_strip items={run_metric_items(@payload)} />

        <DashboardComponents.section_frame
          kicker="Operator control"
          title="Guardrails"
          copy="Approve blocked actions and control full access directly from this run view."
        >
          <section class="split-grid-tight">
            <form phx-change="update_operator_token" class="stack-sm">
              <div class="field-group">
                <label class="field-label" for="run-operator-token">Operator token</label>
                <input
                  id="run-operator-token"
                  type="password"
                  name="operator_token"
                  value={@operator_token}
                  autocomplete="current-password"
                  class="field-input"
                />
              </div>
            </form>

            <DashboardComponents.key_value_list
              items={[
                %{label: "Status", value: if(@operator_authenticated, do: "authenticated", else: "token required")},
                %{label: "Configured", value: if(operator_token_configured?(), do: "yes", else: "no")},
                %{label: "Storage", value: "LiveView session state only"}
              ]}
            />
          </section>
        </DashboardComponents.section_frame>

        <%= if @payload.active_overrides != [] do %>
          <DashboardComponents.section_frame
            kicker="Warning"
            title="Full access is active for this run context"
            copy="Network and full-access sandboxing are currently enabled via an operator override."
            class="attention-card attention-card-alert"
          >
            <div class="button-row">
              <span class="state-badge state-badge-danger"><%= length(@payload.active_overrides) %> override(s)</span>
            </div>
          </DashboardComponents.section_frame>
        <% end %>

        <%= if @payload.live_issue do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Runtime</p>
                <h2 class="section-title">Current issue state</h2>
                <p class="section-copy">Live orchestration state for the same issue, if it is still active in the current runtime.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <tbody>
                  <tr><th>Issue status</th><td><span class={state_badge_class(@payload.live_issue.status || "unknown")}><%= @payload.live_issue.status || "unknown" %></span></td></tr>
                  <tr><th>Workspace</th><td><span class="mono"><%= get_in(@payload.live_issue, [:workspace, :path]) || "n/a" %></span></td></tr>
                  <tr><th>Worker host</th><td><%= get_in(@payload.live_issue, [:workspace, :host]) || "local" %></td></tr>
                  <tr><th>Pending approval</th><td><%= if @payload.pending_approval, do: @payload.pending_approval.summary || "yes", else: "none" %></td></tr>
                  <tr><th>Last error</th><td><%= @payload.live_issue.last_error || "n/a" %></td></tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <%= if @payload.pending_approval do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Approval pending</p>
                <h2 class="section-title">Operator decision required</h2>
                <p class="section-copy">This run is paused until the pending approval is allowed or denied.</p>
              </div>
              <div class="section-meta">
                <span class={state_badge_class(@payload.pending_approval.risk_level || "review")}>
                  <%= @payload.pending_approval.risk_level || "review" %>
                </span>
              </div>
            </div>

            <div class="detail-stack" style="margin-bottom: 1rem;">
              <span class="event-text"><%= @payload.pending_approval.summary || "approval pending" %></span>
              <span class="muted event-meta"><%= @payload.pending_approval.reason || "operator review required" %></span>
              <span :if={get_in(@payload.pending_approval, [:explanation, "evaluation", "reason"])} class="muted event-meta">
                Why: <%= get_in(@payload.pending_approval, [:explanation, "evaluation", "reason"]) %>
              </span>
              <span class="muted event-meta mono"><%= @payload.pending_approval.fingerprint || "n/a" %></span>
              <span :for={line <- approval_detail_preview(@payload.pending_approval)} class="muted event-meta"><%= line %></span>
            </div>

            <div class="detail-stack">
              <form phx-submit="guardrail_decide" class="detail-stack">
                <input type="hidden" name="approval_id" value={@payload.pending_approval.id} />
                <button type="submit" class="subtle-button" name="decision" value="allow_once" disabled={!@operator_authenticated} phx-disable-with="Allowing once...">
                  Allow once
                </button>
                <button type="submit" class="subtle-button" name="decision" value="allow_for_session" disabled={!@operator_authenticated} phx-disable-with="Allowing run...">
                  Allow for run
                </button>
                <button type="submit" class="subtle-button" name="decision" value="allow_via_rule" disabled={!@operator_authenticated} phx-disable-with="Creating rule...">
                  Always allow
                </button>
                <button type="submit" class="subtle-button" name="decision" value="deny" disabled={!@operator_authenticated} phx-disable-with="Denying...">
                  Deny
                </button>
              </form>

              <button
                :if={@payload.pending_approval.run_id}
                type="button"
                class="subtle-button"
                phx-click="enable_run_full_access"
                phx-value-run_id={@payload.pending_approval.run_id}
                disabled={!@operator_authenticated}
                phx-disable-with="Enabling full access..."
              >
                Full access for run
              </button>
            </div>
          </section>
        <% end %>

        <%= if @payload.active_overrides != [] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Safety posture</p>
                <h2 class="section-title">Active overrides</h2>
                <p class="section-copy">Run-scoped and workflow-wide overrides affecting this run context.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <thead>
                  <tr>
                    <th>Scope</th>
                    <th>Reason</th>
                    <th>Created</th>
                    <th>Expires</th>
                    <th>Operator</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={override <- @payload.active_overrides}>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text"><%= override.scope || "n/a" %></span>
                        <span class="muted event-meta"><%= override.scope_key || "n/a" %></span>
                      </div>
                    </td>
                    <td><%= override.reason || "operator override" %></td>
                    <td class="mono"><%= override.created_at || "n/a" %></td>
                    <td class="mono"><%= override.expires_at || "manual disable" %></td>
                    <td>
                      <%= if override.scope == "workflow" do %>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="disable_workflow_full_access"
                          disabled={!@operator_authenticated}
                          phx-disable-with="Disabling..."
                        >
                          Disable
                        </button>
                      <% else %>
                        <button
                          type="button"
                          class="subtle-button"
                          phx-click="disable_run_full_access"
                          phx-value-run_id={override.scope_key}
                          disabled={!@operator_authenticated}
                          phx-disable-with="Disabling..."
                        >
                          Disable
                        </button>
                      <% end %>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <%= if @payload.active_rules != [] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Policy</p>
                <h2 class="section-title">Relevant guardrail rules</h2>
                <p class="section-copy">Persisted rules currently relevant to this run or workflow context.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 820px;">
                <thead>
                  <tr>
                    <th>Scope</th>
                    <th>Action</th>
                    <th>Description</th>
                    <th>Created</th>
                    <th>Uses</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={rule <- @payload.active_rules}>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text"><%= rule[:scope] || rule["scope"] || "n/a" %></span>
                        <span class="muted event-meta"><%= rule[:scope_key] || rule["scope_key"] || "n/a" %></span>
                      </div>
                    </td>
                    <td><%= rule[:action_type] || rule["action_type"] || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text"><%= rule[:description] || rule["description"] || "guardrail rule" %></span>
                        <pre class="code-panel code-panel-compact"><%= pretty_value(rule[:match] || rule["match"]) %></pre>
                      </div>
                    </td>
                    <td class="mono"><%= rule[:created_at] || rule["created_at"] || "n/a" %></td>
                    <td>
                      <div class="detail-stack">
                        <span class="numeric"><%= remaining_uses_label(rule[:remaining_uses] || rule["remaining_uses"]) %></span>
                        <div class="detail-stack">
                          <button
                            type="button"
                            class="subtle-button"
                            phx-click="disable_guardrail_rule"
                            phx-value-rule_id={rule[:id] || rule["id"]}
                            disabled={!@operator_authenticated}
                            phx-disable-with="Disabling..."
                          >
                            Disable
                          </button>
                          <button
                            type="button"
                            class="subtle-button"
                            phx-click="expire_guardrail_rule"
                            phx-value-rule_id={rule[:id] || rule["id"]}
                            disabled={!@operator_authenticated}
                            phx-disable-with="Expiring..."
                          >
                            Expire
                          </button>
                        </div>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_duration_ms(run["duration_ms"]) %></p>
            <p class="metric-detail">Codex execution time for this run.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Queue wait</p>
            <p class="metric-value numeric"><%= format_duration_ms(get_in(run, ["timing", "queue_wait_ms"])) %></p>
            <p class="metric-detail">Time from eligibility to dispatch.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Human wait</p>
            <p class="metric-value numeric"><%= format_duration_ms(get_in(run, ["timing", "blocked_for_human_ms"])) %></p>
            <p class="metric-detail">Time spent waiting for human follow-up before this run.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Turns</p>
            <p class="metric-value numeric"><%= run["turn_count"] || 0 %></p>
            <p class="metric-detail">Completed Codex turns for this run.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Tokens</p>
            <p class="metric-value numeric"><%= format_int(get_in(run, ["tokens", "total_tokens"]) || 0) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(get_in(run, ["tokens", "input_tokens"]) || 0) %> / Cached <%= format_int(get_in(run, ["tokens", "cached_input_tokens"]) || 0) %> / Uncached <%= format_int(get_in(run, ["tokens", "uncached_input_tokens"]) || 0) %> / Out <%= format_int(get_in(run, ["tokens", "output_tokens"]) || 0) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Storage</p>
            <p class="metric-value"><%= @payload.storage_backend || "n/a" %></p>
            <p class="metric-detail">Audit backend used for this persisted run.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Run summary</h2>
              <p class="section-copy">Outcome, state transitions, git metadata, and hook results from the persisted run summary.</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table" style="min-width: 760px;">
              <tbody>
                <tr><th>Tracker state</th><td><%= tracker_state_label(run) %></td></tr>
                <tr><th>Next action</th><td><%= run["next_action"] || "n/a" %></td></tr>
                <tr><th>Last error</th><td><%= run["last_error"] || "n/a" %></td></tr>
                <tr><th>Queue source</th><td><%= get_in(run, ["timing", "queue_source"]) || "n/a" %></td></tr>
                <tr><th>Human marker</th><td><%= human_marker_label(run) %></td></tr>
                <tr><th>Git</th><td><%= run_git_label(run) %></td></tr>
                <tr><th>Changed files</th><td><%= run_changed_files_label(run) %></td></tr>
                <tr><th>Diff summary</th><td><%= run_diff_summary(run) %></td></tr>
                <tr><th>Hooks</th><td><%= hook_results_label(run["hook_results"]) %></td></tr>
                <tr><th>Trello summary</th><td><%= trello_summary_label(run) %></td></tr>
                <tr><th>Workspace</th><td><span class="mono"><%= run["workspace_path"] || "n/a" %></span></td></tr>
                <tr><th>Session</th><td><span class="mono"><%= run["session_id"] || "n/a" %></span></td></tr>
                <tr><th>Continuation turns</th><td><%= run["continuation_turn_count"] || 0 %></td></tr>
                <tr><th>Efficiency posture</th><td><span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}><%= efficiency_label(run) %></span></td></tr>
                <tr><th>Efficiency flags</th><td><%= efficiency_flags_label(run) %></td></tr>
              </tbody>
            </table>
          </div>
        </section>

        <%= if run["prompt_shape"] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Prompt cost</h2>
                <p class="section-copy">Base prompt shape and continuity metadata captured for this run.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <tbody>
                  <tr><th>Tracker payload chars</th><td><%= format_int(get_in(run, ["prompt_shape", "tracker_payload_chars"]) || 0) %></td></tr>
                  <tr><th>Workflow prompt chars</th><td><%= format_int(get_in(run, ["prompt_shape", "workflow_prompt_chars"]) || 0) %></td></tr>
                  <tr><th>Rendered prompt chars</th><td><%= format_int(get_in(run, ["prompt_shape", "rendered_prompt_chars"]) || 0) %></td></tr>
                  <tr><th>Issue body chars</th><td><%= format_int(get_in(run, ["prompt_shape", "issue_description_chars"]) || 0) %></td></tr>
                  <tr><th>Prompt body chars</th><td><%= format_int(get_in(run, ["prompt_shape", "issue_prompt_description_chars"]) || 0) %></td></tr>
                  <tr><th>Description truncated</th><td><%= if(get_in(run, ["prompt_shape", "issue_description_truncated"]), do: "yes", else: "no") %></td></tr>
                  <tr><th>Truncated chars</th><td><%= format_int(get_in(run, ["prompt_shape", "issue_description_truncated_chars"]) || 0) %></td></tr>
                  <tr><th>Included previous handoff</th><td><%= if(get_in(run, ["prompt_shape", "included_previous_run_handoff"]), do: "yes", else: "no") %></td></tr>
                  <tr><th>Previous run</th><td><%= get_in(run, ["prompt_shape", "previous_run_id"]) || "n/a" %></td></tr>
                  <tr><th>Previous handoff chars</th><td><%= format_int(get_in(run, ["prompt_shape", "previous_run_handoff_chars"]) || 0) %></td></tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Run efficiency</h2>
              <p class="section-copy">Advisory classification for this run, separating cached-heavy context from true uncached spend.</p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table" style="min-width: 760px;">
              <tbody>
                <tr><th>Classification</th><td><span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}><%= efficiency_label(run) %></span></td></tr>
                <tr><th>Flags</th><td><%= efficiency_flags_label(run) %></td></tr>
                <tr><th>Changed files</th><td><%= get_in(run, ["efficiency", "changed_file_count"]) || 0 %></td></tr>
                <tr><th>Tokens / changed file</th><td><%= format_ratio(get_in(run, ["efficiency", "tokens_per_changed_file"])) %></td></tr>
                <tr><th>Uncached / changed file</th><td><%= format_ratio(get_in(run, ["efficiency", "uncached_input_tokens_per_changed_file"])) %></td></tr>
                <tr><th>Tokens / minute</th><td><%= format_ratio(get_in(run, ["efficiency", "tokens_per_minute"])) %></td></tr>
                <tr><th>Cached input share</th><td><%= format_pct(get_in(run, ["efficiency", "cached_input_share_pct"])) %></td></tr>
              </tbody>
            </table>
          </div>
        </section>

        <%= if @payload.issue_rollup do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Issue efficiency</h2>
                <p class="section-copy">Aggregate metrics across persisted runs for this ticket.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 760px;">
                <tbody>
                  <tr><th>Run count</th><td><%= @payload.issue_rollup["run_count"] || 0 %></td></tr>
                  <tr><th>Latest status</th><td><%= @payload.issue_rollup["latest_status"] || "n/a" %></td></tr>
                  <tr><th>Rollup posture</th><td><span class={efficiency_badge_class(@payload.issue_rollup["classification"])}><%= @payload.issue_rollup["primary_label"] || "Normal" %></span></td></tr>
                  <tr><th>Rollup flags</th><td><%= efficiency_flags_label(@payload.issue_rollup) %></td></tr>
                  <tr><th>Average runtime</th><td><%= format_duration_ms(@payload.issue_rollup["avg_duration_ms"]) %></td></tr>
                  <tr><th>Average queue wait</th><td><%= format_duration_ms(@payload.issue_rollup["avg_queue_wait_ms"]) %></td></tr>
                  <tr><th>Average handoff wait</th><td><%= format_duration_ms(@payload.issue_rollup["avg_handoff_latency_ms"]) %></td></tr>
                  <tr><th>Average merge runtime</th><td><%= format_duration_ms(@payload.issue_rollup["avg_merge_latency_ms"]) %></td></tr>
                  <tr><th>Total tokens</th><td><%= format_int(@payload.issue_rollup["total_tokens"] || 0) %></td></tr>
                  <tr><th>Total uncached input</th><td><%= format_int(@payload.issue_rollup["total_uncached_input_tokens"] || 0) %></td></tr>
                  <tr><th>Average uncached / run</th><td><%= format_ratio(@payload.issue_rollup["avg_uncached_input_tokens_per_run"]) %></td></tr>
                  <tr><th>Average tokens / changed file</th><td><%= format_ratio(@payload.issue_rollup["avg_tokens_per_changed_file"]) %></td></tr>
                  <tr><th>Average uncached / changed file</th><td><%= format_ratio(@payload.issue_rollup["avg_uncached_input_tokens_per_changed_file"]) %></td></tr>
                  <tr><th>Expensive runs</th><td><%= @payload.issue_rollup["expensive_runs"] || 0 %></td></tr>
                  <tr><th>Cheap wins</th><td><%= @payload.issue_rollup["cheap_win_runs"] || 0 %></td></tr>
                  <tr><th>Total retry attempts</th><td><%= @payload.issue_rollup["total_retry_attempts"] || 0 %></td></tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Diff preview</h2>
              <p class="section-copy">File-level change preview from git metadata, without storing the full patch.</p>
            </div>
          </div>

          <%= if diff_preview_files(run) == [] do %>
            <p class="empty-state">No diff preview was captured for this run.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 900px;">
                <thead>
                  <tr>
                    <th>Path</th>
                    <th>Status</th>
                    <th>Stats</th>
                    <th>Hunks</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={diff_file <- diff_preview_files(run)}>
                    <td><span class="mono"><%= diff_file["path"] || "n/a" %></span></td>
                    <td><%= diff_file["status"] || "n/a" %></td>
                    <td><%= diff_file_stats_label(diff_file) %></td>
                    <td><pre class="code-panel"><%= diff_file_hunks_label(diff_file) %></pre></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Run navigation</h2>
              <p class="section-copy">Jump to adjacent persisted runs for the same issue.</p>
            </div>
          </div>

          <div class="detail-stack">
            <%= if @payload.previous_run do %>
              <a class="issue-link" href={run_path(@payload.issue_identifier, @payload.previous_run["run_id"])}>
                Older run: <%= @payload.previous_run["run_id"] %>
              </a>
            <% else %>
              <span class="muted">No older run.</span>
            <% end %>

            <%= if @payload.next_run do %>
              <a class="issue-link" href={run_path(@payload.issue_identifier, @payload.next_run["run_id"])}>
                Newer run: <%= @payload.next_run["run_id"] %>
              </a>
            <% else %>
              <span class="muted">No newer run.</span>
            <% end %>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Event timeline</h2>
              <p class="section-copy">Persisted event stream for this run, including hooks, Codex updates, and lifecycle events.</p>
            </div>
          </div>

          <%= if @payload.events == [] do %>
            <p class="empty-state">No events were persisted for this run.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 940px;">
                <thead>
                  <tr>
                    <th>At</th>
                    <th>Kind</th>
                    <th>Event</th>
                    <th>Summary</th>
                    <th>Details</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={event <- @payload.events}>
                    <td class="mono"><%= event["recorded_at"] || "n/a" %></td>
                    <td><%= event["kind"] || "n/a" %></td>
                    <td><%= event["event"] || "n/a" %></td>
                    <td><%= event["summary"] || "n/a" %></td>
                    <td><pre class="code-panel"><%= pretty_value(event["details"]) %></pre></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
      <% end %>
      </section>
    </section>
    """
  end

  defp load_payload(%{"issue_identifier" => issue_identifier, "run_id" => run_id}) do
    case Presenter.run_page_payload(issue_identifier, run_id, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        payload

      {:error, :issue_not_found} ->
        %{error: %{code: "issue_not_found", message: "Run not found"}}
    end
  end

  defp load_payload(_params), do: %{error: %{code: "invalid_params", message: "Missing issue identifier or run id"}}

  defp reload_payload(%{issue_identifier: issue_identifier, run: %{"run_id" => run_id}})
       when is_binary(issue_identifier) and is_binary(run_id) do
    load_payload(%{"issue_identifier" => issue_identifier, "run_id" => run_id})
  end

  defp reload_payload(payload), do: payload

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp run_path(issue_identifier, run_id), do: "/runs/#{issue_identifier}/#{run_id}"

  defp run_navigation_items do
    [
      %{label: "Overview", href: "/", current: false},
      %{label: "Approvals", href: "/approvals", current: false},
      %{label: "Settings", href: "/settings", current: false},
      %{label: "Runs", href: "/runs", current: true}
    ]
  end

  defp run_utility_items(%{urls: urls}) when is_map(urls) do
    [
      %{label: "Dashboard", href: Map.get(urls, :dashboard) || "/"},
      %{label: "Issue JSON", href: Map.get(urls, :issue_json) || "/runs"},
      %{label: "Run JSON", href: Map.get(urls, :run_json) || "/runs"},
      %{label: "Audit bundle", href: Map.get(urls, :export_bundle) || "/runs"}
    ]
  end

  defp run_utility_items(_payload), do: [%{label: "Dashboard", href: "/"}, %{label: "Runs", href: "/runs"}]

  defp run_metric_items(%{run: run, storage_backend: storage_backend}) when is_map(run) do
    [
      %{label: "Runtime", value: format_duration_ms(run["duration_ms"]), value_class: "numeric", detail: "Codex execution time"},
      %{label: "Queue wait", value: format_duration_ms(get_in(run, ["timing", "queue_wait_ms"])), value_class: "numeric", detail: "Eligibility to dispatch"},
      %{label: "Human wait", value: format_duration_ms(get_in(run, ["timing", "blocked_for_human_ms"])), value_class: "numeric", detail: "Blocked on human follow-up"},
      %{label: "Tokens", value: format_int(get_in(run, ["tokens", "total_tokens"]) || 0), value_class: "numeric", detail: efficiency_flags_label(run)},
      %{label: "Storage", value: storage_backend || "n/a", detail: run_changed_files_label(run)}
    ]
  end

  defp run_metric_items(_payload), do: []
  defp operator_token_configured?, do: is_binary(configured_operator_token())

  defp format_duration_ms(duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    total_seconds = div(duration_ms, 1_000)
    minutes = div(total_seconds, 60)
    seconds = rem(total_seconds, 60)
    "#{minutes}m #{seconds}s"
  end

  defp format_duration_ms(_duration_ms), do: "n/a"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp format_ratio(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)
  defp format_ratio(value) when is_integer(value), do: format_int(value)
  defp format_ratio(_value), do: "n/a"

  defp format_pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2) <> "%"
  defp format_pct(value) when is_integer(value), do: format_int(value) <> "%"
  defp format_pct(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["critical", "danger", "high"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["progress", "running", "active", "completed", "done"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry", "review", "medium"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp tracker_state_label(run) when is_map(run) do
    started = run["issue_state_started"]
    finished = run["issue_state_finished"]
    transition = run["tracker_transition"] || %{}
    target = transition["to"]

    cond do
      is_binary(started) and is_binary(target) -> "#{started} -> #{target}"
      is_binary(started) and is_binary(finished) and started != finished -> "#{started} -> #{finished}"
      is_binary(finished) -> finished
      is_binary(started) -> started
      true -> "n/a"
    end
  end

  defp tracker_state_label(_run), do: "n/a"

  defp run_git_label(run) when is_map(run) do
    git = get_in(run, ["workspace_metadata", "git"]) || %{}
    branch = git["branch"]
    head_commit = git["head_commit"]
    head_subject = git["head_subject"]

    cond do
      is_binary(branch) and is_binary(head_commit) and is_binary(head_subject) ->
        "#{branch} @ #{String.slice(head_commit, 0, 8)} (#{head_subject})"

      is_binary(branch) and is_binary(head_commit) ->
        "#{branch} @ #{String.slice(head_commit, 0, 8)}"

      is_binary(branch) ->
        branch

      is_binary(head_commit) ->
        String.slice(head_commit, 0, 8)

      true ->
        "n/a"
    end
  end

  defp run_git_label(_run), do: "n/a"

  defp run_changed_files_label(run) when is_map(run) do
    git = get_in(run, ["workspace_metadata", "git"]) || %{}
    changed_files = git["changed_files"] || []
    changed_file_count = git["changed_file_count"] || length(changed_files)

    paths =
      changed_files
      |> Enum.flat_map(fn
        %{"path" => path} when is_binary(path) -> [path]
        _ -> []
      end)
      |> Enum.take(5)

    cond do
      changed_file_count == 0 ->
        "no changed files"

      paths == [] ->
        "#{changed_file_count} file(s)"

      changed_file_count > length(paths) ->
        "#{Enum.join(paths, ", ")} (+#{changed_file_count - length(paths)} more)"

      true ->
        Enum.join(paths, ", ")
    end
  end

  defp run_changed_files_label(_run), do: "n/a"

  defp hook_results_label(hook_results) when is_map(hook_results) do
    labels =
      hook_results
      |> Enum.flat_map(fn {hook_name, payload} ->
        case payload do
          %{"status" => status} when is_binary(status) -> ["#{hook_name}=#{status}"]
          _ -> []
        end
      end)

    case labels do
      [] -> "n/a"
      _ -> Enum.join(labels, ", ")
    end
  end

  defp hook_results_label(_hook_results), do: "n/a"

  defp trello_summary_label(run) when is_map(run) do
    case run["trello_summary"] do
      %{"status" => "posted", "posted_at" => posted_at} ->
        "posted at #{posted_at}"

      %{"status" => "failed", "error" => error} ->
        "failed: #{error}"

      %{"status" => status} when is_binary(status) ->
        status

      _ ->
        "n/a"
    end
  end

  defp trello_summary_label(_run), do: "n/a"

  defp human_marker_label(run) when is_map(run) do
    timing = run["timing"] || %{}
    marker = timing["human_response_marker"] || %{}

    case marker do
      %{"kind" => kind, "at" => at} when is_binary(kind) and is_binary(at) ->
        summary = marker["summary"] || kind
        "#{summary} @ #{at}"

      _ ->
        "n/a"
    end
  end

  defp human_marker_label(_run), do: "n/a"

  defp efficiency_label(%{"efficiency" => %{"primary_label" => label}}) when is_binary(label), do: label
  defp efficiency_label(%{"primary_label" => label}) when is_binary(label), do: label
  defp efficiency_label(_value), do: "Normal"

  defp efficiency_flags_label(%{"efficiency" => %{"flags" => flags}}), do: efficiency_flags_label(flags)
  defp efficiency_flags_label(%{"flags" => flags}), do: efficiency_flags_label(flags)

  defp efficiency_flags_label(flags) when is_list(flags) do
    case Enum.map(flags, &humanize_efficiency_flag/1) do
      [] -> "no advisory flags"
      values -> Enum.join(values, ", ")
    end
  end

  defp efficiency_flags_label(_flags), do: "no advisory flags"

  defp humanize_efficiency_flag("high_uncached_input"), do: "high uncached input"
  defp humanize_efficiency_flag("high_tokens_per_changed_file"), do: "high tokens / file"
  defp humanize_efficiency_flag("high_retry_overhead"), do: "retry overhead"
  defp humanize_efficiency_flag("high_uncached_input_low_change_yield"), do: "high uncached / low output"
  defp humanize_efficiency_flag("context_window_heavy"), do: "context-window heavy"
  defp humanize_efficiency_flag("expensive_rework_loop"), do: "expensive rework loop"
  defp humanize_efficiency_flag("repeated_expensive_rework_loops"), do: "repeated expensive rework"
  defp humanize_efficiency_flag(flag) when is_binary(flag), do: String.replace(flag, "_", " ")
  defp humanize_efficiency_flag(_flag), do: "n/a"

  defp efficiency_badge_class("expensive"), do: "state-badge state-badge-danger"
  defp efficiency_badge_class("needs_attention"), do: "state-badge state-badge-danger"
  defp efficiency_badge_class("context_window_heavy"), do: "state-badge state-badge-warning"
  defp efficiency_badge_class("cheap_win"), do: "state-badge state-badge-active"
  defp efficiency_badge_class("cheap_wins"), do: "state-badge state-badge-active"
  defp efficiency_badge_class(_classification), do: "state-badge"

  defp run_diff_summary(run) when is_map(run) do
    get_in(run, ["workspace_metadata", "git", "diff_summary"]) || "n/a"
  end

  defp run_diff_summary(_run), do: "n/a"

  defp diff_preview_files(run) when is_map(run) do
    get_in(run, ["workspace_metadata", "git", "diff_files"]) || []
  end

  defp diff_preview_files(_run), do: []

  defp diff_file_stats_label(diff_file) when is_map(diff_file) do
    additions = diff_file["additions"]
    deletions = diff_file["deletions"]

    cond do
      is_integer(additions) and is_integer(deletions) -> "+#{additions} / -#{deletions}"
      is_integer(additions) -> "+#{additions}"
      is_integer(deletions) -> "-#{deletions}"
      true -> "n/a"
    end
  end

  defp diff_file_stats_label(_diff_file), do: "n/a"

  defp diff_file_hunks_label(diff_file) when is_map(diff_file) do
    case diff_file["hunks"] do
      hunks when is_list(hunks) and hunks != [] -> Enum.join(hunks, "\n")
      _ -> "n/a"
    end
  end

  defp diff_file_hunks_label(_diff_file), do: "n/a"

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp approval_detail_preview(approval) when is_map(approval) do
    details = approval.details || %{}
    review_tags = approval.review_tags || []

    [
      detail_preview_line("command", Map.get(details, "wrapped_command") || Map.get(details, "command")),
      detail_preview_line("cwd", Map.get(details, "cwd")),
      detail_preview_line("workspace", approval.workspace_path),
      detail_preview_line("paths", preview_list(Map.get(details, "file_paths"))),
      detail_preview_line("sensitive", preview_list(Map.get(details, "sensitive_paths"))),
      detail_preview_line("flags", preview_list(review_tags))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp approval_detail_preview(_approval), do: []

  defp detail_preview_line(_label, nil), do: nil
  defp detail_preview_line(_label, ""), do: nil
  defp detail_preview_line(label, value), do: "#{label}: #{value}"

  defp preview_list(values) when is_list(values) and values != [] do
    values
    |> Enum.take(3)
    |> Enum.join(", ")
    |> then(fn preview ->
      if length(values) > 3 do
        preview <> ", +" <> Integer.to_string(length(values) - 3) <> " more"
      else
        preview
      end
    end)
  end

  defp preview_list(_values), do: nil

  defp remaining_uses_label(value) when is_integer(value), do: value
  defp remaining_uses_label(_value), do: "unlimited"

  defp require_operator_access(socket) do
    if socket.assigns.operator_authenticated do
      :ok
    else
      {:error, :operator_token_invalid}
    end
  end

  defp valid_operator_token?(token) when is_binary(token) do
    case configured_operator_token() do
      expected when is_binary(expected) ->
        byte_size(expected) == byte_size(token) and Plug.Crypto.secure_compare(expected, token)

      _ ->
        false
    end
  end

  defp valid_operator_token?(_token), do: false

  defp configured_operator_token do
    case Config.settings!().guardrails.operator_token do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp humanize_guardrail_error(:approval_not_found), do: "Approval not found."
  defp humanize_guardrail_error(:approval_stale), do: "Approval is no longer pending."
  defp humanize_guardrail_error({:approval_already_resolved, decision}), do: "Approval was already resolved as #{decision}."
  defp humanize_guardrail_error(:override_not_found), do: "Full-access override not found."
  defp humanize_guardrail_error(:rule_not_found), do: "Guardrail rule not found."
  defp humanize_guardrail_error(:operator_action_rate_limited), do: "Another operator action just updated this item. Try again in a moment."
  defp humanize_guardrail_error(:operator_token_invalid), do: "Operator token missing or invalid."
  defp humanize_guardrail_error(:operator_token_not_configured), do: "Operator token is not configured."
  defp humanize_guardrail_error(:guardrails_disabled), do: "Guardrails are disabled in the current workflow."
  defp humanize_guardrail_error(reason), do: "Guardrail action failed: #{inspect(reason)}"

  defp success_message_for_decision("allow_once"), do: "Approval allowed once."
  defp success_message_for_decision("allow_for_session"), do: "Approval allowed for the current run."
  defp success_message_for_decision("allow_via_rule"), do: "Approval converted into an always-allow rule."
  defp success_message_for_decision("deny"), do: "Approval denied."
  defp success_message_for_decision(_decision), do: "Guardrail decision applied."

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
