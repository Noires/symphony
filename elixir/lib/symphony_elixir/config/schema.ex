defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string)
      field(:api_key, :string)
      field(:api_token, :string)
      field(:project_slug, :string)
      field(:board_id, :string)
      field(:owner, :string)
      field(:repo, :string)
      field(:project_number, :string)
      field(:status_field_name, :string, default: "Status")
      field(:assignee, :string)
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_key,
          :api_token,
          :project_slug,
          :board_id,
          :owner,
          :repo,
          :project_number,
          :status_field_name,
          :assignee,
          :active_states,
          :terminal_states
        ],
        empty_values: []
      )
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:continue_on_active_issue, :boolean, default: true)
      field(:max_issue_description_prompt_chars, :integer)
      field(:include_full_issue_description_in_prompt, :boolean, default: true)
      field(:handoff_summary_enabled, :boolean, default: false)
      field(:completed_issue_state, :string)
      field(:completed_issue_state_by_state, :map, default: %{})
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :continue_on_active_issue,
          :max_issue_description_prompt_chars,
          :include_full_issue_description_in_prompt,
          :handoff_summary_enabled,
          :completed_issue_state,
          :completed_issue_state_by_state,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state
        ],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_issue_description_prompt_chars, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:completed_issue_state_by_state, &Schema.normalize_completed_issue_state_overrides/1)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_completed_issue_state_overrides(:completed_issue_state_by_state)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex app-server")
      field(:model, :string)
      field(:reasoning_effort, :string)

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :model,
          :reasoning_effort,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_success, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_success, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset
    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
      field(:audit_enabled, :boolean, default: true)
      field(:audit_storage_backend, :string, default: "flat_files")
      field(:audit_runs_per_issue, :integer, default: 20)
      field(:audit_dashboard_runs, :integer, default: 8)
      field(:issue_rollup_limit, :integer, default: 8)
      field(:audit_event_limit, :integer, default: 200)
      field(:audit_max_string_length, :integer, default: 4_000)
      field(:audit_max_list_items, :integer, default: 50)
      field(:diff_preview_enabled, :boolean, default: true)
      field(:diff_preview_max_files, :integer, default: 10)
      field(:diff_preview_hunks_per_file, :integer, default: 3)
      field(:diff_preview_max_line_length, :integer, default: 240)
      field(:audit_redact_keys, {:array, :string}, default: ["api_key", "api_token", "token", "secret", "password", "authorization", "cookie", "auth"])
      field(:audit_store_reasoning_text, :boolean, default: false)
      field(:trello_run_summary_enabled, :boolean, default: true)
      field(:tracker_summary_template, :string)
      field(:expensive_run_uncached_input_threshold, :integer, default: 8_000)
      field(:expensive_run_tokens_per_changed_file_threshold, :integer, default: 4_000)
      field(:expensive_run_retry_attempt_threshold, :integer, default: 2)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :dashboard_enabled,
          :refresh_ms,
          :render_interval_ms,
          :audit_enabled,
          :audit_storage_backend,
          :audit_runs_per_issue,
          :audit_dashboard_runs,
          :issue_rollup_limit,
          :audit_event_limit,
          :audit_max_string_length,
          :audit_max_list_items,
          :diff_preview_enabled,
          :diff_preview_max_files,
          :diff_preview_hunks_per_file,
          :diff_preview_max_line_length,
          :audit_redact_keys,
          :audit_store_reasoning_text,
          :trello_run_summary_enabled,
          :tracker_summary_template,
          :expensive_run_uncached_input_threshold,
          :expensive_run_tokens_per_changed_file_threshold,
          :expensive_run_retry_attempt_threshold
        ],
        empty_values: []
      )
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
      |> validate_number(:audit_runs_per_issue, greater_than: 0)
      |> validate_number(:audit_dashboard_runs, greater_than: 0)
      |> validate_number(:issue_rollup_limit, greater_than: 0)
      |> validate_number(:audit_event_limit, greater_than: 0)
      |> validate_number(:audit_max_string_length, greater_than: 0)
      |> validate_number(:audit_max_list_items, greater_than: 0)
      |> validate_number(:diff_preview_max_files, greater_than: 0)
      |> validate_number(:diff_preview_hunks_per_file, greater_than: 0)
      |> validate_number(:diff_preview_max_line_length, greater_than: 0)
      |> validate_number(:expensive_run_uncached_input_threshold, greater_than: 0)
      |> validate_number(:expensive_run_tokens_per_changed_file_threshold, greater_than: 0)
      |> validate_number(:expensive_run_retry_attempt_threshold, greater_than_or_equal_to: 0)
      |> validate_inclusion(:audit_storage_backend, ["flat_files"])
      |> update_change(:audit_redact_keys, &Schema.normalize_redact_keys/1)
      |> update_change(:tracker_summary_template, &Schema.normalize_string_value/1)
    end
  end

  defmodule Guardrails do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: false)
      field(:operator_token, :string)
      field(:default_review_mode, :string, default: "review")
      field(:builtin_rule_preset, :string, default: "safe")
      field(:full_access_run_ttl_ms, :integer, default: 3_600_000)
      field(:full_access_workflow_ttl_ms, :integer, default: 28_800_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :enabled,
          :operator_token,
          :default_review_mode,
          :builtin_rule_preset,
          :full_access_run_ttl_ms,
          :full_access_workflow_ttl_ms
        ],
        empty_values: []
      )
      |> validate_inclusion(:default_review_mode, ["review", "deny"])
      |> validate_inclusion(:builtin_rule_preset, ["safe", "off"])
      |> validate_number(:full_access_run_ttl_ms, greater_than: 0)
      |> validate_number(:full_access_workflow_ttl_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:guardrails, Guardrails, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec normalize_completed_issue_state_overrides(nil | map()) :: map()
  def normalize_completed_issue_state_overrides(nil), do: %{}

  def normalize_completed_issue_state_overrides(overrides) when is_map(overrides) do
    Enum.reduce(overrides, %{}, fn {state_name, completed_state}, acc ->
      normalized_completed_state =
        completed_state
        |> to_string()
        |> normalize_string_value()

      normalized_state_name =
        state_name
        |> to_string()
        |> String.trim()
        |> normalize_issue_state()

      Map.put(acc, normalized_state_name, normalized_completed_state)
    end)
  end

  def normalize_completed_issue_state_overrides(_overrides), do: %{}

  @doc false
  @spec normalize_redact_keys(nil | [term()]) :: [String.t()]
  def normalize_redact_keys(nil), do: []

  def normalize_redact_keys(keys) when is_list(keys) do
    keys
    |> Enum.map(&(to_string(&1) |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_redact_keys(_keys), do: []

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  @doc false
  @spec validate_completed_issue_state_overrides(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_completed_issue_state_overrides(changeset, field) do
    validate_change(changeset, field, fn ^field, overrides ->
      Enum.flat_map(overrides, fn {state_name, completed_state} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_binary(completed_state) or String.trim(completed_state) == "" ->
            [{field, "completed states must be non-blank strings"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:guardrails, with: &Guardrails.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings) do
    tracker = finalize_tracker_settings(settings.tracker)
    agent = finalize_agent_settings(settings.agent)

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = finalize_codex_settings(settings.codex)

    guardrails = %{
      settings.guardrails
      | operator_token: resolve_secret_setting(settings.guardrails.operator_token, guardrails_operator_token_env_fallback()),
        default_review_mode: resolve_string_setting(settings.guardrails.default_review_mode, "review"),
        builtin_rule_preset: resolve_string_setting(settings.guardrails.builtin_rule_preset, "safe")
    }

    %{settings | tracker: tracker, workspace: workspace, agent: agent, codex: codex, guardrails: guardrails}
  end

  defp finalize_codex_settings(codex) do
    base_command = resolve_string_setting(codex.command, "codex app-server")
    parsed_command = parse_codex_command(base_command)
    model = resolve_string_setting(codex.model, parsed_command.model)
    reasoning_effort = resolve_string_setting(codex.reasoning_effort, parsed_command.reasoning_effort)

    %{
      codex
      | command: build_codex_command(parsed_command, model, reasoning_effort),
        model: model,
        reasoning_effort: reasoning_effort,
        approval_policy: normalize_keys(codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(codex.turn_sandbox_policy)
    }
  end

  defp parse_codex_command(command) when is_binary(command) do
    case OptionParser.split(command) do
      [executable | args] ->
        {pre_app_server_args, post_app_server_args, app_server?} = split_codex_command_args(args)
        {clean_pre_args, model, reasoning_effort} = extract_codex_launch_settings(pre_app_server_args, nil, nil, [])

        %{
          raw_command: command,
          parsed?: true,
          executable: executable,
          pre_app_server_args: clean_pre_args,
          post_app_server_args: post_app_server_args,
          app_server?: app_server?,
          model: model,
          reasoning_effort: reasoning_effort
        }

      _ ->
        %{
          raw_command: command,
          parsed?: false,
          executable: "codex",
          pre_app_server_args: [],
          post_app_server_args: [],
          app_server?: true,
          model: nil,
          reasoning_effort: nil
        }
    end
  rescue
    _ ->
      %{
        raw_command: command,
        parsed?: false,
        executable: "codex",
        pre_app_server_args: [],
        post_app_server_args: [],
        app_server?: true,
        model: nil,
        reasoning_effort: nil
      }
  end

  defp split_codex_command_args(args) when is_list(args) do
    case Enum.find_index(args, &(&1 == "app-server")) do
      nil ->
        {args, [], false}

      index ->
        {Enum.take(args, index), Enum.drop(args, index + 1), true}
    end
  end

  defp extract_codex_launch_settings([], model, reasoning_effort, acc) do
    {Enum.reverse(acc), model, reasoning_effort}
  end

  defp extract_codex_launch_settings(["--model", value | rest], _model, reasoning_effort, acc) do
    extract_codex_launch_settings(rest, value, reasoning_effort, acc)
  end

  defp extract_codex_launch_settings(["-m", value | rest], _model, reasoning_effort, acc) do
    extract_codex_launch_settings(rest, value, reasoning_effort, acc)
  end

  defp extract_codex_launch_settings(["--config", value | rest], model, reasoning_effort, acc) do
    case parse_codex_config_override(value) do
      {:reasoning_effort, parsed_value} ->
        extract_codex_launch_settings(rest, model, parsed_value, acc)

      :ignore ->
        extract_codex_launch_settings(rest, model, reasoning_effort, [value, "--config" | acc])
    end
  end

  defp extract_codex_launch_settings(["-c", value | rest], model, reasoning_effort, acc) do
    case parse_codex_config_override(value) do
      {:reasoning_effort, parsed_value} ->
        extract_codex_launch_settings(rest, model, parsed_value, acc)

      :ignore ->
        extract_codex_launch_settings(rest, model, reasoning_effort, [value, "-c" | acc])
    end
  end

  defp extract_codex_launch_settings([arg | rest], model, reasoning_effort, acc)
       when is_binary(arg) do
    cond do
      String.starts_with?(arg, "--model=") ->
        extract_codex_launch_settings(rest, String.replace_prefix(arg, "--model=", ""), reasoning_effort, acc)

      String.starts_with?(arg, "--config=") ->
        case parse_codex_config_override(String.replace_prefix(arg, "--config=", "")) do
          {:reasoning_effort, parsed_value} ->
            extract_codex_launch_settings(rest, model, parsed_value, acc)

          :ignore ->
            extract_codex_launch_settings(rest, model, reasoning_effort, [arg | acc])
        end

      true ->
        extract_codex_launch_settings(rest, model, reasoning_effort, [arg | acc])
    end
  end

  defp parse_codex_config_override(value) when is_binary(value) do
    case String.split(value, "=", parts: 2) do
      ["model_reasoning_effort", raw_value] ->
        {:reasoning_effort, trim_surrounding_quotes(String.trim(raw_value))}

      _ ->
        :ignore
    end
  end

  defp parse_codex_config_override(_value), do: :ignore

  defp build_codex_command(parsed_command, model, reasoning_effort) when is_map(parsed_command) do
    if Map.get(parsed_command, :parsed?) == false and is_nil(model) and is_nil(reasoning_effort) do
      Map.get(parsed_command, :raw_command, "codex app-server")
    else
      tokens =
        [parsed_command.executable]
        |> Kernel.++(Map.get(parsed_command, :pre_app_server_args, []))
        |> maybe_append_reasoning_effort(reasoning_effort)
        |> maybe_append_model(model)
        |> maybe_append_app_server(parsed_command)

      Enum.map_join(tokens, " ", &shell_join_token/1)
    end
  end

  defp maybe_append_reasoning_effort(tokens, nil), do: tokens
  defp maybe_append_reasoning_effort(tokens, ""), do: tokens

  defp maybe_append_reasoning_effort(tokens, reasoning_effort) when is_binary(reasoning_effort) do
    tokens ++ ["--config", "model_reasoning_effort=#{reasoning_effort}"]
  end

  defp maybe_append_model(tokens, nil), do: tokens
  defp maybe_append_model(tokens, ""), do: tokens
  defp maybe_append_model(tokens, model) when is_binary(model), do: tokens ++ ["--model", model]

  defp maybe_append_app_server(tokens, %{app_server?: true, post_app_server_args: post_args}) do
    tokens ++ ["app-server"] ++ post_args
  end

  defp maybe_append_app_server(tokens, %{app_server?: false, post_app_server_args: post_args}) do
    tokens ++ post_args
  end

  defp shell_join_token(token) when is_binary(token) do
    if token == "" do
      "''"
    else
      if Regex.match?(~r'^[A-Za-z0-9_@%+=:,./~${}-]+$', token) do
        token
      else
        "'" <> String.replace(token, "'", "'\"'\"'") <> "'"
      end
    end
  end

  defp trim_surrounding_quotes("\"" <> rest) do
    case String.ends_with?(rest, "\"") do
      true -> String.trim_trailing(rest, "\"")
      false -> "\"" <> rest
    end
  end

  defp trim_surrounding_quotes("'" <> rest) do
    case String.ends_with?(rest, "'") do
      true -> String.trim_trailing(rest, "'")
      false -> "'" <> rest
    end
  end

  defp trim_surrounding_quotes(value), do: value

  defp finalize_tracker_settings(tracker) do
    kind = normalize_tracker_kind(tracker.kind) || "linear"

    %{
      tracker
      | endpoint: default_tracker_endpoint(tracker.endpoint, kind),
        api_key: resolve_secret_setting(tracker.api_key, tracker_api_key_env_fallback(kind)),
        api_token: resolve_secret_setting(tracker.api_token, tracker_api_token_env_fallback(kind)),
        board_id: resolve_string_setting(tracker.board_id, tracker_board_id_env_fallback(kind)),
        owner: resolve_string_setting(tracker.owner, tracker_owner_env_fallback(kind)),
        repo: resolve_string_setting(tracker.repo, tracker_repo_env_fallback(kind)),
        project_number: resolve_string_setting(tracker.project_number, tracker_project_number_env_fallback(kind)),
        status_field_name: resolve_string_setting(tracker.status_field_name, "Status"),
        assignee: resolve_secret_setting(tracker.assignee, tracker_assignee_env_fallback(kind))
    }
  end

  defp finalize_agent_settings(agent) do
    %{
      agent
      | completed_issue_state: resolve_string_setting(agent.completed_issue_state, nil),
        completed_issue_state_by_state: finalize_completed_issue_state_overrides(agent.completed_issue_state_by_state)
    }
  end

  defp finalize_completed_issue_state_overrides(overrides) when is_map(overrides) do
    Enum.reduce(overrides, %{}, fn {state_name, completed_state}, acc ->
      case normalize_string_value(to_string(completed_state)) do
        nil ->
          acc

        normalized_completed_state ->
          normalized_state_name =
            state_name
            |> to_string()
            |> String.trim()
            |> normalize_issue_state()

          Map.put(acc, normalized_state_name, normalized_completed_state)
      end
    end)
  end

  defp finalize_completed_issue_state_overrides(_overrides), do: %{}

  defp normalize_tracker_kind(kind) when is_binary(kind) do
    kind
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tracker_kind(_kind), do: nil

  defp default_tracker_endpoint(value, kind) when is_binary(value) do
    case String.trim(value) do
      "" -> tracker_default_endpoint(kind)
      endpoint -> endpoint
    end
  end

  defp default_tracker_endpoint(_value, kind), do: tracker_default_endpoint(kind)

  defp tracker_default_endpoint("trello"), do: "https://api.trello.com/1"
  defp tracker_default_endpoint("linear"), do: "https://api.linear.app/graphql"
  defp tracker_default_endpoint("github"), do: "https://api.github.com"
  defp tracker_default_endpoint(_kind), do: nil

  defp tracker_api_key_env_fallback("linear"), do: System.get_env("LINEAR_API_KEY")
  defp tracker_api_key_env_fallback("trello"), do: System.get_env("TRELLO_API_KEY")
  defp tracker_api_key_env_fallback(_kind), do: nil

  defp tracker_api_token_env_fallback("trello"), do: System.get_env("TRELLO_API_TOKEN")
  defp tracker_api_token_env_fallback("github"), do: System.get_env("GITHUB_TOKEN")
  defp tracker_api_token_env_fallback(_kind), do: nil

  defp tracker_board_id_env_fallback("trello"), do: System.get_env("TRELLO_BOARD_ID")
  defp tracker_board_id_env_fallback(_kind), do: nil

  defp tracker_owner_env_fallback("github"), do: System.get_env("GITHUB_OWNER")
  defp tracker_owner_env_fallback(_kind), do: nil

  defp tracker_repo_env_fallback("github"), do: System.get_env("GITHUB_REPO")
  defp tracker_repo_env_fallback(_kind), do: nil

  defp tracker_project_number_env_fallback("github"), do: System.get_env("GITHUB_PROJECT_NUMBER")
  defp tracker_project_number_env_fallback(_kind), do: nil

  defp tracker_assignee_env_fallback("linear"), do: System.get_env("LINEAR_ASSIGNEE")
  defp tracker_assignee_env_fallback("trello"), do: System.get_env("TRELLO_ASSIGNEE")
  defp tracker_assignee_env_fallback("github"), do: System.get_env("GITHUB_ASSIGNEE")
  defp tracker_assignee_env_fallback(_kind), do: nil

  defp guardrails_operator_token_env_fallback do
    System.get_env("SYMPHONY_OPERATOR_TOKEN") || System.get_env("SYMPHONY_GUARDRAILS_OPERATOR_TOKEN")
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_string_setting(nil, fallback), do: normalize_string_value(fallback)

  defp resolve_string_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_string_value(resolved)
      _resolved -> nil
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> Path.expand(default)
          "" -> Path.expand(default)
          env_value -> Path.expand(env_value)
        end

      :error ->
        case String.trim(value) do
          "" -> Path.expand(default)
          _ when value == default -> Path.expand(default)
          _ -> value
        end
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  @doc false
  @spec normalize_string_value(term()) :: String.t() | nil
  def normalize_string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_string_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
