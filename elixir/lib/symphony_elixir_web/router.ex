defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :overview)
    live("/approvals", DashboardLive, :approvals)
    live("/settings", DashboardLive, :settings)
    live("/runs", DashboardLive, :runs)
    live("/runs/:issue_identifier/:run_id", RunLive, :show)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    post("/api/v1/settings", ObservabilityApiController, :update_settings)
    post("/api/v1/settings/reset", ObservabilityApiController, :reset_settings)
    get("/api/v1/settings", ObservabilityApiController, :settings)
    get("/api/v1/settings/overlay", ObservabilityApiController, :settings_overlay)
    get("/api/v1/settings/history", ObservabilityApiController, :settings_history)
    get("/api/v1/github", ObservabilityApiController, :github_access)
    post("/api/v1/github/config", ObservabilityApiController, :update_github_access_config)
    post("/api/v1/github/config/reset", ObservabilityApiController, :reset_github_access_config)
    post("/api/v1/github/token", ObservabilityApiController, :set_github_access_token)
    post("/api/v1/github/token/clear", ObservabilityApiController, :clear_github_access_token)
    get("/api/v1/codex/auth", ObservabilityApiController, :codex_auth)
    post("/api/v1/codex/auth/refresh", ObservabilityApiController, :refresh_codex_auth)
    post("/api/v1/codex/auth/device/start", ObservabilityApiController, :start_codex_device_auth)
    post("/api/v1/codex/auth/device/cancel", ObservabilityApiController, :cancel_codex_device_auth)
    match(:*, "/api/v1/settings", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/settings/overlay", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/settings/history", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/settings/reset", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/github", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/github/config", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/github/config/reset", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/github/token", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/github/token/clear", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/codex/auth", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/codex/auth/refresh", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/codex/auth/device/start", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/codex/auth/device/cancel", ObservabilityApiController, :method_not_allowed)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/rollups", ObservabilityApiController, :rollups)
    match(:*, "/api/v1/rollups", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/guardrails/approvals", ObservabilityApiController, :guardrail_approvals)
    match(:*, "/api/v1/guardrails/approvals", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/guardrails/approvals/:approval_id", ObservabilityApiController, :guardrail_approval)
    match(:*, "/api/v1/guardrails/approvals/:approval_id", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/guardrails/approvals/:approval_id/explain", ObservabilityApiController, :explain_guardrail_approval)
    match(:*, "/api/v1/guardrails/approvals/:approval_id/explain", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/approvals/:approval_id/decide", ObservabilityApiController, :decide_guardrail_approval)
    match(:*, "/api/v1/guardrails/approvals/:approval_id/decide", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/guardrails/rules", ObservabilityApiController, :guardrail_rules)
    match(:*, "/api/v1/guardrails/rules", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/rules/:rule_id/enable", ObservabilityApiController, :enable_guardrail_rule)
    match(:*, "/api/v1/guardrails/rules/:rule_id/enable", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/rules/:rule_id/disable", ObservabilityApiController, :disable_guardrail_rule)
    match(:*, "/api/v1/guardrails/rules/:rule_id/disable", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/rules/:rule_id/expire", ObservabilityApiController, :expire_guardrail_rule)
    match(:*, "/api/v1/guardrails/rules/:rule_id/expire", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/guardrails/overrides", ObservabilityApiController, :guardrail_overrides)
    match(:*, "/api/v1/guardrails/overrides", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/overrides/run/:run_id/enable", ObservabilityApiController, :enable_run_full_access)
    match(:*, "/api/v1/guardrails/overrides/run/:run_id/enable", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/overrides/run/:run_id/disable", ObservabilityApiController, :disable_run_full_access)
    match(:*, "/api/v1/guardrails/overrides/run/:run_id/disable", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/overrides/workflow/enable", ObservabilityApiController, :enable_workflow_full_access)
    match(:*, "/api/v1/guardrails/overrides/workflow/enable", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/guardrails/overrides/workflow/disable", ObservabilityApiController, :disable_workflow_full_access)
    match(:*, "/api/v1/guardrails/overrides/workflow/disable", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier/export", ObservabilityApiController, :export_issue)
    match(:*, "/api/v1/:issue_identifier/export", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier/runs", ObservabilityApiController, :runs)
    match(:*, "/api/v1/:issue_identifier/runs", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier/runs/:run_id", ObservabilityApiController, :run)
    match(:*, "/api/v1/:issue_identifier/runs/:run_id", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
