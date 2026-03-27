defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker issue data.
  """

  alias SymphonyElixir.{AuditLog, Config, Workflow}
  alias SymphonyElixir.Trello.Adapter, as: TrelloAdapter

  @default_compact_issue_description_chars 1_200
  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    issue
    |> build_prompt_result(opts)
    |> Map.fetch!(:prompt)
  end

  @spec build_prompt_result(SymphonyElixir.Linear.Issue.t(), keyword()) :: %{
          prompt: String.t(),
          metadata: map()
        }
  def build_prompt_result(issue, opts \\ []) do
    template_source =
      Workflow.current()
      |> prompt_template!()
      |> default_prompt()

    settings = Config.settings!()
    template = parse_template!(template_source)
    raw_description = issue_description(issue)

    {prompt_description, description_metadata} =
      prepare_issue_description(raw_description, settings.agent)

    issue_for_prompt =
      issue
      |> Map.from_struct()
      |> Map.put(:description, prompt_description)
      |> to_solid_map()

    rendered_prompt =
      render_template!(
        template,
        %{
          "attempt" => Keyword.get(opts, :attempt),
          "issue" => issue_for_prompt
        },
        template_source
      )

    handoff = maybe_prompt_handoff(issue, opts, settings.agent.handoff_summary_enabled == true)
    tracker_runtime_context = maybe_tracker_runtime_context(issue, settings.tracker.kind)

    prompt =
      rendered_prompt
      |> append_handoff(handoff)
      |> append_tracker_runtime_context(tracker_runtime_context)

    %{
      prompt: prompt,
      metadata: %{
        "tracker_payload_chars" => tracker_payload_chars(issue),
        "workflow_prompt_chars" => byte_size(template_source),
        "rendered_prompt_chars" => byte_size(prompt),
        "base_rendered_prompt_chars" => byte_size(rendered_prompt),
        "issue_description_chars" => byte_size(raw_description || ""),
        "issue_prompt_description_chars" => Map.get(description_metadata, "issue_prompt_description_chars", 0),
        "issue_description_truncated" => Map.get(description_metadata, "issue_description_truncated", false),
        "issue_description_truncated_chars" => Map.get(description_metadata, "issue_description_truncated_chars", 0),
        "included_previous_run_handoff" => handoff != nil,
        "previous_run_id" => handoff && handoff.run_id,
        "previous_run_handoff_chars" => if(handoff, do: byte_size(handoff.text), else: 0),
        "tracker_runtime_context_chars" => if(tracker_runtime_context, do: byte_size(tracker_runtime_context), else: 0)
      }
    }
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: prompt

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp render_template!(template, assigns, template_source) when is_binary(template_source) do
    template
    |> Solid.render!(assigns, @render_opts)
    |> IO.iodata_to_binary()
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_render_error: #{Exception.message(error)} template=#{inspect(template_source)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp issue_description(%{description: description}) when is_binary(description), do: description
  defp issue_description(_issue), do: nil

  defp prepare_issue_description(nil, _agent_settings) do
    {nil,
     %{
       "issue_prompt_description_chars" => 0,
       "issue_description_truncated" => false,
       "issue_description_truncated_chars" => 0
     }}
  end

  defp prepare_issue_description(description, agent_settings) when is_binary(description) do
    limit =
      cond do
        is_integer(agent_settings.max_issue_description_prompt_chars) and
            agent_settings.max_issue_description_prompt_chars > 0 ->
          agent_settings.max_issue_description_prompt_chars

        agent_settings.include_full_issue_description_in_prompt == false ->
          @default_compact_issue_description_chars

        true ->
          nil
      end

    case normalize_prompt_description(description, limit) do
      {prompt_description, truncated_chars} ->
        {prompt_description,
         %{
           "issue_prompt_description_chars" => byte_size(prompt_description),
           "issue_description_truncated" => truncated_chars > 0,
           "issue_description_truncated_chars" => truncated_chars
         }}
    end
  end

  defp normalize_prompt_description(description, nil), do: {description, 0}

  defp normalize_prompt_description(description, limit)
       when is_binary(description) and is_integer(limit) and limit > 0 do
    if byte_size(description) <= limit do
      {description, 0}
    else
      suffix = "\n\n[Description truncated for prompt efficiency. Full tracker body remains available in audit/tools.]"
      suffix_bytes = byte_size(suffix)
      visible_limit = max(limit - suffix_bytes, 0)
      truncated = String.slice(description, 0, visible_limit)
      {truncated <> suffix, max(byte_size(description) - visible_limit, 0)}
    end
  end

  defp maybe_prompt_handoff(%{identifier: issue_identifier}, opts, true) when is_binary(issue_identifier) do
    current_run_id = Keyword.get(opts, :run_id)

    case AuditLog.prompt_handoff(issue_identifier, current_run_id: current_run_id) do
      {:ok, %{text: text} = handoff} when is_binary(text) and text != "" -> handoff
      _ -> nil
    end
  end

  defp maybe_prompt_handoff(_issue, _opts, _enabled), do: nil

  defp append_handoff(prompt, nil), do: prompt

  defp append_handoff(prompt, %{text: handoff_text}) when is_binary(prompt) and is_binary(handoff_text) do
    prompt <> "\n\nPrevious run handoff:\n" <> handoff_text
  end

  defp maybe_tracker_runtime_context(%{id: issue_id}, "trello") when is_binary(issue_id) do
    case TrelloAdapter.fetch_codex_workpad_action_id(issue_id) do
      {:ok, action_id} when is_binary(action_id) and action_id != "" ->
        [
          "Trello runtime hint:",
          "- Existing `## Codex Workpad` comment action id: `#{action_id}`.",
          "- Prefer `PUT /actions/#{action_id}` to update that comment instead of listing card actions again."
        ]
        |> Enum.join("\n")

      _ ->
        nil
    end
  end

  defp maybe_tracker_runtime_context(_issue, _tracker_kind), do: nil

  defp append_tracker_runtime_context(prompt, nil), do: prompt

  defp append_tracker_runtime_context(prompt, tracker_runtime_context)
       when is_binary(prompt) and is_binary(tracker_runtime_context) do
    prompt <> "\n\n" <> tracker_runtime_context
  end

  defp tracker_payload_chars(issue) do
    issue
    |> tracker_payload_fragments()
    |> Enum.reduce(0, fn fragment, total -> total + byte_size(fragment) end)
  end

  defp tracker_payload_fragments(%_{} = issue) do
    issue
    |> Map.from_struct()
    |> tracker_payload_fragments()
  end

  defp tracker_payload_fragments(issue) when is_map(issue) do
    [
      Map.get(issue, :id) || Map.get(issue, "id"),
      Map.get(issue, :identifier) || Map.get(issue, "identifier"),
      Map.get(issue, :title) || Map.get(issue, "title"),
      Map.get(issue, :description) || Map.get(issue, "description"),
      Map.get(issue, :state) || Map.get(issue, "state"),
      Map.get(issue, :branch_name) || Map.get(issue, "branch_name"),
      Map.get(issue, :url) || Map.get(issue, "url"),
      Map.get(issue, :assignee_id) || Map.get(issue, "assignee_id"),
      Map.get(issue, :labels) || Map.get(issue, "labels")
    ]
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
  end

  defp tracker_payload_fragments(_issue), do: []

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
