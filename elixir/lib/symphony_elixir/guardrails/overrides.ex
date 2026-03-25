defmodule SymphonyElixir.Guardrails.Overrides do
  @moduledoc false

  defstruct [
    :id,
    :scope,
    :scope_key,
    :mode,
    :status,
    :reason,
    :actor,
    :created_at,
    :expires_at,
    :thread_sandbox,
    :turn_sandbox_policy,
    :network_access
  ]

  @type override :: %__MODULE__{}
  @type state :: %{workflow: override() | nil, runs: %{optional(String.t()) => override()}}

  @spec empty_state() :: state()
  def empty_state, do: %{workflow: nil, runs: %{}}

  @spec full_access_override(:run | :workflow, String.t(), keyword()) :: override()
  def full_access_override(scope, scope_key, opts \\ [])
      when scope in [:run, :workflow] and is_binary(scope_key) do
    created_at = Keyword.get(opts, :created_at, DateTime.utc_now())
    ttl_ms = Keyword.get(opts, :ttl_ms)

    %__MODULE__{
      id: override_id(scope),
      scope: Atom.to_string(scope),
      scope_key: scope_key,
      mode: "full_access",
      status: "active",
      reason: normalize_optional_string(Keyword.get(opts, :reason)) || "operator full access override",
      actor: normalize_optional_string(Keyword.get(opts, :actor)),
      created_at: created_at,
      expires_at: expires_at(created_at, ttl_ms),
      thread_sandbox: "danger-full-access",
      turn_sandbox_policy: %{"type" => "dangerFullAccess"},
      network_access: true
    }
  end

  @spec prune(state(), DateTime.t()) :: state()
  def prune(state, now \\ DateTime.utc_now())

  def prune(%{workflow: workflow, runs: runs} = state, now) when is_map(runs) do
    workflow =
      if active?(workflow, now) do
        workflow
      else
        nil
      end

    runs =
      Enum.reduce(runs, %{}, fn {run_id, override}, acc ->
        if active?(override, now) do
          Map.put(acc, run_id, override)
        else
          acc
        end
      end)

    %{state | workflow: workflow, runs: runs}
  end

  def prune(_state, _now), do: empty_state()

  @spec active_entries(state(), DateTime.t()) :: [override()]
  def active_entries(%{workflow: workflow, runs: runs}, now \\ DateTime.utc_now()) when is_map(runs) do
    workflow_entries =
      case workflow do
        %__MODULE__{} = override ->
          if active?(override, now), do: [override], else: []

        _ ->
          []
      end

    run_entries =
      runs
      |> Map.values()
      |> Enum.filter(&active?(&1, now))

    workflow_entries ++ run_entries
  end

  @spec effective_override(state(), String.t() | nil, DateTime.t()) :: override() | nil
  def effective_override(state, run_id, now \\ DateTime.utc_now())

  def effective_override(%{workflow: workflow, runs: runs}, run_id, now) when is_map(runs) do
    run_override =
      case run_id do
        value when is_binary(value) -> Map.get(runs, value)
        _ -> nil
      end

    cond do
      active?(run_override, now) -> run_override
      active?(workflow, now) -> workflow
      true -> nil
    end
  end

  def effective_override(_state, _run_id, _now), do: nil

  @spec snapshot_entry(override()) :: map()
  def snapshot_entry(%__MODULE__{} = override) do
    %{
      id: override.id,
      scope: override.scope,
      scope_key: override.scope_key,
      mode: override.mode,
      status: override.status,
      reason: override.reason,
      actor: override.actor,
      created_at: iso8601(override.created_at),
      expires_at: iso8601(override.expires_at),
      thread_sandbox: override.thread_sandbox,
      turn_sandbox_policy: override.turn_sandbox_policy,
      network_access: override.network_access
    }
  end

  @spec from_snapshot(map()) :: override() | nil
  def from_snapshot(snapshot) when is_map(snapshot) do
    %__MODULE__{
      id: normalize_optional_string(Map.get(snapshot, "id") || Map.get(snapshot, :id)),
      scope: normalize_optional_string(Map.get(snapshot, "scope") || Map.get(snapshot, :scope)),
      scope_key: normalize_optional_string(Map.get(snapshot, "scope_key") || Map.get(snapshot, :scope_key)),
      mode: normalize_optional_string(Map.get(snapshot, "mode") || Map.get(snapshot, :mode)),
      status: normalize_optional_string(Map.get(snapshot, "status") || Map.get(snapshot, :status)),
      reason: normalize_optional_string(Map.get(snapshot, "reason") || Map.get(snapshot, :reason)),
      actor: normalize_optional_string(Map.get(snapshot, "actor") || Map.get(snapshot, :actor)),
      created_at: parse_datetime(Map.get(snapshot, "created_at") || Map.get(snapshot, :created_at)),
      expires_at: parse_datetime(Map.get(snapshot, "expires_at") || Map.get(snapshot, :expires_at)),
      thread_sandbox: normalize_optional_string(Map.get(snapshot, "thread_sandbox") || Map.get(snapshot, :thread_sandbox)),
      turn_sandbox_policy: normalize_map(Map.get(snapshot, "turn_sandbox_policy") || Map.get(snapshot, :turn_sandbox_policy)),
      network_access: truthy(field_value(snapshot, "network_access", :network_access))
    }
    |> case do
      %__MODULE__{id: nil} -> nil
      %__MODULE__{} = override -> override
    end
  end

  def from_snapshot(_snapshot), do: nil

  @spec disable(override(), keyword()) :: override()
  def disable(%__MODULE__{} = override, opts \\ []) do
    disabled_at = Keyword.get(opts, :disabled_at, DateTime.utc_now())

    %{
      override
      | status: "disabled",
        reason: normalize_optional_string(Keyword.get(opts, :reason)) || override.reason,
        expires_at: override.expires_at || disabled_at
    }
  end

  @spec apply_runtime_settings(map(), override() | nil) :: map()
  def apply_runtime_settings(runtime_settings, nil) when is_map(runtime_settings), do: runtime_settings

  def apply_runtime_settings(runtime_settings, %__MODULE__{mode: "full_access"} = override)
      when is_map(runtime_settings) do
    runtime_settings
    |> Map.put(:approval_policy, "never")
    |> Map.put(:thread_sandbox, override.thread_sandbox)
    |> Map.put(:turn_sandbox_policy, override.turn_sandbox_policy)
  end

  def apply_runtime_settings(runtime_settings, _override) when is_map(runtime_settings), do: runtime_settings

  @spec active?(override() | nil, DateTime.t()) :: boolean()
  def active?(override, now \\ DateTime.utc_now())

  def active?(%__MODULE__{status: "active", expires_at: nil}, _now), do: true

  def active?(%__MODULE__{status: "active", expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, now) == :gt
  end

  def active?(_override, _now), do: false

  defp expires_at(_created_at, ttl_ms) when not is_integer(ttl_ms) or ttl_ms <= 0, do: nil
  defp expires_at(%DateTime{} = created_at, ttl_ms), do: DateTime.add(created_at, ttl_ms, :millisecond)

  defp override_id(scope) do
    scope_prefix =
      case scope do
        :run -> "run"
        :workflow -> "workflow"
      end

    "#{scope_prefix}-override-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_map(%{} = value), do: Map.new(value, fn {key, nested} -> {to_string(key), nested} end)
  defp normalize_map(_value), do: %{}

  defp truthy(value) when value in [true, "true", 1, "1"], do: true
  defp truthy(_value), do: false

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

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(DateTime.truncate(value, :second))
  defp iso8601(_value), do: nil
end
