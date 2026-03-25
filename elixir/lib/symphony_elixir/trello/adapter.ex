defmodule SymphonyElixir.Trello.Adapter do
  @moduledoc """
  Trello-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Trello.Client

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().create_comment(issue_id, body) do
      {:ok, %{"id" => _comment_id}} -> :ok
      {:ok, %{"type" => "commentCard"}} -> :ok
      {:ok, _unexpected} -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    case client_module().update_issue_state(issue_id, state_name) do
      {:ok, %{"idList" => _list_id}} -> :ok
      {:ok, _unexpected} -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec fetch_human_response_marker(String.t(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_human_response_marker(issue_id, opts \\ []) when is_binary(issue_id) and is_list(opts) do
    client_module().fetch_human_response_marker(issue_id, opts)
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :trello_client_module, Client)
  end
end
