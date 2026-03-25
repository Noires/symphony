defmodule SymphonyElixir.SecretStore do
  @moduledoc """
  Persists write-only runtime secrets and non-sensitive metadata.
  """

  alias SymphonyElixir.LogFile

  @metadata_version 1

  @type entry :: %{
          key: String.t(),
          configured: boolean(),
          source: String.t(),
          updated_at: String.t() | nil,
          updated_by: String.t() | nil,
          reason: String.t() | nil,
          cleared_at: String.t() | nil,
          cleared_by: String.t() | nil,
          clear_reason: String.t() | nil,
          value: String.t() | nil
        }

  @spec set(String.t(), String.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def set(key, raw_value, opts \\ [])

  def set(key, raw_value, opts) when is_binary(key) and is_binary(raw_value) do
    with {:ok, normalized_key} <- normalize_key(key),
         {:ok, value} <- normalize_secret(raw_value),
         metadata <- updated_metadata(normalized_key, value, metadata_document(normalized_key), opts),
         :ok <- persist_value(normalized_key, value),
         :ok <- persist_metadata(normalized_key, metadata) do
      get(normalized_key)
    end
  end

  def set(_key, _raw_value, _opts), do: {:error, {:invalid_secret_value, "must be a non-blank string"}}

  @spec clear(String.t(), keyword()) :: {:ok, entry()} | {:error, term()}
  def clear(key, opts \\ [])

  def clear(key, opts) when is_binary(key) do
    with {:ok, normalized_key} <- normalize_key(key),
         metadata <- cleared_metadata(normalized_key, metadata_document(normalized_key), opts),
         :ok <- remove_value_file(normalized_key),
         :ok <- persist_metadata(normalized_key, metadata) do
      get(normalized_key)
    end
  end

  def clear(_key, _opts), do: {:error, :invalid_secret_key}

  @spec get(String.t()) :: {:ok, entry()} | {:error, term()}
  def get(key) when is_binary(key) do
    with {:ok, normalized_key} <- normalize_key(key) do
      metadata = metadata_document(normalized_key)
      value = read_value(normalized_key)

      {:ok,
       %{
         key: normalized_key,
         configured: is_binary(value),
         source: if(is_binary(value), do: "ui_secret", else: "none"),
         updated_at: Map.get(metadata, "updated_at"),
         updated_by: Map.get(metadata, "updated_by"),
         reason: Map.get(metadata, "reason"),
         cleared_at: Map.get(metadata, "cleared_at"),
         cleared_by: Map.get(metadata, "cleared_by"),
         clear_reason: Map.get(metadata, "clear_reason"),
         value: value
       }}
    end
  end

  def get(_key), do: {:error, :invalid_secret_key}

  @spec value(String.t()) :: String.t() | nil
  def value(key) when is_binary(key) do
    case get(key) do
      {:ok, %{value: value}} -> value
      _ -> nil
    end
  end

  def value(_key), do: nil

  @spec metadata(String.t()) :: {:ok, map()} | {:error, term()}
  def metadata(key) when is_binary(key) do
    with {:ok, normalized_key} <- normalize_key(key) do
      {:ok, metadata_document(normalized_key)}
    end
  end

  def metadata(_key), do: {:error, :invalid_secret_key}

  @spec file_path(String.t()) :: Path.t()
  def file_path(key) when is_binary(key) do
    case normalize_key(key) do
      {:ok, normalized_key} -> value_path(normalized_key)
      {:error, _reason} -> value_path("invalid_secret_key")
    end
  end

  def file_path(_key), do: value_path("invalid_secret_key")

  defp normalize_key(key) when is_binary(key) do
    trimmed = String.trim(key)

    cond do
      trimmed == "" ->
        {:error, :invalid_secret_key}

      String.match?(trimmed, ~r/^[A-Za-z0-9._-]+$/) ->
        {:ok, trimmed}

      true ->
        {:error, :invalid_secret_key}
    end
  end

  defp normalize_secret(raw_value) when is_binary(raw_value) do
    case String.trim(raw_value) do
      "" -> {:error, {:invalid_secret_value, "must be a non-blank string"}}
      value -> {:ok, value}
    end
  end

  defp updated_metadata(key, _value, previous_metadata, opts) do
    %{
      "version" => Map.get(previous_metadata, "version", @metadata_version),
      "key" => key,
      "updated_at" => now_iso8601(),
      "updated_by" => Keyword.get(opts, :actor, "system"),
      "reason" => Keyword.get(opts, :reason),
      "cleared_at" => nil,
      "cleared_by" => nil,
      "clear_reason" => nil
    }
  end

  defp cleared_metadata(key, previous_metadata, opts) do
    %{
      "version" => Map.get(previous_metadata, "version", @metadata_version),
      "key" => key,
      "updated_at" => Map.get(previous_metadata, "updated_at"),
      "updated_by" => Map.get(previous_metadata, "updated_by"),
      "reason" => Map.get(previous_metadata, "reason"),
      "cleared_at" => now_iso8601(),
      "cleared_by" => Keyword.get(opts, :actor, "system"),
      "clear_reason" => Keyword.get(opts, :reason)
    }
  end

  defp metadata_document(key) when is_binary(key) do
    case read_json_file(metadata_path(key)) do
      %{} = document -> document
      _ -> %{"version" => @metadata_version, "key" => key}
    end
  end

  defp persist_value(key, value) when is_binary(key) and is_binary(value) do
    :ok = File.mkdir_p(secrets_root())
    :ok = File.write(value_path(key), value)
    maybe_restrict_file(value_path(key))
  rescue
    exception ->
      {:error, {:secret_persist_failed, Exception.message(exception)}}
  end

  defp persist_metadata(key, metadata) when is_binary(key) and is_map(metadata) do
    :ok = File.mkdir_p(secrets_root())
    :ok = File.write(metadata_path(key), Jason.encode_to_iodata!(metadata, pretty: true))
    maybe_restrict_file(metadata_path(key))
  rescue
    exception ->
      {:error, {:secret_metadata_persist_failed, Exception.message(exception)}}
  end

  defp remove_value_file(key) when is_binary(key) do
    case File.rm(value_path(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:secret_clear_failed, reason}}
    end
  end

  defp read_value(key) when is_binary(key) do
    case File.read(value_path(key)) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  defp maybe_restrict_file(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp value_path(key), do: Path.join(secrets_root(), "#{key}.secret")
  defp metadata_path(key), do: Path.join(secrets_root(), "#{key}.json")

  defp secrets_root do
    audit_root()
    |> Path.join("settings")
    |> Path.join("secrets")
    |> Path.join("runtime")
  end

  defp read_json_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = decoded} -> decoded
          _ -> nil
        end

      {:error, :enoent} ->
        nil

      {:error, _reason} ->
        nil
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
