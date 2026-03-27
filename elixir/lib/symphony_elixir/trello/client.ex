defmodule SymphonyElixir.Trello.Client do
  @moduledoc """
  Thin Trello REST client for polling candidate cards and mutating card state.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @max_error_body_log_bytes 1_000
  @card_fields "id,idShort,name,desc,idList,idBoard,url,idMembers,labels,dateLastActivity,closed"

  @type request_fun :: (keyword() -> {:ok, map()} | {:error, term()})

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_trello_api_key}

      is_nil(tracker.api_token) ->
        {:error, :missing_trello_api_token}

      is_nil(tracker.board_id) ->
        {:error, :missing_trello_board_id}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, issues} <- fetch_issues_for_board_states(tracker.board_id, tracker.active_states, assignee_filter) do
          {:ok, issues}
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
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

        cond do
          is_nil(tracker.api_key) ->
            {:error, :missing_trello_api_key}

          is_nil(tracker.api_token) ->
            {:error, :missing_trello_api_token}

          is_nil(tracker.board_id) ->
            {:error, :missing_trello_board_id}

          true ->
            fetch_issues_for_board_states(tracker.board_id, normalized_states, nil)
        end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids =
      issue_ids
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case ids do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, cards} <- fetch_cards_by_ids(ids),
             {:ok, issues} <- normalize_cards(cards, assignee_filter) do
          {:ok, issues}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_comment(card_id, body) when is_binary(card_id) and is_binary(body) do
    request(:post, "/cards/#{card_id}/actions/comments", %{"text" => body})
  end

  @spec update_issue_state(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_issue_state(card_id, state_name)
      when is_binary(card_id) and is_binary(state_name) do
    with {:ok, card} <- fetch_card(card_id),
         board_id when is_binary(board_id) <- card["idBoard"] || Config.settings!().tracker.board_id,
         {:ok, lists_by_name} <- fetch_board_lists_by_normalized_name(board_id),
         normalized_state when is_binary(normalized_state) <- normalize_state_name(state_name),
         %{id: list_id} <- Map.get(lists_by_name, normalized_state) do
      request(:put, "/cards/#{card_id}", %{"idList" => list_id})
    else
      nil -> {:error, :state_not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  @spec fetch_human_response_marker(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_human_response_marker(card_id, opts \\ []) when is_binary(card_id) and is_list(opts) do
    since =
      opts
      |> Keyword.get(:since)
      |> coerce_datetime()

    active_states =
      opts
      |> Keyword.get(:active_states, Config.settings!().tracker.active_states)
      |> normalize_state_name_set()

    with {:ok, actions} <- fetch_card_actions(card_id) do
      marker =
        actions
        |> Enum.map(&normalize_human_response_action(&1, since, active_states))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&Map.get(&1, "at"))
        |> List.first()

      {:ok, marker}
    end
  end

  @spec fetch_codex_workpad_action_id(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch_codex_workpad_action_id(card_id) when is_binary(card_id) do
    with {:ok, actions} <- fetch_card_actions(card_id) do
      {:ok, find_codex_workpad_action_id(actions)}
    end
  end

  @spec request(atom() | String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, map() | list() | String.t()} | {:error, term()}
  def request(method, path, query \\ %{}, body \\ nil, opts \\ [])
      when is_binary(path) and is_map(query) and is_list(opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    with {:ok, http_method} <- normalize_http_method(method),
         {:ok, auth_query} <- auth_query(),
         {:ok, url} <- build_url(path),
         request_opts <- build_request_opts(http_method, url, Map.merge(auth_query, query), body),
         {:ok, %{status: status, body: response_body}} <- request_fun.(request_opts) do
      case status do
        status when status in 200..299 ->
          {:ok, response_body}

        _ ->
          Logger.error("Trello request failed status=#{status}#{trello_error_context(url, response_body)}")
          {:error, {:trello_api_status, status}}
      end
    else
      {:error, reason} ->
        Logger.error("Trello request failed: #{inspect(reason)}")
        {:error, normalize_request_error(reason)}

      {:ok, response} ->
        response_status = Map.get(response, :status) || Map.get(response, "status")
        response_body = Map.get(response, :body) || Map.get(response, "body")

        Logger.error("Trello request failed status=#{response_status}#{trello_error_context(path, response_body)}")

        {:error, {:trello_api_status, response_status}}
    end
  end

  @doc false
  @spec normalize_card_for_test(map(), map(), map() | nil) :: Issue.t() | nil
  def normalize_card_for_test(card, lists_by_id, assignee_filter \\ nil)
      when is_map(card) and is_map(lists_by_id) do
    normalize_card(card, lists_by_id, assignee_filter)
  end

  @doc false
  @spec card_created_at_for_test(String.t()) :: DateTime.t() | nil
  def card_created_at_for_test(card_id) when is_binary(card_id), do: card_created_at(card_id)

  defp fetch_issues_for_board_states(board_id, state_names, assignee_filter)
       when is_binary(board_id) and is_list(state_names) do
    with {:ok, lists} <- fetch_board_lists(board_id),
         lists_by_state <- lists_by_normalized_name(lists),
         target_lists <- select_target_lists(lists_by_state, state_names),
         {:ok, cards} <- fetch_cards_for_lists(target_lists),
         {:ok, issues} <- normalize_cards(cards, assignee_filter, lists) do
      {:ok, issues}
    end
  end

  defp fetch_cards_by_ids(ids) when is_list(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn card_id, {:ok, acc} ->
      case fetch_card(card_id) do
        {:ok, card} -> {:cont, {:ok, [card | acc]}}
        {:error, {:trello_api_status, 404}} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      other -> other
    end
  end

  defp fetch_cards_for_lists(lists) when is_list(lists) do
    lists
    |> Enum.reduce_while({:ok, []}, fn %{id: list_id}, {:ok, acc} ->
      case request(:get, "/lists/#{list_id}/cards", %{"fields" => @card_fields}) do
        {:ok, cards} when is_list(cards) -> {:cont, {:ok, Enum.reverse(cards, acc)}}
        {:ok, _unexpected} -> {:halt, {:error, :trello_unknown_payload}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cards} -> {:ok, Enum.reverse(cards)}
      other -> other
    end
  end

  defp fetch_card(card_id) when is_binary(card_id) do
    request(:get, "/cards/#{card_id}", %{"fields" => @card_fields})
  end

  defp fetch_card_actions(card_id) when is_binary(card_id) do
    query = %{
      "filter" => "commentCard,updateCard:idList",
      "limit" => 100,
      "fields" => "type,date,data,memberCreator"
    }

    case request(:get, "/cards/#{card_id}/actions", query) do
      {:ok, actions} when is_list(actions) -> {:ok, actions}
      {:ok, _unexpected} -> {:error, :trello_unknown_payload}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_codex_workpad_action_id(actions) when is_list(actions) do
    Enum.find_value(actions, fn
      %{"type" => "commentCard", "id" => action_id} = action when is_binary(action_id) ->
        text =
          action
          |> Map.get("data", %{})
          |> Map.get("text")

        if codex_workpad_comment?(text), do: action_id, else: nil

      _ ->
        nil
    end)
  end

  defp fetch_board_lists(board_id) when is_binary(board_id) do
    case request(:get, "/boards/#{board_id}/lists", %{"fields" => "id,name,closed"}) do
      {:ok, lists} when is_list(lists) ->
        {:ok, Enum.map(lists, &normalize_list/1) |> Enum.reject(&is_nil/1)}

      {:ok, _unexpected} ->
        {:error, :trello_unknown_payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_board_lists_by_normalized_name(board_id) when is_binary(board_id) do
    with {:ok, lists} <- fetch_board_lists(board_id) do
      {:ok, lists_by_normalized_name(lists)}
    end
  end

  defp normalize_cards(cards, assignee_filter, lists \\ nil)

  defp normalize_cards(cards, assignee_filter, nil) when is_list(cards) do
    board_ids =
      cards
      |> Enum.map(&Map.get(&1, "idBoard"))
      |> Enum.map(&normalize_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    with {:ok, lists} <- fetch_lists_for_board_ids(board_ids) do
      normalize_cards(cards, assignee_filter, lists)
    end
  end

  defp normalize_cards(cards, assignee_filter, lists) when is_list(cards) and is_list(lists) do
    lists_by_id =
      Map.new(lists, fn %{id: list_id} = list -> {list_id, list} end)

    {:ok,
     cards
     |> Enum.map(&normalize_card(&1, lists_by_id, assignee_filter))
     |> Enum.reject(&is_nil/1)}
  end

  defp fetch_lists_for_board_ids(board_ids) when is_list(board_ids) do
    board_ids
    |> Enum.reduce_while({:ok, []}, fn board_id, {:ok, acc} ->
      case fetch_board_lists(board_id) do
        {:ok, lists} -> {:cont, {:ok, lists ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, lists} -> {:ok, lists}
      other -> other
    end
  end

  defp normalize_card(card, lists_by_id, assignee_filter)
       when is_map(card) and is_map(lists_by_id) do
    member_ids = extract_member_ids(card)
    list = lists_by_id[card["idList"]]
    state = list && list.name

    if card["closed"] == true do
      nil
    else
      %Issue{
        id: card["id"],
        identifier: card_identifier(card),
        title: card["name"],
        description: card["desc"],
        priority: nil,
        state: state,
        branch_name: nil,
        url: card["url"],
        assignee_id: List.first(member_ids),
        blocked_by: [],
        labels: extract_labels(card),
        assigned_to_worker: assigned_to_worker?(member_ids, assignee_filter),
        created_at: card_created_at(card["id"]),
        updated_at: parse_datetime(card["dateLastActivity"])
      }
    end
  end

  defp normalize_card(_card, _lists_by_id, _assignee_filter), do: nil

  defp normalize_list(%{"id" => id, "name" => name} = raw_list)
       when is_binary(id) and is_binary(name) do
    %{id: id, name: name, normalized_name: normalize_state_name(name), closed: raw_list["closed"] == true}
  end

  defp normalize_list(_raw_list), do: nil

  defp lists_by_normalized_name(lists) when is_list(lists) do
    Map.new(lists, fn %{normalized_name: normalized_name} = list -> {normalized_name, list} end)
  end

  defp select_target_lists(lists_by_state, state_names) when is_map(lists_by_state) and is_list(state_names) do
    state_names
    |> Enum.map(&normalize_state_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn normalized_state ->
      case Map.get(lists_by_state, normalized_state) do
        nil -> []
        list -> [list]
      end
    end)
  end

  defp normalize_http_method(method) when is_atom(method) do
    method |> Atom.to_string() |> normalize_http_method()
  end

  defp normalize_http_method(method) when is_binary(method) do
    case method |> String.trim() |> String.upcase() do
      "GET" -> {:ok, :get}
      "POST" -> {:ok, :post}
      "PUT" -> {:ok, :put}
      "DELETE" -> {:ok, :delete}
      _ -> {:error, :invalid_trello_method}
    end
  end

  defp normalize_http_method(_method), do: {:error, :invalid_trello_method}

  defp auth_query do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_trello_api_key}

      is_nil(tracker.api_token) ->
        {:error, :missing_trello_api_token}

      true ->
        {:ok, %{"key" => tracker.api_key, "token" => tracker.api_token}}
    end
  end

  defp build_url(path) when is_binary(path) do
    case normalize_path(path) do
      nil ->
        {:error, :invalid_trello_path}

      normalized_path ->
        endpoint =
          Config.settings!().tracker.endpoint
          |> to_string()
          |> String.trim_trailing("/")

        {:ok, endpoint <> normalized_path}
    end
  end

  defp build_request_opts(method, url, query, nil) do
    [
      method: method,
      url: url,
      params: query,
      connect_options: [timeout: 30_000]
    ]
  end

  defp build_request_opts(method, url, query, body) when is_map(body) or is_list(body) do
    [
      method: method,
      url: url,
      params: query,
      json: body,
      connect_options: [timeout: 30_000]
    ]
  end

  defp build_request_opts(method, url, query, body) do
    [
      method: method,
      url: url,
      params: query,
      body: body,
      connect_options: [timeout: 30_000]
    ]
  end

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_string(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_current_member_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp build_assignee_filter(_assignee), do: {:ok, nil}

  defp resolve_current_member_filter do
    case request(:get, "/members/me", %{"fields" => "id"}) do
      {:ok, %{"id" => member_id}} when is_binary(member_id) ->
        {:ok, %{configured_assignee: "me", match_values: MapSet.new([member_id])}}

      {:ok, _body} ->
        {:error, :missing_trello_member_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assigned_to_worker?(_member_ids, nil), do: true

  defp assigned_to_worker?(member_ids, %{match_values: match_values})
       when is_list(member_ids) and is_struct(match_values, MapSet) do
    Enum.any?(member_ids, &MapSet.member?(match_values, &1))
  end

  defp assigned_to_worker?(_member_ids, _assignee_filter), do: false

  defp extract_member_ids(%{"idMembers" => member_ids}) when is_list(member_ids) do
    member_ids
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_member_ids(_card), do: []

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) and name != "" -> String.downcase(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_card), do: []

  defp card_identifier(%{"idShort" => id_short}) when is_integer(id_short), do: "TR-#{id_short}"

  defp card_identifier(%{"idShort" => id_short}) when is_binary(id_short) do
    case Integer.parse(id_short) do
      {parsed, _} -> "TR-#{parsed}"
      _ -> id_short
    end
  end

  defp card_identifier(%{"id" => card_id}) when is_binary(card_id), do: card_id
  defp card_identifier(_card), do: nil

  defp card_created_at(card_id) when is_binary(card_id) do
    with <<timestamp_hex::binary-size(8), _rest::binary>> <- card_id,
         {timestamp, ""} <- Integer.parse(timestamp_hex, 16),
         {:ok, created_at} <- DateTime.from_unix(timestamp) do
      created_at
    else
      _ -> nil
    end
  end

  defp card_created_at(_card_id), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_raw), do: nil

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

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, ["\n", "\r", <<0>>]) ->
        nil

      String.starts_with?(trimmed, "/") ->
        trimmed

      true ->
        "/" <> trimmed
    end
  end

  defp trello_error_context(url_or_path, response_body) do
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

  defp normalize_request_error({:trello_api_status, _status} = reason), do: reason
  defp normalize_request_error({:trello_api_request, _reason} = reason), do: reason
  defp normalize_request_error(:missing_trello_api_key), do: :missing_trello_api_key
  defp normalize_request_error(:missing_trello_api_token), do: :missing_trello_api_token
  defp normalize_request_error(:missing_trello_board_id), do: :missing_trello_board_id
  defp normalize_request_error(:missing_trello_member_identity), do: :missing_trello_member_identity
  defp normalize_request_error(:invalid_trello_method), do: :invalid_trello_method
  defp normalize_request_error(:invalid_trello_path), do: :invalid_trello_path
  defp normalize_request_error(reason), do: {:trello_api_request, reason}

  defp normalize_human_response_action(action, since, active_states)
       when is_map(action) and is_struct(active_states, MapSet) do
    with %DateTime{} = action_at <- parse_datetime(action["date"]),
         true <- is_nil(since) or DateTime.compare(action_at, since) in [:gt, :eq] do
      case action["type"] do
        "commentCard" ->
          comment_marker(action, action_at)

        "updateCard" ->
          state_transition_marker(action, action_at, active_states)

        _ ->
          nil
      end
    else
      _ -> nil
    end
  end

  defp normalize_human_response_action(_action, _since, _active_states), do: nil

  defp comment_marker(action, action_at) when is_map(action) and is_struct(action_at, DateTime) do
    text =
      action
      |> Map.get("data", %{})
      |> Map.get("text")
      |> normalize_string()

    cond do
      is_nil(text) ->
        nil

      codex_comment?(text) ->
        nil

      true ->
        %{
          "at" => iso8601(action_at),
          "kind" => "comment",
          "summary" => "human comment added on Trello card",
          "comment_excerpt" => truncate_excerpt(text),
          "author" => action_author_name(action)
        }
        |> drop_nil_map_values()
    end
  end

  defp comment_marker(_action, _action_at), do: nil

  defp state_transition_marker(action, action_at, active_states)
       when is_map(action) and is_struct(action_at, DateTime) and is_struct(active_states, MapSet) do
    data = Map.get(action, "data", %{})
    from_state = data |> get_in(["listBefore", "name"]) |> normalize_string()
    to_state = data |> get_in(["listAfter", "name"]) |> normalize_string()

    cond do
      is_nil(from_state) or is_nil(to_state) ->
        nil

      normalize_state_name(from_state) != "human review" ->
        nil

      not MapSet.member?(active_states, normalize_state_name(to_state)) ->
        nil

      true ->
        %{
          "at" => iso8601(action_at),
          "kind" => "state_transition",
          "summary" => "card moved from Human Review to #{to_state}",
          "from_state" => from_state,
          "to_state" => to_state,
          "author" => action_author_name(action)
        }
        |> drop_nil_map_values()
    end
  end

  defp state_transition_marker(_action, _action_at, _active_states), do: nil

  defp codex_comment?(text) when is_binary(text) do
    normalized =
      text
      |> String.trim_leading()
      |> String.downcase()

    String.starts_with?(normalized, "## codex ")
  end

  defp codex_workpad_comment?(text) when is_binary(text) do
    text
    |> String.trim_leading()
    |> String.downcase()
    |> String.starts_with?("## codex workpad")
  end

  defp codex_workpad_comment?(_text), do: false

  defp truncate_excerpt(text) when is_binary(text) do
    trimmed = String.trim(text)

    if String.length(trimmed) > 180 do
      String.slice(trimmed, 0, 180) <> "..."
    else
      trimmed
    end
  end

  defp action_author_name(action) when is_map(action) do
    action
    |> Map.get("memberCreator", %{})
    |> case do
      %{"fullName" => full_name} when is_binary(full_name) and full_name != "" -> full_name
      %{"username" => username} when is_binary(username) and username != "" -> username
      _ -> nil
    end
  end

  defp coerce_datetime(%DateTime{} = datetime), do: datetime
  defp coerce_datetime(value) when is_binary(value), do: parse_datetime(value)
  defp coerce_datetime(_value), do: nil

  defp normalize_state_name_set(values) when is_list(values) do
    values
    |> Enum.map(&normalize_state_name/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp normalize_state_name_set(_values), do: MapSet.new()

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
