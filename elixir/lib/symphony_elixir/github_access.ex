defmodule SymphonyElixir.GitHubAccess do
  @moduledoc """
  Persists operator-managed GitHub workspace access settings and a write-only token.
  """

  require Logger

  alias SymphonyElixir.{LogFile, SecretStore}

  @config_version 1
  @history_limit 50
  @token_env "GITHUB_TOKEN"
  @token_file_env "SYMPHONY_GITHUB_TOKEN_FILE"
  @secret_key "github.token"

  @field_definitions %{
    "source_repo_url" => %{
      label: "Source Repo URL",
      description: "Repository URL used by workspace bootstrap hooks for clone/fetch/push.",
      env_var: "SYMPHONY_SOURCE_REPO_URL",
      default: "https://github.com/Noires/light-archives.git",
      apply_mode: "next workspace hook",
      type: :repo_url
    },
    "git_author_name" => %{
      label: "Git Author Name",
      description: "Commit author name used inside workspaces.",
      env_var: "GIT_AUTHOR_NAME",
      default: "Symphony",
      apply_mode: "next workspace hook",
      type: :string
    },
    "git_author_email" => %{
      label: "Git Author Email",
      description: "Commit author email used inside workspaces.",
      env_var: "GIT_AUTHOR_EMAIL",
      default: "symphony@local.invalid",
      apply_mode: "next workspace hook",
      type: :email
    },
    "git_committer_name" => %{
      label: "Git Committer Name",
      description: "Commit committer name used inside workspaces.",
      env_var: "GIT_COMMITTER_NAME",
      default: "Symphony",
      apply_mode: "next workspace hook",
      type: :string
    },
    "git_committer_email" => %{
      label: "Git Committer Email",
      description: "Commit committer email used inside workspaces.",
      env_var: "GIT_COMMITTER_EMAIL",
      default: "symphony@local.invalid",
      apply_mode: "next workspace hook",
      type: :email
    },
    "landing_mode" => %{
      label: "Landing Mode",
      description: "Whether a Merging run should land directly onto main or create/update a pull request from the issue branch.",
      env_var: "SYMPHONY_GITHUB_LANDING_MODE",
      default: "direct_merge",
      apply_mode: "next workspace hook",
      type: :enum,
      options: ["direct_merge", "pull_request"]
    }
  }

  @spec field_definitions() :: map()
  def field_definitions, do: @field_definitions

  @spec payload(keyword()) :: {:ok, map()} | {:error, term()}
  def payload(opts \\ []) do
    history_limit = Keyword.get(opts, :history_limit, 20)

    with {:ok, config_doc} <- config_document(),
         {:ok, token_entry} <- secret_entry() do
      {:ok,
       %{
         generated_at: now_iso8601(),
         config: config_payload(config_doc),
         settings: describe_fields(config_doc),
         token: token_payload(token_entry),
         history: history(history_limit)
       }}
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

  @spec update_config(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_config(changes, opts \\ []) when is_map(changes) do
    with {:ok, normalized_changes, changed_paths} <- normalize_changes(changes),
         {:ok, config_doc} <- config_document(),
         merged_values <- Map.merge(config_values_from_doc(config_doc), normalized_changes),
         updated_doc <- updated_config_doc(config_doc, merged_values, opts),
         :ok <- persist_config_doc(updated_doc),
         :ok <- persist_history_entry("config_update", changed_paths, normalized_changes, config_doc, updated_doc, opts) do
      payload()
    end
  end

  @spec reset_config([String.t()] | String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reset_config(paths, opts \\ [])

  def reset_config(path, opts) when is_binary(path), do: reset_config([path], opts)

  def reset_config(paths, opts) when is_list(paths) do
    with {:ok, normalized_paths} <- normalize_reset_paths(paths),
         {:ok, config_doc} <- config_document(),
         merged_values <- Map.drop(config_values_from_doc(config_doc), normalized_paths),
         updated_doc <- updated_config_doc(config_doc, merged_values, opts),
         :ok <- persist_config_doc(updated_doc),
         :ok <- persist_history_entry("config_reset", normalized_paths, %{}, config_doc, updated_doc, opts) do
      payload()
    end
  end

  @spec set_token(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def set_token(raw_token, opts \\ [])

  def set_token(raw_token, opts) when is_binary(raw_token) do
    with {:ok, token} <- normalize_token(raw_token),
         {:ok, previous_entry} <- secret_entry(),
         {:ok, _updated_entry} <- SecretStore.set(@secret_key, token, opts),
         {:ok, current_entry} <- secret_entry(),
         :ok <- maybe_remove_legacy_token_files(),
         :ok <- persist_token_history_entry("token_set", previous_entry, current_entry, opts) do
      payload()
    end
  end

  def set_token(_raw_token, _opts), do: {:error, {:invalid_token_value, "must be a non-blank string"}}

  @spec clear_token(keyword()) :: {:ok, map()} | {:error, term()}
  def clear_token(opts \\ []) do
    with {:ok, previous_entry} <- secret_entry(),
         {:ok, _updated_entry} <- SecretStore.clear(@secret_key, opts),
         {:ok, current_entry} <- secret_entry(),
         :ok <- maybe_remove_legacy_token_files(),
         :ok <- persist_token_history_entry("token_clear", previous_entry, current_entry, opts) do
      payload()
    end
  end

  @spec hook_env_overrides(String.t() | nil) :: [{String.t(), String.t()}]
  def hook_env_overrides(worker_host \\ nil) do
    base =
      @field_definitions
      |> Enum.map(fn {path, definition} -> {definition.env_var, effective_value(path)} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case effective_token_info() do
      %{token: token, source: "ui_secret"} when is_binary(token) and is_nil(worker_host) ->
        [{@token_file_env, token_file_path()} | base]

      %{token: token} when is_binary(token) and is_binary(worker_host) ->
        [{"GITHUB_TOKEN", token} | base]

      _ ->
        base
    end
  end

  @spec apply_tracker_token(term()) :: term()
  def apply_tracker_token(%{tracker: %{kind: "github", api_token: api_token} = tracker} = settings) do
    normalized_api_token = blank_to_nil(api_token)

    case effective_token_info() do
      %{token: token, source: "ui_secret"} when is_binary(token) ->
        %{settings | tracker: %{tracker | api_token: token}}

      %{token: token} when is_binary(token) and is_nil(normalized_api_token) ->
        %{settings | tracker: %{tracker | api_token: token}}

      _ ->
        settings
    end
  end

  def apply_tracker_token(settings), do: settings

  @spec effective_token() :: String.t() | nil
  def effective_token do
    case effective_token_info() do
      %{token: token} when is_binary(token) -> token
      _ -> nil
    end
  end

  @spec effective_config_value(String.t()) :: String.t() | nil
  def effective_config_value(path) when is_binary(path) do
    if Map.has_key?(@field_definitions, path) do
      effective_value(path)
    else
      nil
    end
  end

  @spec token_file_path() :: Path.t()
  def token_file_path do
    SecretStore.file_path(@secret_key)
  end

  defp normalize_changes(changes) when map_size(changes) == 0, do: {:error, :no_github_config_changes}

  defp normalize_changes(changes) do
    Enum.reduce_while(changes, {:ok, %{}, []}, fn {path, raw_value}, {:ok, acc, paths} ->
      case normalize_change(path, raw_value) do
        {:ok, normalized_path, cast_value} ->
          {:cont, {:ok, Map.put(acc, normalized_path, cast_value), [normalized_path | paths]}}

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
    normalized_path = String.trim(path)

    case Map.get(@field_definitions, normalized_path) do
      nil ->
        {:error, {:github_setting_not_ui_manageable, normalized_path}}

      definition ->
        with {:ok, cast_value} <- cast_value(definition, raw_value, normalized_path) do
          {:ok, normalized_path, cast_value}
        end
    end
  end

  defp normalize_change(_path, _raw_value), do: {:error, :invalid_github_setting_path}

  defp normalize_reset_paths(paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case normalize_reset_path(path) do
        {:ok, normalized_path} -> {:cont, {:ok, [normalized_path | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized_paths} -> {:ok, Enum.sort(normalized_paths)}
      other -> other
    end
  end

  defp normalize_reset_paths(_paths), do: {:error, :no_github_setting_paths}

  defp normalize_reset_path(path) when is_binary(path) do
    normalized_path = String.trim(path)

    if Map.has_key?(@field_definitions, normalized_path) do
      {:ok, normalized_path}
    else
      {:error, {:github_setting_not_ui_manageable, normalized_path}}
    end
  end

  defp normalize_reset_path(_path), do: {:error, :invalid_github_setting_path}

  defp cast_value(%{type: :string}, raw_value, path) do
    case blank_to_nil(to_string(raw_value)) do
      nil -> {:error, {:invalid_github_setting_value, path, "must be a non-blank string"}}
      value -> {:ok, value}
    end
  end

  defp cast_value(%{type: :email}, raw_value, path) do
    case blank_to_nil(to_string(raw_value)) do
      nil ->
        {:error, {:invalid_github_setting_value, path, "must be a non-blank email"}}

      value ->
        if String.contains?(value, "@") do
          {:ok, value}
        else
          {:error, {:invalid_github_setting_value, path, "must look like an email address"}}
        end
    end
  end

  defp cast_value(%{type: :repo_url}, raw_value, path) do
    case blank_to_nil(to_string(raw_value)) do
      nil ->
        {:error, {:invalid_github_setting_value, path, "must be a non-blank repository URL"}}

      value ->
        if String.starts_with?(value, ["https://", "http://", "git@github.com:"]) do
          {:ok, value}
        else
          {:error, {:invalid_github_setting_value, path, "must start with https://, http://, or git@github.com:"}}
        end
    end
  end

  defp cast_value(%{type: :enum, options: options}, raw_value, path) do
    value =
      raw_value
      |> to_string()
      |> blank_to_nil()

    cond do
      is_nil(value) ->
        {:error, {:invalid_github_setting_value, path, "must be one of #{Enum.join(options, ", ")}"}}

      value in options ->
        {:ok, value}

      true ->
        {:error, {:invalid_github_setting_value, path, "must be one of #{Enum.join(options, ", ")}"}}
    end
  end

  defp normalize_token(raw_token) when is_binary(raw_token) do
    case blank_to_nil(String.trim(raw_token)) do
      nil -> {:error, {:invalid_token_value, "must be a non-blank string"}}
      token -> {:ok, token}
    end
  end

  defp describe_fields(config_doc) do
    overrides = config_values_from_doc(config_doc)

    @field_definitions
    |> Enum.sort_by(fn {path, _definition} -> path end)
    |> Enum.map(fn {path, definition} ->
      override_value = Map.get(overrides, path)
      env_value = blank_to_nil(System.get_env(definition.env_var))
      default_value = definition.default

      source =
        cond do
          is_binary(override_value) -> "ui_override"
          is_binary(env_value) -> "env"
          true -> "default"
        end

      effective_value = override_value || env_value || default_value

      %{
        path: path,
        label: definition.label,
        description: definition.description,
        type: Atom.to_string(definition.type),
        options: field_options(definition),
        apply_mode: definition.apply_mode,
        source: source,
        source_label: source_label(source),
        effective_value: effective_value,
        env_value: env_value,
        default_value: default_value,
        override_value: override_value,
        editable_value: effective_value || ""
      }
    end)
  end

  defp field_options(%{type: :enum, options: options}), do: options
  defp field_options(_definition), do: []

  defp source_label("ui_override"), do: "UI override"
  defp source_label("ui_secret"), do: "UI secret"
  defp source_label("env"), do: "Environment"
  defp source_label("default"), do: "Default"
  defp source_label("none"), do: "None"
  defp source_label(other), do: other

  defp config_payload(config_doc) do
    %{
      version: Map.get(config_doc, "version", @config_version),
      updated_at: Map.get(config_doc, "updated_at"),
      updated_by: Map.get(config_doc, "updated_by"),
      reason: Map.get(config_doc, "reason"),
      values: config_values_from_doc(config_doc)
    }
  end

  defp token_payload(token_entry) do
    %{
      configured: token_entry.configured,
      source: token_entry.source,
      source_label: source_label(token_entry.source),
      updated_at: token_entry.updated_at,
      updated_by: token_entry.updated_by,
      reason: token_entry.reason,
      cleared_at: token_entry.cleared_at,
      cleared_by: token_entry.cleared_by,
      clear_reason: token_entry.clear_reason
    }
  end

  defp config_document do
    case read_json_file(config_path()) do
      nil -> {:ok, %{"version" => @config_version, "values" => %{}}}
      %{} = config_doc -> {:ok, config_doc}
      {:error, reason} -> {:error, reason}
    end
  end

  defp config_values_from_doc(config_doc) when is_map(config_doc) do
    case Map.get(config_doc, "values") do
      %{} = values -> values
      _ -> %{}
    end
  end

  defp updated_config_doc(previous_doc, values, opts) do
    %{
      "version" => Map.get(previous_doc, "version", @config_version),
      "updated_at" => now_iso8601(),
      "updated_by" => Keyword.get(opts, :actor, "system"),
      "reason" => Keyword.get(opts, :reason),
      "values" => values
    }
  end

  defp persist_config_doc(config_doc) when is_map(config_doc) do
    :ok = File.mkdir_p(settings_dir())
    :ok = File.write(config_path(), Jason.encode_to_iodata!(config_doc, pretty: true))
  rescue
    exception ->
      {:error, {:github_config_persist_failed, Exception.message(exception)}}
  end

  defp persist_history_entry(action, paths, changes, previous_doc, updated_doc, opts) do
    entry = %{
      "id" => history_entry_id(),
      "action" => action,
      "recorded_at" => now_iso8601(),
      "actor" => Keyword.get(opts, :actor, "system"),
      "reason" => Keyword.get(opts, :reason),
      "paths" => paths,
      "previous_values" => values_for_paths(config_values_from_doc(previous_doc), paths),
      "new_values" => values_for_paths(config_values_from_doc(updated_doc), paths),
      "applied_changes" => changes
    }

    persist_history_record(entry)
  end

  defp persist_token_history_entry(action, previous_entry, current_entry, opts) do
    entry = %{
      "id" => history_entry_id(),
      "action" => action,
      "recorded_at" => now_iso8601(),
      "actor" => Keyword.get(opts, :actor, "system"),
      "reason" => Keyword.get(opts, :reason),
      "paths" => ["token"],
      "previous_values" => %{"token" => token_history_value(previous_entry)},
      "new_values" => %{"token" => token_history_value(current_entry)}
    }

    persist_history_record(entry)
  end

  defp token_history_value(token_entry) do
    %{
      "configured" => Map.get(token_entry, :configured, false),
      "updated_at" => Map.get(token_entry, :updated_at),
      "cleared_at" => Map.get(token_entry, :cleared_at)
    }
  end

  defp persist_history_record(entry) when is_map(entry) do
    :ok = File.mkdir_p(history_dir())
    :ok = File.write(Path.join(history_dir(), entry["id"] <> ".json"), Jason.encode_to_iodata!(entry, pretty: true))
  rescue
    exception ->
      {:error, {:github_history_persist_failed, Exception.message(exception)}}
  end

  defp effective_value(path) when is_binary(path) do
    definition = Map.fetch!(@field_definitions, path)
    overrides = config_values()
    Map.get(overrides, path) || blank_to_nil(System.get_env(definition.env_var)) || definition.default
  end

  defp effective_token_info do
    ui_token = SecretStore.value(@secret_key) || legacy_token_value()

    cond do
      is_binary(ui_token) ->
        %{token: ui_token, source: "ui_secret"}

      is_binary(blank_to_nil(System.get_env(@token_env))) ->
        %{token: blank_to_nil(System.get_env(@token_env)), source: "env"}

      true ->
        %{token: nil, source: "none"}
    end
  end

  defp config_values do
    case config_document() do
      {:ok, config_doc} -> config_values_from_doc(config_doc)
      _ -> %{}
    end
  end

  defp values_for_paths(values, paths) when is_map(values) and is_list(paths) do
    Enum.into(paths, %{}, fn path -> {path, Map.get(values, path)} end)
  end

  defp settings_dir do
    audit_root()
    |> Path.join("settings")
    |> Path.join("github")
  end

  defp secrets_dir do
    settings_dir()
    |> Path.join("secrets")
  end

  defp config_path do
    settings_dir()
    |> Path.join("config.json")
  end

  defp history_dir do
    settings_dir()
    |> Path.join("history")
  end

  defp secret_entry do
    SecretStore.get(@secret_key)
  end

  defp legacy_token_value do
    case File.read(legacy_token_file_path()) do
      {:ok, contents} -> blank_to_nil(String.trim(contents))
      _ -> nil
    end
  end

  defp maybe_remove_legacy_token_files do
    [legacy_token_file_path(), legacy_token_metadata_path()]
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:github_token_migration_cleanup_failed, path, reason}}}
      end
    end)
  end

  defp legacy_token_file_path do
    secrets_dir()
    |> Path.join("github_token")
  end

  defp legacy_token_metadata_path do
    secrets_dir()
    |> Path.join("github_token_meta.json")
  end

  defp history_entry_id do
    "#{current_time() |> DateTime.to_unix(:millisecond)}-#{System.unique_integer([:positive])}"
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

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

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
end
