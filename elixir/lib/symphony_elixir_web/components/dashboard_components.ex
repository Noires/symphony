defmodule SymphonyElixirWeb.DashboardComponents do
  @moduledoc """
  UI building blocks for Symphony's mission control dashboard.
  """

  use Phoenix.Component

  # ── Flash Messages ──

  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <section :if={flash_messages(@flash) != []} class="flash-stack" aria-label="Status messages" aria-live="polite">
      <ul class="flash-list">
        <li :for={{kind, message} <- flash_messages(@flash)}>
          <article class={flash_class(kind)}>
            <span class="flash-label"><%= flash_label(kind) %></span>
            <p class="flash-message"><%= message %></p>
          </article>
        </li>
      </ul>
    </section>
    """
  end

  # ── Command Bar ──

  attr(:page, :map, required: true)
  attr(:operator_authenticated, :boolean, default: false)
  attr(:operator_token_configured, :boolean, default: false)
  attr(:operator_token, :string, default: "")
  attr(:theme_label, :string, default: "Theme")
  attr(:nav_items, :list, default: [])
  attr(:utility_items, :list, default: [])

  def command_bar(assigns) do
    ~H"""
    <header class="command-bar">
      <div class="command-bar-brand">
        <a href="/">
          <span class="brand-symbol">S</span>
          <span class="brand-title"><%= @page.title %></span>
        </a>
      </div>

      <nav class="command-bar-nav" aria-label="Primary">
        <ul class="nav-list">
          <li :for={item <- @nav_items}>
            <.link
              patch={Map.get(item, :patch)}
              navigate={Map.get(item, :navigate)}
              href={Map.get(item, :href)}
              class={nav_link_class(item)}
              aria-current={if item.current, do: "page", else: "false"}
            >
              <span><%= item.label %></span>
              <span :if={Map.get(item, :meta)} class="nav-link-meta"><%= item.meta %></span>
            </.link>
          </li>
        </ul>
      </nav>

      <div class="command-bar-controls">
        <form phx-change="update_operator_token" class="command-bar-token">
          <input
            type="password"
            name="operator_token"
            value={@operator_token}
            autocomplete="current-password"
            placeholder="operator token"
            aria-label="Operator token"
          />
        </form>

        <span class={operator_pill_class(@operator_authenticated, @operator_token_configured)}>
          <%= operator_pill_short(@operator_authenticated, @operator_token_configured) %>
        </span>

        <button type="button" class="utility-button" data-theme-toggle aria-label="Toggle theme">
          <span class="utility-button-label"><%= @theme_label %></span>
          <span class="utility-button-meta">Auto</span>
        </button>

        <div :if={@utility_items != []} class="utility-link-group">
          <ul class="utility-link-list" aria-label="Utility links">
            <li :for={item <- @utility_items}>
              <a href={item.href} class="utility-link"><%= item.label %></a>
            </li>
          </ul>
        </div>
      </div>
    </header>
    """
  end

  # Legacy app_header — delegates to command_bar
  attr(:page, :map, required: true)
  attr(:operator_authenticated, :boolean, default: false)
  attr(:operator_token_configured, :boolean, default: false)
  attr(:theme_label, :string, default: "Theme")
  attr(:nav_items, :list, default: [])
  attr(:utility_items, :list, default: [])

  def app_header(assigns) do
    assigns = assign(assigns, :operator_token, "")

    ~H"""
    <.command_bar
      page={@page}
      operator_authenticated={@operator_authenticated}
      operator_token_configured={@operator_token_configured}
      operator_token={@operator_token}
      theme_label={@theme_label}
      nav_items={@nav_items}
      utility_items={@utility_items}
    />
    """
  end

  # ── Page Header ──

  attr(:eyebrow, :string, default: nil)
  attr(:title, :string, required: true)
  attr(:copy, :string, default: nil)
  attr(:status_label, :string, default: nil)
  attr(:status_class, :string, default: nil)
  slot(:actions)
  slot(:meta)

  def page_header(assigns) do
    ~H"""
    <header class="page-header">
      <div class="page-header-top">
        <div class="page-header-title">
          <p :if={@eyebrow} class="page-eyebrow"><%= @eyebrow %></p>
          <h1 class="page-title"><%= @title %></h1>
        </div>
        <div class="page-header-right">
          <span :if={@status_label} class={@status_class}><%= @status_label %></span>
          <div :if={@actions != []} class="page-header-actions">
            <%= render_slot(@actions) %>
          </div>
        </div>
      </div>
      <p :if={@copy} class="page-copy"><%= @copy %></p>
      <%= if @meta != [] do %>
        <div class="page-header-meta">
          <%= render_slot(@meta) %>
        </div>
      <% end %>
    </header>
    """
  end

  # ── Metric Strip ──

  attr(:items, :list, default: [])

  def metric_strip(assigns) do
    ~H"""
    <dl class="metric-strip" aria-label="Summary metrics">
      <div :for={item <- @items} class="metric-panel">
        <dt class="metric-panel-label"><%= item.label %></dt>
        <dd class={"metric-panel-value " <> (Map.get(item, :value_class) || "")}><%= item.value %></dd>
        <dd :if={Map.get(item, :detail)} class="metric-panel-detail"><%= item.detail %></dd>
      </div>
    </dl>
    """
  end

  # ── Section Frame ──

  attr(:kicker, :string, default: nil)
  attr(:title, :string, required: true)
  attr(:copy, :string, default: nil)
  attr(:id, :string, default: nil)
  attr(:class, :string, default: nil)
  attr(:body_class, :string, default: nil)
  attr(:collapsible, :boolean, default: false)
  attr(:open, :boolean, default: false)
  slot(:meta)
  slot(:inner_block, required: true)

  def section_frame(assigns) do
    ~H"""
    <%= if @collapsible do %>
      <details id={@id} class={["section-frame section-frame-collapsible", @class]} open={@open}>
        <summary class="section-frame-summary">
          <header class="section-frame-header">
            <div>
              <p :if={@kicker} class="section-kicker"><%= @kicker %></p>
              <h2 class="section-heading"><%= @title %></h2>
              <p :if={@copy} class="section-copy"><%= @copy %></p>
            </div>
            <div class="section-frame-summary-side">
              <div :if={@meta != []} class="section-frame-meta">
                <%= render_slot(@meta) %>
              </div>
              <span class="section-frame-toggle" aria-hidden="true"></span>
            </div>
          </header>
        </summary>
        <div class={["section-frame-body", @body_class]}>
          <%= render_slot(@inner_block) %>
        </div>
      </details>
    <% else %>
      <section id={@id} class={["section-frame", @class]}>
        <header class="section-frame-header">
          <div>
            <p :if={@kicker} class="section-kicker"><%= @kicker %></p>
            <h2 class="section-heading"><%= @title %></h2>
            <p :if={@copy} class="section-copy"><%= @copy %></p>
          </div>
          <div :if={@meta != []} class="section-frame-meta">
            <%= render_slot(@meta) %>
          </div>
        </header>
        <div class={["section-frame-body", @body_class]}>
          <%= render_slot(@inner_block) %>
        </div>
      </section>
    <% end %>
    """
  end

  # ── Filter Toolbar ──

  attr(:label, :string, required: true)
  attr(:copy, :string, default: nil)
  slot(:inner_block, required: true)
  slot(:actions)

  def filter_toolbar(assigns) do
    ~H"""
    <section class="filter-toolbar" aria-label={@label}>
      <header class="filter-toolbar-copy">
        <p class="filter-toolbar-label"><%= @label %></p>
        <p :if={@copy} class="filter-toolbar-copy-text"><%= @copy %></p>
      </header>
      <div class="filter-toolbar-fields">
        <%= render_slot(@inner_block) %>
      </div>
      <div :if={@actions != []} class="filter-toolbar-actions">
        <%= render_slot(@actions) %>
      </div>
    </section>
    """
  end

  # ── Empty State ──

  attr(:title, :string, required: true)
  attr(:copy, :string, default: nil)
  attr(:action_label, :string, default: nil)
  attr(:action_href, :string, default: nil)

  def empty_state(assigns) do
    ~H"""
    <section class="empty-state-panel">
      <h3 class="empty-state-title"><%= @title %></h3>
      <p :if={@copy} class="empty-state-copy"><%= @copy %></p>
      <a :if={@action_label && @action_href} class="inline-link" href={@action_href}>
        <%= @action_label %>
      </a>
    </section>
    """
  end

  # ── Key-Value List ──

  attr(:items, :list, default: [])
  attr(:class, :string, default: nil)

  def key_value_list(assigns) do
    ~H"""
    <dl class={["key-value-list", @class]}>
      <div :for={item <- @items} class="key-value-row">
        <dt class="key-value-label"><%= item.label %></dt>
        <dd class={"key-value-value " <> (Map.get(item, :value_class) || "")}>
          <%= item.value %>
        </dd>
      </div>
    </dl>
    """
  end

  # ── Disclosure Panel ──

  attr(:title, :string, required: true)
  attr(:copy, :string, default: nil)
  attr(:kicker, :string, default: nil)
  attr(:open, :boolean, default: false)
  attr(:class, :string, default: nil)
  slot(:meta)
  slot(:inner_block, required: true)

  def disclosure_panel(assigns) do
    ~H"""
    <details class={["disclosure-panel", @class]} open={@open}>
      <summary class="disclosure-summary">
        <header class="disclosure-copy">
          <p :if={@kicker} class="section-kicker"><%= @kicker %></p>
          <h3 class="disclosure-title"><%= @title %></h3>
          <p :if={@copy} class="disclosure-text"><%= @copy %></p>
        </header>
        <div class="disclosure-side">
          <div :if={@meta != []} class="disclosure-meta">
            <%= render_slot(@meta) %>
          </div>
          <span class="disclosure-toggle" aria-hidden="true"></span>
        </div>
      </summary>
      <div class="disclosure-body">
        <%= render_slot(@inner_block) %>
      </div>
    </details>
    """
  end

  # ── Copy Button ──

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:copied_label, :string, default: "Copied")
  attr(:class, :string, default: nil)

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["utility-button utility-button-copy", @class]}
      data-copy={@value}
      data-copy-label={@label}
      data-copy-copied={@copied_label}
      aria-label={@label}
    >
      <%= @label %>
    </button>
    """
  end

  # ── Private helpers ──

  defp flash_messages(flash) when is_map(flash) do
    flash |> Enum.filter(fn {_kind, message} -> is_binary(message) and String.trim(message) != "" end)
  end
  defp flash_messages(_flash), do: []

  defp flash_class(:error), do: "flash-banner flash-banner-error"
  defp flash_class("error"), do: flash_class(:error)
  defp flash_class(_kind), do: "flash-banner flash-banner-info"

  defp flash_label(:error), do: "Error"
  defp flash_label("error"), do: flash_label(:error)
  defp flash_label(_kind), do: "Notice"

  defp nav_link_class(%{current: true}), do: "nav-link nav-link-current"
  defp nav_link_class(_item), do: "nav-link"

  defp operator_pill_class(true, _configured), do: "status-pill status-pill-positive"
  defp operator_pill_class(false, true), do: "status-pill status-pill-warning"
  defp operator_pill_class(false, false), do: "status-pill status-pill-neutral"

  defp operator_pill_short(true, _configured), do: "Auth"
  defp operator_pill_short(false, true), do: "Locked"
  defp operator_pill_short(false, false), do: "No token"

  # Keep full labels available for use elsewhere
  def operator_pill_label(true, _configured), do: "Operator authenticated"
  def operator_pill_label(false, true), do: "Operator token required"
  def operator_pill_label(false, false), do: "Operator token not configured"
end
