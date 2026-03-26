defmodule SymphonyElixir.SettingsOverlay do
  @moduledoc """
  Persists and resolves operator-managed runtime setting overrides on top of WORKFLOW.md.
  """

  require Logger

  alias SymphonyElixir.{Config.Schema, LogFile, Workflow}

  @overlay_version 1
  @history_limit 50

  @field_definitions %{
    "agent.max_concurrent_agents" => %{
      group: "Throughput",
      label: "Max Concurrent Agents",
      description: "Maximum issue runs Symphony may dispatch at once.",
      type: :integer,
      apply_mode: "next dispatch"
    },
    "agent.max_turns" => %{
      group: "Throughput",
      label: "Max Turns",
      description: "Upper bound for Codex turns per run.",
      type: :integer,
      apply_mode: "next dispatch"
    },
    "agent.continue_on_active_issue" => %{
      group: "Continuation",
      label: "Continue On Active Issue",
      description: "Whether a completed turn should continue automatically while the ticket stays active.",
      type: :boolean,
      apply_mode: "next dispatch"
    },
    "agent.max_concurrent_agents_by_state" => %{
      group: "Throughput",
      label: "Per-State Concurrency Limits",
      description: "JSON map of tracker state to concurrency limit.",
      type: :integer_map,
      apply_mode: "next dispatch"
    },
    "agent.completed_issue_state" => %{
      group: "Continuation",
      label: "Completed Issue State",
      description: "Default state to move an issue to after a successful run. Leave blank to clear.",
      type: :string,
      apply_mode: "next dispatch"
    },
    "agent.completed_issue_state_by_state" => %{
      group: "Continuation",
      label: "Completed State Overrides",
      description: "JSON map of source state to completed state override.",
      type: :string_map,
      apply_mode: "next dispatch"
    },
    "codex.command" => %{
      group: "Codex",
      label: "Codex Command",
      description: "Base Codex launch command. Advanced flags stay here; model and reasoning overrides rewrite their matching launch flags.",
      type: :string,
      apply_mode: "next dispatch"
    },
    "codex.model" => %{
      group: "Codex",
      label: "Codex Model",
      description: "Model passed to Codex with `--model` on the next worker dispatch.",
      type: :string,
      apply_mode: "next dispatch"
    },
    "codex.reasoning_effort" => %{
      group: "Codex",
      label: "Reasoning Effort",
      description: "Reasoning effort passed via `--config model_reasoning_effort=...` on the next worker dispatch.",
      type: :string,
      apply_mode: "next dispatch"
    },
    "observability.refresh_ms" => %{
      group: "Audit And Dashboard",
      label: "Refresh Interval (ms)",
      description: "Terminal/dashboard refresh cadence for the status surface.",
      type: :integer,
      apply_mode: "next runtime read"
    },
    "observability.audit_dashboard_runs" => %{
      group: "Audit And Dashboard",
      label: "Dashboard Run Limit",
      description: "How many persisted runs to show in the dashboard history slice.",
      type: :integer,
      apply_mode: "immediate"
    },
    "observability.issue_rollup_limit" => %{
      group: "Audit And Dashboard",
      label: "Issue Rollup Limit",
      description: "How many issue rollups to show in the dashboard.",
      type: :integer,
      apply_mode: "immediate"
    },
    "observability.expensive_run_uncached_input_threshold" => %{
      group: "Efficiency Thresholds",
      label: "Expensive Run Uncached Input Threshold",
      description: "Uncached input token threshold for advisory expensive-run labeling.",
      type: :integer,
      apply_mode: "immediate"
    },
    "observability.expensive_run_tokens_per_changed_file_threshold" => %{
      group: "Efficiency Thresholds",
      label: "Expensive Run Tokens Per Changed File Threshold",
      description: "Tokens-per-file threshold for advisory expensive-run labeling.",
      type: :integer,
      apply_mode: "immediate"
    },
    "observability.expensive_run_retry_attempt_threshold" => %{
      group: "Efficiency Thresholds",
      label: "Expensive Run Retry Threshold",
      description: "Retry-attempt threshold for advisory expensive-run labeling.",
      type: :integer,
      apply_mode: "immediate"
    },
    "guardrails.default_review_mode" => %{
      group: "Guardrails",
      label: "Default Review Mode",
      description: "Default handling when a risky action is not auto-allowed by policy.",
      type: :enum,
      options: ["review", "deny"],
      apply_mode: "next dispatch"
    },
    "guardrails.builtin_rule_preset" => %{
      group: "Guardrails",
      label: "Builtin Rule Preset",
      description: "Builtin guardrail preset to use for operator-supervised runs.",
      type: :enum,
      options: ["safe", "off"],
      apply_mode: "next dispatch"
    }
  }

  @spec field_definitions() :: map()
  def field_definitions, do: @field_definitions

  @spec apply_to_workflow_config(map()) :: map()
  def apply_to_workflow_config(config) when is_map(config) do
    case overlay_changes() do
      {:ok, changes} when changes == %{} ->
        config

      {:ok, changes} ->
        deep_merge(config, changes)

      {:error, reason} ->
        Logger.warning("Failed to read runtime settings overlay: #{inspect(reason)}; falling back to WORKFLOW.md only")
        config
    end
  end

  @spec payload(keyword()) :: {:ok, map()} | {:error, term()}
  def payload(opts \\ []) do
    history_limit = Keyword.get(opts, :history_limit, 20)

    with {:ok, %{config: workflow_config}} <- Workflow.current(),
         {:ok, overlay_doc} <- overlay_document(),
         {:ok, default_settings} <- Schema.parse(%{}),
         {:ok, workflow_settings} <- Schema.parse(workflow_config),
         {:ok, effective_settings} <- Schema.parse(deep_merge(workflow_config, overlay_changes_from_doc(overlay_doc))) do
      history = history(history_limit)

      {:ok,
       %{
         generated_at: now_iso8601(),
         overlay: overlay_payload(overlay_doc),
         settings:
           describe_fields(
             workflow_config,
             overlay_changes_from_doc(overlay_doc),
             default_settings,
             workflow_settings,
             effective_settings
           ),
         settings_history: history
       }}
    end
  end

  @spec overlay_payload() :: {:ok, map()} | {:error, term()}
  def overlay_payload do
    with {:ok, overlay_doc} <- overlay_document() do
      {:ok, overlay_payload(overlay_doc)}
    end
  end

  @spec history(non_neg_integer()) :: [map()]
  def history(limit \\ @history_limit) when is_integer(limit) and limit > 0 do
    history_dir = history_dir()

    history_dir
    |> File.ls()
    |> case do
      {:ok, files} ->
        files
        |> Enum.sort(:desc)
        |> Enum.take(limit)
        |> Enum.map(&Path.join(history_dir, &1))
        |> Enum.map(&read_json_file/1)
        |> Enum.filter(&is_map/1)

      _ ->
        []
    end
  end

  @spec update_overlay(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_overlay(changes, opts \\ []) when is_map(changes) do
    with {:ok, normalized_changes, changed_paths} <- normalize_changes(changes),
         {:ok, overlay_doc} <- overlay_document(),
         {:ok, %{config: workflow_config}} <- Workflow.current(),
         merged_changes <- deep_merge(overlay_changes_from_doc(overlay_doc), normalized_changes),
         :ok <- validate_effective_config(workflow_config, merged_changes),
         updated_doc <- updated_overlay_doc(overlay_doc, merged_changes, opts),
         :ok <- persist_overlay_doc(updated_doc),
         :ok <- persist_history_entry("update", changed_paths, normalized_changes, overlay_doc, updated_doc, opts) do
      payload()
    end
  end

  @spec reset_overlay([String.t()] | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reset_overlay(paths, opts \\ [])

  def reset_overlay(path, opts) when is_binary(path), do: reset_overlay([path], opts)

  def reset_overlay(paths, opts) when is_list(paths) do
    with {:ok, normalized_paths} <- normalize_reset_paths(paths),
         {:ok, overlay_doc} <- overlay_document(),
         {:ok, %{config: workflow_config}} <- Workflow.current(),
         merged_changes <- remove_paths(overlay_changes_from_doc(overlay_doc), normalized_paths),
         :ok <- validate_effective_config(workflow_config, merged_changes),
         updated_doc <- updated_overlay_doc(overlay_doc, merged_changes, opts),
         :ok <- persist_overlay_doc(updated_doc),
         :ok <- persist_history_entry("reset", normalized_paths, %{}, overlay_doc, updated_doc, opts) do
      payload()
    end
  end

  defp normalize_changes(changes) when map_size(changes) == 0, do: {:error, :no_setting_changes}

  defp normalize_changes(changes) do
    Enum.reduce_while(changes, {:ok, %{}, []}, fn {path, raw_value}, {:ok, acc, paths} ->
      case normalize_change(path, raw_value) do
        {:ok, path_segments, cast_value} ->
          {:cont, {:ok, put_nested(acc, path_segments, cast_value), [Enum.join(path_segments, ".") | paths]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized, paths} -> {:ok, normalized, Enum.sort(paths)}
      other -> other
    end
  end

  defp normalize_change(path, raw_value) when is_binary(path) do
    with {:ok, path_segments, definition} <- allowed_path(path),
         {:ok, cast_value} <- cast_value(definition, raw_value, path) do
      {:ok, path_segments, cast_value}
    end
  end

  defp normalize_change(_path, _raw_value), do: {:error, :invalid_setting_path}

  defp normalize_reset_paths(paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case allowed_path(path) do
        {:ok, path_segments, _definition} -> {:cont, {:ok, [path_segments | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, segments}
      other -> other
    end
  end

  defp normalize_reset_paths(_paths), do: {:error, :no_setting_paths}

  defp cast_value(%{type: :integer}, raw_value, path) do
    case Integer.parse(to_string(raw_value)) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_setting_value, path, "must be a positive integer"}}
    end
  end

  defp cast_value(%{type: :boolean}, raw_value, path) do
    case normalize_boolean(raw_value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_setting_value, path, "must be true or false"}}
    end
  end

  defp cast_value(%{type: :enum, options: options}, raw_value, path) do
    value = to_string(raw_value)

    if value in options do
      {:ok, value}
    else
      {:error, {:invalid_setting_value, path, "must be one of #{Enum.join(options, ", ")}"}}
    end
  end

  defp cast_value(%{type: :string}, raw_value, _path), do: {:ok, to_string(raw_value)}

  defp cast_value(%{type: :integer_map}, raw_value, path) do
    with {:ok, value} <- decode_json_map(raw_value, path),
         {:ok, normalized} <- normalize_integer_map(value, path) do
      {:ok, normalized}
    end
  end

  defp cast_value(%{type: :string_map}, raw_value, path) do
    with {:ok, value} <- decode_json_map(raw_value, path),
         {:ok, normalized} <- normalize_string_map(value, path) do
      {:ok, normalized}
    end
  end

  defp allowed_path(path) when is_binary(path) do
    normalized_path = String.trim(path)

    case Map.get(@field_definitions, normalized_path) do
      nil -> {:error, {:setting_not_ui_manageable, normalized_path}}
      definition -> {:ok, String.split(normalized_path, "."), definition}
    end
  end

  defp allowed_path(_path), do: {:error, :invalid_setting_path}

  defp normalize_boolean(value) when value in [true, "true", "TRUE", "True", 1, "1"], do: {:ok, true}
  defp normalize_boolean(value) when value in [false, "false", "FALSE", "False", 0, "0"], do: {:ok, false}
  defp normalize_boolean(_value), do: :error

  defp decode_json_map(value, path) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, %{}}
      json -> Jason.decode(json)
    end
    |> case do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, {:invalid_setting_value, path, "must be a JSON object"}}
      {:error, _reason} -> {:error, {:invalid_setting_value, path, "must be valid JSON"}}
    end
  end

  defp decode_json_map(value, _path) when is_map(value), do: {:ok, value}
  defp decode_json_map(_value, path), do: {:error, {:invalid_setting_value, path, "must be a JSON object"}}

  defp normalize_integer_map(value, path) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {raw_key, raw_value}, {:ok, acc} ->
      key = to_string(raw_key)

      case Integer.parse(to_string(raw_value)) do
        {limit, ""} when limit > 0 ->
          {:cont, {:ok, Map.put(acc, key, limit)}}

        _ ->
          {:halt, {:error, {:invalid_setting_value, path, "map values must be positive integers"}}}
      end
    end)
  end

  defp normalize_string_map(value, path) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {raw_key, raw_value}, {:ok, acc} ->
      key = to_string(raw_key)
      normalized = Schema.normalize_string_value(to_string(raw_value))

      if normalized do
        {:cont, {:ok, Map.put(acc, key, normalized)}}
      else
        {:halt, {:error, {:invalid_setting_value, path, "map values must be non-blank strings"}}}
      end
    end)
  end

  defp validate_effective_config(workflow_config, overlay_changes) do
    case Schema.parse(deep_merge(workflow_config, overlay_changes)) do
      {:ok, _settings} -> :ok
      {:error, {:invalid_workflow_config, message}} -> {:error, {:invalid_setting_patch, message}}
    end
  end

  defp overlay_document do
    case read_json_file(overlay_path()) do
      nil ->
        {:ok, %{"version" => @overlay_version, "changes" => %{}}}

      %{} = overlay_doc ->
        {:ok, overlay_doc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp overlay_payload(overlay_doc) do
    %{
      version: Map.get(overlay_doc, "version", @overlay_version),
      updated_at: Map.get(overlay_doc, "updated_at"),
      updated_by: Map.get(overlay_doc, "updated_by"),
      reason: Map.get(overlay_doc, "reason"),
      changes: overlay_changes_from_doc(overlay_doc)
    }
  end

  defp overlay_changes do
    case overlay_document() do
      {:ok, overlay_doc} -> {:ok, overlay_changes_from_doc(overlay_doc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp overlay_changes_from_doc(overlay_doc) when is_map(overlay_doc) do
    case Map.get(overlay_doc, "changes") do
      %{} = changes -> changes
      _ -> %{}
    end
  end

  defp describe_fields(workflow_config, overlay_changes, default_settings, workflow_settings, effective_settings) do
    @field_definitions
    |> Enum.sort_by(fn {path, definition} -> {definition.group, path} end)
    |> Enum.map(fn {path, definition} ->
      workflow_explicit? = path_present?(workflow_config, path)
      overlay_present? = path_present?(overlay_changes, path)
      effective_value = get_path_value(effective_settings, path)
      workflow_value = get_path_value(workflow_settings, path)
      default_value = get_path_value(default_settings, path)
      overlay_value = get_path_value(overlay_changes, path)

      %{
        path: path,
        group: definition.group,
        label: definition.label,
        description: definition.description,
        type: Atom.to_string(definition.type),
        apply_mode: definition.apply_mode,
        options: field_options(definition),
        source: field_source(workflow_explicit?, overlay_present?),
        source_label: field_source_label(field_source(workflow_explicit?, overlay_present?)),
        effective_value: effective_value,
        workflow_value: workflow_value,
        default_value: default_value,
        overlay_value: overlay_value,
        editable_value: editable_value(definition, effective_value)
      }
    end)
  end

  defp field_options(%{type: :boolean}) do
    [%{value: "true", label: "true"}, %{value: "false", label: "false"}]
  end

  defp field_options(%{type: :enum, options: options}) do
    options
  end

  defp field_options(_definition), do: []

  defp field_source(_workflow_explicit?, true), do: "ui_override"
  defp field_source(true, false), do: "workflow"
  defp field_source(false, false), do: "default"

  defp field_source_label("ui_override"), do: "UI override"
  defp field_source_label("workflow"), do: "Workflow"
  defp field_source_label("default"), do: "Default"
  defp field_source_label(source), do: source

  defp editable_value(%{type: :integer}, value) when is_integer(value), do: Integer.to_string(value)
  defp editable_value(%{type: :boolean}, true), do: "true"
  defp editable_value(%{type: :boolean}, false), do: "false"
  defp editable_value(%{type: :enum}, value) when is_binary(value), do: value
  defp editable_value(%{type: :string}, value) when is_binary(value), do: value

  defp editable_value(%{type: type}, value) when type in [:integer_map, :string_map] and is_map(value) do
    Jason.encode!(value, pretty: true)
  end

  defp editable_value(_definition, nil), do: ""
  defp editable_value(_definition, value), do: to_string(value)

  defp updated_overlay_doc(previous_doc, changes, opts) do
    now = now_iso8601()

    %{
      "version" => Map.get(previous_doc, "version", @overlay_version),
      "updated_at" => now,
      "updated_by" => Keyword.get(opts, :actor, "system"),
      "reason" => Keyword.get(opts, :reason),
      "changes" => prune_empty_maps(changes)
    }
  end

  defp persist_overlay_doc(overlay_doc) when is_map(overlay_doc) do
    :ok = File.mkdir_p(settings_dir())
    :ok = File.write(overlay_path(), Jason.encode_to_iodata!(overlay_doc, pretty: true))
  rescue
    exception ->
      {:error, {:overlay_persist_failed, Exception.message(exception)}}
  end

  defp persist_history_entry(action, paths, changes, previous_doc, updated_doc, opts) do
    normalized_paths = normalize_history_paths(paths)
    previous_changes = overlay_changes_from_doc(previous_doc)
    next_changes = overlay_changes_from_doc(updated_doc)

    entry = %{
      "id" => history_entry_id(),
      "action" => action,
      "recorded_at" => now_iso8601(),
      "actor" => Keyword.get(opts, :actor, "system"),
      "reason" => Keyword.get(opts, :reason),
      "paths" => normalized_paths,
      "previous_changes" => previous_changes,
      "next_changes" => next_changes,
      "previous_values" => values_for_paths(previous_changes, normalized_paths),
      "new_values" => values_for_paths(next_changes, normalized_paths),
      "applied_changes" => changes
    }

    :ok = File.mkdir_p(history_dir())
    :ok = File.write(Path.join(history_dir(), entry["id"] <> ".json"), Jason.encode_to_iodata!(entry, pretty: true))
  rescue
    exception ->
      {:error, {:history_persist_failed, Exception.message(exception)}}
  end

  defp get_path_value(data, path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(data, fn segment, acc ->
      cond do
        is_nil(acc) ->
          nil

        is_map(acc) ->
          get_segment_value(acc, segment)

        true ->
          nil
      end
    end)
  end

  defp path_present?(data, path) when is_map(data) and is_binary(path) do
    path
    |> String.split(".")
    |> do_path_present?(data)
  end

  defp path_present?(_data, _path), do: false

  defp do_path_present?([], _data), do: true

  defp do_path_present?([segment | rest], data) when is_map(data) do
    case get_segment_value(data, segment, :missing) do
      :missing -> false
      value -> do_path_present?(rest, value)
    end
  end

  defp do_path_present?(_segments, _data), do: false

  defp put_nested(map, [segment], value) when is_map(map), do: Map.put(map, segment, value)

  defp put_nested(map, [segment | rest], value) when is_map(map) do
    nested = Map.get(map, segment, %{})
    Map.put(map, segment, put_nested(nested, rest, value))
  end

  defp remove_paths(map, paths) when is_map(map) and is_list(paths) do
    Enum.reduce(paths, map, &remove_path(&2, &1))
    |> prune_empty_maps()
  end

  defp remove_path(map, [segment]) when is_map(map), do: Map.delete(map, segment)

  defp remove_path(map, [segment | rest]) when is_map(map) do
    case Map.get(map, segment) do
      %{} = nested ->
        next_nested = remove_path(nested, rest)

        if next_nested == %{} do
          Map.delete(map, segment)
        else
          Map.put(map, segment, next_nested)
        end

      _ ->
        map
    end
  end

  defp prune_empty_maps(value) when is_map(value) do
    value
    |> Enum.reduce(%{}, fn {key, nested}, acc ->
      pruned = prune_empty_maps(nested)

      cond do
        pruned == %{} -> acc
        is_nil(pruned) -> acc
        true -> Map.put(acc, key, pruned)
      end
    end)
  end

  defp prune_empty_maps(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right

  defp settings_dir do
    audit_root()
    |> Path.join("settings")
  end

  defp overlay_path do
    settings_dir()
    |> Path.join("runtime_overlay.json")
  end

  defp history_dir do
    settings_dir()
    |> Path.join("history")
  end

  defp history_entry_id do
    "#{current_time() |> DateTime.to_unix(:millisecond)}-#{System.unique_integer([:positive])}"
  end

  defp now_iso8601 do
    current_time()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp current_time do
    case Application.get_env(:symphony_elixir, :ui_visual_now) do
      %DateTime{} = datetime ->
        datetime

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> DateTime.utc_now()
        end

      _ ->
        DateTime.utc_now()
    end
  end

  defp values_for_paths(changes, paths) when is_map(changes) and is_list(paths) do
    Enum.into(paths, %{}, fn path -> {path, get_path_value(changes, path)} end)
  end

  defp normalize_history_paths(paths) when is_list(paths) do
    Enum.map(paths, fn
      path when is_binary(path) -> path
      segments when is_list(segments) -> Enum.join(segments, ".")
    end)
  end

  defp get_segment_value(data, segment, fallback \\ nil)

  defp get_segment_value(data, segment, fallback) when is_map(data) and is_binary(segment) do
    cond do
      Map.has_key?(data, segment) ->
        Map.get(data, segment)

      true ->
        case safe_existing_atom(segment) do
          {:ok, atom_segment} ->
            if Map.has_key?(data, atom_segment), do: Map.get(data, atom_segment), else: fallback

          _ ->
            fallback
        end
    end
  end

  defp get_segment_value(_data, _segment, fallback), do: fallback

  defp safe_existing_atom(segment) when is_binary(segment) do
    try do
      {:ok, String.to_existing_atom(segment)}
    rescue
      ArgumentError -> :error
    end
  end

  defp read_json_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = decoded} -> decoded
          {:ok, _decoded} -> {:error, :invalid_json_document}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp audit_root do
    case Application.get_env(:symphony_elixir, :audit_root) do
      root when is_binary(root) and root != "" ->
        Path.expand(root)

      _ ->
        Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
        |> Path.expand()
        |> Path.dirname()
        |> Path.join("audit")
    end
  end
end
