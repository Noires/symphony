defmodule SymphonyElixir.Guardrails.Policy do
  @moduledoc false

  alias SymphonyElixir.{Config, Guardrails.Rule, StatusDashboard}

  @safe_builtin_read_commands ~w[cat diff find grep head ls pwd rg sed tail]
  @safe_git_subcommands ~w[branch diff log rev-parse show status]
  @safe_mix_subcommands ~w[compile format test]
  @safe_npm_subcommands ~w[test]
  @safe_yarn_subcommands ~w[test]
  @shell_wrapper_commands ~w[bash cmd cmd.exe fish node node.exe powershell powershell.exe pwsh pwsh.exe python python.exe ruby ruby.exe sh zsh]
  @network_command_executables ~w[apk apt apt-get brew cargo composer curl dnf docker gem gh go helm kubectl npm pacman pip pip3 pnpm rsync scp sftp ssh terraform wget yarn]
  @network_git_subcommands ~w[clone fetch ls-remote pull push submodule]
  @network_mix_subcommands ~w[archive.build archive.install deps.get deps.unlock escript.install hex.build hex.info hex.outdated local.hex local.rebar]
  @network_npm_subcommands ~w[add ci exec install login publish view whoami]
  @network_yarn_subcommands ~w[add dlx info install npm publish up why]
  @sensitive_path_markers [
    ".aws/",
    ".env",
    ".env.",
    ".github/workflows/",
    ".npmrc",
    ".pypirc",
    "/auth/",
    "/credentials/",
    "/deploy/",
    "/docker/",
    "/helm/",
    "/infra/",
    "/k8s/",
    "/secret/",
    "/secrets/",
    "/terraform/",
    "docker-compose",
    "dockerfile"
  ]

  @type evaluation :: %{
          disposition: :allow | :review | :deny,
          action_type: String.t(),
          method: String.t(),
          summary: String.t(),
          risk_level: String.t(),
          reason: String.t(),
          fingerprint: String.t(),
          protocol_request_id: String.t() | nil,
          response_decision: String.t() | nil,
          source: String.t(),
          rule_id: String.t() | nil,
          rule_scope: String.t() | nil,
          decision_mode: String.t() | nil,
          details: map(),
          payload: map()
        }

  @spec enabled?() :: boolean()
  def enabled? do
    Config.settings!().guardrails.enabled == true
  end

  @spec evaluate_approval_request(String.t(), map(), map()) :: evaluation()
  def evaluate_approval_request(method, payload, context \\ %{})
      when is_binary(method) and is_map(payload) and is_map(context) do
    explain = explain_decision(method, payload, context)

    explain
    |> Map.fetch!(:evaluation)
    |> Map.update!(:disposition, &String.to_existing_atom/1)
  end

  @spec explain_approval_request(String.t(), map(), map()) :: map()
  def explain_approval_request(method, payload, context \\ %{})
      when is_binary(method) and is_map(payload) and is_map(context) do
    explain_decision(method, payload, context)
  end

  defp explain_decision(method, payload, context) do
    action = action_from_request(method, payload, context)
    settings = Config.settings!().guardrails
    rules = guardrail_rules(context)
    matching_rules = matching_rules(action, context, rules)
    matched_rule = List.first(matching_rules)
    builtin_allow = builtin_allow?(action, settings.builtin_rule_preset)
    full_access_override = full_access_override?(context)

    evaluation =
      case {full_access_override, matched_rule, builtin_allow, settings.default_review_mode} do
        {true, _matched_rule, _builtin_allow, _review_mode} ->
          Map.merge(action, %{
            disposition: :allow,
            response_decision: approval_decision_for_method(method),
            source: "full_access_override",
            decision_mode: "full_access_override",
            reason: "full access override active"
          })

        {false, %Rule{} = rule, _builtin_allow, _review_mode} ->
          Map.merge(action, %{
            disposition: rule_disposition(rule),
            response_decision: response_decision_for_rule(rule, method),
            source: "policy_rule",
            rule_id: rule.id,
            rule_scope: rule.scope,
            decision_mode: rule_decision_mode(rule),
            reason: matched_rule_reason(rule)
          })

        {false, nil, true, _review_mode} ->
          Map.merge(action, %{
            disposition: :allow,
            response_decision: approval_decision_for_method(method),
            source: "builtin_rule",
            decision_mode: "builtin_rule",
            reason: "matched built-in low-risk allow rule"
          })

        {false, nil, false, "deny"} ->
          Map.merge(action, %{
            disposition: :deny,
            response_decision: nil,
            source: "default_review_mode",
            decision_mode: "default_review_mode",
            reason: "default review mode denies unmatched approval requests: " <> default_review_reason(action)
          })

        _ ->
          Map.merge(action, %{
            disposition: :review,
            response_decision: nil,
            source: "default_review_mode",
            decision_mode: "default_review_mode",
            reason: default_review_reason(action)
          })
      end

    %{
      "action" => sanitize_explain_value(action),
      "evaluation" =>
        evaluation
        |> sanitize_explain_value()
        |> Map.update!("disposition", &Atom.to_string/1),
      "full_access_override" => full_access_override,
      "builtin_rule_preset" => settings.builtin_rule_preset,
      "builtin_allow" => builtin_allow,
      "matched_rule" => matched_rule && Rule.snapshot_entry(matched_rule),
      "candidate_rules" => Enum.map(matching_rules, &Rule.snapshot_entry/1),
      "review_tags" => get_in(action, [:details, "review_tags"]) || []
    }
  end

  @spec decision_options() :: [String.t()]
  def decision_options do
    ["allow_once", "allow_for_session", "allow_via_rule", "deny"]
  end

  @spec approval_decision_for_method(String.t()) :: String.t() | nil
  def approval_decision_for_method("item/commandExecution/requestApproval"), do: "acceptForSession"
  def approval_decision_for_method("item/fileChange/requestApproval"), do: "acceptForSession"
  def approval_decision_for_method("execCommandApproval"), do: "approved_for_session"
  def approval_decision_for_method("applyPatchApproval"), do: "approved_for_session"
  def approval_decision_for_method(_method), do: nil

  defp action_from_request(method, payload, context) do
    details = request_details(method, payload, context)
    summary = summarize_request(method, payload)
    action_type = action_type_for_method(method)
    fingerprint = fingerprint_for_request(action_type, details, method)

    %{
      action_type: action_type,
      method: method,
      summary: summary,
      risk_level: risk_level_for_action(action_type, details),
      reason: "approval request captured from codex",
      fingerprint: fingerprint,
      protocol_request_id: normalize_optional_string(Map.get(payload, "id") || Map.get(payload, :id)),
      response_decision: nil,
      source: "request_capture",
      rule_id: nil,
      rule_scope: nil,
      decision_mode: nil,
      details: details,
      payload: payload
    }
  end

  defp request_details(method, payload, context) do
    params = Map.get(payload, "params") || Map.get(payload, :params) || %{}
    command = extract_command(params)
    command_argv = extract_command_argv(command)
    executable = command_argv && command_executable(command_argv)
    shell_wrapper = shell_wrapper_name(executable)
    wrapped_command = shell_wrapper_command(command_argv)
    file_paths = extract_file_paths(params)
    sensitive_paths = sensitive_paths(file_paths)
    outside_workspace_paths = outside_workspace_paths(file_paths, Map.get(context, :workspace_path))
    network_access = network_access_requested?(command, command_argv, wrapped_command, params, context)

    review_tags =
      build_review_tags(
        method,
        shell_wrapper,
        network_access,
        sensitive_paths,
        outside_workspace_paths
      )

    %{
      "method" => method,
      "session_id" => normalize_optional_string(Map.get(context, :session_id)),
      "workspace_path" => normalize_optional_string(Map.get(context, :workspace_path)),
      "thread_sandbox" => normalize_optional_string(Map.get(context, :thread_sandbox)),
      "command" => command,
      "command_argv" => empty_list_to_nil(command_argv),
      "command_executable" => executable,
      "shell_wrapper" => shell_wrapper,
      "wrapped_command" => wrapped_command,
      "cwd" => normalize_optional_string(Map.get(params, "cwd") || Map.get(params, :cwd)),
      "reason" => normalize_optional_string(Map.get(params, "reason") || Map.get(params, :reason)),
      "file_change_count" =>
        Map.get(params, "fileChangeCount") ||
          Map.get(params, :fileChangeCount) ||
          Map.get(params, "changeCount") ||
          Map.get(params, :changeCount),
      "file_paths" => empty_list_to_nil(file_paths),
      "sensitive_paths" => empty_list_to_nil(sensitive_paths),
      "outside_workspace_paths" => empty_list_to_nil(outside_workspace_paths),
      "review_tags" => empty_list_to_nil(review_tags),
      "network_access" => network_access,
      "full_access_override" => full_access_override?(context)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp summarize_request(method, payload) do
    StatusDashboard.humanize_codex_message(%{
      payload: Map.put(payload, "method", method)
    })
  end

  defp action_type_for_method("item/commandExecution/requestApproval"), do: "command_execution"
  defp action_type_for_method("execCommandApproval"), do: "command_execution"
  defp action_type_for_method("item/fileChange/requestApproval"), do: "file_change"
  defp action_type_for_method("applyPatchApproval"), do: "file_change"
  defp action_type_for_method(method), do: "unknown:" <> method

  defp risk_level_for_action("command_execution", details) do
    cond do
      Map.get(details, "network_access") == true -> "high"
      is_binary(Map.get(details, "shell_wrapper")) -> "high"
      true -> "medium"
    end
  end

  defp risk_level_for_action("file_change", details) do
    cond do
      present_list?(Map.get(details, "outside_workspace_paths")) -> "critical"
      present_list?(Map.get(details, "sensitive_paths")) -> "critical"
      true -> "high"
    end
  end

  defp risk_level_for_action(_action_type, _details), do: "high"

  defp builtin_allow?(%{action_type: "command_execution", details: details}, "safe") do
    safe_command?(Map.get(details, "command")) and
      Map.get(details, "network_access") != true and
      is_nil(Map.get(details, "shell_wrapper"))
  end

  defp builtin_allow?(_action, "off"), do: false
  defp builtin_allow?(action, _preset), do: builtin_allow?(action, "safe")

  defp matching_rules(action, context, rules) do
    rules
    |> Enum.filter(&Rule.matches?(&1, action, context))
    |> Enum.sort_by(&rule_precedence/1, :asc)
  end

  defp full_access_override?(context) when is_map(context) do
    case Map.get(context, :full_access_override) do
      %{mode: "full_access"} -> true
      %{mode: :full_access} -> true
      true -> true
      _ -> false
    end
  end

  defp extract_command(%{} = params) do
    normalize_optional_string(
      Map.get(params, "parsedCmd") ||
        Map.get(params, :parsedCmd) ||
        Map.get(params, "command") ||
        Map.get(params, :command)
    )
  end

  defp extract_command(_params), do: nil

  defp extract_command_argv(command) when is_binary(command) do
    case OptionParser.split(command) do
      [] -> nil
      argv -> argv
    end
  rescue
    _ -> nil
  end

  defp extract_command_argv(_command), do: nil

  defp command_executable([executable | _]) when is_binary(executable) do
    executable
    |> Path.basename()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp command_executable(command) when is_binary(command) do
    case OptionParser.split(command) do
      [executable | _] ->
        executable
        |> Path.basename()
        |> String.trim()
        |> case do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end

  defp command_executable(_command), do: nil

  defp shell_wrapper_name(executable) when is_binary(executable) do
    normalized =
      executable
      |> String.downcase()
      |> String.trim()

    if normalized in @shell_wrapper_commands, do: normalized, else: nil
  end

  defp shell_wrapper_name(_executable), do: nil

  defp shell_wrapper_command([wrapper, option, command | _rest]) when is_binary(wrapper) and is_binary(option) and is_binary(command) do
    wrapper_name = String.downcase(Path.basename(wrapper))
    normalized_option = String.downcase(option)

    case wrapper_name do
      value when value in ["bash", "sh", "zsh", "fish"] and option in ["-c", "-lc"] -> command
      value when value in ["powershell", "powershell.exe", "pwsh", "pwsh.exe"] and normalized_option in ["-command", "-c"] -> command
      value when value in ["cmd", "cmd.exe"] and normalized_option in ["/c", "/k"] -> command
      _ -> nil
    end
  end

  defp shell_wrapper_command([wrapper, script | _rest]) when is_binary(wrapper) and is_binary(script) do
    case String.downcase(Path.basename(wrapper)) do
      wrapper_name when wrapper_name in ["python", "python.exe", "node", "node.exe", "ruby", "ruby.exe"] -> script
      _ -> nil
    end
  end

  defp shell_wrapper_command(_argv), do: nil

  defp extract_file_paths(%{} = params) do
    [
      Map.get(params, "filePaths"),
      Map.get(params, :filePaths),
      Map.get(params, "paths"),
      Map.get(params, :paths),
      Map.get(params, "files"),
      Map.get(params, :files),
      Map.get(params, "changedFiles"),
      Map.get(params, :changedFiles),
      Map.get(params, "fileChanges"),
      Map.get(params, :fileChanges)
    ]
    |> Enum.flat_map(&flatten_file_paths/1)
    |> Enum.map(&normalize_path_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp extract_file_paths(_params), do: []

  defp flatten_file_paths(values) when is_list(values), do: Enum.flat_map(values, &flatten_file_paths/1)

  defp flatten_file_paths(%{} = value) do
    [
      Map.get(value, "path"),
      Map.get(value, :path),
      Map.get(value, "filePath"),
      Map.get(value, :filePath),
      Map.get(value, "file"),
      Map.get(value, :file),
      Map.get(value, "relativePath"),
      Map.get(value, :relativePath)
    ]
    |> Enum.flat_map(&flatten_file_paths/1)
  end

  defp flatten_file_paths(value) when is_binary(value), do: [value]
  defp flatten_file_paths(_value), do: []

  defp normalize_path_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_path_string(_value), do: nil

  defp sensitive_paths(paths) when is_list(paths), do: Enum.filter(paths, &sensitive_path?/1)
  defp sensitive_paths(_paths), do: []

  defp sensitive_path?(path) when is_binary(path) do
    normalized =
      path
      |> String.downcase()
      |> String.replace("\\", "/")

    Enum.any?(@sensitive_path_markers, fn marker -> String.contains?(normalized, marker) end)
  end

  defp sensitive_path?(_path), do: false

  defp outside_workspace_paths(paths, workspace_path) when is_list(paths) do
    Enum.filter(paths, &outside_workspace_path?(&1, workspace_path))
  end

  defp outside_workspace_paths(_paths, _workspace_path), do: []

  defp outside_workspace_path?(path, workspace_path) when is_binary(path) do
    normalized = String.replace(path, "\\", "/")

    cond do
      String.starts_with?(normalized, "../") or normalized == ".." ->
        true

      absolute_path?(normalized) and is_binary(workspace_path) ->
        expanded_path = Path.expand(path)
        expanded_workspace = Path.expand(workspace_path)
        workspace_prefix = expanded_workspace <> "/"
        expanded_path != expanded_workspace and not String.starts_with?(expanded_path <> "/", workspace_prefix)

      absolute_path?(normalized) ->
        true

      true ->
        false
    end
  end

  defp outside_workspace_path?(_path, _workspace_path), do: false

  defp absolute_path?(path) when is_binary(path) do
    Path.type(path) == :absolute or Regex.match?(~r/^[A-Za-z]:[\/\\]/, path)
  end

  defp absolute_path?(_path), do: false

  defp network_access_requested?(command, argv, wrapped_command, params, context) do
    sandbox_network_access =
      get_in(context, [:turn_sandbox_policy, "networkAccess"]) ||
        get_in(context, [:turn_sandbox_policy, :networkAccess])

    cond do
      Map.get(params, "networkAccess") == true or Map.get(params, :networkAccess) == true ->
        true

      sandbox_network_access == true ->
        true

      command_requests_network?(wrapped_command || command) ->
        true

      command_requests_network?(argv) ->
        true

      true ->
        false
    end
  end

  defp command_requests_network?(command) when is_binary(command) do
    cond do
      String.contains?(command, "http://") or String.contains?(command, "https://") ->
        true

      true ->
        case extract_command_argv(command) do
          nil -> false
          argv -> command_requests_network?(argv)
        end
    end
  end

  defp command_requests_network?([executable | rest]) when is_binary(executable) do
    normalized = executable |> Path.basename() |> String.downcase()
    subcommand = List.first(rest) |> normalize_optional_string()

    cond do
      normalized == "git" ->
        subcommand in @network_git_subcommands

      normalized == "mix" ->
        subcommand in @network_mix_subcommands

      normalized == "npm" ->
        subcommand in @network_npm_subcommands

      normalized == "yarn" ->
        subcommand in @network_yarn_subcommands

      normalized in @network_command_executables ->
        true

      true ->
        false
    end
  end

  defp command_requests_network?(_command), do: false

  defp build_review_tags(method, shell_wrapper, network_access, sensitive_paths, outside_workspace_paths) do
    []
    |> maybe_append_tag(command_execution_method?(method), "command_execution")
    |> maybe_append_tag(file_change_method?(method), "file_change")
    |> maybe_append_tag(is_binary(shell_wrapper), "shell_wrapper")
    |> maybe_append_tag(network_access == true, "network_access")
    |> maybe_append_tag(present_list?(sensitive_paths), "sensitive_paths")
    |> maybe_append_tag(present_list?(outside_workspace_paths), "outside_workspace")
  end

  defp command_execution_method?(method) when is_binary(method),
    do: method in ["item/commandExecution/requestApproval", "execCommandApproval"]

  defp command_execution_method?(_method), do: false

  defp file_change_method?(method) when is_binary(method),
    do: method in ["item/fileChange/requestApproval", "applyPatchApproval"]

  defp file_change_method?(_method), do: false

  defp maybe_append_tag(tags, true, value), do: tags ++ [value]
  defp maybe_append_tag(tags, _condition, _value), do: tags

  defp safe_command?(command) when is_binary(command) do
    case OptionParser.split(command) do
      [executable] ->
        Path.basename(executable) in @safe_builtin_read_commands

      [executable, subcommand | _rest] ->
        executable = Path.basename(executable)

        cond do
          executable in @safe_builtin_read_commands ->
            true

          executable == "git" ->
            subcommand in @safe_git_subcommands

          executable == "mix" ->
            subcommand in @safe_mix_subcommands

          executable == "npm" ->
            subcommand in @safe_npm_subcommands

          executable == "yarn" ->
            subcommand in @safe_yarn_subcommands

          true ->
            false
        end

      _ ->
        false
    end
  end

  defp safe_command?(_command), do: false

  defp default_review_reason(%{action_type: "command_execution", details: details}) do
    cond do
      Map.get(details, "network_access") == true ->
        "command appears to require network access"

      is_binary(Map.get(details, "shell_wrapper")) ->
        "shell wrapper hides the true executable"

      true ->
        "command execution requires operator review"
    end
  end

  defp default_review_reason(%{action_type: "file_change", details: details}) do
    cond do
      present_list?(Map.get(details, "outside_workspace_paths")) ->
        "file change targets paths outside the current workspace"

      present_list?(Map.get(details, "sensitive_paths")) ->
        "file change touches sensitive deploy/auth/secret paths"

      true ->
        "file changes require operator review"
    end
  end

  defp default_review_reason(_action), do: "approval request requires operator review"

  defp rule_disposition(%Rule{decision: "deny"}), do: :deny
  defp rule_disposition(%Rule{decision: "review"}), do: :review
  defp rule_disposition(_rule), do: :allow

  defp response_decision_for_rule(%Rule{decision: "allow"}, method), do: approval_decision_for_method(method)
  defp response_decision_for_rule(_rule, _method), do: nil

  defp rule_decision_mode(%Rule{remaining_uses: 1}), do: "allow_once"

  defp rule_decision_mode(%Rule{scope: "run"}) do
    "allow_for_session"
  end

  defp rule_decision_mode(%Rule{scope: scope}) when scope in ["workflow", "repository"] do
    "allow_via_rule"
  end

  defp rule_decision_mode(_rule), do: "policy_rule"

  defp matched_rule_reason(%Rule{id: rule_id, scope: scope, reason: reason}) do
    base = "matched #{scope || "policy"} rule #{rule_id || "n/a"}"

    case normalize_optional_string(reason) do
      nil -> base
      text -> "#{base}: #{text}"
    end
  end

  defp guardrail_rules(context) when is_map(context) do
    context
    |> Map.get(:guardrail_rules, [])
    |> Enum.flat_map(fn
      %Rule{} = rule ->
        [rule]

      %{} = snapshot ->
        case Rule.from_snapshot(snapshot) do
          %Rule{} = rule -> [rule]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp rule_precedence(%Rule{scope: "run", decision: "deny"}), do: 0
  defp rule_precedence(%Rule{scope: "workflow", decision: "deny"}), do: 1
  defp rule_precedence(%Rule{scope: "repository", decision: "deny"}), do: 2
  defp rule_precedence(%Rule{scope: "run"}), do: 3
  defp rule_precedence(%Rule{scope: "workflow"}), do: 4
  defp rule_precedence(%Rule{scope: "repository"}), do: 5
  defp rule_precedence(_rule), do: 6

  defp fingerprint_for_request("command_execution", details, method) do
    command = Map.get(details, "command") || method
    "command_execution:" <> normalize_fingerprint_part(command)
  end

  defp fingerprint_for_request("file_change", details, method) do
    case Map.get(details, "file_paths") do
      paths when is_list(paths) and paths != [] ->
        "file_change:" <> normalize_fingerprint_part(Enum.join(paths, "|"))

      _ ->
        file_change_count = Map.get(details, "file_change_count")
        "file_change:" <> normalize_fingerprint_part("#{method}:#{file_change_count || "unknown"}")
    end
  end

  defp fingerprint_for_request(action_type, _details, method) do
    normalize_fingerprint_part("#{action_type}:#{method}")
  end

  defp normalize_fingerprint_part(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_fingerprint_part(value), do: inspect(value)

  defp present_list?(values) when is_list(values), do: values != []
  defp present_list?(_values), do: false

  defp empty_list_to_nil(values) when is_list(values) and values == [], do: nil
  defp empty_list_to_nil(values), do: values

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(value) when is_atom(value), do: value |> Atom.to_string() |> normalize_optional_string()
  defp normalize_optional_string(value) when is_integer(value), do: Integer.to_string(value)
  defp normalize_optional_string(_value), do: nil

  defp sanitize_explain_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), sanitize_explain_value(nested)} end)
  end

  defp sanitize_explain_value(value) when is_list(value), do: Enum.map(value, &sanitize_explain_value/1)
  defp sanitize_explain_value(value) when is_atom(value), do: Atom.to_string(value)
  defp sanitize_explain_value(value), do: value
end
