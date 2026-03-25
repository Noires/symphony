defmodule SymphonyElixir.Guardrails.Rule do
  @moduledoc false

  alias SymphonyElixir.Guardrails.Approvals

  defstruct [
    :id,
    :enabled,
    :scope,
    :scope_key,
    :action_type,
    :match,
    :decision,
    :constraints,
    :created_by,
    :created_at,
    :expires_at,
    :reason,
    :source_approval_id,
    :remaining_uses
  ]

  @type t :: %__MODULE__{}

  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = rule) do
    matchers =
      [
        describe_matcher("fingerprint", Map.get(rule.match || %{}, "fingerprint")),
        describe_matcher("method", Map.get(rule.match || %{}, "method")),
        describe_matcher("command_executable", Map.get(rule.match || %{}, "command_executable")),
        describe_matcher("shell_wrapper", Map.get(rule.match || %{}, "shell_wrapper")),
        describe_matcher("network_access", Map.get(rule.match || %{}, "network_access")),
        describe_matcher("file_paths", Map.get(rule.match || %{}, "file_paths")),
        describe_matcher("sensitive_paths", Map.get(rule.match || %{}, "sensitive_paths"))
      ]
      |> Enum.reject(&is_nil/1)

    constraints =
      [
        describe_constraint("workspace_only", get_in(rule.constraints || %{}, ["workspace_only"])),
        describe_constraint("cwd", get_in(rule.constraints || %{}, ["cwd"]))
      ]
      |> Enum.reject(&is_nil/1)

    parts =
      []
      |> maybe_append_part(rule.action_type)
      |> maybe_append_part(if matchers == [], do: nil, else: Enum.join(matchers, ", "))
      |> maybe_append_part(if constraints == [], do: nil, else: "constraints: " <> Enum.join(constraints, ", "))

    Enum.join(parts, " | ")
  end

  @spec from_approval(Approvals.t(), String.t(), keyword()) :: t()
  def from_approval(%Approvals{} = approval, decision_mode, opts \\ [])
      when decision_mode in ["allow_once", "allow_for_session", "allow_via_rule"] do
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())
    scope = normalize_scope(decision_mode, Keyword.get(opts, :scope))
    scope_key = normalize_scope_key(scope, approval, Keyword.get(opts, :scope_key))

    %__MODULE__{
      id: Keyword.get(opts, :id, rule_id()),
      enabled: true,
      scope: scope,
      scope_key: scope_key,
      action_type: approval.action_type,
      match: build_match(approval),
      decision: "allow",
      constraints: build_constraints(approval, opts),
      created_by: normalize_optional_string(Keyword.get(opts, :created_by)),
      created_at: created_at,
      expires_at: expires_at(created_at, Keyword.get(opts, :ttl_ms)),
      reason: build_reason(decision_mode, approval, Keyword.get(opts, :reason)),
      source_approval_id: approval.id,
      remaining_uses: remaining_uses_for_mode(decision_mode)
    }
  end

  @spec active?(t(), DateTime.t()) :: boolean()
  def active?(%__MODULE__{} = rule, now \\ DateTime.utc_now()) do
    rule.enabled == true and scope_present?(rule.scope) and not expired?(rule, now)
  end

  @spec applies_to_run?(t(), String.t() | nil) :: boolean()
  def applies_to_run?(%__MODULE__{scope: "workflow"}, _run_id), do: true
  def applies_to_run?(%__MODULE__{scope: "repository"}, _run_id), do: true

  def applies_to_run?(%__MODULE__{scope: "run", scope_key: scope_key}, run_id)
      when is_binary(scope_key) and is_binary(run_id) do
    scope_key == run_id
  end

  def applies_to_run?(_rule, _run_id), do: false

  @spec matches?(t(), map(), map()) :: boolean()
  def matches?(%__MODULE__{} = rule, evaluation, context \\ %{})
      when is_map(evaluation) and is_map(context) do
    active?(rule) and
      applies_to_run?(rule, normalize_optional_string(Map.get(context, :run_id))) and
      match_field?(rule.action_type, Map.get(evaluation, :action_type)) and
      match_map?(rule.match || %{}, evaluation)
  end

  @spec consume(t()) :: t()
  def consume(%__MODULE__{remaining_uses: 1} = rule) do
    %{rule | enabled: false, remaining_uses: 0}
  end

  def consume(%__MODULE__{remaining_uses: uses} = rule) when is_integer(uses) and uses > 1 do
    %{rule | remaining_uses: uses - 1}
  end

  def consume(%__MODULE__{} = rule), do: rule

  @spec disable(t(), keyword()) :: t()
  def disable(%__MODULE__{} = rule, opts \\ []) do
    disabled_at = Keyword.get(opts, :disabled_at, DateTime.utc_now())

    %{
      rule
      | enabled: false,
        expires_at: rule.expires_at || disabled_at,
        reason: normalize_optional_string(Keyword.get(opts, :reason)) || rule.reason
    }
  end

  @spec enable(t(), keyword()) :: t()
  def enable(%__MODULE__{} = rule, opts \\ []) do
    enabled_at = Keyword.get(opts, :enabled_at, DateTime.utc_now())
    ttl_ms = Keyword.get(opts, :ttl_ms)

    %{
      rule
      | enabled: true,
        created_at: rule.created_at || enabled_at,
        expires_at: expires_at(enabled_at, ttl_ms),
        reason: normalize_optional_string(Keyword.get(opts, :reason)) || rule.reason,
        remaining_uses: if(rule.remaining_uses == 0, do: 1, else: rule.remaining_uses)
    }
  end

  @spec expire(t(), keyword()) :: t()
  def expire(%__MODULE__{} = rule, opts \\ []) do
    expired_at = Keyword.get(opts, :expired_at, DateTime.utc_now())

    %{
      rule
      | enabled: false,
        expires_at: expired_at,
        reason: normalize_optional_string(Keyword.get(opts, :reason)) || rule.reason
    }
  end

  @spec snapshot_entry(t()) :: map()
  def snapshot_entry(%__MODULE__{} = rule) do
    %{
      id: rule.id,
      enabled: rule.enabled,
      scope: rule.scope,
      scope_key: rule.scope_key,
      action_type: rule.action_type,
      match: rule.match,
      decision: rule.decision,
      constraints: rule.constraints,
      created_by: rule.created_by,
      created_at: iso8601(rule.created_at),
      expires_at: iso8601(rule.expires_at),
      reason: rule.reason,
      source_approval_id: rule.source_approval_id,
      remaining_uses: rule.remaining_uses
    }
  end

  @spec from_snapshot(map()) :: t() | nil
  def from_snapshot(snapshot) when is_map(snapshot) do
    %__MODULE__{
      id: normalize_optional_string(Map.get(snapshot, "id") || Map.get(snapshot, :id)),
      enabled: truthy?(field_value(snapshot, "enabled", :enabled)),
      scope: normalize_optional_string(Map.get(snapshot, "scope") || Map.get(snapshot, :scope)),
      scope_key: normalize_optional_string(Map.get(snapshot, "scope_key") || Map.get(snapshot, :scope_key)),
      action_type: normalize_optional_string(Map.get(snapshot, "action_type") || Map.get(snapshot, :action_type)),
      match: normalize_map(Map.get(snapshot, "match") || Map.get(snapshot, :match)),
      decision: normalize_optional_string(Map.get(snapshot, "decision") || Map.get(snapshot, :decision)),
      constraints: normalize_map(Map.get(snapshot, "constraints") || Map.get(snapshot, :constraints)),
      created_by: normalize_optional_string(Map.get(snapshot, "created_by") || Map.get(snapshot, :created_by)),
      created_at: parse_datetime(Map.get(snapshot, "created_at") || Map.get(snapshot, :created_at)),
      expires_at: parse_datetime(Map.get(snapshot, "expires_at") || Map.get(snapshot, :expires_at)),
      reason: normalize_optional_string(Map.get(snapshot, "reason") || Map.get(snapshot, :reason)),
      source_approval_id: normalize_optional_string(Map.get(snapshot, "source_approval_id") || Map.get(snapshot, :source_approval_id)),
      remaining_uses: normalize_integer(Map.get(snapshot, "remaining_uses") || Map.get(snapshot, :remaining_uses))
    }
    |> case do
      %__MODULE__{id: nil} -> nil
      %__MODULE__{scope: nil} -> nil
      %__MODULE__{} = rule -> rule
    end
  end

  def from_snapshot(_snapshot), do: nil

  defp build_match(%Approvals{} = approval) do
    details = approval.details || %{}

    %{}
    |> maybe_put_match_value("fingerprint", approval.fingerprint)
    |> maybe_put_match_value("method", approval.method)
    |> maybe_put_match_value("command_executable", Map.get(details, "command_executable"))
    |> maybe_put_match_value("shell_wrapper", Map.get(details, "shell_wrapper"))
    |> maybe_put_match_value("network_access", Map.get(details, "network_access"))
    |> maybe_put_match_value("file_paths", Map.get(details, "file_paths"))
    |> maybe_put_match_value("sensitive_paths", Map.get(details, "sensitive_paths"))
  end

  defp build_constraints(%Approvals{} = approval, opts) do
    details = approval.details || %{}

    %{}
    |> maybe_put_match_value("workspace_only", true)
    |> maybe_put_match_value("network_access", Keyword.get(opts, :network_access, false))
    |> maybe_put_match_value("cwd", Map.get(details, "cwd"))
  end

  defp build_reason(decision_mode, %Approvals{} = approval, nil) do
    default =
      case decision_mode do
        "allow_once" -> "operator approved once"
        "allow_for_session" -> "operator approved for current run"
        "allow_via_rule" -> "operator created allow rule"
      end

    default <> ": " <> (approval.summary || approval.action_type || "approval")
  end

  defp build_reason(_decision_mode, _approval, reason), do: normalize_optional_string(reason)

  defp remaining_uses_for_mode("allow_once"), do: 1
  defp remaining_uses_for_mode(_mode), do: nil

  defp normalize_scope("allow_via_rule", nil), do: "workflow"
  defp normalize_scope(_decision_mode, scope) when scope in ["run", "workflow", "repository"], do: scope
  defp normalize_scope(_decision_mode, _scope), do: "run"

  defp normalize_scope_key("run", %Approvals{run_id: run_id}, nil), do: run_id
  defp normalize_scope_key(_scope, _approval, scope_key) when is_binary(scope_key), do: scope_key
  defp normalize_scope_key(_scope, _approval, _scope_key), do: nil

  defp match_map?(matchers, _evaluation) when map_size(matchers) == 0, do: true

  defp match_map?(matchers, evaluation) do
    Enum.all?(matchers, fn
      {"fingerprint", expected} ->
        match_field?(expected, Map.get(evaluation, :fingerprint))

      {"method", expected} ->
        match_field?(expected, Map.get(evaluation, :method))

      {"command_executable", expected} ->
        details = Map.get(evaluation, :details, %{})
        match_field?(expected, Map.get(details, "command_executable"))

      {"shell_wrapper", expected} ->
        details = Map.get(evaluation, :details, %{})
        match_field?(expected, Map.get(details, "shell_wrapper"))

      {"cwd", expected} ->
        details = Map.get(evaluation, :details, %{})
        match_field?(expected, Map.get(details, "cwd"))

      {"network_access", expected} when is_boolean(expected) ->
        details = Map.get(evaluation, :details, %{})

        requested =
          case Map.get(details, "network_access") do
            value when is_boolean(value) -> value
            _ -> false
          end

        requested == expected

      {"file_paths", expected} when is_list(expected) ->
        details = Map.get(evaluation, :details, %{})
        list_field_matches?(expected, Map.get(details, "file_paths"))

      {"sensitive_paths", expected} when is_list(expected) ->
        details = Map.get(evaluation, :details, %{})
        list_field_matches?(expected, Map.get(details, "sensitive_paths"))

      {_key, nil} ->
        true

      {_key, _value} ->
        true
    end)
  end

  defp match_field?(nil, _actual), do: true
  defp match_field?(expected, actual) when is_binary(expected) and is_binary(actual), do: expected == actual
  defp match_field?(expected, actual), do: expected == actual

  defp list_field_matches?(expected, actual) when is_list(expected) and is_list(actual) do
    Enum.sort(expected) == Enum.sort(actual)
  end

  defp list_field_matches?(_expected, _actual), do: false

  defp maybe_put_match_value(map, _key, nil), do: map
  defp maybe_put_match_value(map, key, value), do: Map.put(map, key, value)

  defp maybe_append_part(parts, nil), do: parts
  defp maybe_append_part(parts, ""), do: parts
  defp maybe_append_part(parts, part), do: parts ++ [part]

  defp describe_matcher(_key, nil), do: nil

  defp describe_matcher("network_access", true), do: "network access"
  defp describe_matcher("network_access", false), do: "no network access"
  defp describe_matcher("file_paths", values) when is_list(values), do: "paths: " <> preview_list(values)
  defp describe_matcher("sensitive_paths", values) when is_list(values), do: "sensitive paths: " <> preview_list(values)
  defp describe_matcher("command_executable", value) when is_binary(value), do: "executable: " <> value
  defp describe_matcher("shell_wrapper", value) when is_binary(value), do: "wrapper: " <> value
  defp describe_matcher("fingerprint", value) when is_binary(value), do: "fingerprint: " <> value
  defp describe_matcher("method", value) when is_binary(value), do: "method: " <> value
  defp describe_matcher(_key, value), do: inspect(value)

  defp describe_constraint(_key, nil), do: nil
  defp describe_constraint("workspace_only", true), do: "workspace only"
  defp describe_constraint("cwd", value) when is_binary(value), do: "cwd=" <> value
  defp describe_constraint(_key, value), do: inspect(value)

  defp preview_list(values) when is_list(values) do
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

  defp rule_id do
    "rule-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp expired?(%__MODULE__{expires_at: nil}, _now), do: false

  defp expired?(%__MODULE__{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, now) != :gt
  end

  defp expired?(_rule, _now), do: false

  defp scope_present?(scope) when scope in ["run", "workflow", "repository"], do: true
  defp scope_present?(_scope), do: false

  defp expires_at(_created_at, ttl_ms) when not is_integer(ttl_ms) or ttl_ms <= 0, do: nil
  defp expires_at(%DateTime{} = created_at, ttl_ms), do: DateTime.add(created_at, ttl_ms, :millisecond)

  defp normalize_map(%{} = value), do: Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  defp normalize_map(_value), do: %{}

  defp normalize_integer(value) when is_integer(value), do: value

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp normalize_integer(_value), do: nil

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp field_value(snapshot, string_key, atom_key) when is_map(snapshot) do
    cond do
      Map.has_key?(snapshot, string_key) -> Map.get(snapshot, string_key)
      Map.has_key?(snapshot, atom_key) -> Map.get(snapshot, atom_key)
      true -> nil
    end
  end

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
