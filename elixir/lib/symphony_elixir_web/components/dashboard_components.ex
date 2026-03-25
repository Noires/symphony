defmodule SymphonyElixirWeb.DashboardComponents do
  @moduledoc """
  Shared UI building blocks for Symphony's operator dashboard.
  """

  use Phoenix.Component

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div :if={flash_messages(@flash) != []} class="flash-stack" role="status" aria-live="polite">
      <div :for={{kind, message} <- flash_messages(@flash)} class={flash_class(kind)}>
        <span class="flash-label"><%= flash_label(kind) %></span>
        <p class="flash-message"><%= message %></p>
      </div>
    </div>
    """
  end

  attr :page, :map, required: true
  attr :operator_authenticated, :boolean, default: false
  attr :operator_token_configured, :boolean, default: false
  attr :theme_label, :string, default: "Theme"
  attr :nav_items, :list, default: []
  attr :utility_items, :list, default: []

  def app_header(assigns) do
    ~H"""
    <header class="app-header" aria-label="Symphony navigation">
      <div class="brand-cluster">
        <a class="brand-mark" href="/">
          <span class="brand-mark-symbol">S</span>
          <span class="brand-mark-text">
            <span class="brand-overline">Symphony</span>
            <strong><%= @page.title %></strong>
          </span>
        </a>
      </div>

      <nav class="primary-nav" aria-label="Primary">
        <.link
          :for={item <- @nav_items}
          patch={Map.get(item, :patch)}
          navigate={Map.get(item, :navigate)}
          href={Map.get(item, :href)}
          class={nav_link_class(item)}
          aria-current={if item.current, do: "page", else: "false"}
        >
          <span><%= item.label %></span>
          <span :if={Map.get(item, :meta)} class="nav-link-meta"><%= item.meta %></span>
        </.link>
      </nav>

      <div class="app-header-actions">
        <button
          type="button"
          class="utility-button"
          data-theme-toggle
          aria-label="Toggle theme"
        >
          <span class="utility-button-label"><%= @theme_label %></span>
          <span class="utility-button-meta">Auto</span>
        </button>

        <div class="status-pill-group">
          <span class={operator_pill_class(@operator_authenticated, @operator_token_configured)}>
            <%= operator_pill_label(@operator_authenticated, @operator_token_configured) %>
          </span>
        </div>

        <div class="utility-link-group">
          <a :for={item <- @utility_items} href={item.href} class="utility-link">
            <%= item.label %>
          </a>
        </div>
      </div>
    </header>
    """
  end

  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :copy, :string, default: nil
  attr :status_label, :string, default: nil
  attr :status_class, :string, default: nil
  slot :actions
  slot :meta

  def page_header(assigns) do
    ~H"""
    <section class="page-hero">
      <div class="page-hero-main">
        <p :if={@eyebrow} class="page-eyebrow"><%= @eyebrow %></p>
        <div class="page-title-row">
          <h1 class="page-title"><%= @title %></h1>
          <span :if={@status_label} class={@status_class}><%= @status_label %></span>
        </div>
        <p :if={@copy} class="page-copy"><%= @copy %></p>
      </div>

      <div :if={@actions != [] or @meta != []} class="page-hero-side">
        <div :if={@meta != []} class="page-hero-meta">
          <%= render_slot(@meta) %>
        </div>
        <div :if={@actions != []} class="page-hero-actions">
          <%= render_slot(@actions) %>
        </div>
      </div>
    </section>
    """
  end

  attr :items, :list, default: []

  def metric_strip(assigns) do
    ~H"""
    <section class="metric-strip" aria-label="Summary metrics">
      <article :for={item <- @items} class="metric-panel">
        <p class="metric-panel-label"><%= item.label %></p>
        <p class={"metric-panel-value " <> (Map.get(item, :value_class) || "")}><%= item.value %></p>
        <p :if={Map.get(item, :detail)} class="metric-panel-detail"><%= item.detail %></p>
      </article>
    </section>
    """
  end

  attr :kicker, :string, default: nil
  attr :title, :string, required: true
  attr :copy, :string, default: nil
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  slot :meta
  slot :inner_block, required: true

  def section_frame(assigns) do
    ~H"""
    <section id={@id} class={["surface-card section-frame", @class]}>
      <div class="section-frame-header">
        <div>
          <p :if={@kicker} class="section-kicker"><%= @kicker %></p>
          <h2 class="section-heading"><%= @title %></h2>
          <p :if={@copy} class="section-copy"><%= @copy %></p>
        </div>
        <div :if={@meta != []} class="section-frame-meta">
          <%= render_slot(@meta) %>
        </div>
      </div>

      <div class="section-frame-body">
        <%= render_slot(@inner_block) %>
      </div>
    </section>
    """
  end

  attr :label, :string, required: true
  attr :copy, :string, default: nil
  slot :inner_block, required: true
  slot :actions

  def filter_toolbar(assigns) do
    ~H"""
    <div class="filter-toolbar" role="search">
      <div class="filter-toolbar-copy">
        <p class="filter-toolbar-label"><%= @label %></p>
        <p :if={@copy} class="filter-toolbar-copy-text"><%= @copy %></p>
      </div>

      <div class="filter-toolbar-fields">
        <%= render_slot(@inner_block) %>
      </div>

      <div :if={@actions != []} class="filter-toolbar-actions">
        <%= render_slot(@actions) %>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :copy, :string, default: nil
  attr :action_label, :string, default: nil
  attr :action_href, :string, default: nil

  def empty_state(assigns) do
    ~H"""
    <section class="empty-state-panel">
      <p class="empty-state-title"><%= @title %></p>
      <p :if={@copy} class="empty-state-copy"><%= @copy %></p>
      <a :if={@action_label && @action_href} class="inline-link" href={@action_href}>
        <%= @action_label %>
      </a>
    </section>
    """
  end

  attr :items, :list, default: []
  attr :class, :string, default: nil

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

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :copied_label, :string, default: "Copied"
  attr :class, :string, default: nil

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

  defp flash_messages(flash) when is_map(flash) do
    flash
    |> Enum.filter(fn {_kind, message} -> is_binary(message) and String.trim(message) != "" end)
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

  defp operator_pill_label(true, _configured), do: "Operator authenticated"
  defp operator_pill_label(false, true), do: "Operator token required"
  defp operator_pill_label(false, false), do: "Operator token not configured"
end
