defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias SymphonyElixir.{AuditLog, CodexAuth, Config, GitHubAccess, Orchestrator, SettingsOverlay, StatusDashboard}
  alias SymphonyElixir.Guardrails.Rule
  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec settings(conn :: Conn.t(), params :: map()) :: Conn.t()
  def settings(conn, _params) do
    case SettingsOverlay.payload() do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        error_response(conn, 500, "settings_unavailable", "Failed to load runtime settings: #{inspect(reason)}")
    end
  end

  @spec github_access(conn :: Conn.t(), params :: map()) :: Conn.t()
  def github_access(conn, _params) do
    case GitHubAccess.payload() do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        error_response(conn, 500, "github_access_unavailable", "Failed to load GitHub access settings: #{inspect(reason)}")
    end
  end

  @spec codex_auth(conn :: Conn.t(), params :: map()) :: Conn.t()
  def codex_auth(conn, _params) do
    json(conn, %{codex_auth: CodexAuth.snapshot()})
  end

  @spec update_github_access_config(conn :: Conn.t(), params :: map()) :: Conn.t()
  def update_github_access_config(conn, %{"changes" => changes} = params) when is_map(changes) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <-
           GitHubAccess.update_config(
             changes,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      StatusDashboard.notify_update()
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :no_github_config_changes} ->
        error_response(conn, 400, "no_github_config_changes", "No GitHub config changes were provided")

      {:error, {:github_setting_not_ui_manageable, path}} ->
        error_response(conn, 400, "github_setting_not_ui_manageable", "GitHub setting #{path} is not UI-manageable")

      {:error, {:invalid_github_setting_value, path, message}} ->
        error_response(conn, 400, "invalid_github_setting_value", "Invalid value for #{path}: #{message}")

      {:error, reason} ->
        error_response(conn, 409, "github_config_update_failed", "Failed to update GitHub access config: #{inspect(reason)}")

      _ ->
        error_response(conn, 400, "invalid_github_config_changes", "Missing or invalid GitHub config changes")
    end
  end

  def update_github_access_config(conn, _params) do
    error_response(conn, 400, "invalid_github_config_changes", "Missing or invalid GitHub config changes")
  end

  @spec reset_github_access_config(conn :: Conn.t(), params :: map()) :: Conn.t()
  def reset_github_access_config(conn, params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, paths} <- reset_paths_from_params(params, :github),
         {:ok, payload} <-
           GitHubAccess.reset_config(
             paths,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      StatusDashboard.notify_update()
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :no_github_setting_paths} ->
        error_response(conn, 400, "no_github_setting_paths", "No GitHub setting paths were provided for reset")

      {:error, {:github_setting_not_ui_manageable, path}} ->
        error_response(conn, 400, "github_setting_not_ui_manageable", "GitHub setting #{path} is not UI-manageable")

      {:error, reason} ->
        error_response(conn, 409, "github_config_reset_failed", "Failed to reset GitHub access config: #{inspect(reason)}")
    end
  end

  @spec set_github_access_token(conn :: Conn.t(), params :: map()) :: Conn.t()
  def set_github_access_token(conn, %{"token" => token} = params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <-
           GitHubAccess.set_token(
             token,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      StatusDashboard.notify_update()
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, {:invalid_token_value, message}} ->
        error_response(conn, 400, "invalid_github_token", "Invalid GitHub token: #{message}")

      {:error, reason} ->
        error_response(conn, 409, "github_token_update_failed", "Failed to set GitHub token: #{inspect(reason)}")
    end
  end

  def set_github_access_token(conn, _params) do
    error_response(conn, 400, "invalid_github_token", "Missing or invalid GitHub token")
  end

  @spec clear_github_access_token(conn :: Conn.t(), params :: map()) :: Conn.t()
  def clear_github_access_token(conn, params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <-
           GitHubAccess.clear_token(
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      StatusDashboard.notify_update()
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, reason} ->
        error_response(conn, 409, "github_token_clear_failed", "Failed to clear GitHub token: #{inspect(reason)}")
    end
  end

  @spec refresh_codex_auth(conn :: Conn.t(), params :: map()) :: Conn.t()
  def refresh_codex_auth(conn, _params) do
    case CodexAuth.refresh_status() do
      {:ok, payload} -> json(conn, %{codex_auth: payload})
      {:error, reason} -> error_response(conn, 409, "codex_auth_refresh_failed", "Failed to refresh Codex auth status: #{inspect(reason)}")
    end
  end

  @spec start_codex_device_auth(conn :: Conn.t(), params :: map()) :: Conn.t()
  def start_codex_device_auth(conn, params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <- CodexAuth.start_device_auth() do
      json(conn, %{codex_auth: payload})
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :device_auth_in_progress} ->
        error_response(conn, 409, "device_auth_in_progress", "A Codex device auth flow is already running")

      {:error, reason} ->
        error_response(conn, 409, "codex_device_auth_failed", "Failed to start Codex device auth: #{inspect(reason)}")
    end
  end

  @spec cancel_codex_device_auth(conn :: Conn.t(), params :: map()) :: Conn.t()
  def cancel_codex_device_auth(conn, params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <- CodexAuth.cancel_device_auth() do
      json(conn, %{codex_auth: payload})
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :device_auth_not_running} ->
        error_response(conn, 409, "device_auth_not_running", "No Codex device auth flow is currently running")

      {:error, reason} ->
        error_response(conn, 409, "codex_device_auth_cancel_failed", "Failed to cancel Codex device auth: #{inspect(reason)}")
    end
  end

  @spec settings_overlay(conn :: Conn.t(), params :: map()) :: Conn.t()
  def settings_overlay(conn, _params) do
    case SettingsOverlay.overlay_payload() do
      {:ok, payload} ->
        json(conn, payload)

      {:error, reason} ->
        error_response(conn, 500, "settings_overlay_unavailable", "Failed to load settings overlay: #{inspect(reason)}")
    end
  end

  @spec settings_history(conn :: Conn.t(), params :: map()) :: Conn.t()
  def settings_history(conn, params) do
    limit =
      params["limit"]
      |> parse_positive_integer()
      |> case do
        nil -> 20
        value -> value
      end

    json(conn, %{history: SettingsOverlay.history(limit)})
  end

  @spec update_settings(conn :: Conn.t(), params :: map()) :: Conn.t()
  def update_settings(conn, %{"changes" => changes} = params) when is_map(changes) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <-
           SettingsOverlay.update_overlay(
             changes,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      StatusDashboard.notify_update()
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :no_setting_changes} ->
        error_response(conn, 400, "no_setting_changes", "No runtime setting changes were provided")

      {:error, {:setting_not_ui_manageable, path}} ->
        error_response(conn, 400, "setting_not_ui_manageable", "Setting #{path} is bootstrap-only or not UI-manageable")

      {:error, {:invalid_setting_value, path, message}} ->
        error_response(conn, 400, "invalid_setting_value", "Invalid value for #{path}: #{message}")

      {:error, {:invalid_setting_patch, message}} ->
        error_response(conn, 409, "invalid_setting_patch", "Settings patch rejected: #{message}")

      {:error, reason} ->
        error_response(conn, 409, "settings_update_failed", "Failed to update runtime settings: #{inspect(reason)}")

      _ ->
        error_response(conn, 400, "invalid_setting_changes", "Missing or invalid runtime setting changes")
    end
  end

  def update_settings(conn, _params) do
    error_response(conn, 400, "invalid_setting_changes", "Missing or invalid runtime setting changes")
  end

  @spec reset_settings(conn :: Conn.t(), params :: map()) :: Conn.t()
  def reset_settings(conn, params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, paths} <- reset_paths_from_params(params),
         {:ok, payload} <-
           SettingsOverlay.reset_overlay(
             paths,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      StatusDashboard.notify_update()
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :no_setting_paths} ->
        error_response(conn, 400, "no_setting_paths", "No runtime setting paths were provided for reset")

      {:error, {:setting_not_ui_manageable, path}} ->
        error_response(conn, 400, "setting_not_ui_manageable", "Setting #{path} is bootstrap-only or not UI-manageable")

      {:error, {:invalid_setting_patch, message}} ->
        error_response(conn, 409, "invalid_setting_patch", "Settings reset rejected: #{message}")

      {:error, reason} ->
        error_response(conn, 409, "settings_reset_failed", "Failed to reset runtime settings: #{inspect(reason)}")
    end
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec runs(Conn.t(), map()) :: Conn.t()
  def runs(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_runs_payload(issue_identifier) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec rollups(Conn.t(), map()) :: Conn.t()
  def rollups(conn, _params) do
    json(conn, Presenter.issue_rollups_payload())
  end

  @spec run(Conn.t(), map()) :: Conn.t()
  def run(conn, %{"issue_identifier" => issue_identifier, "run_id" => run_id}) do
    case Presenter.run_payload(issue_identifier, run_id) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec export_issue(Conn.t(), map()) :: Conn.t()
  def export_issue(conn, %{"issue_identifier" => issue_identifier}) do
    case AuditLog.export_issue_bundle(issue_identifier) do
      {:ok, %{path: path, filename: filename}} ->
        send_download(conn, {:file, path}, filename: filename)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")

      {:error, reason} ->
        error_response(conn, 500, "bundle_export_failed", "Failed to export audit bundle: #{inspect(reason)}")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec guardrail_approvals(Conn.t(), map()) :: Conn.t()
  def guardrail_approvals(conn, _params) do
    approval_controls_unsupported_response(conn)
  end

  @spec guardrail_approval(Conn.t(), map()) :: Conn.t()
  def guardrail_approval(conn, %{"approval_id" => approval_id}) do
    _ = approval_id
    approval_controls_unsupported_response(conn)
  end

  @spec explain_guardrail_approval(Conn.t(), map()) :: Conn.t()
  def explain_guardrail_approval(conn, %{"approval_id" => approval_id}) do
    _ = approval_id
    approval_controls_unsupported_response(conn)
  end

  @spec decide_guardrail_approval(Conn.t(), map()) :: Conn.t()
  def decide_guardrail_approval(conn, %{"approval_id" => approval_id} = params) do
    _ = {approval_id, params}
    approval_controls_unsupported_response(conn)
  end

  @spec guardrail_rules(Conn.t(), map()) :: Conn.t()
  def guardrail_rules(conn, params) do
    active_only = params["active_only"] in ["true", "1"]

    case AuditLog.list_guardrail_rules(active_only: active_only) do
      {:ok, rules} ->
        json(conn, %{rules: rules |> Enum.map(&decorate_guardrail_rule/1) |> filter_guardrail_rules(params)})

      _ ->
        error_response(conn, 500, "guardrail_rules_failed", "Failed to load guardrail rules")
    end
  end

  @spec disable_guardrail_rule(Conn.t(), map()) :: Conn.t()
  def disable_guardrail_rule(conn, %{"rule_id" => rule_id} = params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <-
           Orchestrator.disable_guardrail_rule(
             orchestrator(),
             rule_id,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :guardrails_disabled} ->
        error_response(conn, 409, "guardrails_disabled", "Guardrails are disabled in the current workflow")

      {:error, :rule_not_found} ->
        error_response(conn, 404, "rule_not_found", "Guardrail rule not found")

      {:error, :operator_action_rate_limited} ->
        error_response(conn, 409, "operator_action_rate_limited", "Another operator action just updated this item")

      {:error, reason} ->
        error_response(conn, 409, "guardrail_rule_disable_failed", "Failed to disable guardrail rule: #{inspect(reason)}")
    end
  end

  @spec enable_guardrail_rule(Conn.t(), map()) :: Conn.t()
  def enable_guardrail_rule(conn, %{"rule_id" => rule_id} = params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <-
           Orchestrator.enable_guardrail_rule(
             orchestrator(),
             rule_id,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :guardrails_disabled} ->
        error_response(conn, 409, "guardrails_disabled", "Guardrails are disabled in the current workflow")

      {:error, :rule_not_found} ->
        error_response(conn, 404, "rule_not_found", "Guardrail rule not found")

      {:error, :operator_action_rate_limited} ->
        error_response(conn, 409, "operator_action_rate_limited", "Another operator action just updated this item")

      {:error, reason} ->
        error_response(conn, 409, "guardrail_rule_enable_failed", "Failed to enable guardrail rule: #{inspect(reason)}")
    end
  end

  @spec expire_guardrail_rule(Conn.t(), map()) :: Conn.t()
  def expire_guardrail_rule(conn, %{"rule_id" => rule_id} = params) do
    with :ok <- authorize_operator(params, conn),
         {:ok, payload} <-
           Orchestrator.expire_guardrail_rule(
             orchestrator(),
             rule_id,
             actor: params["actor"] || "api",
             reason: params["reason"]
           ) do
      json(conn, payload)
    else
      {:error, :operator_token_not_configured} ->
        error_response(conn, 503, "operator_token_not_configured", "Operator token is not configured")

      {:error, :operator_token_invalid} ->
        error_response(conn, 403, "operator_token_invalid", "Operator token is invalid")

      {:error, :guardrails_disabled} ->
        error_response(conn, 409, "guardrails_disabled", "Guardrails are disabled in the current workflow")

      {:error, :rule_not_found} ->
        error_response(conn, 404, "rule_not_found", "Guardrail rule not found")

      {:error, :operator_action_rate_limited} ->
        error_response(conn, 409, "operator_action_rate_limited", "Another operator action just updated this item")

      {:error, reason} ->
        error_response(conn, 409, "guardrail_rule_expire_failed", "Failed to expire guardrail rule: #{inspect(reason)}")
    end
  end

  @spec guardrail_overrides(Conn.t(), map()) :: Conn.t()
  def guardrail_overrides(conn, _params) do
    approval_controls_unsupported_response(conn)
  end

  @spec enable_run_full_access(Conn.t(), map()) :: Conn.t()
  def enable_run_full_access(conn, %{"run_id" => run_id} = params) do
    _ = {run_id, params}
    approval_controls_unsupported_response(conn)
  end

  @spec disable_run_full_access(Conn.t(), map()) :: Conn.t()
  def disable_run_full_access(conn, %{"run_id" => run_id} = params) do
    _ = {run_id, params}
    approval_controls_unsupported_response(conn)
  end

  @spec enable_workflow_full_access(Conn.t(), map()) :: Conn.t()
  def enable_workflow_full_access(conn, params) do
    _ = params
    approval_controls_unsupported_response(conn)
  end

  @spec disable_workflow_full_access(Conn.t(), map()) :: Conn.t()
  def disable_workflow_full_access(conn, params) do
    _ = params
    approval_controls_unsupported_response(conn)
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp approval_controls_unsupported_response(conn) do
    error_response(
      conn,
      410,
      "approval_controls_unsupported",
      "Codex approval controls are disabled in container-boundary mode"
    )
  end

  defp parse_positive_integer(nil), do: nil
  defp parse_positive_integer(""), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp reset_paths_from_params(params, scope \\ :settings)

  defp reset_paths_from_params(%{"paths" => paths}, _scope) when is_list(paths), do: {:ok, paths}
  defp reset_paths_from_params(%{"paths" => path}, _scope) when is_binary(path), do: {:ok, [path]}
  defp reset_paths_from_params(%{"path" => path}, _scope) when is_binary(path), do: {:ok, [path]}
  defp reset_paths_from_params(_params, :github), do: {:error, :no_github_setting_paths}
  defp reset_paths_from_params(_params, _scope), do: {:error, :no_setting_paths}

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp authorize_operator(params, conn) when is_map(params) do
    case configured_operator_token() do
      nil ->
        {:error, :operator_token_not_configured}

      expected_token ->
        if secure_token_match?(expected_token, operator_token_from_request(params, conn)) do
          :ok
        else
          {:error, :operator_token_invalid}
        end
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

  defp operator_token_from_request(params, conn) do
    bearer_token =
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> case do
        "Bearer " <> token -> token
        _ -> nil
      end

    header_token =
      conn
      |> get_req_header("x-operator-token")
      |> List.first()

    params["operator_token"] || header_token || bearer_token
  end

  defp secure_token_match?(expected, actual) when is_binary(expected) and is_binary(actual) do
    byte_size(expected) == byte_size(actual) and Plug.Crypto.secure_compare(expected, actual)
  end

  defp secure_token_match?(_expected, _actual), do: false

  defp filter_guardrail_rules(rules, params) when is_list(rules) and is_map(params) do
    rules
    |> Enum.filter(fn rule ->
      filter_match?(rule, :scope, params["scope"]) and
        filter_match?(rule, :action_type, params["action_type"]) and
        query_match?(rule, params["q"])
    end)
  end

  defp filter_guardrail_rules(rules, _params), do: rules

  defp decorate_guardrail_rule(rule) when is_map(rule) do
    case Rule.from_snapshot(rule) do
      %Rule{} = parsed ->
        parsed
        |> Rule.snapshot_entry()
        |> Map.put("active", Rule.active?(parsed))
        |> Map.put("lifecycle_state", lifecycle_state(parsed))
        |> Map.put("description", Rule.describe(parsed))

      _ ->
        rule
        |> Map.put("active", false)
        |> Map.put("lifecycle_state", "unknown")
        |> Map.put("description", Map.get(rule, "description") || "guardrail rule")
    end
  end

  defp filter_match?(_entry, _key, nil), do: true
  defp filter_match?(_entry, _key, ""), do: true

  defp filter_match?(entry, key, expected) when is_map(entry) and is_binary(expected) do
    actual =
      Map.get(entry, key) ||
        Map.get(entry, Atom.to_string(key))

    normalize_filter_value(actual) == normalize_filter_value(expected)
  end

  defp query_match?(_entry, nil), do: true
  defp query_match?(_entry, ""), do: true

  defp query_match?(entry, query) when is_map(entry) and is_binary(query) do
    haystack =
      entry
      |> Map.take([:issue_identifier, :action_type, :summary, :reason, :fingerprint, :worker_host, "issue_identifier", "action_type", "summary", "reason", "fingerprint", "worker_host", "description"])
      |> inspect(limit: :infinity)
      |> String.downcase()

    String.contains?(haystack, String.downcase(String.trim(query)))
  end

  defp normalize_filter_value(value) when is_binary(value), do: String.downcase(String.trim(value))
  defp normalize_filter_value(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_filter_value()
  defp normalize_filter_value(value), do: value

  defp lifecycle_state(%Rule{} = rule) do
    now = DateTime.utc_now()

    cond do
      Rule.active?(rule) -> "active"
      match?(%DateTime{}, rule.expires_at) and DateTime.compare(rule.expires_at, now) != :gt -> "expired"
      rule.enabled == false -> "disabled"
      true -> "inactive"
    end
  end
end
