defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub client for GitHub Issues backed by a GitHub Projects v2 workflow board.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @api_version "2022-11-28"
  @max_error_body_log_bytes 1_000
  @page_size 100
  @project_status_field_default "Status"

  @viewer_query """
  query SymphonyGitHubViewer {
    viewer {
      login
    }
  }
  """

  @project_context_query """
  query SymphonyGitHubProjectContext($owner: String!, $number: Int!) {
    organization(login: $owner) {
      projectV2(number: $number) {
        id
        title
        fields(first: 100) {
          nodes {
            ... on ProjectV2FieldCommon {
              id
              name
            }
            ... on ProjectV2SingleSelectField {
              id
              name
              options {
                id
                name
              }
            }
          }
        }
      }
    }
    user(login: $owner) {
      projectV2(number: $number) {
        id
        title
        fields(first: 100) {
          nodes {
            ... on ProjectV2FieldCommon {
              id
              name
            }
            ... on ProjectV2SingleSelectField {
              id
              name
              options {
                id
                name
              }
            }
          }
        }
      }
    }
  }
  """

  @project_items_query """
  query SymphonyGitHubProjectItems($projectId: ID!, $after: String) {
    node(id: $projectId) {
      ... on ProjectV2 {
        items(first: #{@page_size}, after: $after) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            fieldValues(first: 20) {
              nodes {
                ... on ProjectV2ItemFieldSingleSelectValue {
                  name
                  optionId
                  field {
                    ... on ProjectV2FieldCommon {
                      id
                      name
                    }
                  }
                }
              }
            }
            content {
              __typename
              ... on Issue {
                id
                number
                title
                body
                url
                state
                createdAt
                updatedAt
                labels(first: 20) {
                  nodes {
                    name
                  }
                }
                assignees(first: 20) {
                  nodes {
                    id
                    login
                  }
                }
                repository {
                  name
                  owner {
                    login
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  """

  @project_item_nodes_query """
  query SymphonyGitHubProjectItemsByIds($ids: [ID!]!) {
    nodes(ids: $ids) {
      ... on ProjectV2Item {
        id
        fieldValues(first: 20) {
          nodes {
            ... on ProjectV2ItemFieldSingleSelectValue {
              name
              optionId
              field {
                ... on ProjectV2FieldCommon {
                  id
                  name
                }
              }
            }
          }
        }
        content {
          __typename
          ... on Issue {
            id
            number
            title
            body
            url
            state
            createdAt
            updatedAt
            labels(first: 20) {
              nodes {
                name
              }
            }
            assignees(first: 20) {
              nodes {
                id
                login
              }
            }
            repository {
              name
              owner {
                login
              }
            }
          }
        }
      }
    }
  }
  """

  @project_item_comment_target_query """
  query SymphonyGitHubProjectItemCommentTarget($itemId: ID!) {
    node(id: $itemId) {
      ... on ProjectV2Item {
        content {
          __typename
          ... on Issue {
            number
            repository {
              name
              owner {
                login
              }
            }
          }
        }
      }
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyGitHubUpdateProjectItemState(
    $projectId: ID!,
    $itemId: ID!,
    $fieldId: ID!,
    $optionId: String!
  ) {
    updateProjectV2ItemFieldValue(
      input: {
        projectId: $projectId,
        itemId: $itemId,
        fieldId: $fieldId,
        value: {singleSelectOptionId: $optionId}
      }
    ) {
      projectV2Item {
        id
      }
    }
  }
  """

  @type request_fun :: (keyword() -> {:ok, map()} | {:error, term()})

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts \\ []) when is_list(opts) do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker(tracker),
         {:ok, assignee_filter} <- routing_assignee_filter(opts),
         {:ok, project} <- project_context(opts),
         {:ok, items} <- fetch_project_items(project.id, opts),
         {:ok, issues} <- normalize_project_items(items, assignee_filter, tracker, project.status_field_name) do
      {:ok, filter_issues_by_states(issues, tracker.active_states)}
    end
  end

  @spec fetch_issues_by_states([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, opts \\ []) when is_list(state_names) and is_list(opts) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state_name/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case normalized_states do
      [] ->
        {:ok, []}

      _ ->
        tracker = Config.settings!().tracker

        with :ok <- validate_tracker(tracker),
             {:ok, project} <- project_context(opts),
             {:ok, items} <- fetch_project_items(project.id, opts),
             {:ok, issues} <- normalize_project_items(items, nil, tracker, project.status_field_name) do
          {:ok, filter_issues_by_states(issues, normalized_states)}
        end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()], keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, opts \\ []) when is_list(issue_ids) and is_list(opts) do
    ids =
      issue_ids
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        {:ok, []}

      _ ->
        tracker = Config.settings!().tracker

        with :ok <- validate_tracker(tracker),
             {:ok, assignee_filter} <- routing_assignee_filter(opts),
             {:ok, project} <- project_context(opts),
             {:ok, items} <- fetch_project_item_nodes(ids, opts),
             {:ok, issues} <- normalize_project_items(items, assignee_filter, tracker, project.status_field_name) do
          {:ok, issues}
        end
    end
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_comment(item_id, body, opts \\ [])
      when is_binary(item_id) and is_binary(body) and is_list(opts) do
    with :ok <- validate_tracker(Config.settings!().tracker),
         {:ok, %{owner: owner, repo: repo, issue_number: issue_number}} <- resolve_comment_target(item_id, opts) do
      request(
        :post,
        "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments",
        %{},
        %{"body" => body},
        opts
      )
    end
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_issue_state(item_id, state_name, opts \\ [])
      when is_binary(item_id) and is_binary(state_name) and is_list(opts) do
    with :ok <- validate_tracker(Config.settings!().tracker),
         {:ok, project} <- project_context(opts),
         {:ok, status_field} <- status_field(project, project.status_field_name),
         {:ok, option_id} <- state_option_id(status_field, state_name),
         {:ok, response} <-
           graphql(
             @update_state_mutation,
             %{
               projectId: project.id,
               itemId: item_id,
               fieldId: status_field.id,
               optionId: option_id
             },
             opts
           ),
         project_item_id when is_binary(project_item_id) <-
           get_in(response, ["data", "updateProjectV2ItemFieldValue", "projectV2Item", "id"]) do
      {:ok, %{"id" => project_item_id}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec fetch_human_response_marker(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_human_response_marker(item_id, opts \\ []) when is_binary(item_id) and is_list(opts) do
    with :ok <- validate_tracker(Config.settings!().tracker),
         {:ok, comment_target} <- resolve_comment_target(item_id, opts),
         {:ok, comments} <- fetch_issue_comments(comment_target, opts) do
      marker =
        comments
        |> Enum.map(&normalize_human_response_comment(&1, opts))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&Map.get(&1, "at"))
        |> List.first()

      {:ok, marker}
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    with {:ok, token} <- api_token(),
         {:ok, url} <- build_graphql_url(),
         {:ok, %{status: status, body: body}} <-
           request_fun.(
             method: :post,
             url: url,
             headers: auth_headers(token),
             json: %{"query" => query, "variables" => variables},
             connect_options: [timeout: 30_000]
           ) do
      case status do
        status when status in 200..299 ->
          {:ok, body}

        _ ->
          Logger.error("GitHub GraphQL request failed status=#{status}#{github_error_context(url, body)}")
          {:error, {:github_api_status, status}}
      end
    else
      {:error, reason} ->
        Logger.error("GitHub GraphQL request failed: #{inspect(reason)}")
        {:error, normalize_request_error(reason)}

      {:ok, response} ->
        response_status = Map.get(response, :status) || Map.get(response, "status")
        response_body = Map.get(response, :body) || Map.get(response, "body")
        Logger.error("GitHub GraphQL request failed status=#{response_status}#{github_error_context("graphql", response_body)}")
        {:error, {:github_api_status, response_status}}
    end
  end

  @spec request(atom() | String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, map() | list() | String.t()} | {:error, term()}
  def request(method, path, query \\ %{}, body \\ nil, opts \\ [])
      when is_binary(path) and is_map(query) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    with {:ok, http_method} <- normalize_http_method(method),
         {:ok, token} <- api_token(),
         {:ok, url} <- build_rest_url(path),
         {:ok, %{status: status, body: response_body}} <-
           request_fun.(build_request_opts(http_method, url, query, body, token)) do
      case status do
        status when status in 200..299 ->
          {:ok, response_body}

        _ ->
          Logger.error("GitHub REST request failed status=#{status}#{github_error_context(url, response_body)}")
          {:error, {:github_api_status, status}}
      end
    else
      {:error, reason} ->
        Logger.error("GitHub REST request failed: #{inspect(reason)}")
        {:error, normalize_request_error(reason)}

      {:ok, response} ->
        response_status = Map.get(response, :status) || Map.get(response, "status")
        response_body = Map.get(response, :body) || Map.get(response, "body")
        Logger.error("GitHub REST request failed status=#{response_status}#{github_error_context(path, response_body)}")
        {:error, {:github_api_status, response_status}}
    end
  end

  defp validate_tracker(tracker) do
    cond do
      not is_binary(tracker.api_token) -> {:error, :missing_github_api_token}
      not is_binary(tracker.owner) -> {:error, :missing_github_owner}
      not is_binary(tracker.repo) -> {:error, :missing_github_repo}
      not is_binary(tracker.project_number) -> {:error, :missing_github_project_number}
      true -> :ok
    end
  end

  defp project_context(opts) when is_list(opts) do
    tracker = Config.settings!().tracker

    with {:ok, project_number} <- parse_project_number(tracker.project_number),
         {:ok, data} <- graphql_data(@project_context_query, %{owner: tracker.owner, number: project_number}, opts),
         {:ok, project} <- extract_project(data),
         status_field_name = normalize_string(tracker.status_field_name) || @project_status_field_default do
      {:ok, Map.put(project, :status_field_name, status_field_name)}
    end
  end

  defp fetch_project_items(project_id, opts, after_cursor \\ nil, acc \\ [])

  defp fetch_project_items(project_id, opts, after_cursor, acc)
       when is_binary(project_id) and is_list(opts) and is_list(acc) do
    with {:ok, data} <-
           graphql_data(@project_items_query, %{projectId: project_id, after: after_cursor}, opts),
         %{"items" => %{"nodes" => items, "pageInfo" => page_info}} <- get_in(data, ["node"]) do
      updated_acc = acc ++ Enum.reject(items || [], &is_nil/1)

      if page_info["hasNextPage"] == true and is_binary(page_info["endCursor"]) do
        fetch_project_items(project_id, opts, page_info["endCursor"], updated_acc)
      else
        {:ok, updated_acc}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp fetch_project_item_nodes(ids, opts) when is_list(ids) and is_list(opts) do
    ids
    |> Enum.chunk_every(50)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, acc} ->
      case graphql_data(@project_item_nodes_query, %{ids: chunk}, opts) do
        {:ok, %{"nodes" => nodes}} when is_list(nodes) ->
          {:cont, {:ok, acc ++ Enum.reject(nodes, &is_nil/1)}}

        {:ok, _unexpected} ->
          {:halt, {:error, :github_unknown_payload}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_project_items(items, assignee_filter, tracker, status_field_name)
       when is_list(items) do
    {:ok,
     items
     |> Enum.map(&normalize_project_item(&1, assignee_filter, tracker, status_field_name))
     |> Enum.reject(&is_nil/1)}
  end

  defp normalize_project_item(item, assignee_filter, tracker, status_field_name)
       when is_map(item) and is_map(tracker) do
    with %{"content" => %{"__typename" => "Issue"} = content} <- item,
         true <- repository_matches?(content, tracker),
         state when is_binary(state) <- issue_state(item, status_field_name),
         assignees <- extract_assignees(content) do
      %Issue{
        id: item["id"],
        identifier: issue_identifier(content["number"]),
        title: content["title"],
        description: content["body"],
        priority: nil,
        state: state,
        branch_name: nil,
        url: content["url"],
        assignee_id: first_assignee_login(assignees),
        blocked_by: [],
        labels: extract_labels(content),
        assigned_to_worker: assigned_to_worker?(assignees, assignee_filter),
        created_at: parse_datetime(content["createdAt"]),
        updated_at: parse_datetime(content["updatedAt"])
      }
    else
      _ -> nil
    end
  end

  defp filter_issues_by_states(issues, states) when is_list(issues) and is_list(states) do
    allowed_states =
      states
      |> Enum.map(&normalize_state_name/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.filter(issues, fn
      %Issue{state: state} -> MapSet.member?(allowed_states, normalize_state_name(state))
      _ -> false
    end)
  end

  defp issue_state(item, status_field_name) when is_map(item) and is_binary(status_field_name) do
    item
    |> Map.get("fieldValues", %{})
    |> Map.get("nodes", [])
    |> Enum.find_value(fn
      %{"name" => value_name, "field" => %{"name" => field_name}}
      when is_binary(value_name) and is_binary(field_name) ->
        if normalize_state_name(field_name) == normalize_state_name(status_field_name), do: value_name

      _ ->
        nil
    end)
  end

  defp repository_matches?(content, tracker) when is_map(content) and is_map(tracker) do
    repository = Map.get(content, "repository", %{})
    repo_name = repository |> Map.get("name") |> normalize_string() |> normalize_state_name()
    owner_login = repository |> get_in(["owner", "login"]) |> normalize_string() |> normalize_state_name()

    normalize_string(tracker.repo) |> normalize_state_name() == repo_name and
      normalize_string(tracker.owner) |> normalize_state_name() == owner_login
  end

  defp repository_matches?(_content, _tracker), do: false

  defp resolve_comment_target(item_id, opts) when is_binary(item_id) and is_list(opts) do
    with {:ok, data} <- graphql_data(@project_item_comment_target_query, %{itemId: item_id}, opts),
         %{"content" => %{"__typename" => "Issue"} = issue} <- get_in(data, ["node"]),
         issue_number when is_integer(issue_number) <- issue["number"],
         repo when is_binary(repo) <- issue |> get_in(["repository", "name"]) |> normalize_string(),
         owner when is_binary(owner) <- issue |> get_in(["repository", "owner", "login"]) |> normalize_string() do
      {:ok, %{owner: owner, repo: repo, issue_number: issue_number}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_not_found}
    end
  end

  defp fetch_issue_comments(%{owner: owner, repo: repo, issue_number: issue_number}, opts)
       when is_binary(owner) and is_binary(repo) and is_integer(issue_number) and is_list(opts) do
    query =
      %{"per_page" => 100}
      |> maybe_put_since(Keyword.get(opts, :since))

    case request(:get, "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments", query, nil, opts) do
      {:ok, comments} when is_list(comments) -> {:ok, comments}
      {:ok, _unexpected} -> {:error, :github_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_human_response_comment(comment, opts) when is_map(comment) and is_list(opts) do
    since =
      opts
      |> Keyword.get(:since)
      |> coerce_datetime()

    with %DateTime{} = created_at <- parse_datetime(comment["created_at"]),
         true <- is_nil(since) or DateTime.compare(created_at, since) in [:gt, :eq],
         body when is_binary(body) <- normalize_string(comment["body"]),
         false <- codex_comment?(body),
         false <- github_bot_comment?(comment) do
      %{
        "at" => iso8601(created_at),
        "kind" => "comment",
        "summary" => "human comment added on GitHub issue",
        "comment_excerpt" => truncate_excerpt(body),
        "author" => comment |> get_in(["user", "login"]) |> normalize_string()
      }
      |> drop_nil_map_values()
    else
      _ -> nil
    end
  end

  defp routing_assignee_filter(opts) when is_list(opts) do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee, opts)
    end
  end

  defp build_assignee_filter(assignee, opts) when is_binary(assignee) and is_list(opts) do
    case normalize_string(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_filter(opts)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([String.downcase(normalized)])}}
    end
  end

  defp build_assignee_filter(_assignee, _opts), do: {:ok, nil}

  defp resolve_viewer_filter(opts) when is_list(opts) do
    with {:ok, data} <- graphql_data(@viewer_query, %{}, opts),
         login when is_binary(login) <- get_in(data, ["viewer", "login"]) |> normalize_string() do
      {:ok, %{configured_assignee: "me", match_values: MapSet.new([String.downcase(login)])}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_github_viewer_identity}
    end
  end

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, %{match_values: match_values})
       when is_list(assignees) and is_struct(match_values, MapSet) do
    Enum.any?(assignees, fn assignee ->
      assignee
      |> Map.get("login")
      |> normalize_string()
      |> case do
        nil -> false
        login -> MapSet.member?(match_values, String.downcase(login))
      end
    end)
  end

  defp assigned_to_worker?(_assignees, _filter), do: false

  defp extract_assignees(%{"assignees" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.filter(fn
      %{"login" => login} when is_binary(login) and login != "" -> true
      _ -> false
    end)
  end

  defp extract_assignees(_content), do: []

  defp extract_labels(%{"labels" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) and name != "" -> String.downcase(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_content), do: []

  defp first_assignee_login([%{"login" => login} | _rest]) when is_binary(login), do: login
  defp first_assignee_login(_assignees), do: nil

  defp status_field(project, field_name)
       when is_map(project) and is_binary(field_name) do
    case Enum.find(project.fields, fn field ->
           normalize_state_name(field.name) == normalize_state_name(field_name)
         end) do
      %{id: id, name: name, options: options} ->
        {:ok, %{id: id, name: name, options: options}}

      _ ->
        {:error, :missing_github_status_field}
    end
  end

  defp state_option_id(status_field, state_name)
       when is_map(status_field) and is_binary(state_name) do
    normalized_target = normalize_state_name(state_name)

    case Enum.find(status_field.options, fn %{name: option_name} ->
           normalize_state_name(option_name) == normalized_target
         end) do
      %{id: option_id} when is_binary(option_id) -> {:ok, option_id}
      _ -> {:error, :state_not_found}
    end
  end

  defp extract_project(data) when is_map(data) do
    project =
      get_in(data, ["organization", "projectV2"]) ||
        get_in(data, ["user", "projectV2"])

    case project do
      %{"id" => project_id, "fields" => %{"nodes" => field_nodes}} when is_binary(project_id) and is_list(field_nodes) ->
        {:ok,
         %{
           id: project_id,
           title: normalize_string(project["title"]),
           fields: normalize_project_fields(field_nodes)
         }}

      _ ->
        {:error, :missing_github_project}
    end
  end

  defp normalize_project_fields(field_nodes) when is_list(field_nodes) do
    Enum.reduce(field_nodes, [], fn
      %{"id" => id, "name" => name, "options" => options}, acc
      when is_binary(id) and is_binary(name) and is_list(options) ->
        [
          %{
            id: id,
            name: name,
            options:
              Enum.reduce(options, [], fn
                %{"id" => option_id, "name" => option_name}, option_acc
                when is_binary(option_id) and is_binary(option_name) ->
                  [%{id: option_id, name: option_name} | option_acc]

                _unexpected, option_acc ->
                  option_acc
              end)
              |> Enum.reverse()
          }
          | acc
        ]

      %{"id" => id, "name" => name}, acc when is_binary(id) and is_binary(name) ->
        [%{id: id, name: name, options: []} | acc]

      _unexpected, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp graphql_data(query, variables, opts) when is_binary(query) and is_map(variables) and is_list(opts) do
    case graphql(query, variables, opts) do
      {:ok, %{"data" => data, "errors" => errors}} when is_map(data) and is_list(errors) and errors != [] ->
        if graphql_data_all_nil?(data) do
          {:error, {:github_graphql_errors, errors}}
        else
          Logger.debug("GitHub GraphQL partial errors (ignored): #{inspect(errors)}")
          {:ok, data}
        end

      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        {:error, {:github_graphql_errors, errors}}

      {:ok, %{"data" => data}} when is_map(data) ->
        {:ok, data}

      {:ok, _unexpected} ->
        {:error, :github_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp graphql_data_all_nil?(data) when is_map(data) do
    data |> Map.values() |> Enum.all?(&is_nil/1)
  end

  defp api_token do
    case Config.settings!().tracker.api_token do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :missing_github_api_token}
    end
  end

  defp parse_project_number(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> {:ok, number}
      _ -> {:error, :invalid_github_project_number}
    end
  end

  defp parse_project_number(_value), do: {:error, :invalid_github_project_number}

  defp auth_headers(token) when is_binary(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", @api_version}
    ]
  end

  defp build_graphql_url do
    endpoint =
      Config.settings!().tracker.endpoint
      |> to_string()
      |> String.trim()
      |> String.trim_trailing("/")

    cond do
      endpoint == "" ->
        {:error, :invalid_github_endpoint}

      String.ends_with?(endpoint, "/graphql") ->
        {:ok, endpoint}

      true ->
        {:ok, endpoint <> "/graphql"}
    end
  end

  defp build_rest_url(path) when is_binary(path) do
    case normalize_path(path) do
      nil ->
        {:error, :invalid_github_path}

      normalized_path ->
        endpoint =
          Config.settings!().tracker.endpoint
          |> to_string()
          |> String.trim()
          |> String.trim_trailing("/")
          |> trim_graphql_suffix()

        if endpoint == "" do
          {:error, :invalid_github_endpoint}
        else
          {:ok, endpoint <> normalized_path}
        end
    end
  end

  defp build_request_opts(method, url, query, nil, token) do
    [
      method: method,
      url: url,
      headers: auth_headers(token),
      params: query,
      connect_options: [timeout: 30_000]
    ]
  end

  defp build_request_opts(method, url, query, body, token) when is_map(body) or is_list(body) do
    [
      method: method,
      url: url,
      headers: auth_headers(token),
      params: query,
      json: body,
      connect_options: [timeout: 30_000]
    ]
  end

  defp build_request_opts(method, url, query, body, token) do
    [
      method: method,
      url: url,
      headers: auth_headers(token),
      params: query,
      body: body,
      connect_options: [timeout: 30_000]
    ]
  end

  defp normalize_http_method(method) when is_atom(method) do
    method |> Atom.to_string() |> normalize_http_method()
  end

  defp normalize_http_method(method) when is_binary(method) do
    case method |> String.trim() |> String.upcase() do
      "GET" -> {:ok, :get}
      "POST" -> {:ok, :post}
      "PUT" -> {:ok, :put}
      "PATCH" -> {:ok, :patch}
      "DELETE" -> {:ok, :delete}
      _ -> {:error, :invalid_github_method}
    end
  end

  defp normalize_http_method(_method), do: {:error, :invalid_github_method}

  defp normalize_request_error({:github_api_status, _status} = reason), do: reason
  defp normalize_request_error({:github_api_request, _reason} = reason), do: reason
  defp normalize_request_error(:missing_github_api_token), do: :missing_github_api_token
  defp normalize_request_error(:missing_github_owner), do: :missing_github_owner
  defp normalize_request_error(:missing_github_repo), do: :missing_github_repo
  defp normalize_request_error(:missing_github_project_number), do: :missing_github_project_number
  defp normalize_request_error(:invalid_github_project_number), do: :invalid_github_project_number
  defp normalize_request_error(:missing_github_project), do: :missing_github_project
  defp normalize_request_error(:missing_github_status_field), do: :missing_github_status_field
  defp normalize_request_error(:missing_github_viewer_identity), do: :missing_github_viewer_identity
  defp normalize_request_error(:invalid_github_method), do: :invalid_github_method
  defp normalize_request_error(:invalid_github_path), do: :invalid_github_path
  defp normalize_request_error(:invalid_github_endpoint), do: :invalid_github_endpoint
  defp normalize_request_error(reason), do: {:github_api_request, reason}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> nil
      String.contains?(trimmed, ["\n", "\r", <<0>>]) -> nil
      String.starts_with?(trimmed, "/") -> trimmed
      true -> "/" <> trimmed
    end
  end

  defp trim_graphql_suffix(endpoint) when is_binary(endpoint) do
    if String.ends_with?(endpoint, "/graphql") do
      String.replace_suffix(endpoint, "/graphql", "")
    else
      endpoint
    end
  end

  defp github_error_context(url_or_path, response_body) do
    body_text =
      response_body
      |> encode_error_body()
      |> truncate_error_body()

    " url=#{url_or_path} body=#{inspect(body_text)}"
  end

  defp encode_error_body(body) when is_map(body) or is_list(body), do: Jason.encode!(body)
  defp encode_error_body(body) when is_binary(body), do: body
  defp encode_error_body(body), do: inspect(body)

  defp truncate_error_body(body_text) when is_binary(body_text) do
    if byte_size(body_text) <= @max_error_body_log_bytes do
      body_text
    else
      binary_part(body_text, 0, @max_error_body_log_bytes) <> "... (truncated)"
    end
  end

  defp normalize_state_name(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> String.downcase(normalized)
    end
  end

  defp normalize_state_name(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_state_name()
  defp normalize_state_name(value) when is_integer(value), do: value |> Integer.to_string() |> normalize_state_name()
  defp normalize_state_name(_value), do: nil

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(_value), do: nil

  defp issue_identifier(number) when is_integer(number), do: "GH-#{number}"
  defp issue_identifier(number) when is_binary(number), do: "GH-#{number}"
  defp issue_identifier(_number), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

  defp coerce_datetime(%DateTime{} = datetime), do: datetime
  defp coerce_datetime(value) when is_binary(value), do: parse_datetime(value)
  defp coerce_datetime(_value), do: nil

  defp maybe_put_since(query, nil), do: query

  defp maybe_put_since(query, %DateTime{} = datetime) do
    Map.put(query, "since", iso8601(datetime))
  end

  defp maybe_put_since(query, value) when is_binary(value) do
    case parse_datetime(value) do
      %DateTime{} = datetime -> Map.put(query, "since", iso8601(datetime))
      _ -> query
    end
  end

  defp maybe_put_since(query, _value), do: query

  defp codex_comment?(text) when is_binary(text) do
    normalized =
      text
      |> String.trim_leading()
      |> String.downcase()

    String.starts_with?(normalized, "## codex ")
  end

  defp github_bot_comment?(comment) when is_map(comment) do
    comment
    |> get_in(["user", "type"])
    |> case do
      "Bot" -> true
      _ -> false
    end
  end

  defp truncate_excerpt(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.length(trimmed) > 180 do
      String.slice(trimmed, 0, 180) <> "..."
    else
      trimmed
    end
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil

  defp drop_nil_map_values(map) when is_map(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
