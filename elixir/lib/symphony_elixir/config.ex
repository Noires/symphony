defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.GitHubAccess
  alias SymphonyElixir.SettingsOverlay
  alias SymphonyElixir.Workflow

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        with {:ok, settings} <-
               config
               |> SettingsOverlay.apply_to_workflow_config()
               |> Schema.parse() do
          {:ok, GitHubAccess.apply_tracker_token(settings)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec guardrails_enabled?() :: boolean()
  def guardrails_enabled? do
    settings!().guardrails.enabled == true
  end

  @spec execution_boundary() :: String.t()
  def execution_boundary do
    "container"
  end

  @spec container_boundary_mode?() :: boolean()
  def container_boundary_mode? do
    true
  end

  @spec approval_controls_supported?() :: boolean()
  def approval_controls_supported? do
    false
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    default_prompt = default_prompt_template()

    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: default_prompt, else: prompt

      _ ->
        default_prompt
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    _ = workspace
    _ = opts

    with {:ok, _settings} <- settings() do
      {:ok, container_boundary_runtime_settings()}
    end
  end

  defp container_boundary_runtime_settings do
    %{
      approval_policy: "never",
      thread_sandbox: "danger-full-access",
      turn_sandbox_policy: %{"type" => "dangerFullAccess"}
    }
  end

  defp validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["linear", "memory", "trello", "github"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_linear_api_token}

      settings.tracker.kind == "linear" and not is_binary(settings.tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      settings.tracker.kind == "trello" and not is_binary(settings.tracker.api_key) ->
        {:error, :missing_trello_api_key}

      settings.tracker.kind == "trello" and not is_binary(settings.tracker.api_token) ->
        {:error, :missing_trello_api_token}

      settings.tracker.kind == "trello" and not is_binary(settings.tracker.board_id) ->
        {:error, :missing_trello_board_id}

      settings.tracker.kind == "github" and not is_binary(settings.tracker.api_token) ->
        {:error, :missing_github_api_token}

      settings.tracker.kind == "github" and not is_binary(settings.tracker.owner) ->
        {:error, :missing_github_owner}

      settings.tracker.kind == "github" and not is_binary(settings.tracker.repo) ->
        {:error, :missing_github_repo}

      settings.tracker.kind == "github" and not is_binary(settings.tracker.project_number) ->
        {:error, :missing_github_project_number}

      settings.tracker.kind == "github" and not github_project_number?(settings.tracker.project_number) ->
        {:error, :invalid_github_project_number}

      true ->
        :ok
    end
  end

  defp default_prompt_template do
    tracker_label =
      case settings() do
        {:ok, settings} ->
          case settings.tracker.kind do
            "trello" -> "Trello card"
            "linear" -> "Linear issue"
            "github" -> "GitHub issue"
            _ -> "tracker issue"
          end

        _ ->
          "tracker issue"
      end

    """
    You are working on a #{tracker_label}.

    Identifier: {{ issue.identifier }}
    Title: {{ issue.title }}

    Body:
    {% if issue.description %}
    {{ issue.description }}
    {% else %}
    No description provided.
    {% endif %}
    """
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end

  defp github_project_number?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> true
      _ -> false
    end
  end

  defp github_project_number?(_value), do: false
end
