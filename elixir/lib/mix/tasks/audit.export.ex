defmodule Mix.Tasks.Audit.Export do
  @moduledoc """
  Exports persisted audit artifacts for one issue into a zip bundle.
  """

  use Mix.Task

  alias SymphonyElixir.AuditLog

  @shortdoc "Export one issue's audit artifacts as a zip bundle"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [output: :string]
      )

    case {invalid, positional} do
      {[], [issue_identifier]} ->
        export_issue(issue_identifier, opts)

      _ ->
        Mix.raise("usage: mix audit.export ISSUE_IDENTIFIER [--output path.zip]")
    end
  end

  defp export_issue(issue_identifier, opts) do
    export_opts =
      case Keyword.get(opts, :output) do
        nil -> []
        path -> [output_path: path, filename: Path.basename(path), output_dir: Path.dirname(path)]
      end

    case AuditLog.export_issue_bundle(issue_identifier, export_opts) do
      {:ok, %{path: path, run_count: run_count}} ->
        Mix.shell().info("Exported #{run_count} run(s) to #{path}")

      {:error, :issue_not_found} ->
        Mix.raise("no persisted audit runs found for #{issue_identifier}")

      {:error, reason} ->
        Mix.raise("failed to export audit bundle for #{issue_identifier}: #{inspect(reason)}")
    end
  end
end
