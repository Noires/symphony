defmodule Mix.Tasks.PrBody.Check do
  use Mix.Task

  @shortdoc "Validate PR body format against the repository PR template"

  @moduledoc """
  Validates a PR description markdown file against the structure and expectations
  implied by the repository pull request template.

  Usage:

      mix pr_body.check --file /path/to/pr_body.md
  """

  @template_paths [
    ".github/pull_request_template.md",
    "../.github/pull_request_template.md"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, strict: [file: :string, help: :boolean], aliases: [h: :help])

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("Invalid option(s): #{inspect(invalid)}")

      true ->
        file_path = required_opt(opts, :file)

        with {:ok, template_path, template} <- read_template(),
             {:ok, body} <- read_file(file_path),
             {:ok, headings} <- extract_template_headings(template, template_path),
             :ok <- lint_and_print(template_path, template, body, headings) do
          Mix.shell().info("PR body format OK")
        else
          {:error, message} -> Mix.raise(message)
        end
    end
  end

  defp read_template do
    case Enum.find_value(@template_paths, &read_template_candidate/1) do
      {:ok, _path, _template} = result ->
        result

      nil ->
        joined_paths = Enum.join(@template_paths, ", ")
        {:error, "Unable to read PR template from any of: #{joined_paths}"}
    end
  end

  defp read_template_candidate(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, path, content}
      {:error, _reason} -> nil
    end
  end

  defp required_opt(opts, key) do
    case opts[key] do
      nil -> Mix.raise("Missing required option --#{key}")
      value -> value
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Unable to read #{path}: #{inspect(reason)}"}
    end
  end

  defp extract_template_headings(template, template_path) do
    headings =
      Regex.scan(~r/^\#{4,6}\s+.+$/m, normalize_newlines(template))
      |> Enum.map(&hd/1)

    if headings == [] do
      {:error, "No markdown headings found in #{template_path}"}
    else
      {:ok, headings}
    end
  end

  defp lint_and_print(template_path, template, body, headings) do
    errors = lint(template, body, headings)

    if errors == [] do
      :ok
    else
      Enum.each(errors, fn err -> Mix.shell().error("ERROR: #{err}") end)

      {:error, "PR body format invalid. Read `#{template_path}` and follow it precisely."}
    end
  end

  defp lint(template, body, headings) do
    normalized_template = normalize_newlines(template)
    normalized_body = normalize_newlines(body)
    template_doc = parse_sections(normalized_template, headings)
    body_doc = parse_sections(normalized_body, headings)

    []
    |> check_required_headings(normalized_body, headings)
    |> check_order(body_doc, headings)
    |> check_no_placeholders(body)
    |> check_heading_delimiters(body_doc)
    |> check_sections_from_template(template_doc, body_doc, headings)
  end

  defp check_required_headings(errors, body, headings) do
    missing = Enum.filter(headings, fn heading -> not heading_present?(body, heading) end)
    errors ++ Enum.map(missing, fn heading -> "Missing required heading: #{heading}" end)
  end

  defp check_order(errors, body_doc, headings) do
    positions =
      headings
      |> Enum.map(&Enum.find_index(body_doc.order, fn heading -> heading == &1 end))
      |> Enum.reject(&is_nil/1)

    if positions == Enum.sort(positions), do: errors, else: errors ++ ["Required headings are out of order."]
  end

  defp check_no_placeholders(errors, body) do
    if String.contains?(body, "<!--") do
      errors ++ ["PR description still contains template placeholder comments (<!-- ... -->)."]
    else
      errors
    end
  end

  defp check_heading_delimiters(errors, body_doc) do
    body_doc.missing_delimiter_after_heading
    |> Enum.sort()
    |> Enum.reduce(errors, fn heading, acc ->
      acc ++ ["Heading must be followed by a blank line: #{heading}"]
    end)
  end

  defp check_sections_from_template(errors, template_doc, body_doc, headings) do
    Enum.reduce(headings, errors, fn heading, acc ->
      template_section = Map.get(template_doc.sections, heading, "")
      body_section = Map.get(body_doc.sections, heading)

      cond do
        is_nil(body_section) ->
          acc

        String.trim(body_section) == "" ->
          acc ++ ["Section cannot be empty: #{heading}"]

        true ->
          acc
          |> maybe_require_bullets(heading, template_section, body_section)
          |> maybe_require_checkboxes(heading, template_section, body_section)
      end
    end)
  end

  defp maybe_require_bullets(errors, heading, template_section, body_section) do
    requires_bullets = Regex.match?(~r/^- /m, template_section || "")

    if requires_bullets and not Regex.match?(~r/^- /m, body_section) do
      errors ++ ["Section must include at least one bullet item: #{heading}"]
    else
      errors
    end
  end

  defp maybe_require_checkboxes(errors, heading, template_section, body_section) do
    requires_checkboxes = Regex.match?(~r/^- \[ \] /m, template_section || "")

    if requires_checkboxes and not Regex.match?(~r/^- \[[ xX]\] /m, body_section) do
      errors ++ ["Section must include at least one checkbox item: #{heading}"]
    else
      errors
    end
  end

  defp parse_sections(doc, headings) do
    required_headings = MapSet.new(headings)

    doc
    |> String.split("\n", trim: false)
    |> Enum.reduce(initial_parse_state(), fn line, state ->
      parse_line(line, state, required_headings)
    end)
    |> finalize_parse_state()
  end

  defp initial_parse_state do
    %{
      current_heading: nil,
      current_lines: [],
      order: [],
      sections: %{},
      awaiting_blank_line: false,
      missing_delimiter_after_heading: MapSet.new()
    }
  end

  defp parse_line(line, state, required_headings) do
    cond do
      MapSet.member?(required_headings, line) ->
        state
        |> close_current_section()
        |> start_section(line)

      is_nil(state.current_heading) ->
        state

      state.awaiting_blank_line and line == "" ->
        %{state | awaiting_blank_line: false}

      state.awaiting_blank_line ->
        %{
          state
          | awaiting_blank_line: false,
            current_lines: [line],
            missing_delimiter_after_heading: MapSet.put(state.missing_delimiter_after_heading, state.current_heading)
        }

      true ->
        %{state | current_lines: state.current_lines ++ [line]}
    end
  end

  defp start_section(state, heading) do
    %{
      state
      | current_heading: heading,
        current_lines: [],
        order: state.order ++ [heading],
        awaiting_blank_line: true
    }
  end

  defp close_current_section(%{current_heading: nil} = state), do: state

  defp close_current_section(state) do
    %{
      state
      | sections: Map.put(state.sections, state.current_heading, Enum.join(state.current_lines, "\n")),
        current_heading: nil,
        current_lines: [],
        awaiting_blank_line: false
    }
  end

  defp finalize_parse_state(state) do
    state
    |> close_current_section()
    |> Map.take([:order, :sections, :missing_delimiter_after_heading])
  end

  defp normalize_newlines(doc) do
    doc
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp heading_present?(body, heading) do
    Regex.match?(~r/(?:\A|\n)#{Regex.escape(heading)}(?:\n|\z)/, body)
  end
end
