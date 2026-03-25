defmodule SymphonyElixir.Guardrails.Approvals do
  @moduledoc false

  alias SymphonyElixir.Guardrails.Policy
  alias SymphonyElixir.Linear.Issue

  defstruct [
    :id,
    :issue_id,
    :issue_identifier,
    :issue_state,
    :run_id,
    :session_id,
    :worker_host,
    :workspace_path,
    :status,
    :requested_at,
    :action_type,
    :method,
    :summary,
    :risk_level,
    :reason,
    :source,
    :fingerprint,
    :protocol_request_id,
    :decision_options,
    :decision,
    :decision_scope,
    :resolved_by,
    :resolved_at,
    :resolution_reason,
    :details,
    :payload
  ]

  @type t :: %__MODULE__{}

  @spec new(map(), map()) :: t()
  def new(%{issue: %Issue{} = issue} = running_entry, evaluation)
      when is_map(running_entry) and is_map(evaluation) do
    %__MODULE__{
      id: approval_id(),
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_state: issue.state,
      run_id: Map.get(running_entry, :run_id),
      session_id: Map.get(running_entry, :session_id),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      status: "pending_review",
      requested_at: DateTime.utc_now(),
      action_type: Map.get(evaluation, :action_type),
      method: Map.get(evaluation, :method),
      summary: Map.get(evaluation, :summary),
      risk_level: Map.get(evaluation, :risk_level),
      reason: Map.get(evaluation, :reason),
      source: Map.get(evaluation, :source),
      fingerprint: Map.get(evaluation, :fingerprint),
      protocol_request_id: Map.get(evaluation, :protocol_request_id),
      decision_options: Policy.decision_options(),
      details: Map.get(evaluation, :details, %{}),
      payload: Map.get(evaluation, :payload, %{})
    }
  end

  @spec snapshot_entry(t()) :: map()
  def snapshot_entry(%__MODULE__{} = approval) do
    %{
      id: approval.id,
      issue_id: approval.issue_id,
      issue_identifier: approval.issue_identifier,
      state: approval.issue_state,
      run_id: approval.run_id,
      session_id: approval.session_id,
      worker_host: approval.worker_host,
      workspace_path: approval.workspace_path,
      status: approval.status,
      requested_at: iso8601(approval.requested_at),
      action_type: approval.action_type,
      method: approval.method,
      summary: approval.summary,
      risk_level: approval.risk_level,
      reason: approval.reason,
      source: approval.source,
      fingerprint: approval.fingerprint,
      protocol_request_id: approval.protocol_request_id,
      decision_options: approval.decision_options,
      decision: approval.decision,
      decision_scope: approval.decision_scope,
      resolved_by: approval.resolved_by,
      resolved_at: iso8601(approval.resolved_at),
      resolution_reason: approval.resolution_reason,
      details: approval.details,
      payload: approval.payload
    }
  end

  @spec from_snapshot(map()) :: t() | nil
  def from_snapshot(snapshot) when is_map(snapshot) do
    %__MODULE__{
      id: normalize_optional_string(Map.get(snapshot, "id") || Map.get(snapshot, :id)),
      issue_id: normalize_optional_string(Map.get(snapshot, "issue_id") || Map.get(snapshot, :issue_id)),
      issue_identifier: normalize_optional_string(Map.get(snapshot, "issue_identifier") || Map.get(snapshot, :issue_identifier)),
      issue_state: normalize_optional_string(Map.get(snapshot, "state") || Map.get(snapshot, :state) || Map.get(snapshot, "issue_state") || Map.get(snapshot, :issue_state)),
      run_id: normalize_optional_string(Map.get(snapshot, "run_id") || Map.get(snapshot, :run_id)),
      session_id: normalize_optional_string(Map.get(snapshot, "session_id") || Map.get(snapshot, :session_id)),
      worker_host: normalize_optional_string(Map.get(snapshot, "worker_host") || Map.get(snapshot, :worker_host)),
      workspace_path: normalize_optional_string(Map.get(snapshot, "workspace_path") || Map.get(snapshot, :workspace_path)),
      status: normalize_optional_string(Map.get(snapshot, "status") || Map.get(snapshot, :status)),
      requested_at: parse_datetime(Map.get(snapshot, "requested_at") || Map.get(snapshot, :requested_at)),
      action_type: normalize_optional_string(Map.get(snapshot, "action_type") || Map.get(snapshot, :action_type)),
      method: normalize_optional_string(Map.get(snapshot, "method") || Map.get(snapshot, :method)),
      summary: normalize_optional_string(Map.get(snapshot, "summary") || Map.get(snapshot, :summary)),
      risk_level: normalize_optional_string(Map.get(snapshot, "risk_level") || Map.get(snapshot, :risk_level)),
      reason: normalize_optional_string(Map.get(snapshot, "reason") || Map.get(snapshot, :reason)),
      source: normalize_optional_string(Map.get(snapshot, "source") || Map.get(snapshot, :source)),
      fingerprint: normalize_optional_string(Map.get(snapshot, "fingerprint") || Map.get(snapshot, :fingerprint)),
      protocol_request_id: normalize_optional_string(Map.get(snapshot, "protocol_request_id") || Map.get(snapshot, :protocol_request_id)),
      decision_options: normalize_list(Map.get(snapshot, "decision_options") || Map.get(snapshot, :decision_options), &normalize_optional_string/1),
      decision: normalize_optional_string(Map.get(snapshot, "decision") || Map.get(snapshot, :decision)),
      decision_scope: normalize_optional_string(Map.get(snapshot, "decision_scope") || Map.get(snapshot, :decision_scope)),
      resolved_by: normalize_optional_string(Map.get(snapshot, "resolved_by") || Map.get(snapshot, :resolved_by)),
      resolved_at: parse_datetime(Map.get(snapshot, "resolved_at") || Map.get(snapshot, :resolved_at)),
      resolution_reason: normalize_optional_string(Map.get(snapshot, "resolution_reason") || Map.get(snapshot, :resolution_reason)),
      details: normalize_map(Map.get(snapshot, "details") || Map.get(snapshot, :details)),
      payload: normalize_map(Map.get(snapshot, "payload") || Map.get(snapshot, :payload))
    }
    |> case do
      %__MODULE__{id: nil} -> nil
      %__MODULE__{} = approval -> approval
    end
  end

  def from_snapshot(_snapshot), do: nil

  @spec update_issue_state(t(), String.t() | nil) :: t()
  def update_issue_state(%__MODULE__{} = approval, state_name) when is_binary(state_name) do
    %{approval | issue_state: state_name}
  end

  def update_issue_state(%__MODULE__{} = approval, _state_name), do: approval

  @spec cancel(t(), String.t()) :: t()
  def cancel(%__MODULE__{} = approval, reason) when is_binary(reason) do
    %{
      approval
      | status: "cancelled",
        reason: reason
    }
  end

  @spec resolve(t(), String.t(), keyword()) :: t()
  def resolve(%__MODULE__{} = approval, decision, opts \\ [])
      when decision in ["allow_once", "allow_for_session", "allow_via_rule", "deny"] do
    resolved_at = Keyword.get(opts, :resolved_at, DateTime.utc_now())

    %{
      approval
      | status: resolved_status(decision),
        decision: decision,
        decision_scope: normalize_optional_string(Keyword.get(opts, :decision_scope)),
        resolved_by: normalize_optional_string(Keyword.get(opts, :resolved_by)),
        resolved_at: resolved_at,
        resolution_reason: normalize_optional_string(Keyword.get(opts, :reason))
    }
  end

  @spec audit_event(t()) :: map()
  def audit_event(%__MODULE__{} = approval) do
    %{
      event: "approval_pending",
      summary: approval.summary || "approval pending operator review",
      recorded_at: approval.requested_at,
      details: %{
        "approval_id" => approval.id,
        "status" => approval.status,
        "action_type" => approval.action_type,
        "method" => approval.method,
        "risk_level" => approval.risk_level,
        "reason" => approval.reason,
        "source" => approval.source,
        "fingerprint" => approval.fingerprint,
        "protocol_request_id" => approval.protocol_request_id,
        "decision_options" => approval.decision_options,
        "details" => approval.details
      }
    }
  end

  @spec cancellation_audit_event(t(), String.t()) :: map()
  def cancellation_audit_event(%__MODULE__{} = approval, reason) when is_binary(reason) do
    %{
      event: "approval_cancelled",
      summary: "pending approval cancelled: #{reason}",
      recorded_at: DateTime.utc_now(),
      details: %{
        "approval_id" => approval.id,
        "status" => "cancelled",
        "reason" => reason
      }
    }
  end

  @spec decision_audit_event(t()) :: map()
  def decision_audit_event(%__MODULE__{} = approval) do
    %{
      event: decision_event_name(approval.decision),
      summary: decision_summary(approval),
      recorded_at: approval.resolved_at || DateTime.utc_now(),
      details: %{
        "approval_id" => approval.id,
        "status" => approval.status,
        "decision" => approval.decision,
        "decision_scope" => approval.decision_scope,
        "resolved_by" => approval.resolved_by,
        "resolution_reason" => approval.resolution_reason,
        "fingerprint" => approval.fingerprint,
        "action_type" => approval.action_type,
        "method" => approval.method
      }
    }
  end

  defp approval_id do
    "approval-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp resolved_status("deny"), do: "denied_by_operator"
  defp resolved_status(_decision), do: "approved"

  defp decision_event_name("allow_once"), do: "approval_allowed_once"
  defp decision_event_name("allow_for_session"), do: "approval_allowed_for_run"
  defp decision_event_name("allow_via_rule"), do: "approval_allowed_via_rule"
  defp decision_event_name("deny"), do: "approval_denied_by_operator"
  defp decision_event_name(_decision), do: "approval_decided"

  defp decision_summary(%__MODULE__{decision: decision, summary: summary}) when is_binary(decision) do
    label =
      case decision do
        "allow_once" -> "approval allowed once"
        "allow_for_session" -> "approval allowed for current run"
        "allow_via_rule" -> "approval converted into allow rule"
        "deny" -> "approval denied"
        _ -> "approval decided"
      end

    case normalize_optional_string(summary) do
      nil -> label
      text -> "#{label}: #{text}"
    end
  end

  defp decision_summary(_approval), do: "approval decided"

  defp normalize_map(%{} = value), do: Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  defp normalize_map(_value), do: %{}

  defp normalize_list(values, mapper) when is_list(values) and is_function(mapper, 1) do
    values
    |> Enum.map(mapper)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_list(_values, _mapper), do: []

  defp parse_datetime(%DateTime{} = value), do: value

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_optional_string()
  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(DateTime.truncate(value, :second))
  defp iso8601(_value), do: nil
end
