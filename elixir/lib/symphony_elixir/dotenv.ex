defmodule SymphonyElixir.Dotenv do
  @moduledoc false

  require Logger

  @state_env_key :dotenv_state
  @key_pattern ~r/^[A-Za-z_][A-Za-z0-9_]*$/

  @spec load_for_workflow_path(Path.t()) :: :ok
  def load_for_workflow_path(workflow_path) when is_binary(workflow_path) do
    dotenv_path = path_for_workflow(workflow_path)

    entries =
      case File.read(dotenv_path) do
        {:ok, content} ->
          parse(content, dotenv_path)

        {:error, :enoent} ->
          %{}

        {:error, reason} ->
          Logger.warning("Failed to read .env path=#{dotenv_path} reason=#{inspect(reason)}")
          %{}
      end

    replace_loaded_entries(dotenv_path, entries)
  end

  @spec path_for_workflow(Path.t()) :: Path.t()
  def path_for_workflow(workflow_path) when is_binary(workflow_path) do
    workflow_path
    |> Path.expand()
    |> Path.dirname()
    |> Path.join(".env")
  end

  defp replace_loaded_entries(dotenv_path, entries) when is_map(entries) do
    unload_previously_loaded_entries()

    applied_entries =
      Enum.reduce(entries, %{}, fn {key, value}, acc ->
        case System.get_env(key) do
          nil ->
            System.put_env(key, value)
            Map.put(acc, key, value)

          _existing ->
            acc
        end
      end)

    Application.put_env(:symphony_elixir, @state_env_key, %{path: dotenv_path, entries: applied_entries})
    :ok
  end

  defp unload_previously_loaded_entries do
    case Application.get_env(:symphony_elixir, @state_env_key) do
      %{entries: entries} when is_map(entries) ->
        Enum.each(entries, fn {key, value} ->
          if System.get_env(key) == value do
            System.delete_env(key)
          end
        end)

      _ ->
        :ok
    end
  end

  defp parse(content, dotenv_path) when is_binary(content) do
    content
    |> String.split(~r/\R/, trim: false)
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {line, line_number}, acc ->
      case parse_line(line) do
        {:ok, nil} ->
          acc

        {:ok, {key, value}} ->
          Map.put(acc, key, value)

        {:error, reason} ->
          Logger.warning("Ignoring invalid .env entry path=#{dotenv_path} line=#{line_number} reason=#{reason}")

          acc
      end
    end)
  end

  defp parse_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {:ok, nil}

      String.starts_with?(trimmed, "#") ->
        {:ok, nil}

      true ->
        trimmed
        |> String.trim_leading("export ")
        |> split_assignment()
    end
  end

  defp split_assignment(line) when is_binary(line) do
    case String.split(line, "=", parts: 2) do
      [raw_key, raw_value] ->
        key = String.trim(raw_key)

        cond do
          key == "" ->
            {:error, "missing key"}

          not String.match?(key, @key_pattern) ->
            {:error, "invalid key"}

          true ->
            {:ok, {key, parse_value(raw_value)}}
        end

      _ ->
        {:error, "missing assignment"}
    end
  end

  defp parse_value(raw_value) when is_binary(raw_value) do
    value = String.trim_leading(raw_value)

    cond do
      quoted_with?(value, "\"") ->
        value
        |> trim_wrapping_quotes()
        |> decode_double_quoted_value()

      quoted_with?(value, "'") ->
        trim_wrapping_quotes(value)

      true ->
        strip_inline_comment(value)
    end
  end

  defp quoted_with?(value, quote) when is_binary(value) and is_binary(quote) do
    String.starts_with?(value, quote) and String.ends_with?(value, quote) and String.length(value) >= 2
  end

  defp trim_wrapping_quotes(value) when is_binary(value) do
    value
    |> String.slice(1, String.length(value) - 2)
  end

  defp decode_double_quoted_value(value) when is_binary(value) do
    value
    |> String.replace("\\n", "\n")
    |> String.replace("\\r", "\r")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp strip_inline_comment(value) when is_binary(value) do
    value
    |> String.split(~r/\s+#/, parts: 2)
    |> List.first()
    |> String.trim_trailing()
  end
end
