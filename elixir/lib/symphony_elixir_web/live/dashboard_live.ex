defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live operator dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.{CodexAuth, Config, GitHubAccess, Orchestrator, SettingsOverlay, StatusDashboard}
  alias SymphonyElixirWeb.{DashboardComponents, Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000
  @approval_param_keys ~w(q issue_identifier action_type risk_level worker_host selected)
  @run_param_keys ~w(q status sort view)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, current_time())
      |> assign(:page, dashboard_page(socket.assigns[:live_action] || :overview))
      |> assign(:current_params, %{})
      |> assign(:operator_token, "")
      |> assign(:operator_authenticated, false)
      |> assign(:guardrail_filters, default_guardrail_filters())
      |> assign(:filtered_approvals, [])
      |> assign(:selected_approval, nil)
      |> assign(:run_filters, default_run_filters())
      |> assign(:filtered_runs, [])
      |> assign(:run_view, "history")
      |> rebuild_page_state(%{})

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:current_params, params)
     |> assign(:page, dashboard_page(socket.assigns[:live_action] || :overview))
     |> rebuild_page_state(params)}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, current_time())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, current_time())
     |> rebuild_page_state(socket.assigns.current_params)}
  end

  @impl true
  def handle_event("update_operator_token", %{"operator_token" => token}, socket) do
    {:noreply,
     socket
     |> assign(:operator_token, token)
     |> assign(:operator_authenticated, valid_operator_token?(token))}
  end

  def handle_event("update_guardrail_filters", params, socket) do
    filters =
      params
      |> normalize_guardrail_filters()
      |> Map.put("selected", "")

    {:noreply, push_patch(socket, to: page_path(:approvals, filters))}
  end

  def handle_event("clear_guardrail_filters", _params, socket) do
    {:noreply, push_patch(socket, to: page_path(:approvals))}
  end

  def handle_event("update_run_filters", params, socket) do
    {:noreply, push_patch(socket, to: page_path(:runs, normalize_run_filters(params)))}
  end

  def handle_event("clear_run_filters", _params, socket) do
    {:noreply, push_patch(socket, to: page_path(:runs))}
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
    <DashboardComponents.command_bar
      page={@page}
      operator_authenticated={@operator_authenticated}
      operator_token_configured={operator_token_configured?()}
      operator_token={@operator_token}
      nav_items={navigation_items(@page, @payload)}
      utility_items={utility_items(@page)}
    />

    <section class="page-theater">
      <DashboardComponents.page_header
        eyebrow={@page.nav_label}
        title={@page.title}
        copy={@page.copy}
        status_label={system_health_label(@payload)}
        status_class={system_health_class(@payload)}
      />

      <%= if @payload[:error] do %>
        <DashboardComponents.section_frame
          kicker="Unavailable"
          title="Snapshot unavailable"
          copy="The dashboard could not read the current runtime snapshot. Check the orchestrator process and retry."
          class="section-frame-danger"
        >
          <DashboardComponents.key_value_list
            items={[
              %{label: "Code", value: @payload.error.code || "snapshot_unavailable"},
              %{label: "Message", value: @payload.error.message || "Snapshot unavailable"},
              %{label: "Generated", value: @payload.generated_at || DateTime.to_iso8601(@now)}
            ]}
          />
        </DashboardComponents.section_frame>
      <% else %>
        <DashboardComponents.metric_strip
          items={page_metrics(@page, @payload, @now, @filtered_approvals, @filtered_runs, @filtered_rollups, @run_filters, @operator_authenticated)}
        />

        <%= case @page.key do %>
          <% :overview -> %>
            <%= overview_page(assigns) %>
          <% :approvals -> %>
            <%= approvals_page(assigns) %>
          <% :settings -> %>
            <%= settings_page(assigns) %>
          <% :runs -> %>
            <%= runs_page(assigns) %>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp overview_page(assigns) do
    ~H"""
    <section class="stack-lg">
      <%!-- Full width: Attention cards --%>
      <section class="attention-grid" aria-label="Attention now">
        <article class={attention_card_class(@payload.counts.pending_approvals > 0)}>
          <p class="attention-kicker">Urgent approvals</p>
          <h2 class="attention-title"><%= @payload.counts.pending_approvals %> waiting</h2>
          <p class="attention-copy">
            <%= first_pending_summary(@filtered_approvals || @payload.pending_approvals) %>
          </p>
          <.link patch={page_path(:approvals)} class="inline-link">Open approvals queue</.link>
        </article>

        <article class={attention_card_class(@payload.counts.retrying > 0)}>
          <p class="attention-kicker">Retry pressure</p>
          <h2 class="attention-title"><%= @payload.counts.retrying %> queued</h2>
          <p class="attention-copy"><%= retry_focus_label(@payload.retrying) %></p>
          <a href="#retry-queue" class="inline-link">Inspect retry queue</a>
        </article>

        <article class={attention_card_class(@payload.counts.active_overrides > 0)}>
          <p class="attention-kicker">Safety posture</p>
          <h2 class="attention-title"><%= @payload.counts.active_overrides %> active overrides</h2>
          <p class="attention-copy"><%= override_summary(@payload.guardrail_overrides) %></p>
          <.link patch={page_path(:approvals)} class="inline-link">Review full access posture</.link>
        </article>
      </section>

      <%!-- Full width: Running sessions --%>
      <DashboardComponents.section_frame
        id="running-sessions"
        kicker="Live execution"
        title="Running sessions"
        copy="Active issues, last known agent activity, and token usage."
        collapsible={true}
        open={@payload.running != []}
      >
        <%= if @payload.running == [] do %>
          <DashboardComponents.empty_state
            title="No active sessions"
            copy="When Symphony claims work, the live session table appears here with session state, runtime, and Codex output."
          />
        <% else %>
          <div class="table-scroll">
            <table class="data-table">
              <caption class="sr-only">Running sessions with issue, state, worker, runtime, Codex update, tokens, and session copy action</caption>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>State</th>
                  <th>Worker</th>
                  <th>Runtime</th>
                  <th>Codex update</th>
                  <th>Tokens</th>
                  <th>Session</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- overview_running_entries(@payload.running)}>
                  <td>
                    <div class="cell-stack">
                      <strong class="cell-primary"><%= entry.issue_identifier %></strong>
                      <span class="cell-secondary"><%= entry.workspace_path || "workspace pending" %></span>
                    </div>
                  </td>
                  <td><span class={state_badge_class(entry.state)}><%= entry.state %></span></td>
                  <td class="mono"><%= entry.worker_host || "local" %></td>
                  <td class="numeric"><%= format_runtime_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                  <td>
                    <div class="cell-stack">
                      <span class="cell-primary"><%= entry.last_message || to_string(entry.last_event || "n/a") %></span>
                      <span class="cell-secondary mono"><%= entry.last_event_at || "n/a" %></span>
                    </div>
                  </td>
                  <td class="numeric">
                    <div class="cell-stack">
                      <span class="cell-primary"><%= format_int(entry.tokens.total_tokens || 0) %></span>
                      <span class="cell-secondary">uncached <%= format_int(entry.tokens.uncached_input_tokens || 0) %></span>
                    </div>
                  </td>
                  <td>
                    <%= if entry.session_id do %>
                      <DashboardComponents.copy_button label="Copy ID" value={entry.session_id} />
                    <% else %>
                      <span class="muted-copy">n/a</span>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </DashboardComponents.section_frame>

      <%!-- Operational pulse (non-collapsible, standalone) --%>
      <DashboardComponents.section_frame
        kicker="System readout"
        title="Operational pulse"
        copy="Short-form context for triage before you drill into approvals, retries, or audit history."
      >
        <DashboardComponents.key_value_list
          items={[
            %{label: "System health", value: system_health_copy(@payload)},
            %{label: "Priority session", value: primary_running_label(@payload.running)},
            %{label: "Rate limits", value: rate_limit_focus(@payload.rate_limits)},
            %{label: "Efficiency watch", value: efficiency_watch_label(@payload.expensive_runs, @payload.cheap_wins)},
            %{label: "Recent landing", value: latest_completed_label(@payload.completed_runs)}
          ]}
        />
      </DashboardComponents.section_frame>

      <%!-- Collapsible sections — each gets its own full-width row --%>
      <DashboardComponents.section_frame
        id="retry-queue"
        kicker="Backoff queue"
        title="Next retries"
        copy="The next issues scheduled to re-enter dispatch."
        collapsible={true}
        open={@payload.retrying != []}
      >
        <%= if @payload.retrying == [] do %>
          <DashboardComponents.empty_state title="No retry queue" copy="Nothing is backing off right now." />
        <% else %>
          <div class="table-scroll">
            <table class="data-table data-table-compact">
              <caption class="sr-only">Upcoming retry queue entries with issue identifier, retry attempt, and next due time</caption>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Attempt</th>
                  <th>Due</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- Enum.take(sorted_retrying(@payload.retrying), 6)}>
                  <td>
                    <div class="cell-stack">
                      <strong class="cell-primary"><%= entry.issue_identifier %></strong>
                      <span class="cell-secondary"><%= entry.error || "retry scheduled" %></span>
                    </div>
                  </td>
                  <td class="numeric"><%= entry.attempt %></td>
                  <td class="mono"><%= entry.due_at || "n/a" %></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </DashboardComponents.section_frame>

      <DashboardComponents.section_frame
        kicker="Pending approvals"
        title="Queue preview"
        copy="Highest-risk approvals waiting for operator review."
        collapsible={true}
        open={@payload.pending_approvals != []}
      >
        <%= if @payload.pending_approvals == [] do %>
          <DashboardComponents.empty_state title="Approval queue clear" copy="No guardrail actions are blocked right now." />
        <% else %>
          <ul class="stack-sm card-list">
            <li :for={approval <- Enum.take(sort_approvals(@payload.pending_approvals), 4)} class="list-card">
              <div class="list-card-head">
                <strong><%= approval.issue_identifier %></strong>
                <span class={state_badge_class(approval.risk_level || "review")}><%= approval.risk_level || "review" %></span>
              </div>
              <p class="list-card-copy"><%= approval.summary || "approval pending operator review" %></p>
              <.link patch={page_path(:approvals, %{"selected" => approval.id})} class="inline-link">Inspect approval</.link>
            </li>
          </ul>
        <% end %>
      </DashboardComponents.section_frame>
    </section>
    """
  end

  defp approvals_page(assigns) do
    ~H"""
    <section class="stack-lg">
      <%!-- Full width: Pending approvals queue --%>
      <DashboardComponents.section_frame
        kicker="Queue triage"
        title="Pending approvals"
        copy="URL-backed filters let you share exactly what needs review without losing operator state."
      >
        <form phx-change="update_guardrail_filters" class="stack-md">
          <DashboardComponents.filter_toolbar
            label="Filter queue"
            copy="Search by issue, summary, command, fingerprint, path, or worker host."
          >
            <div class="field-group field-group-search">
              <label for="approval-filter-query" class="field-label">Search</label>
              <input
                id="approval-filter-query"
                type="search"
                name="q"
                value={@guardrail_filters["q"]}
                class="field-input"
                placeholder="Search approvals"
              />
            </div>

            <div class="field-group">
              <label for="approval-filter-issue" class="field-label">Issue</label>
              <select id="approval-filter-issue" name="issue_identifier" class="field-select">
                <option value="">All issues</option>
                <option :for={value <- filter_values_with_selected(unique_filter_values(@payload.pending_approvals, :issue_identifier), @guardrail_filters["issue_identifier"])} value={value} selected={@guardrail_filters["issue_identifier"] == value}>
                  <%= value %>
                </option>
              </select>
            </div>

            <div class="field-group">
              <label for="approval-filter-action" class="field-label">Action</label>
              <select id="approval-filter-action" name="action_type" class="field-select">
                <option value="">All actions</option>
                <option :for={value <- filter_values_with_selected(unique_filter_values(@payload.pending_approvals, :action_type), @guardrail_filters["action_type"])} value={value} selected={@guardrail_filters["action_type"] == value}>
                  <%= value %>
                </option>
              </select>
            </div>

            <div class="field-group">
              <label for="approval-filter-risk" class="field-label">Risk</label>
              <select id="approval-filter-risk" name="risk_level" class="field-select">
                <option value="">All risks</option>
                <option :for={value <- filter_values_with_selected(unique_filter_values(@payload.pending_approvals, :risk_level), @guardrail_filters["risk_level"])} value={value} selected={@guardrail_filters["risk_level"] == value}>
                  <%= value %>
                </option>
              </select>
            </div>

            <div class="field-group">
              <label for="approval-filter-host" class="field-label">Worker host</label>
              <select id="approval-filter-host" name="worker_host" class="field-select">
                <option value="">All hosts</option>
                <option :for={value <- filter_values_with_selected(unique_filter_values(@payload.pending_approvals, :worker_host), @guardrail_filters["worker_host"])} value={value} selected={@guardrail_filters["worker_host"] == value}>
                  <%= value %>
                </option>
              </select>
            </div>

            <:actions>
              <button type="button" class="secondary-button" phx-click="clear_guardrail_filters">
                Reset filters
              </button>
            </:actions>
          </DashboardComponents.filter_toolbar>
        </form>

        <%= if @filtered_approvals == [] do %>
          <DashboardComponents.empty_state
            title="No approvals match these filters"
            copy="Broaden the filter set or wait for a new guardrail decision to enter the queue."
          />
        <% else %>
          <div class="table-scroll">
            <table class="data-table">
              <caption class="sr-only">Pending approvals with issue, risk, action, request time, worker host, and inspect action</caption>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>Risk</th>
                  <th>Action</th>
                  <th>Requested</th>
                  <th>Host</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={approval <- sort_approvals(@filtered_approvals)} class={if selected_approval?(@selected_approval, approval), do: "table-row-selected", else: nil}>
                  <td>
                    <div class="cell-stack">
                      <strong class="cell-primary"><%= approval.issue_identifier %></strong>
                      <span class="cell-secondary"><%= approval.summary || "approval pending operator review" %></span>
                    </div>
                  </td>
                  <td><span class={state_badge_class(approval.risk_level || "review")}><%= approval.risk_level || "review" %></span></td>
                  <td><span class="mono"><%= approval.action_type || approval.method || "n/a" %></span></td>
                  <td class="mono"><%= approval.requested_at || "n/a" %></td>
                  <td class="mono"><%= approval.worker_host || "local" %></td>
                  <td class="table-actions">
                    <.link patch={page_path(:approvals, Map.put(@guardrail_filters, "selected", approval.id))} class="inline-link">
                      Inspect
                    </.link>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </DashboardComponents.section_frame>

      <%!-- Approval detail (full width) --%>
      <%= approval_detail(assigns) %>

      <%!-- Collapsible sections — each gets its own full-width row --%>
      <%= active_overrides_panel(assigns) %>
      <%= guardrail_rules_panel(assigns) %>
    </section>
    """
  end

  attr(:setting, :map, required: true)
  attr(:operator_authenticated, :boolean, default: false)

  defp runtime_setting_control(assigns) do
    ~H"""
    <DashboardComponents.disclosure_panel
      title={@setting.label || @setting.path}
      copy={@setting.path}
      class="setting-disclosure"
    >
      <:meta>
        <div class="setting-summary-meta">
          <span class={state_badge_class(@setting.source || "default")}>
            <%= @setting.source_label || @setting.source || "default" %>
          </span>
          <span class="summary-chip"><%= @setting.apply_mode || "immediate" %></span>
          <span class="summary-chip summary-chip-value"><%= setting_value_preview(@setting.effective_value) %></span>
        </div>
      </:meta>

      <div class="stack-sm">
        <p class="setting-card-copy"><%= @setting.description %></p>

        <DashboardComponents.key_value_list
          class="setting-card-details"
          items={[
            %{label: "Applies", value: @setting.apply_mode || "immediate"},
            %{label: "Current", value: pretty_value(@setting.effective_value)},
            %{label: "Workflow", value: pretty_value(@setting.workflow_value)},
            %{label: "Default", value: pretty_value(@setting.default_value)}
          ]}
        />

        <form phx-submit="update_runtime_setting" class="stack-sm">
          <input type="hidden" name="path" value={@setting.path} />
          <%= runtime_setting_input(%{setting: @setting}) %>
          <div class="button-row">
            <button type="submit" class="primary-button" disabled={!@operator_authenticated} phx-disable-with="Applying...">
              Apply
            </button>
            <button
              type="button"
              class="secondary-button"
              phx-click="reset_runtime_setting"
              phx-value-path={@setting.path}
              disabled={!@operator_authenticated}
              phx-disable-with="Resetting..."
            >
              Reset
            </button>
          </div>
        </form>
      </div>
    </DashboardComponents.disclosure_panel>
    """
  end

  attr(:setting, :map, required: true)
  attr(:operator_authenticated, :boolean, default: false)

  defp github_setting_control(assigns) do
    ~H"""
    <DashboardComponents.disclosure_panel
      title={@setting.label || @setting.path}
      copy={@setting.path}
      class="setting-disclosure"
    >
      <:meta>
        <div class="setting-summary-meta">
          <span class={state_badge_class(@setting.source || "default")}>
            <%= @setting.source_label || @setting.source || "default" %>
          </span>
          <span class="summary-chip"><%= @setting.apply_mode || "next workspace hook" %></span>
          <span class="summary-chip summary-chip-value"><%= setting_value_preview(@setting.effective_value) %></span>
        </div>
      </:meta>

      <div class="stack-sm">
        <p class="setting-card-copy"><%= @setting.description %></p>

        <DashboardComponents.key_value_list
          class="setting-card-details"
          items={[
            %{label: "Applies", value: @setting.apply_mode || "next workspace hook"},
            %{label: "Current", value: pretty_value(@setting.effective_value)},
            %{label: "Environment", value: pretty_value(@setting.env_value)},
            %{label: "Default", value: pretty_value(@setting.default_value)}
          ]}
        />

        <form phx-submit="update_github_access_setting" class="stack-sm">
          <input type="hidden" name="path" value={@setting.path} />
          <.github_setting_input setting={@setting} operator_authenticated={@operator_authenticated} />
          <div class="button-row">
            <button type="submit" class="primary-button" disabled={!@operator_authenticated} phx-disable-with="Applying...">
              Apply
            </button>
            <button
              type="button"
              class="secondary-button"
              phx-click="reset_github_access_setting"
              phx-value-path={@setting.path}
              disabled={!@operator_authenticated}
              phx-disable-with="Resetting..."
            >
              Reset
            </button>
          </div>
        </form>
      </div>
    </DashboardComponents.disclosure_panel>
    """
  end

  attr(:setting, :map, required: true)
  attr(:operator_authenticated, :boolean, default: false)

  defp github_setting_input(assigns) do
    case github_setting_type(assigns.setting) do
      "enum" ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"github-setting-#{@setting.path}"}>Value</label>
          <select
            id={"github-setting-#{@setting.path}"}
            name="value"
            class="field-select"
            disabled={!@operator_authenticated}
          >
            <option :for={value <- @setting.options || []} value={value} selected={editable_value_string(@setting) == value}><%= value %></option>
          </select>
        </div>
        """

      _ ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"github-setting-#{@setting.path}"}>Value</label>
          <input
            id={"github-setting-#{@setting.path}"}
            name="value"
            type={github_setting_input_type(@setting)}
            value={editable_value_string(@setting)}
            class="field-input"
            disabled={!@operator_authenticated}
          />
        </div>
        """
    end
  end

  defp settings_page(assigns) do
    ~H"""
    <section class="stack-lg">
      <%!-- Row 1: Codex auth + GitHub token side by side --%>
      <section class="settings-top-grid">
        <DashboardComponents.section_frame
          kicker="Codex auth"
          title="Device login"
          copy="Start a device-code login flow and finish the browser step from any machine."
        >
          <DashboardComponents.key_value_list
            items={[
              %{label: "Phase", value: @payload.codex_auth.phase || "unknown"},
              %{label: "Status", value: @payload.codex_auth.status_summary || "status unknown"},
              %{label: "Authenticated", value: yes_no_label(@payload.codex_auth.authenticated)},
              %{label: "Last checked", value: @payload.codex_auth.status_checked_at || "n/a"}
            ]}
          />

          <%= if @payload.codex_auth.verification_uri do %>
            <div class="stack-sm mt-3">
              <p class="field-label">Verification URL</p>
              <p class="mono-wrap text-sm"><%= @payload.codex_auth.verification_uri %></p>
              <DashboardComponents.copy_button label="Copy URL" value={@payload.codex_auth.verification_uri} />
            </div>
          <% end %>

          <%= if @payload.codex_auth.user_code do %>
            <div class="stack-sm mt-2">
              <p class="field-label">User code</p>
              <p class="mono-wrap text-sm font-semibold"><%= @payload.codex_auth.user_code %></p>
              <DashboardComponents.copy_button label="Copy Code" value={@payload.codex_auth.user_code} />
            </div>
          <% end %>

          <div class="button-row mt-3">
            <button type="button" class="secondary-button" phx-click="refresh_codex_auth_status">Refresh status</button>
            <button type="button" class="primary-button" phx-click="start_codex_device_auth" disabled={!@operator_authenticated} phx-disable-with="Starting...">Start login</button>
            <button type="button" class="secondary-button" phx-click="cancel_codex_device_auth" disabled={!@operator_authenticated} phx-disable-with="Cancelling...">Cancel flow</button>
          </div>
        </DashboardComponents.section_frame>

        <DashboardComponents.section_frame
          kicker="GitHub secret"
          title="Write-only token"
          copy="Store a GitHub token for clone, fetch, push, and optional GitHub tracker auth."
        >
          <%= if @payload.github_access_error do %>
            <DashboardComponents.empty_state title="Token metadata unavailable" copy="GitHub token metadata could not be loaded." />
          <% else %>
            <DashboardComponents.key_value_list
              items={[
                %{label: "Configured", value: yes_no_label(@payload.github_access.token.configured)},
                %{label: "Source", value: @payload.github_access.token.source_label || "None"},
                %{label: "Updated", value: @payload.github_access.token.updated_at || "n/a"},
                %{label: "Cleared", value: @payload.github_access.token.cleared_at || "n/a"}
              ]}
            />

            <form phx-submit="set_github_access_token" class="stack-sm" class="mt-3">
              <div class="field-group">
                <label for="github-token" class="field-label">GitHub token</label>
                <input id="github-token" type="password" name="token" value="" autocomplete="new-password" class="field-input" disabled={!@operator_authenticated} />
              </div>
              <div class="button-row">
                <button type="submit" class="primary-button" disabled={!@operator_authenticated} phx-disable-with="Storing...">Store token</button>
                <button type="button" class="secondary-button" phx-click="clear_github_access_token" disabled={!@operator_authenticated} phx-disable-with="Clearing...">Clear token</button>
              </div>
            </form>
          <% end %>
        </DashboardComponents.section_frame>
      </section>

      <%!-- Full width: GitHub workspace settings --%>
      <DashboardComponents.section_frame
        kicker="GitHub workspace access"
        title="Repo bootstrap and landing"
        copy="Manage the repository URL and Git identity used by workspace hooks without editing Docker env files."
        collapsible={true}
        open={true}
      >
        <%= if @payload.github_access_error do %>
          <DashboardComponents.empty_state title="GitHub access unavailable" copy={"GitHub access settings are unavailable: #{@payload.github_access_error}"} />
        <% else %>
          <ul class="settings-card-grid card-list">
            <li :for={setting <- @payload.github_access.settings}>
              <.github_setting_control setting={setting} operator_authenticated={@operator_authenticated} />
            </li>
          </ul>
        <% end %>
      </DashboardComponents.section_frame>

      <%!-- Full width: Runtime settings --%>
      <DashboardComponents.section_frame
        id="runtime-settings"
        kicker="Runtime controls"
        title="UI-managed settings"
        copy="Selected runtime knobs can be changed here without editing WORKFLOW.md or restarting the process."
        collapsible={true}
        open={true}
      >
        <%= if @payload.settings_error do %>
          <DashboardComponents.empty_state title="Runtime settings unavailable" copy={"Runtime settings are unavailable: #{@payload.settings_error}"} />
        <% else %>
          <div class="stack-sm">
            <DashboardComponents.disclosure_panel
              :for={{group, settings} <- grouped_settings(@payload.settings)}
              title={group}
              copy={"#{length(settings)} editable setting#{plural(length(settings))}"}
              class="settings-group-panel"
            >
              <ul class="settings-card-grid card-list">
                <li :for={setting <- settings}>
                  <.runtime_setting_control setting={setting} operator_authenticated={@operator_authenticated} />
                </li>
              </ul>
            </DashboardComponents.disclosure_panel>
          </div>
        <% end %>
      </DashboardComponents.section_frame>

      <%!-- Bottom row: Audit + Posture side by side --%>
      <section class="settings-bottom-grid">
        <DashboardComponents.section_frame
          kicker="Settings audit"
          title="Recent changes"
          copy="Every operator-managed change is persisted so the current posture is explainable."
        >
          <%= if recent_operator_changes(@payload) == [] do %>
            <DashboardComponents.empty_state title="No operator changes yet" copy="Runtime and GitHub changes will appear here once they are applied." />
          <% else %>
            <ul class="stack-sm card-list">
              <li :for={entry <- recent_operator_changes(@payload)} class="list-card">
                <div class="list-card-head"><strong><%= entry["action"] || "update" %></strong><span class="mono"><%= entry["recorded_at"] || "n/a" %></span></div>
                <p class="list-card-copy"><%= Enum.join(entry["paths"] || [], ", ") %></p>
                <p class="muted-copy"><%= entry["actor"] || "operator" %><%= if blank_to_nil(entry["reason"]), do: " / #{entry["reason"]}", else: "" %></p>
              </li>
            </ul>
          <% end %>
        </DashboardComponents.section_frame>

        <DashboardComponents.section_frame
          kicker="Safety posture"
          title="Operator posture"
          copy="Approval pressure, active overrides, and current auth state."
        >
          <DashboardComponents.key_value_list
            items={[
              %{label: "Pending approvals", value: @payload.counts.pending_approvals},
              %{label: "Active overrides", value: @payload.counts.active_overrides},
              %{label: "Guardrail rules", value: @payload.counts.guardrail_rules},
              %{label: "Operator mode", value: if(@operator_authenticated, do: "authenticated", else: "token required")}
            ]}
          />
        </DashboardComponents.section_frame>
      </section>
    </section>
    """
  end

  defp runs_page(assigns) do
    ~H"""
    <section class="stack-lg">
        <DashboardComponents.section_frame
          kicker="Search and audit"
          title="Run explorer"
          copy="Search completed runs by issue, status, efficiency signal, or workspace metadata."
        >
          <form phx-change="update_run_filters" class="stack-md">
            <input type="hidden" name="view" value={@run_view} />
            <DashboardComponents.filter_toolbar
              label="Filter runs"
              copy="Share the current audit slice through URL params without storing server-side views."
            >
              <div class="field-group field-group-search">
                <label for="run-filter-query" class="field-label">Search</label>
                <input id="run-filter-query" type="search" name="q" value={@run_filters["q"]} class="field-input" />
              </div>

              <div class="field-group">
                <label for="run-filter-status" class="field-label">Status</label>
                <select id="run-filter-status" name="status" class="field-select">
                  <option value="">All statuses</option>
                  <option :for={value <- filter_values_with_selected(unique_run_statuses(@payload.completed_runs), @run_filters["status"])} value={value} selected={@run_filters["status"] == value}>
                    <%= value %>
                  </option>
                </select>
              </div>

              <div class="field-group">
                <label for="run-filter-sort" class="field-label">Sort</label>
                <select id="run-filter-sort" name="sort" class="field-select">
                  <option value="recent" selected={@run_filters["sort"] == "recent"}>Most recent</option>
                  <option value="tokens" selected={@run_filters["sort"] == "tokens"}>Highest tokens</option>
                  <option value="uncached" selected={@run_filters["sort"] == "uncached"}>Highest uncached</option>
                  <option value="runtime" selected={@run_filters["sort"] == "runtime"}>Longest runtime</option>
                  <option value="efficiency" selected={@run_filters["sort"] == "efficiency"}>Efficiency watchlist</option>
                </select>
              </div>

              <:actions>
                <div class="toolbar-actions-stack">
                  <div class="segmented-control" role="tablist" aria-label="Run views">
                    <.link patch={page_path(:runs, Map.put(@run_filters, "view", "history"))} class={run_view_link_class(@run_view == "history")}>History</.link>
                    <.link patch={page_path(:runs, Map.put(@run_filters, "view", "expensive"))} class={run_view_link_class(@run_view == "expensive")}>Expensive</.link>
                    <.link patch={page_path(:runs, Map.put(@run_filters, "view", "cheap"))} class={run_view_link_class(@run_view == "cheap")}>Cheap wins</.link>
                    <.link patch={page_path(:runs, Map.put(@run_filters, "view", "rollups"))} class={run_view_link_class(@run_view == "rollups")}>Issue efficiency</.link>
                  </div>
                  <button type="button" class="secondary-button" phx-click="clear_run_filters">Reset filters</button>
                </div>
              </:actions>
            </DashboardComponents.filter_toolbar>
          </form>

          <%= if @run_view == "rollups" do %>
            <%= if @filtered_rollups == [] do %>
              <DashboardComponents.empty_state title="No rollups match these filters" copy="Broaden the filter set or wait for more persisted runs to accumulate." />
            <% else %>
              <div class="table-scroll">
                <table class="data-table">
                  <caption class="sr-only">Issue efficiency rollups with latest status, run count, average runtime, total tokens, and efficiency signals</caption>
                  <thead>
                    <tr><th>Issue</th><th>Latest</th><th>Runs</th><th>Avg runtime</th><th>Total tokens</th><th>Signals</th></tr>
                  </thead>
                  <tbody>
                    <tr :for={rollup <- @filtered_rollups}>
                      <td><div class="cell-stack"><strong class="cell-primary"><%= rollup["issue_identifier"] %></strong><span class="cell-secondary"><%= rollup["latest_run_id"] || "no linked run" %></span></div></td>
                      <td><span class={state_badge_class(rollup["latest_status"] || "completed")}><%= rollup["latest_status"] || "completed" %></span></td>
                      <td class="numeric"><%= rollup["run_count"] || 0 %></td>
                      <td class="numeric"><%= format_duration_ms(rollup["avg_duration_ms"]) %></td>
                      <td class="numeric"><%= format_int(rollup["total_tokens"] || 0) %></td>
                      <td><div class="cell-stack"><span class={efficiency_badge_class(rollup["classification"])}><%= rollup["primary_label"] || "Normal" %></span><span class="cell-secondary"><%= efficiency_flags_label(rollup) %></span></div></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% else %>
            <%= if @filtered_runs == [] do %>
              <DashboardComponents.empty_state title="No completed runs match these filters" copy="Broaden the query or switch views to expensive runs, cheap wins, or issue efficiency." />
            <% else %>
              <div class="table-scroll">
                <table class="data-table">
                  <caption class="sr-only">Persisted runs with status, timing, token usage, efficiency, git context, and link to run details</caption>
                  <thead>
                    <tr><th>Issue</th><th>Status</th><th>Ended</th><th>Runtime</th><th>Tokens</th><th>Efficiency</th><th>Git</th><th></th></tr>
                  </thead>
                  <tbody>
                    <tr :for={run <- @filtered_runs}>
                      <td><div class="cell-stack"><strong class="cell-primary"><%= run["issue_identifier"] %></strong><span class="cell-secondary mono"><%= run["run_id"] %></span></div></td>
                      <td><span class={state_badge_class(run["status"] || "completed")}><%= run["status"] || "completed" %></span></td>
                      <td class="mono"><%= run["ended_at"] || "n/a" %></td>
                      <td class="numeric"><%= format_duration_ms(run["duration_ms"]) %></td>
                      <td class="numeric"><div class="cell-stack"><span class="cell-primary"><%= format_int(get_in(run, ["tokens", "total_tokens"]) || 0) %></span><span class="cell-secondary">uncached <%= format_int(get_in(run, ["tokens", "uncached_input_tokens"]) || 0) %></span></div></td>
                      <td><div class="cell-stack"><span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}><%= efficiency_label(run) %></span><span class="cell-secondary"><%= efficiency_flags_label(run) %></span></div></td>
                      <td>
                        <div class="cell-stack">
                          <span class="cell-primary"><%= run_git_label(run) %></span>
                          <span class="cell-secondary"><%= run_changed_files_label(run) %></span>
                          <details class="table-inline-disclosure">
                            <summary class="table-inline-summary">More context</summary>
                            <div class="table-inline-body">
                              <p class="mono-wrap"><%= run["workspace_path"] || "n/a" %></p>
                              <p class="muted-copy">session <%= run["session_id"] || "n/a" %></p>
                            </div>
                          </details>
                        </div>
                      </td>
                      <td class="table-actions"><.link href={run_path(run)} class="inline-link">Run details</.link></td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          <% end %>
        </DashboardComponents.section_frame>

        <%!-- Collapsible sections — each gets its own full-width row --%>
        <DashboardComponents.section_frame kicker="Efficiency watchlist" title="Expensive runs" copy="Recent persisted runs that look meaningfully expensive, not just large because of cached context." collapsible={true} open={@run_view == "expensive" or @run_view == "history"}>
          <%= if @payload.expensive_runs == [] do %>
            <DashboardComponents.empty_state title="No expensive runs" copy="No recent expensive runs were detected." />
          <% else %>
            <ul class="stack-sm card-list">
              <li :for={run <- @payload.expensive_runs} class="list-card">
                <div class="list-card-head"><strong><%= run["issue_identifier"] %></strong><span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}><%= efficiency_label(run) %></span></div>
                <p class="list-card-copy"><%= efficiency_flags_label(run) %></p>
                <p class="muted-copy">uncached <%= format_int(get_in(run, ["tokens", "uncached_input_tokens"]) || 0) %> / retry <%= run["retry_attempt"] || 0 %></p>
                <.link href={run_path(run)} class="inline-link">Run details</.link>
              </li>
            </ul>
          <% end %>
        </DashboardComponents.section_frame>

        <DashboardComponents.section_frame kicker="Cheap wins" title="Cheap wins" copy="Runs that landed useful changes with low uncached spend." collapsible={true} open={@run_view == "cheap" or @run_view == "history"}>
          <%= if @payload.cheap_wins == [] do %>
            <DashboardComponents.empty_state title="No cheap wins yet" copy="Runs flagged as efficient will appear here." />
          <% else %>
            <ul class="stack-sm card-list">
              <li :for={run <- @payload.cheap_wins} class="list-card">
                <div class="list-card-head"><strong><%= run["issue_identifier"] %></strong><span class={efficiency_badge_class(get_in(run, ["efficiency", "classification"]))}><%= efficiency_label(run) %></span></div>
                <p class="list-card-copy"><%= run_changed_files_label(run) %></p>
                <p class="muted-copy">total <%= format_int(get_in(run, ["tokens", "total_tokens"]) || 0) %></p>
                <.link href={run_path(run)} class="inline-link">Run details</.link>
              </li>
            </ul>
          <% end %>
        </DashboardComponents.section_frame>
    </section>
    """
  end

  defp operator_access_panel(assigns) do
    ~H"""
    <DashboardComponents.section_frame
      kicker="Operator control"
      title="Operator access"
      copy="Enter the operator token once for this browser tab. It stays in LiveView state only and is never persisted."
    >
      <section class="split-grid-tight">
        <form phx-change="update_operator_token" class="stack-sm">
          <div class="field-group">
            <label for="dashboard-operator-token" class="field-label">Operator token</label>
            <input id="dashboard-operator-token" type="password" name="operator_token" value={@operator_token} autocomplete="current-password" class="field-input" />
          </div>
        </form>

        <DashboardComponents.key_value_list
          items={[
            %{label: "Status", value: if(@operator_authenticated, do: "authenticated", else: "token required")},
            %{label: "Configured", value: yes_no_label(operator_token_configured?())},
            %{label: "Storage", value: "LiveView session state only"}
          ]}
        />
      </section>
    </DashboardComponents.section_frame>
    """
  end

  defp approval_detail(assigns) do
    ~H"""
    <%= if @selected_approval do %>
      <DashboardComponents.section_frame kicker="Focused review" title={@selected_approval.issue_identifier} copy={@selected_approval.summary || "approval pending operator review"} class="approval-workbench">
        <DashboardComponents.key_value_list
          items={[
            %{label: "Risk", value: @selected_approval.risk_level || "review"},
            %{label: "Action", value: @selected_approval.action_type || @selected_approval.method || "n/a"},
            %{label: "Requested", value: @selected_approval.requested_at || "n/a"},
            %{label: "Worker", value: @selected_approval.worker_host || "local"},
            %{label: "Reason", value: @selected_approval.reason || "operator review required"}
          ]}
        />

        <%= if @selected_approval.session_id do %>
          <div class="button-row"><DashboardComponents.copy_button label="Copy Session ID" value={@selected_approval.session_id} /></div>
        <% end %>

        <%= if approval_detail_preview(@selected_approval) != [] do %>
          <DashboardComponents.disclosure_panel title="Context preview" copy="Command, cwd, and path details captured for this review." open={true}>
            <ul class="detail-list"><li :for={line <- approval_detail_preview(@selected_approval)}><%= line %></li></ul>
          </DashboardComponents.disclosure_panel>
        <% end %>

        <%= if get_in(@selected_approval, [:explanation, "evaluation", "reason"]) do %>
          <DashboardComponents.disclosure_panel title="Policy explanation" copy="Why the policy engine requested operator review.">
            <p class="list-card-copy"><%= get_in(@selected_approval, [:explanation, "evaluation", "reason"]) %></p>
          </DashboardComponents.disclosure_panel>
        <% end %>

        <DashboardComponents.disclosure_panel title="Raw approval details" copy="Structured metadata, fingerprint, and persisted request payload.">
          <DashboardComponents.key_value_list
            items={[
              %{label: "Fingerprint", value: @selected_approval.fingerprint || "n/a"},
              %{label: "Method", value: @selected_approval.method || "n/a"},
              %{label: "Session", value: @selected_approval.session_id || "n/a"}
            ]}
          />
          <pre class="code-panel code-panel-compact"><%= pretty_value(@selected_approval.details || %{}) %></pre>
        </DashboardComponents.disclosure_panel>

        <form phx-submit="guardrail_decide" class="stack-sm">
          <input type="hidden" name="approval_id" value={@selected_approval.id} />
          <div class="field-group">
            <label for="approval-reason" class="field-label">Decision note</label>
            <textarea id="approval-reason" name="reason" rows="4" class="field-textarea" placeholder="Optional context for the audit log"></textarea>
          </div>
          <div class="button-row">
            <button type="submit" class="primary-button" name="decision" value="allow_once" disabled={!@operator_authenticated} phx-disable-with="Allowing...">Allow once</button>
            <button type="submit" class="secondary-button" name="decision" value="allow_for_session" disabled={!@operator_authenticated} phx-disable-with="Allowing...">Allow for run</button>
            <button type="submit" class="secondary-button" name="decision" value="allow_via_rule" disabled={!@operator_authenticated} phx-disable-with="Creating...">Always allow</button>
            <button type="submit" class="secondary-button secondary-button-danger" name="decision" value="deny" disabled={!@operator_authenticated} phx-disable-with="Denying...">Deny</button>
          </div>
        </form>

        <DashboardComponents.disclosure_panel title="Override access posture" copy="Escalate access only if the underlying rule or one-time decision is insufficient.">
          <div class="button-row">
            <button :if={@selected_approval.run_id} type="button" class="secondary-button" phx-click="enable_run_full_access" phx-value-run_id={@selected_approval.run_id} disabled={!@operator_authenticated} phx-disable-with="Enabling...">Full access for run</button>
            <button type="button" class="secondary-button" phx-click="enable_workflow_full_access" disabled={!@operator_authenticated} phx-disable-with="Enabling...">Full access for workflow</button>
          </div>
        </DashboardComponents.disclosure_panel>
      </DashboardComponents.section_frame>
    <% else %>
      <DashboardComponents.section_frame kicker="Focused review" title="Select an approval" copy="Pick an approval from the queue to inspect its command context, explanation, and available operator actions.">
        <DashboardComponents.empty_state title="No approval selected" copy="Choose a queue row to open the decision surface." />
      </DashboardComponents.section_frame>
    <% end %>
    """
  end

  defp active_overrides_panel(assigns) do
    ~H"""
    <DashboardComponents.section_frame
      kicker="Safety posture"
      title="Active overrides"
      copy="Run-scoped and workflow-wide full-access overrides currently weakening the default guardrail posture."
      collapsible={true}
      open={@payload.guardrail_overrides != []}
    >
      <%= if @payload.guardrail_overrides == [] do %>
        <DashboardComponents.empty_state
          title="No active overrides"
          copy="No run-level or workflow-wide override is active right now."
        />
      <% else %>
        <div class="table-scroll">
          <table class="data-table data-table-compact">
            <caption class="sr-only">Active full-access overrides with scope, reason, created time, expiry, and disable action</caption>
            <thead>
              <tr>
                <th>Scope</th>
                <th>Reason</th>
                <th>Created</th>
                <th>Expires</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={override <- @payload.guardrail_overrides}>
                <% scope = guardrail_value(override, :scope) || "n/a" %>
                <% scope_key = guardrail_value(override, :scope_key) || "n/a" %>
                <td>
                  <div class="cell-stack">
                    <strong class="cell-primary"><%= scope %></strong>
                    <span class="cell-secondary mono"><%= scope_key %></span>
                  </div>
                </td>
                <td><%= guardrail_value(override, :reason) || "operator override" %></td>
                <td class="mono"><%= guardrail_value(override, :created_at) || "n/a" %></td>
                <td class="mono"><%= guardrail_value(override, :expires_at) || "manual disable" %></td>
                <td class="table-actions">
                  <button
                    :if={scope == "workflow"}
                    type="button"
                    class="secondary-button"
                    phx-click="disable_workflow_full_access"
                    disabled={!@operator_authenticated}
                    phx-disable-with="Disabling..."
                  >
                    Disable
                  </button>
                  <button
                    :if={scope != "workflow" and scope_key != "n/a"}
                    type="button"
                    class="secondary-button"
                    phx-click="disable_run_full_access"
                    phx-value-run_id={scope_key}
                    disabled={!@operator_authenticated}
                    phx-disable-with="Disabling..."
                  >
                    Disable
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </DashboardComponents.section_frame>
    """
  end

  defp guardrail_rules_panel(assigns) do
    ~H"""
    <DashboardComponents.section_frame
      kicker="Policy"
      title="Guardrail rules"
      copy="Persisted rules that shape approval decisions and long-lived access posture."
      collapsible={true}
    >
      <%= if @payload.guardrail_rules == [] do %>
        <DashboardComponents.empty_state
          title="No persisted rules"
          copy="There are no saved allow or deny rules on record."
        />
      <% else %>
        <div class="table-scroll">
          <table class="data-table data-table-compact">
            <caption class="sr-only">Persisted guardrail rules with scope, action, state, description, remaining uses, and operator actions</caption>
            <thead>
              <tr>
                <th>Scope</th>
                <th>Action</th>
                <th>State</th>
                <th>Description</th>
                <th>Uses</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={rule <- @payload.guardrail_rules}>
                <% scope = guardrail_value(rule, :scope) || "n/a" %>
                <% scope_key = guardrail_value(rule, :scope_key) || "n/a" %>
                <% lifecycle_state = guardrail_value(rule, :lifecycle_state) || if(guardrail_rule_active?(rule), do: "active", else: "inactive") %>
                <% rule_id = guardrail_value(rule, :id) %>
                <td>
                  <div class="cell-stack">
                    <strong class="cell-primary"><%= scope %></strong>
                    <span class="cell-secondary mono"><%= scope_key %></span>
                  </div>
                </td>
                <td><span class="mono"><%= guardrail_value(rule, :action_type) || "n/a" %></span></td>
                <td><span class={state_badge_class(lifecycle_state)}><%= lifecycle_state %></span></td>
                <td>
                  <DashboardComponents.disclosure_panel
                    title={guardrail_value(rule, :description) || "guardrail rule"}
                    copy="Open to inspect the persisted rule match payload."
                    class="table-disclosure"
                  >
                    <pre class="code-panel code-panel-compact"><%= pretty_value(guardrail_value(rule, :match)) %></pre>
                  </DashboardComponents.disclosure_panel>
                </td>
                <td class="numeric"><%= remaining_uses_label(guardrail_value(rule, :remaining_uses)) %></td>
                <td class="table-actions">
                  <button
                    :if={rule_id && not guardrail_rule_active?(rule)}
                    type="button"
                    class="secondary-button"
                    phx-click="enable_guardrail_rule"
                    phx-value-rule_id={rule_id}
                    disabled={!@operator_authenticated}
                    phx-disable-with="Enabling..."
                  >
                    Enable
                  </button>
                  <button
                    :if={rule_id && guardrail_rule_active?(rule)}
                    type="button"
                    class="secondary-button"
                    phx-click="disable_guardrail_rule"
                    phx-value-rule_id={rule_id}
                    disabled={!@operator_authenticated}
                    phx-disable-with="Disabling..."
                  >
                    Disable
                  </button>
                  <button
                    :if={rule_id}
                    type="button"
                    class="secondary-button secondary-button-danger"
                    phx-click="expire_guardrail_rule"
                    phx-value-rule_id={rule_id}
                    disabled={!@operator_authenticated}
                    phx-disable-with="Expiring..."
                  >
                    Expire
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
    </DashboardComponents.section_frame>
    """
  end

  defp dashboard_page(:overview) do
    %{
      key: :overview,
      nav_label: "Overview",
      title: "Operations Dashboard",
      copy: "A triage-first control surface for live execution, retry pressure, and the approvals queue.",
      focus: "What needs attention now, without losing the full operational picture.",
      next_step: "Clear operator-blocked work first, then inspect retries and active sessions."
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

  defp page_path(page, params \\ %{})
  defp page_path(:overview, params), do: build_page_path("/", sanitize_page_params(:overview, params))
  defp page_path(:approvals, params), do: build_page_path("/approvals", sanitize_page_params(:approvals, params))
  defp page_path(:settings, params), do: build_page_path("/settings", sanitize_page_params(:settings, params))
  defp page_path(:runs, params), do: build_page_path("/runs", sanitize_page_params(:runs, params))

  defp build_page_path(base, params) when params == %{}, do: base
  defp build_page_path(base, params), do: base <> "?" <> URI.encode_query(params)

  defp navigation_items(page, payload) do
    counts = payload_counts(payload)

    [
      %{label: "Overview", patch: page_path(:overview), current: page.key == :overview, meta: counts.running},
      %{label: "Approvals", patch: page_path(:approvals), current: page.key == :approvals, meta: counts.pending_approvals},
      %{label: "Settings", patch: page_path(:settings), current: page.key == :settings, meta: ui_override_count(payload)},
      %{label: "Runs", patch: page_path(:runs), current: page.key == :runs, meta: counts.completed_runs}
    ]
  end

  defp utility_items(:overview), do: [%{label: "State API", href: "/api/v1/state"}, %{label: "Rollups API", href: "/api/v1/rollups"}]
  defp utility_items(:approvals), do: [%{label: "Approvals API", href: "/api/v1/guardrails/approvals"}, %{label: "Rules API", href: "/api/v1/guardrails/rules"}]
  defp utility_items(:settings), do: [%{label: "Settings API", href: "/api/v1/settings"}, %{label: "GitHub API", href: "/api/v1/github"}]
  defp utility_items(:runs), do: [%{label: "State API", href: "/api/v1/state"}, %{label: "Rollups API", href: "/api/v1/rollups"}]
  defp utility_items(_page), do: utility_items(:overview)

  defp page_header_actions(page, payload) do
    counts = payload_counts(payload)

    case page.key do
      :overview ->
        [%{label: "Open approvals", patch: page_path(:approvals), primary: counts.pending_approvals > 0}, %{label: "Run explorer", patch: page_path(:runs)}]

      :approvals ->
        [%{label: "Guardrail API", href: "/api/v1/guardrails/approvals"}, %{label: "Safety posture", patch: page_path(:settings)}]

      :settings ->
        [%{label: "Settings API", href: "/api/v1/settings"}, %{label: "GitHub API", href: "/api/v1/github"}]

      :runs ->
        [%{label: "Expensive runs", patch: page_path(:runs, %{"view" => "expensive"})}, %{label: "Issue efficiency", patch: page_path(:runs, %{"view" => "rollups"})}]
    end
  end

  defp page_header_meta(page, payload, now) do
    [
      %{label: "Generated", value: payload.generated_at || DateTime.to_iso8601(now)},
      %{label: "Storage", value: Map.get(payload, :storage_backend, "n/a")},
      %{label: "Focus", value: page.focus},
      %{label: "Next step", value: page.next_step}
    ]
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

  defp page_metrics(page, payload, now, filtered_approvals, filtered_runs, filtered_rollups, run_filters, operator_authenticated) do
    counts = payload_counts(payload)

    case page.key do
      :overview ->
        [
          %{label: "Live work", value: counts.running, detail: "active sessions"},
          %{label: "Pending approvals", value: counts.pending_approvals, detail: "operator decisions waiting"},
          %{label: "Retry queue", value: counts.retrying, detail: "issues scheduled to retry"},
          %{label: "Total tokens", value: format_int(payload.codex_totals.total_tokens || 0), detail: "live + completed"},
          %{label: "Runtime", value: format_runtime_seconds(total_runtime_seconds(payload, now)), detail: "aggregate Codex time"},
          %{label: "Recent completed", value: counts.completed_runs, detail: "persisted runs"}
        ]

      :approvals ->
        [
          %{label: "Filtered queue", value: length(filtered_approvals), detail: "matching current filters"},
          %{label: "High risk", value: count_by_risk(filtered_approvals, "high"), detail: "high / critical requests"},
          %{label: "Overrides", value: counts.active_overrides, detail: "full-access currently active"},
          %{label: "Rules", value: counts.guardrail_rules, detail: "#{counts.active_guardrail_rules} active"},
          %{label: "Operator mode", value: if(operator_authenticated, do: "Live", else: "Locked"), detail: "token gate"},
          %{label: "Retrying", value: counts.retrying, detail: "issues under backoff"}
        ]

      :settings ->
        [
          %{label: "UI overrides", value: ui_override_count(payload), detail: "runtime settings overridden"},
          %{label: "GitHub overrides", value: github_override_count(payload), detail: "workspace values overridden"},
          %{label: "Token", value: yes_no_label(get_in(payload, [:github_access, :token, :configured])), detail: "GitHub credential"},
          %{label: "Codex auth", value: payload.codex_auth.phase || "unknown", detail: payload.codex_auth.status_summary || "status unknown"},
          %{label: "Settings history", value: length(payload.settings_history || []), detail: "runtime change audit"},
          %{label: "GitHub history", value: length(get_in(payload, [:github_access, :history]) || []), detail: "workspace change audit"}
        ]

      :runs ->
        [
          %{label: "Filtered slice", value: if(run_filters["view"] == "rollups", do: length(filtered_rollups), else: length(filtered_runs)), detail: "shared via URL state"},
          %{label: "Expensive runs", value: counts.expensive_runs, detail: "advisory watchlist"},
          %{label: "Cheap wins", value: counts.cheap_wins, detail: "efficient landed runs"},
          %{label: "Issue efficiency", value: counts.issue_rollups, detail: "aggregate rollups"},
          %{label: "Completed", value: counts.completed_runs, detail: "persisted runs"},
          %{label: "Total tokens", value: format_int(sum_run_tokens(filtered_runs, payload.completed_runs, run_filters["view"])), detail: "current filtered slice"}
        ]
    end
  end

  defp run_view_link_class(true), do: "segment-link segment-link-current"
  defp run_view_link_class(false), do: "segment-link"

  defp rebuild_page_state(socket, params) do
    payload = socket.assigns.payload
    guardrail_filters = normalize_guardrail_filters(params)
    filtered_approvals = filtered_pending_approvals(payload.pending_approvals || [], guardrail_filters)
    selected_approval = select_approval(filtered_approvals, guardrail_filters["selected"])
    run_filters = normalize_run_filters(params)
    filtered_runs = filtered_runs(payload.completed_runs || [], run_filters)
    filtered_rollups = filtered_rollups(payload.issue_rollups || [], run_filters)

    socket
    |> assign(:guardrail_filters, guardrail_filters)
    |> assign(:filtered_approvals, filtered_approvals)
    |> assign(:selected_approval, selected_approval)
    |> assign(:run_filters, run_filters)
    |> assign(:filtered_runs, filtered_runs)
    |> assign(:filtered_rollups, filtered_rollups)
    |> assign(:run_view, run_filters["view"])
  end

  defp refresh_dashboard(socket, success_message) do
    socket
    |> assign(:payload, load_payload())
    |> assign(:now, current_time())
    |> rebuild_page_state(socket.assigns.current_params)
    |> put_flash(:info, success_message)
  end

  defp default_guardrail_filters do
    %{"q" => "", "issue_identifier" => "", "action_type" => "", "risk_level" => "", "worker_host" => "", "selected" => ""}
  end

  defp normalize_guardrail_filters(params) when is_map(params) do
    default_guardrail_filters()
    |> Map.merge(%{
      "q" => blank_to_empty(params["q"]),
      "issue_identifier" => blank_to_empty(params["issue_identifier"]),
      "action_type" => blank_to_empty(params["action_type"]),
      "risk_level" => blank_to_empty(params["risk_level"]),
      "worker_host" => blank_to_empty(params["worker_host"]),
      "selected" => blank_to_empty(params["selected"])
    })
  end

  defp normalize_guardrail_filters(_params), do: default_guardrail_filters()

  defp default_run_filters do
    %{"q" => "", "status" => "", "sort" => "recent", "view" => "history"}
  end

  defp normalize_run_filters(params) when is_map(params) do
    default_run_filters()
    |> Map.merge(%{
      "q" => blank_to_empty(params["q"]),
      "status" => blank_to_empty(params["status"]),
      "sort" => normalize_run_sort(params["sort"]),
      "view" => normalize_run_view(params["view"])
    })
  end

  defp normalize_run_filters(_params), do: default_run_filters()

  defp normalize_run_sort("tokens"), do: "tokens"
  defp normalize_run_sort("uncached"), do: "uncached"
  defp normalize_run_sort("runtime"), do: "runtime"
  defp normalize_run_sort("efficiency"), do: "efficiency"
  defp normalize_run_sort(_value), do: "recent"

  defp normalize_run_view("expensive"), do: "expensive"
  defp normalize_run_view("cheap"), do: "cheap"
  defp normalize_run_view("rollups"), do: "rollups"
  defp normalize_run_view(_value), do: "history"

  defp sanitize_page_params(:overview, _params), do: %{}

  defp sanitize_page_params(:approvals, params) when is_map(params) do
    params |> Map.take(@approval_param_keys) |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end) |> Enum.into(%{})
  end

  defp sanitize_page_params(:settings, _params), do: %{}

  defp sanitize_page_params(:runs, params) when is_map(params) do
    params
    |> Map.take(@run_param_keys)
    |> Enum.reject(fn
      {"sort", "recent"} -> true
      {"view", "history"} -> true
      {_key, value} -> is_nil(value) or value == ""
    end)
    |> Enum.into(%{})
  end

  defp sanitize_page_params(_page, _params), do: %{}

  defp filtered_pending_approvals(approvals, filters) when is_list(approvals) and is_map(filters) do
    approvals
    |> Enum.filter(fn approval ->
      filter_match?(approval.issue_identifier, filters["issue_identifier"]) and
        filter_match?(approval.action_type, filters["action_type"]) and
        filter_match?(approval.risk_level, filters["risk_level"]) and
        filter_match?(approval.worker_host, filters["worker_host"]) and
        filter_query_match?(approval, filters["q"])
    end)
  end

  defp filtered_pending_approvals(approvals, _filters), do: approvals

  defp filtered_runs(runs, filters) when is_list(runs) and is_map(filters) do
    runs
    |> Enum.filter(&run_matches_status?(&1, filters["status"]))
    |> Enum.filter(&run_query_match?(&1, filters["q"]))
    |> Enum.filter(&run_matches_view?(&1, filters["view"]))
    |> sort_runs(filters["sort"])
  end

  defp filtered_runs(runs, _filters), do: runs

  defp filtered_rollups(rollups, filters) when is_list(rollups) and is_map(filters) do
    rollups
    |> Enum.filter(fn rollup ->
      filter_match?(rollup["latest_status"], filters["status"]) and rollup_query_match?(rollup, filters["q"])
    end)
    |> Enum.sort_by(fn rollup -> {-(rollup["run_count"] || 0), rollup["issue_identifier"] || ""} end)
  end

  defp filtered_rollups(rollups, _filters), do: rollups

  defp sort_runs(runs, "tokens"), do: Enum.sort_by(runs, fn run -> {-(get_in(run, ["tokens", "total_tokens"]) || 0), run["ended_at"] || ""} end)
  defp sort_runs(runs, "uncached"), do: Enum.sort_by(runs, fn run -> {-(get_in(run, ["tokens", "uncached_input_tokens"]) || 0), run["ended_at"] || ""} end)
  defp sort_runs(runs, "runtime"), do: Enum.sort_by(runs, fn run -> {-(run["duration_ms"] || 0), run["ended_at"] || ""} end)

  defp sort_runs(runs, "efficiency") do
    Enum.sort_by(runs, fn run ->
      score =
        case get_in(run, ["efficiency", "classification"]) do
          "expensive" -> 4
          "needs_attention" -> 3
          "context_window_heavy" -> 2
          "cheap_win" -> 0
          _ -> 1
        end

      {-score, -(get_in(run, ["tokens", "uncached_input_tokens"]) || 0), run["ended_at"] || ""}
    end)
  end

  defp sort_runs(runs, _sort), do: Enum.sort_by(runs, &(&1["ended_at"] || ""), :desc)

  defp run_matches_view?(_run, "history"), do: true
  defp run_matches_view?(run, "expensive"), do: get_in(run, ["efficiency", "classification"]) == "expensive"
  defp run_matches_view?(run, "cheap"), do: get_in(run, ["efficiency", "classification"]) == "cheap_win"
  defp run_matches_view?(_run, "rollups"), do: true
  defp run_matches_view?(_run, _view), do: true

  defp run_matches_status?(_run, ""), do: true
  defp run_matches_status?(_run, nil), do: true
  defp run_matches_status?(run, status), do: normalize_filter_value(run["status"]) == normalize_filter_value(status)

  defp run_query_match?(_run, ""), do: true
  defp run_query_match?(_run, nil), do: true

  defp run_query_match?(run, query) do
    haystack =
      [run["issue_identifier"], run["run_id"], run["status"], run["summary"], run_git_label(run), run_changed_files_label(run), efficiency_label(run), efficiency_flags_label(run)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(haystack, normalize_filter_value(query))
  end

  defp rollup_query_match?(_rollup, ""), do: true
  defp rollup_query_match?(_rollup, nil), do: true

  defp rollup_query_match?(rollup, query) do
    haystack = [rollup["issue_identifier"], rollup["latest_status"], rollup["primary_label"], efficiency_flags_label(rollup)] |> Enum.reject(&is_nil/1) |> Enum.join(" ") |> String.downcase()
    String.contains?(haystack, normalize_filter_value(query))
  end

  defp select_approval([], _selected), do: nil
  defp select_approval(approvals, ""), do: List.first(sort_approvals(approvals))
  defp select_approval(approvals, nil), do: List.first(sort_approvals(approvals))
  defp select_approval(approvals, selected_id) when is_list(approvals), do: Enum.find(approvals, &(to_string(&1.id) == to_string(selected_id))) || List.first(sort_approvals(approvals))

  defp sort_approvals(approvals) do
    Enum.sort_by(approvals, fn approval -> {-risk_sort_key(approval.risk_level), approval.requested_at || "", approval.issue_identifier || ""} end)
  end

  defp risk_sort_key(level) do
    case normalize_filter_value(level) do
      value when value in ["critical", "danger", "high"] -> 3
      value when value in ["medium", "review", "pending"] -> 2
      value when value in ["low", "safe"] -> 1
      _ -> 0
    end
  end

  defp overview_running_entries(running), do: Enum.sort_by(running, &(-(&1.tokens.total_tokens || 0)))
  defp sorted_retrying(retrying), do: Enum.sort_by(retrying, &retry_sort_value(&1.due_at))

  defp count_by_risk(approvals, risk) when is_list(approvals) do
    Enum.count(approvals, fn approval ->
      normalized = normalize_filter_value(approval.risk_level)
      if normalize_filter_value(risk) == "high", do: normalized in ["high", "critical", "danger"], else: normalized == normalize_filter_value(risk)
    end)
  end

  defp count_by_risk(_approvals, _risk), do: 0
  defp first_pending_summary([]), do: "No operator decisions are waiting."

  defp first_pending_summary(approvals) do
    case List.first(sort_approvals(approvals)) do
      nil -> "No operator decisions are waiting."
      approval -> "#{approval.issue_identifier} · #{approval.summary || approval.action_type || "review requested"}"
    end
  end

  defp override_summary([]), do: "No manual full-access overrides are active."

  defp override_summary(overrides) when is_list(overrides) do
    workflow = Enum.count(overrides, &((&1.scope || &1["scope"]) == "workflow"))
    run = length(overrides) - workflow

    cond do
      workflow > 0 and run > 0 -> "#{workflow} workflow and #{run} run override#{plural(length(overrides))} active."
      workflow > 0 -> "#{workflow} workflow override#{plural(workflow)} active."
      run > 0 -> "#{run} run override#{plural(run)} active."
      true -> "No manual full-access overrides are active."
    end
  end

  defp selected_approval?(nil, _approval), do: false
  defp selected_approval?(selected, approval), do: to_string(selected.id) == to_string(approval.id)

  defp recent_operator_changes(payload) do
    ((payload.settings_history || []) ++ (get_in(payload, [:github_access, :history]) || []))
    |> Enum.sort_by(&(&1["recorded_at"] || ""), :desc)
    |> Enum.take(6)
  end

  defp runtime_setting_input(assigns) do
    setting = assigns.setting

    case normalize_setting_type(setting.type) do
      "boolean" ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"runtime-setting-#{@setting.path}"}>Value</label>
          <select id={"runtime-setting-#{@setting.path}"} name="value" class="field-select">
            <option value="true" selected={editable_value_string(@setting) == "true"}>true</option>
            <option value="false" selected={editable_value_string(@setting) == "false"}>false</option>
          </select>
        </div>
        """

      "enum" ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"runtime-setting-#{@setting.path}"}>Value</label>
          <select id={"runtime-setting-#{@setting.path}"} name="value" class="field-select">
            <option :for={value <- @setting.options || []} value={value} selected={editable_value_string(@setting) == value}><%= value %></option>
          </select>
        </div>
        """

      "integer_map" ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"runtime-setting-#{@setting.path}"}>JSON value</label>
          <textarea id={"runtime-setting-#{@setting.path}"} name="value" rows="4" class="field-textarea"><%= editable_value_string(@setting) %></textarea>
        </div>
        """

      "string_map" ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"runtime-setting-#{@setting.path}"}>JSON value</label>
          <textarea id={"runtime-setting-#{@setting.path}"} name="value" rows="4" class="field-textarea"><%= editable_value_string(@setting) %></textarea>
        </div>
        """

      "integer" ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"runtime-setting-#{@setting.path}"}>Value</label>
          <input id={"runtime-setting-#{@setting.path}"} name="value" type="number" value={editable_value_string(@setting)} class="field-input" />
        </div>
        """

      _ ->
        ~H"""
        <div class="field-group">
          <label class="field-label" for={"runtime-setting-#{@setting.path}"}>Value</label>
          <input id={"runtime-setting-#{@setting.path}"} name="value" type="text" value={editable_value_string(@setting)} class="field-input" />
        </div>
        """
    end
  end

  defp run_path(%{"issue_identifier" => issue_identifier, "run_id" => run_id}) when is_binary(issue_identifier) and is_binary(run_id), do: "/runs/#{issue_identifier}/#{run_id}"
  defp run_path(_run), do: "/runs"

  defp unique_filter_values(entries, field) when is_list(entries) do
    entries |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq() |> Enum.sort()
  end

  defp unique_filter_values(_entries, _field), do: []
  defp filter_values_with_selected(values, ""), do: values
  defp filter_values_with_selected(values, nil), do: values

  defp filter_values_with_selected(values, current) when is_list(values) and is_binary(current) do
    if current in values, do: values, else: [current | values]
  end

  defp unique_run_statuses(runs) when is_list(runs) do
    runs |> Enum.map(& &1["status"]) |> Enum.reject(&(is_nil(&1) or &1 == "")) |> Enum.uniq() |> Enum.sort()
  end

  defp unique_run_statuses(_runs), do: []

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
    |> then(fn preview -> if length(values) > 3, do: preview <> ", +" <> Integer.to_string(length(values) - 3) <> " more", else: preview end)
  end

  defp preview_list(_values), do: nil

  defp completed_runtime_seconds(payload), do: payload.codex_totals.seconds_running || 0

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) + Enum.reduce(payload.running || [], 0, fn entry, total -> total + runtime_seconds_from_started_at(entry.started_at, now) end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0,
    do: "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"

  defp format_runtime_and_turns(started_at, _turn_count, now), do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    "#{div(whole_seconds, 60)}m #{rem(whole_seconds, 60)}s"
  end

  defp format_runtime_seconds(_seconds), do: "n/a"
  defp format_duration_ms(duration_ms) when is_integer(duration_ms) and duration_ms >= 0, do: format_runtime_seconds(duration_ms / 1_000)
  defp format_duration_ms(_duration_ms), do: "n/a"
  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now), do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value |> Integer.to_string() |> String.reverse() |> String.replace(~r/.{3}(?=.)/, "\\0,") |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp state_badge_class(state) do
    base = "state-badge state-badge-neutral"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["critical", "danger", "high"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["progress", "running", "active", "completed", "done", "authenticated"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed", "deny", "denied"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry", "review", "medium"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp system_health_class(payload) do
    case system_health_level(payload) do
      :healthy -> "status-pill status-pill-positive"
      :warning -> "status-pill status-pill-warning"
      :idle -> "status-pill status-pill-neutral"
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
    counts = payload_counts(payload)

    case system_health_level(payload) do
      :healthy -> "Active flow is healthy with #{counts.running} live issue session#{plural(counts.running)} and no retry backlog."
      :warning -> "Retry pressure is present on #{counts.retrying} issue#{plural(counts.retrying)}."
      :idle -> "No live work is running and no issues are waiting to retry."
    end
  end

  defp primary_running_label([]), do: "No active sessions"

  defp primary_running_label(running) when is_list(running) do
    case Enum.max_by(running, fn entry -> entry.tokens.total_tokens || 0 end, fn -> nil end) do
      nil -> "No active sessions"
      entry -> "#{entry.issue_identifier} / #{format_int(entry.tokens.total_tokens)} tokens"
    end
  end

  defp retry_focus_label([]), do: "No backoff pressure"

  defp retry_focus_label(retrying) when is_list(retrying) do
    case Enum.min_by(retrying, &retry_sort_value(&1.due_at), fn -> nil end) do
      nil -> "No backoff pressure"
      entry -> "#{entry.issue_identifier} / attempt #{entry.attempt}"
    end
  end

  defp latest_completed_label([]), do: "No completed runs yet"

  defp latest_completed_label(completed_runs) when is_list(completed_runs) do
    case List.first(completed_runs) do
      %{"issue_identifier" => issue_identifier, "status" => status} -> "#{issue_identifier} / #{status || "completed"}"
      _ -> "No completed runs yet"
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

  defp efficiency_watch_label(expensive_runs, cheap_wins) when is_list(expensive_runs) and is_list(cheap_wins) do
    cond do
      expensive_runs != [] ->
        case List.first(expensive_runs) do
          %{"issue_identifier" => issue_identifier, "efficiency" => %{"primary_label" => label}} when is_binary(label) ->
            "#{issue_identifier} / #{label}"

          %{"issue_identifier" => issue_identifier} ->
            "#{issue_identifier} / expensive"

          _ ->
            "Expensive runs detected"
        end

      cheap_wins != [] ->
        case List.first(cheap_wins) do
          %{"issue_identifier" => issue_identifier} -> "#{issue_identifier} / cheap win"
          _ -> "Cheap wins available"
        end

      true ->
        "No recent efficiency outliers"
    end
  end

  defp efficiency_watch_label(_expensive_runs, _cheap_wins), do: "No recent efficiency outliers"

  defp system_health_level(payload) do
    case payload_counts(payload) do
      counts when counts.retrying > 0 or counts.pending_approvals > 0 -> :warning
      counts when counts.running > 0 -> :healthy
      _ -> :idle
    end
  end

  defp retry_sort_value(nil), do: {{9999, 12, 31}, {23, 59, 59}, 999_999}

  defp retry_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> {Date.to_erl(DateTime.to_date(parsed)), Time.to_erl(DateTime.to_time(parsed)), 0}
      _ -> retry_sort_value(nil)
    end
  end

  defp run_git_label(run) when is_map(run) do
    git = get_in(run, ["workspace_metadata", "git"]) || %{}
    branch = git["branch"]
    head_commit = git["head_commit"]
    head_subject = git["head_subject"]

    cond do
      is_binary(branch) and is_binary(head_commit) and is_binary(head_subject) -> "#{branch} @ #{String.slice(head_commit, 0, 8)} (#{head_subject})"
      is_binary(branch) and is_binary(head_commit) -> "#{branch} @ #{String.slice(head_commit, 0, 8)}"
      is_binary(branch) -> branch
      is_binary(head_commit) -> String.slice(head_commit, 0, 8)
      true -> "n/a"
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
      |> Enum.take(3)

    cond do
      changed_file_count == 0 -> "no changed files"
      paths == [] -> "#{changed_file_count} file(s)"
      changed_file_count > length(paths) -> "#{Enum.join(paths, ", ")} (+#{changed_file_count - length(paths)} more)"
      true -> Enum.join(paths, ", ")
    end
  end

  defp run_changed_files_label(_run), do: "n/a"
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
  defp efficiency_badge_class(_classification), do: "state-badge state-badge-neutral"
  defp attention_card_class(true), do: "surface-card attention-card attention-card-alert"
  defp attention_card_class(false), do: "surface-card attention-card"

  defp payload_counts(%{counts: counts}) when is_map(counts), do: counts

  defp payload_counts(_payload) do
    %{running: 0, pending_approvals: 0, retrying: 0, guardrail_rules: 0, active_guardrail_rules: 0, active_overrides: 0, completed_runs: 0, issue_rollups: 0, expensive_runs: 0, cheap_wins: 0}
  end

  defp ui_override_count(payload), do: Enum.count(payload.settings || [], &(&1.source == "ui_override"))
  defp github_override_count(payload), do: Enum.count(get_in(payload, [:github_access, :settings]) || [], &(&1.source == "ui_override"))
  defp sum_run_tokens(_filtered_runs, completed_runs, "rollups"), do: Enum.count(completed_runs || [])
  defp sum_run_tokens(filtered_runs, _completed_runs, _view), do: Enum.reduce(filtered_runs || [], 0, fn run, total -> total + (get_in(run, ["tokens", "total_tokens"]) || 0) end)
  defp operator_token_configured?, do: is_binary(configured_operator_token())
  defp yes_no_label(true), do: "yes"
  defp yes_no_label(_value), do: "no"
  defp plural(1), do: ""
  defp plural(_value), do: "s"
  defp remaining_uses_label(value) when is_integer(value), do: value
  defp remaining_uses_label(_value), do: "unlimited"
  defp guardrail_value(values, key) when is_map(values), do: Map.get(values, key) || Map.get(values, to_string(key))
  defp guardrail_value(_values, _key), do: nil
  defp guardrail_rule_active?(rule), do: truthy?(guardrail_value(rule, :active)) or guardrail_value(rule, :lifecycle_state) == "active"
  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false
  defp editable_value_string(%{editable_value: value}) when is_binary(value), do: value
  defp editable_value_string(%{editable_value: value}) when is_integer(value), do: Integer.to_string(value)
  defp editable_value_string(%{editable_value: value}) when is_boolean(value), do: to_string(value)
  defp editable_value_string(%{editable_value: value}) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp editable_value_string(%{editable_value: nil}), do: ""
  defp editable_value_string(_setting), do: ""

  defp normalize_setting_type(type) when is_atom(type), do: Atom.to_string(type)
  defp normalize_setting_type(type) when is_binary(type), do: type
  defp normalize_setting_type(_type), do: ""
  defp github_setting_type(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp github_setting_type(%{type: type}) when is_binary(type), do: type
  defp github_setting_type(_setting), do: "string"
  defp github_setting_input_type(%{type: :email}), do: "email"
  defp github_setting_input_type(%{type: "email"}), do: "email"
  defp github_setting_input_type(_setting), do: "text"

  defp require_operator_access(socket) do
    cond do
      not operator_token_configured?() -> {:error, :operator_token_not_configured}
      socket.assigns.operator_authenticated -> :ok
      true -> {:error, :operator_token_invalid}
    end
  end

  defp valid_operator_token?(token) when is_binary(token) do
    case configured_operator_token() do
      expected when is_binary(expected) -> byte_size(expected) == byte_size(token) and Plug.Crypto.secure_compare(expected, token)
      _ -> false
    end
  end

  defp valid_operator_token?(_token), do: false

  defp current_time do
    case Application.get_env(:symphony_elixir, :ui_visual_now) do
      %DateTime{} = value ->
        value

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, parsed, _offset} -> parsed
          _ -> DateTime.utc_now()
        end

      _ ->
        DateTime.utc_now()
    end
  end

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
  defp blank_to_empty(value) when is_binary(value), do: String.trim(value)
  defp blank_to_empty(_value), do: ""
  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value) when is_binary(value), do: value
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp setting_value_preview(value) do
    value
    |> pretty_value()
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_text(48)
  end

  defp grouped_settings(settings) when is_list(settings) do
    settings |> Enum.group_by(& &1.group) |> Enum.sort_by(fn {group, _settings} -> group end)
  end

  defp grouped_settings(_settings), do: []

  defp truncate_text(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max - 3) <> "..."
  end

  defp truncate_text(value, _max), do: value
  defp filter_match?(_value, nil), do: true
  defp filter_match?(_value, ""), do: true
  defp filter_match?(value, expected) when is_binary(expected), do: normalize_filter_value(value) == normalize_filter_value(expected)
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
  defp schedule_runtime_tick, do: Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
end
