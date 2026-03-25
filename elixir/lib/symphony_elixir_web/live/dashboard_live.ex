defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{CodexAuth, Config, GitHubAccess, Orchestrator, SettingsOverlay, StatusDashboard}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:page, dashboard_page(socket.assigns[:live_action] || :overview))
      |> assign(:operator_token, "")
      |> assign(:operator_authenticated, false)
      |> assign(:guardrail_filters, default_guardrail_filters())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :page, dashboard_page(socket.assigns[:live_action] || :overview))}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("update_operator_token", %{"operator_token" => token}, socket) do
    {:noreply,
     socket
     |> assign(:operator_token, token)
     |> assign(:operator_authenticated, valid_operator_token?(token))}
  end

  def handle_event("update_guardrail_filters", params, socket) do
    {:noreply, assign(socket, :guardrail_filters, normalize_guardrail_filters(params))}
  end

  def handle_event("guardrail_decide", %{"approval_id" => approval_id, "decision" => decision} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.decide_guardrail_approval(
             orchestrator(),
             approval_id,
             decision,
             actor: "dashboard",
             reason: blank_to_nil(params["reason"]),
             scope: blank_to_nil(params["scope"])
           ) do
      {:noreply, refresh_dashboard(socket, success_message_for_decision(decision))}
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
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply, refresh_dashboard(socket, "Guardrail rule disabled.")}
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
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply, refresh_dashboard(socket, "Guardrail rule enabled.")}
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
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply, refresh_dashboard(socket, "Guardrail rule expired.")}
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
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply, refresh_dashboard(socket, "Run full access enabled.")}
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
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply, refresh_dashboard(socket, "Run full access disabled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("enable_workflow_full_access", params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           Orchestrator.enable_full_access_for_workflow(
             orchestrator(),
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply, refresh_dashboard(socket, "Workflow full access enabled.")}
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
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      {:noreply, refresh_dashboard(socket, "Workflow full access disabled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_guardrail_error(reason))}
    end
  end

  def handle_event("update_runtime_setting", %{"path" => path, "value" => value} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           SettingsOverlay.update_overlay(
             %{path => value},
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      StatusDashboard.notify_update()
      {:noreply, refresh_dashboard(socket, "Runtime setting updated.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_settings_error(reason))}
    end
  end

  def handle_event("reset_runtime_setting", %{"path" => path} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           SettingsOverlay.reset_overlay(
             [path],
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      StatusDashboard.notify_update()
      {:noreply, refresh_dashboard(socket, "Runtime setting reset to workflow/default.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_settings_error(reason))}
    end
  end

  def handle_event("update_github_access_setting", %{"path" => path, "value" => value} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           GitHubAccess.update_config(
             %{path => value},
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      StatusDashboard.notify_update()
      {:noreply, refresh_dashboard(socket, "GitHub access setting updated.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_github_access_error(reason))}
    end
  end

  def handle_event("reset_github_access_setting", %{"path" => path} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           GitHubAccess.reset_config(
             [path],
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      StatusDashboard.notify_update()
      {:noreply, refresh_dashboard(socket, "GitHub access setting reset.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_github_access_error(reason))}
    end
  end

  def handle_event("set_github_access_token", %{"token" => token} = params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           GitHubAccess.set_token(
             token,
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      StatusDashboard.notify_update()
      {:noreply, refresh_dashboard(socket, "GitHub token stored.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_github_access_error(reason))}
    end
  end

  def handle_event("clear_github_access_token", params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <-
           GitHubAccess.clear_token(
             actor: "dashboard",
             reason: blank_to_nil(params["reason"])
           ) do
      StatusDashboard.notify_update()
      {:noreply, refresh_dashboard(socket, "GitHub token cleared.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_github_access_error(reason))}
    end
  end

  def handle_event("refresh_codex_auth_status", _params, socket) do
    case CodexAuth.refresh_status() do
      {:ok, _payload} -> {:noreply, refresh_dashboard(socket, "Codex auth status refreshed.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, humanize_codex_auth_error(reason))}
    end
  end

  def handle_event("start_codex_device_auth", _params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <- CodexAuth.start_device_auth() do
      {:noreply, refresh_dashboard(socket, "Codex device auth started.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_codex_auth_error(reason))}
    end
  end

  def handle_event("cancel_codex_device_auth", _params, socket) do
    with :ok <- require_operator_access(socket),
         {:ok, _payload} <- CodexAuth.cancel_device_auth() do
      {:noreply, refresh_dashboard(socket, "Codex device auth cancelled.")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, humanize_codex_auth_error(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <div class="dashboard-layout">
          <aside class="dashboard-sidebar">
            <section class="section-card nav-card nav-card-primary">
              <div class="section-header">
                <div>
                  <p class="section-kicker">Navigator</p>
                  <h2 class="section-title">Sections</h2>
                  <p class="section-copy">Jump to the part of the control surface you need right now.</p>
                </div>
              </div>

              <div class="nav-group">
                <p class="nav-group-label">Overview</p>
                <nav class="sidebar-nav">
                  <a class={sidebar_link_class(@page.key, :overview)} href={page_path(:overview)}>Mission control</a>
                  <a class={sidebar_link_class(@page.key, :runs)} href={page_path(:runs)}>Runs and history</a>
                </nav>
              </div>

              <div class="nav-group">
                <p class="nav-group-label">Governance</p>
                <nav class="sidebar-nav">
                  <a class={sidebar_link_class(@page.key, :approvals)} href={page_path(:approvals)}>Pending approvals</a>
                  <a class={sidebar_link_class(@page.key, :settings)} href={page_path(:settings)}>Runtime settings</a>
                </nav>
              </div>

              <div class="nav-group">
                <p class="nav-group-label">Current view</p>
                <nav class="sidebar-nav">
                  <a class="sidebar-link sidebar-link-static" href={"/api/v1/state"}>State API</a>
                  <a class="sidebar-link sidebar-link-static" href={"/api/v1/rollups"}>Rollups API</a>
                </nav>
              </div>
            </section>

            <section class="section-card nav-card">
              <div class="section-header">
                <div>
                  <p class="section-kicker">At a glance</p>
                  <h2 class="section-title">Current posture</h2>
                </div>
              </div>

              <div class="signal-list signal-list-dense">
                <div class="signal-item">
                  <span class="signal-label">System health</span>
                  <span class="signal-value"><%= system_health_label(@payload) %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Live work</span>
                  <span class="signal-value numeric"><%= @payload.counts.running %> active</span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Retry pressure</span>
                  <span class="signal-value numeric"><%= @payload.counts.retrying %> queued</span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Approvals waiting</span>
                  <span class="signal-value numeric"><%= @payload.counts.pending_approvals %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Operator mode</span>
                  <span class="signal-value"><%= if @operator_authenticated, do: "authenticated", else: "token required" %></span>
                </div>
              </div>
            </section>

            <section class="section-card nav-card">
              <div class="section-header">
                <div>
                  <p class="section-kicker">Read path</p>
                  <h2 class="section-title">Current view</h2>
                </div>
              </div>

              <div class="detail-stack">
                <div class="signal-item">
                  <span class="signal-label">Page</span>
                  <span class="signal-value"><%= @page.nav_label %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Focus</span>
                  <span class="signal-value"><%= @page.focus %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Next step</span>
                  <span class="signal-value"><%= @page.next_step %></span>
                </div>
              </div>
            </section>
          </aside>

          <div class="dashboard-main">
        <header class="hero-card hero-card-ops" id="overview">
          <div class="hero-grid hero-grid-ops">
            <div class="hero-main">
              <div class="eyebrow-row">
                <p class="eyebrow">
                  Symphony Observability
                </p>
                <span class={system_health_class(@payload)}>
                  <span class="status-badge-dot"></span>
                  <%= system_health_label(@payload) %>
                </span>
              </div>

              <h1 class="hero-title"><%= @page.title %></h1>

              <p class="hero-copy hero-copy-ops"><%= @page.copy %></p>

              <div class="hero-pill-row">
                <a class={hero_pill_class(@page.key, :overview)} href={page_path(:overview)}>Overview</a>
                <a class={hero_pill_class(@page.key, :approvals)} href={page_path(:approvals)}>Approvals</a>
                <a class={hero_pill_class(@page.key, :settings)} href={page_path(:settings)}>Settings</a>
                <a class={hero_pill_class(@page.key, :runs)} href={page_path(:runs)}>Runs</a>
              </div>

              <div class="hero-stat-grid">
                <article class="hero-stat-card">
                  <span class="hero-stat-label">Last updated</span>
                  <span class="hero-stat-value mono"><%= @payload.generated_at || DateTime.to_iso8601(@now) %></span>
                </article>

                <article class="hero-stat-card">
                  <span class="hero-stat-label">Live work</span>
                  <span class="hero-stat-value numeric"><%= @payload.counts.running %> active</span>
                </article>

                <article class="hero-stat-card">
                  <span class="hero-stat-label">Retry pressure</span>
                  <span class="hero-stat-value numeric"><%= @payload.counts.retrying %> queued</span>
                </article>
              </div>

              <div class="hero-actions">
                <a class="action-link" href="/api/v1/state">State API</a>
                <a class="action-link" href="/api/v1/rollups">Rollups API</a>
              </div>
            </div>

            <aside class="hero-aside">
              <div class="status-stack status-stack-hero">
                <span class="status-badge status-badge-live">
                  <span class="status-badge-dot"></span>
                  Live
                </span>
                <span class="status-badge status-badge-offline">
                  <span class="status-badge-dot"></span>
                  Offline
                </span>
              </div>

              <div class="signal-card">
                <p class="signal-kicker">Control pulse</p>

                <div class="signal-list">
                  <div class="signal-item">
                    <span class="signal-label">Priority session</span>
                    <span class="signal-value"><%= primary_running_label(@payload.running) %></span>
                  </div>

                  <div class="signal-item">
                    <span class="signal-label">Queue focus</span>
                    <span class="signal-value"><%= retry_focus_label(@payload.retrying) %></span>
                  </div>

                  <div class="signal-item">
                    <span class="signal-label">Latest landing</span>
                    <span class="signal-value"><%= latest_completed_label(@payload.completed_runs) %></span>
                  </div>

                  <div class="signal-item">
                    <span class="signal-label">Efficiency watch</span>
                    <span class="signal-value"><%= efficiency_watch_label(@payload.expensive_runs, @payload.cheap_wins) %></span>
                  </div>

                  <div class="signal-item">
                    <span class="signal-label">Rate limits</span>
                    <span class="signal-value"><%= rate_limit_focus(@payload.rate_limits) %></span>
                  </div>
                </div>
              </div>
            </aside>
          </div>
        </header>

        <%= if @payload.counts.active_overrides > 0 do %>
          <section class="section-card" style="border-color: rgba(255, 122, 69, 0.7); box-shadow: 0 18px 48px rgba(255, 122, 69, 0.12);">
            <div class="section-header">
              <div>
                <p class="section-kicker">Warning</p>
                <h2 class="section-title">Full access is active</h2>
                <p class="section-copy">
                  One or more runs are currently operating with full access, including network enablement.
                </p>
              </div>
              <div class="section-meta">
                <span class="state-badge state-badge-danger"><%= @payload.counts.active_overrides %> override(s)</span>
              </div>
            </div>
          </section>
        <% end %>

        <%= if @page.key == :overview do %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Pending approvals</p>
            <p class="metric-value numeric"><%= @payload.counts.pending_approvals %></p>
            <p class="metric-detail">Guardrail requests waiting for operator review.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Guardrail rules</p>
            <p class="metric-value numeric"><%= @payload.counts.guardrail_rules %></p>
            <p class="metric-detail">Active <%= @payload.counts.active_guardrail_rules %> / total persisted rules <%= @payload.counts.guardrail_rules %>.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Active overrides</p>
            <p class="metric-value numeric"><%= @payload.counts.active_overrides %></p>
            <p class="metric-detail">Full-access overrides currently in effect.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(@payload.codex_totals.input_tokens) %> / Cached <%= format_int(@payload.codex_totals.cached_input_tokens) %> / Uncached <%= format_int(@payload.codex_totals.uncached_input_tokens) %> / Out <%= format_int(@payload.codex_totals.output_tokens) %>
            </p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total Codex runtime across completed and active sessions.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Recent completed</p>
            <p class="metric-value numeric"><%= @payload.counts.completed_runs %></p>
            <p class="metric-detail">Persisted runs visible in the audit history panel.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Issue rollups</p>
            <p class="metric-value numeric"><%= @payload.counts.issue_rollups %></p>
            <p class="metric-detail">Issues with persisted efficiency aggregates.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Expensive runs</p>
            <p class="metric-value numeric"><%= @payload.counts.expensive_runs %></p>
            <p class="metric-detail">Recent runs flagged for high uncached cost, retries, or low change yield.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Cheap wins</p>
            <p class="metric-value numeric"><%= @payload.counts.cheap_wins %></p>
            <p class="metric-detail">Recent runs that landed useful changes with low uncached spend.</p>
          </article>
        </section>

        <section class="dashboard-board">
          <section class="section-card section-card-feature" id="running-sessions">
            <div class="section-header section-header-feature">
              <div>
                <p class="section-kicker">Live execution</p>
                <h2 class="section-title">Running sessions</h2>
                <p class="section-copy">Active issues, last known agent activity, and token usage.</p>
              </div>

              <div class="section-meta">
                <span class="section-meta-label">
                  <span class="section-meta-value numeric"><%= @payload.counts.running %></span>
                  live issue<%= if @payload.counts.running == 1, do: "", else: "s" %>
                </span>
              </div>
            </div>

            <%= if @payload.running == [] do %>
              <p class="empty-state">No active sessions.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-running">
                  <colgroup>
                    <col style="width: 12rem;" />
                    <col style="width: 8rem;" />
                    <col style="width: 7.5rem;" />
                    <col style="width: 8.5rem;" />
                    <col />
                    <col style="width: 10rem;" />
                  </colgroup>
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>State</th>
                      <th>Session</th>
                      <th>Runtime / turns</th>
                      <th>Codex update</th>
                      <th>Tokens</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.running}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </div>
                      </td>
                      <td>
                        <span class={state_badge_class(entry.state)}>
                          <%= entry.state %>
                        </span>
                      </td>
                      <td>
                        <div class="session-stack">
                          <%= if entry.session_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              data-label="Copy ID"
                              data-copy={entry.session_id}
                              onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                            >
                              Copy ID
                            </button>
                          <% else %>
                            <span class="muted">n/a</span>
                          <% end %>
                        </div>
                      </td>
                      <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                      <td>
                        <div class="detail-stack">
                          <span
                            class="event-text"
                            title={entry.last_message || to_string(entry.last_event || "n/a")}
                          ><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                          <span class="muted event-meta">
                            <%= entry.last_event || "n/a" %>
                            <%= if entry.last_event_at do %>
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Cached <%= format_int(entry.tokens.cached_input_tokens) %> / Uncached <%= format_int(entry.tokens.uncached_input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <aside class="board-side-column">
            <section class="section-card signal-panel">
              <div class="section-header">
                <div>
                  <p class="section-kicker">At a glance</p>
                  <h2 class="section-title">Priority watchlist</h2>
                  <p class="section-copy">The fastest scan for what needs attention right now.</p>
                </div>
              </div>

              <div class="signal-list signal-list-dense">
                <div class="signal-item">
                  <span class="signal-label">Most active session</span>
                  <span class="signal-value"><%= primary_running_label(@payload.running) %></span>
                </div>

                <div class="signal-item">
                  <span class="signal-label">Retry queue</span>
                  <span class="signal-value"><%= retry_focus_label(@payload.retrying) %></span>
                </div>

                <div class="signal-item">
                  <span class="signal-label">Recent completed</span>
                  <span class="signal-value"><%= latest_completed_label(@payload.completed_runs) %></span>
                </div>

                <div class="signal-item">
                  <span class="signal-label">Issue rollups</span>
                  <span class="signal-value numeric"><%= @payload.counts.issue_rollups %> tracked</span>
                </div>
              </div>
            </section>

            <section class="section-card signal-panel" id="rate-limits">
              <div class="section-header">
                <div>
                  <p class="section-kicker">Upstream</p>
                  <h2 class="section-title">Rate limits</h2>
                  <p class="section-copy">Latest upstream rate-limit snapshot, when available.</p>
                </div>
              </div>

              <div class="rate-limit-summary"><%= rate_limit_focus(@payload.rate_limits) %></div>
              <pre class="code-panel code-panel-compact"><%= pretty_value(@payload.rate_limits) %></pre>
            </section>
          </aside>
        </section>
        <% end %>

        <%= if @page.key == :approvals do %>
        <section class="dashboard-grid dashboard-grid-dual">
          <section class="section-card" id="pending-approvals">
            <div class="section-header">
              <div>
                <p class="section-kicker">Guardrails</p>
                <h2 class="section-title">Pending approvals</h2>
                <p class="section-copy">Runs paused because Codex requested approval and no operator decision has been applied yet.</p>
              </div>
            </div>

            <div class="detail-stack" style="margin-bottom: 1rem;">
              <form phx-change="update_operator_token" class="detail-stack">
                <label class="muted" for="operator-token-input">Operator token</label>
                <input
                  id="operator-token-input"
                  type="password"
                  name="operator_token"
                  value={@operator_token}
                  placeholder="Enter operator token"
                  class="code-panel"
                  style="max-width: 24rem;"
                />
              </form>

              <div class="detail-stack">
                <span class={if @operator_authenticated, do: "state-badge state-badge-active", else: "state-badge state-badge-warning"}>
                  <%= if @operator_authenticated, do: "operator authenticated", else: "operator token required" %>
                </span>
                <div class="detail-stack">
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="enable_workflow_full_access"
                    disabled={!@operator_authenticated}
                    phx-disable-with="Enabling..."
                  >
                    Enable workflow full access
                  </button>
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="disable_workflow_full_access"
                    disabled={!@operator_authenticated}
                    phx-disable-with="Disabling..."
                  >
                    Disable workflow full access
                  </button>
                </div>
              </div>
            </div>

            <form phx-change="update_guardrail_filters" class="detail-stack" style="margin-bottom: 1rem;">
              <label class="muted" for="guardrail-filter-query">Approval filters</label>
              <div class="detail-stack">
                <input
                  id="guardrail-filter-query"
                  type="text"
                  name="query"
                  value={@guardrail_filters["query"]}
                  placeholder="Search issue, summary, fingerprint, command, path"
                  class="code-panel"
                  style="max-width: 28rem;"
                />
                <select name="issue_identifier" class="code-panel" style="max-width: 14rem;">
                  <option value="">All issues</option>
                  <option :for={value <- unique_filter_values(@payload.pending_approvals, :issue_identifier)} selected={@guardrail_filters["issue_identifier"] == value}>
                    <%= value %>
                  </option>
                </select>
                <select name="action_type" class="code-panel" style="max-width: 14rem;">
                  <option value="">All action types</option>
                  <option :for={value <- unique_filter_values(@payload.pending_approvals, :action_type)} selected={@guardrail_filters["action_type"] == value}>
                    <%= value %>
                  </option>
                </select>
                <select name="risk_level" class="code-panel" style="max-width: 12rem;">
                  <option value="">All risks</option>
                  <option :for={value <- unique_filter_values(@payload.pending_approvals, :risk_level)} selected={@guardrail_filters["risk_level"] == value}>
                    <%= value %>
                  </option>
                </select>
                <select name="worker_host" class="code-panel" style="max-width: 14rem;">
                  <option value="">All worker hosts</option>
                  <option :for={value <- unique_filter_values(@payload.pending_approvals, :worker_host)} selected={@guardrail_filters["worker_host"] == value}>
                    <%= value %>
                  </option>
                </select>
              </div>
            </form>

            <% filtered_approvals = filtered_pending_approvals(@payload.pending_approvals, @guardrail_filters) %>

            <%= if filtered_approvals == [] do %>
              <p class="empty-state">No approvals are currently waiting for review.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Action</th>
                      <th>Requested at</th>
                      <th>Risk</th>
                      <th>Summary</th>
                      <th>Operator</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={approval <- filtered_approvals}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= approval.issue_identifier %></span>
                          <a class="issue-link" href={"/api/v1/#{approval.issue_identifier}"}>JSON details</a>
                          <%= if approval.run_id do %>
                            <a class="issue-link" href={"/runs/#{approval.issue_identifier}/#{approval.run_id}"}>Run details</a>
                          <% end %>
                        </div>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class="event-text"><%= approval.action_type || "approval" %></span>
                          <span class="muted event-meta"><%= approval.method || "n/a" %></span>
                        </div>
                      </td>
                      <td class="mono"><%= approval.requested_at || "n/a" %></td>
                      <td>
                        <span class={state_badge_class(approval.risk_level || "review")}>
                          <%= approval.risk_level || "review" %>
                        </span>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class="event-text"><%= approval.summary || "approval pending" %></span>
                          <span class="muted event-meta"><%= approval.reason || "operator review required" %></span>
                          <span :if={approval.explanation && get_in(approval.explanation, ["evaluation", "reason"])} class="muted event-meta">
                            Why: <%= get_in(approval.explanation, ["evaluation", "reason"]) %>
                          </span>
                          <span class="muted event-meta mono"><%= approval.fingerprint || "n/a" %></span>
                          <span :for={line <- approval_detail_preview(approval)} class="muted event-meta"><%= line %></span>
                        </div>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <form phx-submit="guardrail_decide" class="detail-stack">
                            <input type="hidden" name="approval_id" value={approval.id} />
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

                          <%= if approval.run_id do %>
                            <button
                              type="button"
                              class="subtle-button"
                              phx-click="enable_run_full_access"
                              phx-value-run_id={approval.run_id}
                              disabled={!@operator_authenticated}
                              phx-disable-with="Enabling full access..."
                            >
                              Full access for run
                            </button>
                          <% end %>
                        </div>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Safety posture</p>
                <h2 class="section-title">Active overrides</h2>
                <p class="section-copy">Run-level and workflow-wide full-access overrides currently active in the runtime.</p>
              </div>
            </div>

            <%= if @payload.guardrail_overrides == [] do %>
              <p class="empty-state">No full-access overrides are active.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
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
                    <tr :for={override <- @payload.guardrail_overrides}>
                      <td>
                        <div class="detail-stack">
                          <span class="event-text"><%= override.scope || "override" %></span>
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
            <% end %>
          </section>
        </section>

        <section class="section-card">
          <div class="section-header">
              <div>
                <p class="section-kicker">Policy</p>
                <h2 class="section-title">Guardrail rules</h2>
                <p class="section-copy">Persisted allow/deny rules across active, disabled, and expired lifecycle states.</p>
              </div>
            </div>

          <%= if @payload.guardrail_rules == [] do %>
            <p class="empty-state">No guardrail rules have been recorded yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table data-table-compact">
                <thead>
                  <tr>
                    <th>Scope</th>
                    <th>Action</th>
                    <th>Status</th>
                    <th>Match</th>
                    <th>Created</th>
                    <th>Uses</th>
                    <th>Operator</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={rule <- @payload.guardrail_rules}>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text"><%= rule.scope || "n/a" %></span>
                        <span class="muted event-meta"><%= rule.scope_key || "n/a" %></span>
                      </div>
                    </td>
                    <td><%= rule.action_type || "n/a" %></td>
                    <td>
                      <span class={state_badge_class(rule.lifecycle_state || "inactive")}>
                        <%= rule.lifecycle_state || "inactive" %>
                      </span>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text"><%= rule[:description] || rule["description"] || "guardrail rule" %></span>
                        <pre class="code-panel code-panel-compact"><%= pretty_value(rule.match) %></pre>
                      </div>
                    </td>
                    <td class="mono"><%= rule.created_at || "n/a" %></td>
                    <td class="numeric"><%= remaining_uses_label(rule.remaining_uses) %></td>
                    <td>
                      <div class="detail-stack">
                        <button
                          :if={rule.active}
                          type="button"
                          class="subtle-button"
                          phx-click="disable_guardrail_rule"
                          phx-value-rule_id={rule.id}
                          disabled={!@operator_authenticated}
                          phx-disable-with="Disabling..."
                        >
                          Disable
                        </button>
                        <button
                          :if={rule.active}
                          type="button"
                          class="subtle-button"
                          phx-click="expire_guardrail_rule"
                          phx-value-rule_id={rule.id}
                          disabled={!@operator_authenticated}
                          phx-disable-with="Expiring..."
                        >
                          Expire
                        </button>
                        <button
                          :if={!rule.active}
                          type="button"
                          class="subtle-button"
                          phx-click="enable_guardrail_rule"
                          phx-value-rule_id={rule.id}
                          disabled={!@operator_authenticated}
                          phx-disable-with="Enabling..."
                        >
                          Enable
                        </button>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
        <% end %>

        <%= if @page.key == :settings do %>
        <section class="section-card">
          <div class="section-header">
            <div>
              <p class="section-kicker">Codex auth</p>
              <h2 class="section-title">Device login</h2>
              <p class="section-copy">Start a device-code login flow inside the running environment and finish the browser step from any machine.</p>
            </div>
            <div class="section-meta">
              <a class="action-link" href="/api/v1/codex/auth">Codex auth API</a>
            </div>
          </div>

          <div class="dashboard-grid dashboard-grid-dual">
            <div class="detail-stack">
              <div class="signal-list signal-list-dense">
                <div class="signal-item">
                  <span class="signal-label">Phase</span>
                  <span class="signal-value">
                    <span class={state_badge_class(@payload.codex_auth.phase || "unknown")}>
                      <%= @payload.codex_auth.phase || "unknown" %>
                    </span>
                  </span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Status</span>
                  <span class="signal-value"><%= @payload.codex_auth.status_summary || "status unknown" %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Authenticated</span>
                  <span class="signal-value"><%= if @payload.codex_auth.authenticated, do: "yes", else: "no" %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Last checked</span>
                  <span class="signal-value mono"><%= @payload.codex_auth.status_checked_at || "n/a" %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Started</span>
                  <span class="signal-value mono"><%= @payload.codex_auth.started_at || "n/a" %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Completed</span>
                  <span class="signal-value mono"><%= @payload.codex_auth.completed_at || "n/a" %></span>
                </div>
              </div>

              <div class="detail-stack">
                <button type="button" class="subtle-button" phx-click="refresh_codex_auth_status" phx-disable-with="Refreshing...">
                  Refresh status
                </button>
                <button
                  type="button"
                  class="subtle-button"
                  phx-click="start_codex_device_auth"
                  disabled={!@operator_authenticated or @payload.codex_auth.in_progress}
                  phx-disable-with="Starting..."
                >
                  Start device auth
                </button>
                <button
                  type="button"
                  class="subtle-button"
                  phx-click="cancel_codex_device_auth"
                  disabled={!@operator_authenticated or !@payload.codex_auth.in_progress}
                  phx-disable-with="Cancelling..."
                >
                  Cancel
                </button>
              </div>
            </div>

            <div class="detail-stack">
              <div class="signal-list signal-list-dense">
                <div class="signal-item">
                  <span class="signal-label">Verification URL</span>
                  <span class="signal-value">
                    <%= if @payload.codex_auth.verification_uri do %>
                      <a class="issue-link" href={@payload.codex_auth.verification_uri} target="_blank" rel="noreferrer">
                        <%= @payload.codex_auth.verification_uri %>
                      </a>
                    <% else %>
                      n/a
                    <% end %>
                  </span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">User code</span>
                  <span class="signal-value mono"><%= @payload.codex_auth.user_code || "n/a" %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Launch command</span>
                  <span class="signal-value mono"><%= @payload.codex_auth.launch_command || "n/a" %></span>
                </div>
                <div :if={@payload.codex_auth.error} class="signal-item">
                  <span class="signal-label">Error</span>
                  <span class="signal-value"><%= @payload.codex_auth.error %></span>
                </div>
              </div>

              <div class="detail-stack">
                <p class="section-kicker">Recent output</p>
                <%= if @payload.codex_auth.output_lines in [nil, []] do %>
                  <p class="empty-state">No Codex auth output captured yet.</p>
                <% else %>
                  <pre class="code-panel code-panel-compact"><%= Enum.join(@payload.codex_auth.output_lines, "\n") %></pre>
                <% end %>
              </div>
            </div>
          </div>
        </section>

        <section class="dashboard-grid dashboard-grid-dual">
          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">GitHub workspace access</p>
                <h2 class="section-title">Repo bootstrap and landing</h2>
                <p class="section-copy">Manage the repository URL and Git identity used by workspace hooks without editing Docker env files.</p>
              </div>
              <div class="section-meta">
                <a class="action-link" href="/api/v1/github">GitHub access API</a>
              </div>
            </div>

            <%= if @payload.github_access_error do %>
              <p class="empty-state">GitHub access settings are unavailable: <%= @payload.github_access_error %></p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
                  <thead>
                    <tr>
                      <th>Setting</th>
                      <th>Current</th>
                      <th>Environment</th>
                      <th>Default</th>
                      <th>Source</th>
                      <th>Operator</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={setting <- @payload.github_access.settings}>
                      <td>
                        <div class="detail-stack">
                          <span class="event-text"><%= setting.path %></span>
                          <span class="muted event-meta"><%= setting.description %></span>
                          <span class="muted event-meta">Applies: <%= setting.apply_mode %></span>
                        </div>
                      </td>
                      <td><pre class="code-panel code-panel-compact"><%= pretty_value(setting.effective_value) %></pre></td>
                      <td><pre class="code-panel code-panel-compact"><%= pretty_value(setting.env_value) %></pre></td>
                      <td><pre class="code-panel code-panel-compact"><%= pretty_value(setting.default_value) %></pre></td>
                      <td>
                        <span class={state_badge_class(setting.source)}>
                          <%= setting.source_label %>
                        </span>
                      </td>
                      <td>
                        <form phx-submit="update_github_access_setting" class="detail-stack">
                          <input type="hidden" name="path" value={setting.path} />
                          <input
                            type="text"
                            name="value"
                            value={setting.editable_value}
                            class="code-panel"
                            disabled={!@operator_authenticated}
                          />
                          <div class="detail-stack">
                            <button type="submit" class="subtle-button" disabled={!@operator_authenticated} phx-disable-with="Saving...">
                              Save
                            </button>
                            <button
                              type="button"
                              class="subtle-button"
                              phx-click="reset_github_access_setting"
                              phx-value-path={setting.path}
                              disabled={!@operator_authenticated}
                              phx-disable-with="Resetting..."
                            >
                              Reset
                            </button>
                          </div>
                        </form>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">GitHub secret</p>
                <h2 class="section-title">Write-only token</h2>
                <p class="section-copy">Store a GitHub token for clone, fetch, push, and optional GitHub tracker auth without exposing it back through the UI.</p>
              </div>
            </div>

            <%= if @payload.github_access_error do %>
              <p class="empty-state">GitHub token metadata is unavailable.</p>
            <% else %>
              <div class="signal-list signal-list-dense">
                <div class="signal-item">
                  <span class="signal-label">Configured</span>
                  <span class="signal-value"><%= if @payload.github_access.token.configured, do: "yes", else: "no" %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Source</span>
                  <span class="signal-value">
                    <span class={state_badge_class(@payload.github_access.token.source || "none")}>
                      <%= @payload.github_access.token.source_label || "None" %>
                    </span>
                  </span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Updated</span>
                  <span class="signal-value mono"><%= @payload.github_access.token.updated_at || "n/a" %></span>
                </div>
                <div class="signal-item">
                  <span class="signal-label">Cleared</span>
                  <span class="signal-value mono"><%= @payload.github_access.token.cleared_at || "n/a" %></span>
                </div>
              </div>

              <form phx-submit="set_github_access_token" class="detail-stack" style="margin-top: 1rem;">
                <input
                  type="password"
                  name="token"
                  value=""
                  autocomplete="new-password"
                  placeholder="Paste GitHub token"
                  class="code-panel"
                  disabled={!@operator_authenticated}
                />
                <div class="detail-stack">
                  <button type="submit" class="subtle-button" disabled={!@operator_authenticated} phx-disable-with="Saving...">
                    Store token
                  </button>
                  <button
                    type="button"
                    class="subtle-button"
                    phx-click="clear_github_access_token"
                    disabled={!@operator_authenticated}
                    phx-disable-with="Clearing..."
                  >
                    Clear token
                  </button>
                </div>
              </form>

              <div class="detail-stack" style="margin-top: 1rem;">
                <p class="section-kicker">Recent access changes</p>
                <%= if @payload.github_access.history == [] do %>
                  <p class="empty-state">No GitHub access changes have been recorded yet.</p>
                <% else %>
                  <div class="table-wrap">
                    <table class="data-table data-table-compact">
                      <thead>
                        <tr>
                          <th>When</th>
                          <th>Actor</th>
                          <th>Action</th>
                          <th>Paths</th>
                          <th>Why</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={entry <- @payload.github_access.history}>
                          <td class="mono"><%= entry["recorded_at"] || "n/a" %></td>
                          <td><%= entry["actor"] || "n/a" %></td>
                          <td>
                            <span class={state_badge_class(entry["action"] || "update")}>
                              <%= entry["action"] || "update" %>
                            </span>
                          </td>
                          <td>
                            <div class="detail-stack">
                              <span class="event-text"><%= Enum.join(entry["paths"] || [], ", ") %></span>
                              <%= if map_size(entry["new_values"] || %{}) > 0 do %>
                                <pre class="code-panel code-panel-compact"><%= pretty_value(entry["new_values"]) %></pre>
                              <% end %>
                            </div>
                          </td>
                          <td><%= entry["reason"] || "operator change" %></td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </div>
            <% end %>
          </section>
        </section>

        <section class="dashboard-grid dashboard-grid-dual" id="runtime-settings">
          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Runtime controls</p>
                <h2 class="section-title">UI-managed settings</h2>
                <p class="section-copy">Selected runtime knobs can be changed here without editing `WORKFLOW.md` or restarting the process.</p>
              </div>
              <div class="section-meta">
                <a class="action-link" href="/api/v1/settings">Settings API</a>
              </div>
            </div>

            <%= if @payload.settings_error do %>
              <p class="empty-state">Runtime settings are unavailable: <%= @payload.settings_error %></p>
            <% else %>
              <div :for={{group, settings} <- grouped_settings(@payload.settings)} class="detail-stack" style="margin-bottom: 1.5rem;">
                <div class="detail-stack">
                  <p class="section-kicker"><%= group %></p>
                  <p class="muted"><%= length(settings) %> editable setting<%= if length(settings) == 1, do: "", else: "s" %></p>
                </div>

                <div class="table-wrap">
                  <table class="data-table data-table-compact">
                    <thead>
                      <tr>
                        <th>Setting</th>
                        <th>Current</th>
                        <th>Workflow</th>
                        <th>Default</th>
                        <th>Source</th>
                        <th>Operator</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={setting <- settings}>
                        <td>
                          <div class="detail-stack">
                            <span class="event-text"><%= setting.path %></span>
                            <span class="muted event-meta"><%= setting.description %></span>
                            <span class="muted event-meta">Applies: <%= setting.apply_mode %></span>
                          </div>
                        </td>
                        <td><pre class="code-panel code-panel-compact"><%= pretty_value(setting.effective_value) %></pre></td>
                        <td><pre class="code-panel code-panel-compact"><%= pretty_value(setting.workflow_value) %></pre></td>
                        <td><pre class="code-panel code-panel-compact"><%= pretty_value(setting.default_value) %></pre></td>
                        <td>
                          <span class={state_badge_class(setting.source)}>
                            <%= setting.source_label %>
                          </span>
                        </td>
                        <td>
                          <div class="detail-stack">
                            <form phx-submit="update_runtime_setting" class="detail-stack">
                              <input type="hidden" name="path" value={setting.path} />
                              <%= case setting.type do %>
                                <% "boolean" -> %>
                                  <select name="value" class="code-panel" disabled={!@operator_authenticated}>
                                    <option :for={option <- setting.options} value={option.value} selected={setting.editable_value == option.value}>
                                      <%= option.label %>
                                    </option>
                                  </select>
                                <% "enum" -> %>
                                  <select name="value" class="code-panel" disabled={!@operator_authenticated}>
                                    <option :for={option <- setting.options} value={option.value} selected={setting.editable_value == option.value}>
                                      <%= option.label %>
                                    </option>
                                  </select>
                                <% "integer_map" -> %>
                                  <textarea name="value" class="code-panel" rows="4" disabled={!@operator_authenticated}><%= setting.editable_value %></textarea>
                                <% "string_map" -> %>
                                  <textarea name="value" class="code-panel" rows="4" disabled={!@operator_authenticated}><%= setting.editable_value %></textarea>
                                <% _ -> %>
                                  <input
                                    type={if setting.type == "integer", do: "number", else: "text"}
                                    name="value"
                                    value={setting.editable_value}
                                    class="code-panel"
                                    disabled={!@operator_authenticated}
                                  />
                              <% end %>
                              <div class="detail-stack">
                                <button type="submit" class="subtle-button" disabled={!@operator_authenticated} phx-disable-with="Saving...">
                                  Save
                                </button>
                                <button
                                  type="button"
                                  class="subtle-button"
                                  phx-click="reset_runtime_setting"
                                  phx-value-path={setting.path}
                                  disabled={!@operator_authenticated}
                                  phx-disable-with="Resetting..."
                                >
                                  Reset
                                </button>
                              </div>
                            </form>
                          </div>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Settings audit</p>
                <h2 class="section-title">Recent changes</h2>
                <p class="section-copy">Every UI-managed runtime setting change is persisted so operators can see what changed and why.</p>
              </div>
              <div class="section-meta">
                <a class="action-link" href="/api/v1/settings/history">History API</a>
              </div>
            </div>

            <%= if @payload.settings_history == [] do %>
              <p class="empty-state">No runtime setting changes have been recorded yet.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
                  <thead>
                    <tr>
                      <th>When</th>
                      <th>Actor</th>
                      <th>Action</th>
                      <th>Paths</th>
                      <th>Why</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.settings_history}>
                      <td class="mono"><%= entry["recorded_at"] || "n/a" %></td>
                      <td><%= entry["actor"] || "n/a" %></td>
                      <td>
                        <span class={state_badge_class(entry["action"] || "update")}>
                          <%= entry["action"] || "update" %>
                        </span>
                      </td>
                      <td>
                        <div class="detail-stack">
                          <span class="event-text"><%= Enum.join(entry["paths"] || [], ", ") %></span>
                          <%= if map_size(entry["new_values"] || %{}) > 0 do %>
                            <pre class="code-panel code-panel-compact"><%= pretty_value(entry["new_values"]) %></pre>
                          <% end %>
                        </div>
                      </td>
                      <td><%= entry["reason"] || "operator change" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>
        </section>
        <% end %>

        <%= if @page.key == :overview do %>
        <section class="dashboard-grid dashboard-grid-dual">
          <section class="section-card" id="retry-queue">
            <div class="section-header">
              <div>
                <p class="section-kicker">Backoff queue</p>
                <h2 class="section-title">Retry queue</h2>
                <p class="section-copy">Issues waiting for the next retry window.</p>
              </div>
            </div>

            <%= if @payload.retrying == [] do %>
              <p class="empty-state">No issues are currently backing off.</p>
            <% else %>
              <div class="table-wrap">
                <table class="data-table data-table-compact">
                  <thead>
                    <tr>
                      <th>Issue</th>
                      <th>Attempt</th>
                      <th>Due at</th>
                      <th>Error</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={entry <- @payload.retrying}>
                      <td>
                        <div class="issue-stack">
                          <span class="issue-id"><%= entry.issue_identifier %></span>
                          <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        </div>
                      </td>
                      <td class="numeric"><%= entry.attempt %></td>
                      <td class="mono"><%= entry.due_at || "n/a" %></td>
                      <td><%= entry.error || "n/a" %></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <p class="section-kicker">Signal quality</p>
                <h2 class="section-title">Delivery readout</h2>
                <p class="section-copy">Compressed operational view from the current runtime and persisted runs.</p>
              </div>
            </div>

            <div class="signal-list signal-list-dense">
              <div class="signal-item">
                <span class="signal-label">System health</span>
                <span class="signal-value"><%= system_health_copy(@payload) %></span>
              </div>
              <div class="signal-item">
                <span class="signal-label">Total runtime</span>
                <span class="signal-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></span>
              </div>
              <div class="signal-item">
                <span class="signal-label">Token burn</span>
                <span class="signal-value numeric"><%= format_int(@payload.codex_totals.total_tokens) %> total</span>
              </div>
              <div class="signal-item">
                <span class="signal-label">Completed runs</span>
                <span class="signal-value numeric"><%= @payload.counts.completed_runs %> captured</span>
              </div>
            </div>
          </section>
        </section>
        <% end %>

        <%= if @page.key == :runs do %>
        <section class="section-card" id="expensive-runs">
          <div class="section-header">
            <div>
              <p class="section-kicker">Efficiency watchlist</p>
              <h2 class="section-title">Expensive runs</h2>
              <p class="section-copy">Recent persisted runs that look meaningfully expensive, not just large because of cached context.</p>
            </div>
            <div class="section-meta">
              <span class="section-meta-label">
                <span class="section-meta-value numeric"><%= @payload.counts.expensive_runs %></span>
                flagged
              </span>
            </div>
          </div>

          <%= if @payload.expensive_runs == [] do %>
            <p class="empty-state">No recent expensive runs were detected.</p>
          <% else %>
            <div class="table-wrap" id="expensive-runs">
              <table class="data-table" style="min-width: 980px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Signal</th>
                    <th>Uncached</th>
                    <th>Tokens / file</th>
                    <th>Retries</th>
                    <th>Ended at</th>
                    <th>Links</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @payload.expensive_runs}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= run["issue_identifier"] %></span>
                        <span class="muted event-meta"><%= run["status"] || "n/a" %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}>
                          <%= efficiency_label(run) %>
                        </span>
                        <span class="muted event-meta"><%= efficiency_flags_label(run) %></span>
                      </div>
                    </td>
                    <td class="numeric"><%= format_int(get_in(run, ["tokens", "uncached_input_tokens"]) || 0) %></td>
                    <td class="numeric"><%= format_ratio(get_in(run, ["efficiency", "tokens_per_changed_file"])) %></td>
                    <td class="numeric"><%= run["retry_attempt"] || 0 %></td>
                    <td class="mono"><%= run["ended_at"] || "n/a" %></td>
                    <td>
                      <div class="issue-stack">
                        <a class="issue-link" href={"/runs/#{run["issue_identifier"]}/#{run["run_id"]}"}>Run details</a>
                        <a class="issue-link" href={"/api/v1/#{run["issue_identifier"]}/runs/#{run["run_id"]}"}>Run JSON</a>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card" id="cheap-wins">
          <div class="section-header">
            <div>
              <p class="section-kicker">Efficiency watchlist</p>
              <h2 class="section-title">Cheap wins</h2>
              <p class="section-copy">Completed runs with good change yield and low uncached spend.</p>
            </div>
            <div class="section-meta">
              <span class="section-meta-label">
                <span class="section-meta-value numeric"><%= @payload.counts.cheap_wins %></span>
                recent
              </span>
            </div>
          </div>

          <%= if @payload.cheap_wins == [] do %>
            <p class="empty-state">No recent cheap wins were detected.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 920px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Signal</th>
                    <th>Changed files</th>
                    <th>Total tokens</th>
                    <th>Uncached</th>
                    <th>Ended at</th>
                    <th>Links</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @payload.cheap_wins}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= run["issue_identifier"] %></span>
                        <span class="muted event-meta"><%= run["status"] || "n/a" %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}>
                          <%= efficiency_label(run) %>
                        </span>
                        <span class="muted event-meta"><%= run_changed_files_label(run) %></span>
                      </div>
                    </td>
                    <td class="numeric"><%= get_in(run, ["efficiency", "changed_file_count"]) || 0 %></td>
                    <td class="numeric"><%= format_int(get_in(run, ["tokens", "total_tokens"]) || 0) %></td>
                    <td class="numeric"><%= format_int(get_in(run, ["tokens", "uncached_input_tokens"]) || 0) %></td>
                    <td class="mono"><%= run["ended_at"] || "n/a" %></td>
                    <td>
                      <div class="issue-stack">
                        <a class="issue-link" href={"/runs/#{run["issue_identifier"]}/#{run["run_id"]}"}>Run details</a>
                        <a class="issue-link" href={"/api/v1/#{run["issue_identifier"]}/runs/#{run["run_id"]}"}>Run JSON</a>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card" id="completed-runs">
          <div class="section-header">
            <div>
              <p class="section-kicker">Audit history</p>
              <h2 class="section-title">Recent completed runs</h2>
              <p class="section-copy">Persisted run summaries from the audit log, including outcome and changed-file metadata.</p>
            </div>
          </div>

          <%= if @payload.completed_runs == [] do %>
            <p class="empty-state">No completed runs have been captured yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 840px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Status</th>
                    <th>Ended at</th>
                    <th>Runtime</th>
                    <th>Efficiency</th>
                    <th>Summary</th>
                    <th>Git</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @payload.completed_runs}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= run["issue_identifier"] %></span>
                        <a class="issue-link" href={"/api/v1/#{run["issue_identifier"]}"}>Issue JSON</a>
                        <a class="issue-link" href={"/runs/#{run["issue_identifier"]}/#{run["run_id"]}"}>Run details</a>
                        <a class="issue-link" href={"/api/v1/#{run["issue_identifier"]}/runs/#{run["run_id"]}"}>Run JSON</a>
                      </div>
                    </td>
                    <td>
                      <span class={state_badge_class(run["status"] || "completed")}>
                        <%= run["status"] || "completed" %>
                      </span>
                    </td>
                    <td class="mono"><%= run["ended_at"] || "n/a" %></td>
                    <td class="numeric"><%= format_duration_ms(run["duration_ms"]) %></td>
                    <td>
                      <div class="detail-stack">
                        <span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}>
                          <%= efficiency_label(run) %>
                        </span>
                        <span class="muted event-meta"><%= efficiency_flags_label(run) %></span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text" title={run["last_message"] || "n/a"}>
                          <%= run["last_message"] || "n/a" %>
                        </span>
                        <span class="muted event-meta">
                          <%= run["next_action"] || "n/a" %>
                        </span>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text"><%= run_git_label(run) %></span>
                        <span class="muted event-meta"><%= run_changed_files_label(run) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card" id="issue-efficiency">
          <div class="section-header">
            <div>
              <p class="section-kicker">Rollups</p>
              <h2 class="section-title">Issue efficiency</h2>
              <p class="section-copy">Compact rollups across persisted runs, including retries, handoffs, merge-time signals, and token-efficiency ratios.</p>
            </div>
          </div>

          <%= if @payload.issue_rollups == [] do %>
            <p class="empty-state">No issue rollups are available yet.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table" style="min-width: 1080px;">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Latest</th>
                    <th>Runs</th>
                    <th>Avg runtime</th>
                    <th>Avg queue</th>
                    <th>Avg handoff</th>
                    <th>Avg merge</th>
                    <th>Retries</th>
                    <th>Total tokens</th>
                    <th>Uncached</th>
                    <th>Avg uncached / run</th>
                    <th>Avg tokens / file</th>
                    <th>Signals</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={rollup <- @payload.issue_rollups}>
                    <td>
                      <div class="issue-stack">
                        <span class="issue-id"><%= rollup["issue_identifier"] %></span>
                        <a class="issue-link" href={"/api/v1/#{rollup["issue_identifier"]}"}>Issue JSON</a>
                        <%= if rollup["latest_run_id"] do %>
                          <a class="issue-link" href={"/runs/#{rollup["issue_identifier"]}/#{rollup["latest_run_id"]}"}>Latest run</a>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={state_badge_class(rollup["latest_status"] || "completed")}>
                          <%= rollup["latest_status"] || "n/a" %>
                        </span>
                        <span class="muted event-meta"><%= rollup["latest_ended_at"] || "n/a" %></span>
                      </div>
                    </td>
                    <td class="numeric"><%= rollup["run_count"] || 0 %></td>
                    <td class="numeric"><%= format_duration_ms(rollup["avg_duration_ms"]) %></td>
                    <td class="numeric"><%= format_duration_ms(rollup["avg_queue_wait_ms"]) %></td>
                    <td class="numeric"><%= format_duration_ms(rollup["avg_handoff_latency_ms"]) %></td>
                    <td class="numeric"><%= format_duration_ms(rollup["avg_merge_latency_ms"]) %></td>
                    <td class="numeric"><%= rollup["total_retry_attempts"] || 0 %></td>
                    <td class="numeric"><%= format_int(rollup["total_tokens"] || 0) %></td>
                    <td class="numeric"><%= format_int(rollup["total_uncached_input_tokens"] || 0) %></td>
                    <td class="numeric"><%= format_ratio(rollup["avg_uncached_input_tokens_per_run"]) %></td>
                    <td class="numeric"><%= format_ratio(rollup["avg_tokens_per_changed_file"]) %></td>
                    <td>
                      <div class="detail-stack">
                        <span class={efficiency_badge_class(rollup["classification"])}>
                          <%= rollup["primary_label"] || "Normal" %>
                        </span>
                        <span class="muted event-meta"><%= efficiency_flags_label(rollup) %></span>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>
        <% end %>
          </div>
        </div>
      <% end %>
    </section>
    """
  end

  defp dashboard_page(:index), do: dashboard_page(:overview)

  defp dashboard_page(:overview) do
    %{
      key: :overview,
      nav_label: "Overview",
      title: "Operations Dashboard",
      copy: "Black-surface mission control for live sessions, retries, throughput, and runtime posture.",
      focus: "Live execution, queue pressure, and the current operating pulse.",
      next_step: "Move into approvals, settings, or runs when the overview points at a bottleneck."
    }
  end

  defp dashboard_page(:approvals) do
    %{
      key: :approvals,
      nav_label: "Approvals",
      title: "Approval Control",
      copy: "Resolve blocked runs, manage full-access posture, and keep guardrail rules predictable.",
      focus: "Pending operator decisions, temporary overrides, and long-lived rules.",
      next_step: "Clear waiting approvals first, then remove stale overrides and tighten rules."
    }
  end

  defp dashboard_page(:settings) do
    %{
      key: :settings,
      nav_label: "Settings",
      title: "Runtime Settings",
      copy: "Tune the runtime without editing workflow files, and keep the operator change history visible.",
      focus: "UI-managed knobs, effective values, and recent operator changes.",
      next_step: "Adjust only the current bottleneck, then watch the next run before changing more."
    }
  end

  defp dashboard_page(:runs) do
    %{
      key: :runs,
      nav_label: "Runs",
      title: "Run Intelligence",
      copy: "Review expensive runs, cheap wins, persisted completions, and cross-run efficiency signals.",
      focus: "Post-run audit history, efficiency outliers, and issue-level rollups.",
      next_step: "Start with expensive runs, then inspect completed details and issue rollups."
    }
  end

  defp dashboard_page(_other), do: dashboard_page(:overview)

  defp page_path(:overview), do: "/"
  defp page_path(:approvals), do: "/approvals"
  defp page_path(:settings), do: "/settings"
  defp page_path(:runs), do: "/runs"

  defp sidebar_link_class(current_page, target_page) do
    base = "sidebar-link"

    if current_page == target_page do
      base <> " sidebar-link-active"
    else
      base
    end
  end

  defp hero_pill_class(current_page, target_page) do
    base = "hero-pill"

    if current_page == target_page do
      base <> " hero-pill-active"
    else
      base
    end
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp completed_runtime_seconds(payload) do
    payload.codex_totals.seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_duration_ms(duration_ms) when is_integer(duration_ms) and duration_ms >= 0 do
    format_runtime_seconds(duration_ms / 1_000)
  end

  defp format_duration_ms(_duration_ms), do: "n/a"

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

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

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["critical", "danger", "high"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry", "review", "medium"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp system_health_class(payload) do
    base = "status-badge status-badge-system"

    case system_health_level(payload) do
      :healthy -> "#{base} status-badge-positive"
      :warning -> "#{base} status-badge-warning"
      :idle -> "#{base} status-badge-neutral"
    end
  end

  defp system_health_label(payload) do
    case system_health_level(payload) do
      :healthy -> "Stable"
      :warning -> "Attention"
      :idle -> "Idle"
    end
  end

  defp system_health_copy(payload) do
    case system_health_level(payload) do
      :healthy ->
        "Active flow is healthy with #{payload.counts.running} live issue sessions and no retry backlog."

      :warning ->
        "Retry pressure is present on #{payload.counts.retrying} issue#{if payload.counts.retrying == 1, do: "", else: "s"}."

      :idle ->
        "No live work is running and no issues are waiting to retry."
    end
  end

  defp primary_running_label([]), do: "No active sessions"

  defp primary_running_label(running) when is_list(running) do
    running
    |> Enum.max_by(fn entry -> entry.tokens.total_tokens || 0 end, fn -> nil end)
    |> case do
      nil -> "No active sessions"
      entry -> "#{entry.issue_identifier} · #{format_int(entry.tokens.total_tokens)} tokens"
    end
  end

  defp retry_focus_label([]), do: "No backoff pressure"

  defp retry_focus_label(retrying) when is_list(retrying) do
    retrying
    |> Enum.min_by(&retry_sort_value(&1.due_at), fn -> nil end)
    |> case do
      nil -> "No backoff pressure"
      entry -> "#{entry.issue_identifier} · attempt #{entry.attempt}"
    end
  end

  defp latest_completed_label([]), do: "No completed runs yet"

  defp latest_completed_label(completed_runs) when is_list(completed_runs) do
    case List.first(completed_runs) do
      %{"issue_identifier" => issue_identifier, "status" => status} ->
        "#{issue_identifier} · #{status || "completed"}"

      _ ->
        "No completed runs yet"
    end
  end

  defp rate_limit_focus(rate_limits) when is_map(rate_limits) do
    primary = Map.get(rate_limits, "primary") || Map.get(rate_limits, :primary)

    case primary do
      %{"remaining" => remaining} when is_integer(remaining) -> "Primary remaining #{remaining}"
      %{remaining: remaining} when is_integer(remaining) -> "Primary remaining #{remaining}"
      _ -> "No structured rate-limit snapshot"
    end
  end

  defp rate_limit_focus(_rate_limits), do: "No structured rate-limit snapshot"

  defp efficiency_watch_label(expensive_runs, cheap_wins)
       when is_list(expensive_runs) and is_list(cheap_wins) do
    cond do
      expensive_runs != [] ->
        case List.first(expensive_runs) do
          %{"issue_identifier" => issue_identifier, "efficiency" => %{"primary_label" => label}}
          when is_binary(label) ->
            "#{issue_identifier} · #{label}"

          %{"issue_identifier" => issue_identifier} ->
            "#{issue_identifier} · expensive"

          _ ->
            "Expensive runs detected"
        end

      cheap_wins != [] ->
        case List.first(cheap_wins) do
          %{"issue_identifier" => issue_identifier} -> "#{issue_identifier} · cheap win"
          _ -> "Cheap wins available"
        end

      true ->
        "No recent efficiency outliers"
    end
  end

  defp system_health_level(payload) do
    cond do
      payload.counts.retrying > 0 -> :warning
      payload.counts.running > 0 -> :healthy
      true -> :idle
    end
  end

  defp retry_sort_value(nil), do: {{9999, 12, 31}, {23, 59, 59}, 999_999}

  defp retry_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} ->
        {Date.to_erl(DateTime.to_date(parsed)), Time.to_erl(DateTime.to_time(parsed)), 0}

      _ ->
        retry_sort_value(nil)
    end
  end

  defp run_git_label(run) when is_map(run) do
    git = run["workspace_metadata"] && run["workspace_metadata"]["git"]
    branch = git && git["branch"]
    head = git && git["head_commit"]

    cond do
      is_binary(branch) and is_binary(head) -> "#{branch} @ #{String.slice(head, 0, 8)}"
      is_binary(branch) -> branch
      is_binary(head) -> String.slice(head, 0, 8)
      true -> "n/a"
    end
  end

  defp run_git_label(_run), do: "n/a"

  defp run_changed_files_label(run) when is_map(run) do
    git =
      run["workspace_metadata"] &&
        run["workspace_metadata"]["git"]

    changed_files = git && git["changed_files"]
    changed_file_count = git && git["changed_file_count"]

    case changed_files do
      [%{"path" => first_path} | _rest] ->
        count = changed_file_count || length(changed_files)

        if count > 1 do
          "#{count} files, incl. #{first_path}"
        else
          first_path
        end

      _ ->
        "no changed-file summary"
    end
  end

  defp run_changed_files_label(_run), do: "no changed-file summary"

  defp efficiency_label(%{"efficiency" => %{"primary_label" => label}}) when is_binary(label), do: label
  defp efficiency_label(%{"primary_label" => label}) when is_binary(label), do: label
  defp efficiency_label(_run), do: "Normal"

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

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp refresh_dashboard(socket, success_message) do
    socket
    |> assign(:payload, load_payload())
    |> assign(:now, DateTime.utc_now())
    |> put_flash(:info, success_message)
  end

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
  defp humanize_guardrail_error(:rule_not_found), do: "Guardrail rule not found."
  defp humanize_guardrail_error(:override_not_found), do: "Full-access override not found."
  defp humanize_guardrail_error(:operator_action_rate_limited), do: "Another operator action just updated this item. Try again in a moment."
  defp humanize_guardrail_error(:operator_token_invalid), do: "Operator token missing or invalid."
  defp humanize_guardrail_error(:operator_token_not_configured), do: "Operator token is not configured."
  defp humanize_guardrail_error(:guardrails_disabled), do: "Guardrails are disabled in the current workflow."
  defp humanize_guardrail_error(reason), do: "Guardrail action failed: #{inspect(reason)}"

  defp humanize_settings_error(:no_setting_changes), do: "No runtime setting changes were provided."
  defp humanize_settings_error(:no_setting_paths), do: "No runtime setting paths were provided."
  defp humanize_settings_error({:setting_not_ui_manageable, path}), do: "#{path} is bootstrap-only or not UI-manageable."
  defp humanize_settings_error({:invalid_setting_value, path, message}), do: "Invalid value for #{path}: #{message}."
  defp humanize_settings_error({:invalid_setting_patch, message}), do: "Settings patch rejected: #{message}."
  defp humanize_settings_error(reason), do: "Settings change failed: #{inspect(reason)}"

  defp humanize_github_access_error(:no_github_config_changes), do: "No GitHub access changes were provided."
  defp humanize_github_access_error(:no_github_setting_paths), do: "No GitHub access setting paths were provided."
  defp humanize_github_access_error({:github_setting_not_ui_manageable, path}), do: "#{path} is not UI-manageable."
  defp humanize_github_access_error({:invalid_github_setting_value, path, message}), do: "Invalid value for #{path}: #{message}."
  defp humanize_github_access_error({:invalid_token_value, message}), do: "Invalid GitHub token: #{message}."
  defp humanize_github_access_error(reason), do: "GitHub access action failed: #{inspect(reason)}"

  defp humanize_codex_auth_error(:device_auth_in_progress), do: "A Codex device auth flow is already running."
  defp humanize_codex_auth_error(:device_auth_not_running), do: "No Codex device auth flow is currently running."
  defp humanize_codex_auth_error(:codex_command_not_configured), do: "Codex command is not configured."
  defp humanize_codex_auth_error(:bash_not_found), do: "bash is required to launch the configured Codex command."
  defp humanize_codex_auth_error(reason), do: "Codex auth action failed: #{inspect(reason)}"

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

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp grouped_settings(settings) when is_list(settings) do
    settings
    |> Enum.group_by(& &1.group)
    |> Enum.sort_by(fn {group, _settings} -> group end)
  end

  defp grouped_settings(_settings), do: []

  defp default_guardrail_filters do
    %{
      "query" => "",
      "issue_identifier" => "",
      "action_type" => "",
      "risk_level" => "",
      "worker_host" => ""
    }
  end

  defp normalize_guardrail_filters(params) when is_map(params) do
    default_guardrail_filters()
    |> Map.merge(%{
      "query" => blank_to_empty(params["query"]),
      "issue_identifier" => blank_to_empty(params["issue_identifier"]),
      "action_type" => blank_to_empty(params["action_type"]),
      "risk_level" => blank_to_empty(params["risk_level"]),
      "worker_host" => blank_to_empty(params["worker_host"])
    })
  end

  defp normalize_guardrail_filters(_params), do: default_guardrail_filters()

  defp filtered_pending_approvals(approvals, filters) when is_list(approvals) and is_map(filters) do
    approvals
    |> Enum.filter(fn approval ->
      filter_match?(approval.issue_identifier, filters["issue_identifier"]) and
        filter_match?(approval.action_type, filters["action_type"]) and
        filter_match?(approval.risk_level, filters["risk_level"]) and
        filter_match?(approval.worker_host, filters["worker_host"]) and
        filter_query_match?(approval, filters["query"])
    end)
  end

  defp filtered_pending_approvals(approvals, _filters), do: approvals

  defp unique_filter_values(entries, field) when is_list(entries) do
    entries
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

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

  defp filter_match?(_value, nil), do: true
  defp filter_match?(_value, ""), do: true

  defp filter_match?(value, expected) when is_binary(expected) do
    normalize_filter_value(value) == normalize_filter_value(expected)
  end

  defp filter_query_match?(_approval, nil), do: true
  defp filter_query_match?(_approval, ""), do: true

  defp filter_query_match?(approval, query) when is_map(approval) and is_binary(query) do
    haystack =
      [
        approval.issue_identifier,
        approval.summary,
        approval.reason,
        approval.fingerprint,
        approval.action_type,
        approval.method,
        approval.worker_host,
        approval.workspace_path,
        inspect(approval.details || %{}, limit: :infinity)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, normalize_filter_value(query))
  end

  defp normalize_filter_value(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_filter_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_filter_value()
  defp normalize_filter_value(_value), do: ""

  defp blank_to_empty(value) when is_binary(value), do: String.trim(value)
  defp blank_to_empty(_value), do: ""
end
