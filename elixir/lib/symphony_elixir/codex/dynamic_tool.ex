defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Client, as: GitHubClient
  alias SymphonyElixir.Linear.Client, as: LinearClient
  alias SymphonyElixir.Trello.Client, as: TrelloClient

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @trello_api_tool "trello_api"
  @trello_api_description """
  Execute a Trello REST API request using Symphony's configured Trello auth.
  """
  @trello_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method. Supported values: GET, POST, PUT, DELETE."
      },
      "path" => %{
        "type" => "string",
        "description" => "Trello REST path relative to the configured endpoint, for example `/cards/{id}`."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional Trello query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "array", "string", "number", "boolean", "null"],
        "description" => "Optional request body for POST or PUT requests."
      }
    }
  }

  @github_graphql_tool "github_graphql"
  @github_graphql_description """
  Execute a raw GraphQL query or mutation against GitHub using Symphony's configured auth.
  """
  @github_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against GitHub."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @github_api_tool "github_api"
  @github_api_description """
  Execute a GitHub REST API request using Symphony's configured GitHub auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "description" => "HTTP method. Supported values: GET, POST, PUT, PATCH, DELETE."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path relative to the configured API root, for example `/repos/{owner}/{repo}/issues/{number}`."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional GitHub query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "array", "string", "number", "boolean", "null"],
        "description" => "Optional request body for POST, PUT, or PATCH requests."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @trello_api_tool ->
        execute_trello_api(arguments, opts)

      @github_graphql_tool ->
        execute_github_graphql(arguments, opts)

      @github_api_tool ->
        execute_github_api(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case tracker_kind() do
      "github" ->
        [
          %{
            "name" => @github_graphql_tool,
            "description" => @github_graphql_description,
            "inputSchema" => @github_graphql_input_schema
          },
          %{
            "name" => @github_api_tool,
            "description" => @github_api_description,
            "inputSchema" => @github_api_input_schema
          }
        ]

      "trello" ->
        [
          %{
            "name" => @trello_api_tool,
            "description" => @trello_api_description,
            "inputSchema" => @trello_api_input_schema
          }
        ]

      "linear" ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]

      _ ->
        []
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &LinearClient.graphql/3)

    with {:ok, query, variables} <- normalize_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_trello_api(arguments, opts) do
    trello_client = Keyword.get(opts, :trello_client, &TrelloClient.request/5)

    with {:ok, method, path, query, body} <- normalize_trello_api_arguments(arguments),
         {:ok, response} <- trello_client.(method, path, query, body, []) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_github_graphql(arguments, opts) do
    github_client = Keyword.get(opts, :github_graphql_client, &GitHubClient.graphql/3)

    with {:ok, query, variables} <- normalize_graphql_arguments(arguments),
         {:ok, response} <- github_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(github_graphql_reason(reason)))
    end
  end

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &GitHubClient.request/5)

    with {:ok, method, path, query, body} <- normalize_github_api_arguments(arguments),
         {:ok, response} <- github_client.(method, path, query, body, []) do
      dynamic_tool_response(true, encode_payload(response))
    else
      {:error, reason} ->
        failure_response(tool_error_payload(github_api_reason(reason)))
    end
  end

  defp normalize_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_trello_api_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_trello_api_method(arguments),
         {:ok, path} <- normalize_trello_api_path(arguments),
         {:ok, query} <- normalize_trello_api_query(arguments) do
      {:ok, method, path, query, trello_api_body(arguments)}
    end
  end

  defp normalize_trello_api_arguments(_arguments), do: {:error, :invalid_trello_arguments}

  defp normalize_github_api_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_github_api_method(arguments),
         {:ok, path} <- normalize_github_api_path(arguments),
         {:ok, query} <- normalize_github_api_query(arguments) do
      {:ok, method, path, query, github_api_body(arguments)}
    end
  end

  defp normalize_github_api_arguments(_arguments), do: {:error, :invalid_github_arguments}

  defp normalize_trello_api_method(arguments) do
    case Map.get(arguments, "method") || Map.get(arguments, :method) do
      method when is_binary(method) ->
        case normalize_trello_method_string(method) do
          nil -> {:error, :invalid_trello_method}
          normalized -> {:ok, normalized}
        end

      _ ->
        {:error, :missing_trello_method}
    end
  end

  defp normalize_trello_api_path(arguments) do
    case Map.get(arguments, "path") || Map.get(arguments, :path) do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> {:error, :missing_trello_path}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_trello_path}
    end
  end

  defp normalize_trello_api_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) || %{} do
      query when is_map(query) -> {:ok, query}
      _ -> {:error, :invalid_trello_query}
    end
  end

  defp normalize_github_api_method(arguments) do
    case Map.get(arguments, "method") || Map.get(arguments, :method) do
      method when is_binary(method) ->
        case normalize_github_method_string(method) do
          nil -> {:error, :invalid_github_method}
          normalized -> {:ok, normalized}
        end

      _ ->
        {:error, :missing_github_method}
    end
  end

  defp normalize_github_api_path(arguments) do
    case Map.get(arguments, "path") || Map.get(arguments, :path) do
      path when is_binary(path) ->
        case String.trim(path) do
          "" -> {:error, :missing_github_path}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_github_path}
    end
  end

  defp normalize_github_api_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) || %{} do
      query when is_map(query) -> {:ok, query}
      _ -> {:error, :invalid_github_query}
    end
  end

  defp normalize_trello_method_string(method) when is_binary(method) do
    case method |> String.trim() |> String.upcase() do
      "GET" = normalized -> normalized
      "POST" = normalized -> normalized
      "PUT" = normalized -> normalized
      "DELETE" = normalized -> normalized
      _ -> nil
    end
  end

  defp normalize_github_method_string(method) when is_binary(method) do
    case method |> String.trim() |> String.upcase() do
      "GET" = normalized -> normalized
      "POST" = normalized -> normalized
      "PUT" = normalized -> normalized
      "PATCH" = normalized -> normalized
      "DELETE" = normalized -> normalized
      _ -> nil
    end
  end

  defp trello_api_body(arguments) when is_map(arguments) do
    cond do
      Map.has_key?(arguments, "body") -> Map.get(arguments, "body")
      Map.has_key?(arguments, :body) -> Map.get(arguments, :body)
      true -> nil
    end
  end

  defp github_api_body(arguments) when is_map(arguments) do
    cond do
      Map.has_key?(arguments, "body") -> Map.get(arguments, "body")
      Map.has_key?(arguments, :body) -> Map.get(arguments, :body)
      true -> nil
    end
  end

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:github_missing_query) do
    %{
      "error" => %{
        "message" => "`github_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:github_invalid_arguments) do
    %{
      "error" => %{
        "message" => "`github_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:github_invalid_variables) do
    %{
      "error" => %{
        "message" => "`github_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_trello_method) do
    %{
      "error" => %{
        "message" => "`trello_api` requires a non-empty `method` string."
      }
    }
  end

  defp tool_error_payload(:missing_trello_path) do
    %{
      "error" => %{
        "message" => "`trello_api` requires a non-empty `path` string."
      }
    }
  end

  defp tool_error_payload(:invalid_trello_arguments) do
    %{
      "error" => %{
        "message" => "`trello_api` expects an object with `method`, `path`, and optional `query` and `body`."
      }
    }
  end

  defp tool_error_payload(:invalid_trello_method) do
    %{
      "error" => %{
        "message" => "`trello_api.method` must be one of `GET`, `POST`, `PUT`, or `DELETE`."
      }
    }
  end

  defp tool_error_payload(:invalid_trello_query) do
    %{
      "error" => %{
        "message" => "`trello_api.query` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_github_method) do
    %{
      "error" => %{
        "message" => "`github_api` requires a non-empty `method` string."
      }
    }
  end

  defp tool_error_payload(:missing_github_path) do
    %{
      "error" => %{
        "message" => "`github_api` requires a non-empty `path` string."
      }
    }
  end

  defp tool_error_payload(:invalid_github_arguments) do
    %{
      "error" => %{
        "message" => "`github_api` expects an object with `method`, `path`, and optional `query` and `body`."
      }
    }
  end

  defp tool_error_payload(:invalid_github_method) do
    %{
      "error" => %{
        "message" => "`github_api.method` must be one of `GET`, `POST`, `PUT`, `PATCH`, or `DELETE`."
      }
    }
  end

  defp tool_error_payload(:invalid_github_query) do
    %{
      "error" => %{
        "message" => "`github_api.query` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_trello_api_key) do
    %{
      "error" => %{
        "message" => "Symphony is missing Trello auth. Set `tracker.api_key` in `WORKFLOW.md` or export `TRELLO_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:missing_trello_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing a Trello API token. Set `tracker.api_token` in `WORKFLOW.md` or export `TRELLO_API_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:trello_api_status, status}) do
    %{
      "error" => %{
        "message" => "Trello API request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:trello_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Trello API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(:missing_github_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.api_token` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_status, status}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "#{fallback_tool_label()} tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tracker_kind do
    case Config.settings() do
      {:ok, settings} -> settings.tracker.kind
      {:error, _reason} -> nil
    end
  end

  defp fallback_tool_label do
    case tracker_kind() do
      "github" -> "GitHub"
      "trello" -> "Trello API"
      _ -> "Linear GraphQL"
    end
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end

  defp github_graphql_reason(:missing_query), do: :github_missing_query
  defp github_graphql_reason(:invalid_arguments), do: :github_invalid_arguments
  defp github_graphql_reason(:invalid_variables), do: :github_invalid_variables
  defp github_graphql_reason(reason), do: reason

  defp github_api_reason(:missing_github_method), do: :missing_github_method
  defp github_api_reason(:missing_github_path), do: :missing_github_path
  defp github_api_reason(:invalid_github_arguments), do: :invalid_github_arguments
  defp github_api_reason(:invalid_github_method), do: :invalid_github_method
  defp github_api_reason(:invalid_github_query), do: :invalid_github_query
  defp github_api_reason(reason), do: reason
end
