defmodule Chronicle.Server.Host.ExternalTasks.Executors.Database do
  @moduledoc "Built-in SQL/database service task executor plugin."

  @behaviour Chronicle.Server.Host.ExternalTasks.Executors.Executor

  alias Chronicle.Persistence.Repo
  alias Chronicle.Server.Host.ExternalTasks.Executors.Helpers

  @impl true
  def topics, do: ["database", "db", "sql"]

  @impl true
  def execute(event, extension) do
    extensions = extension.extensions || %{}

    with {:ok, query} <- Helpers.required_binary(Map.get(extensions, "query") || extension.body, "query"),
         :ok <- ensure_sql_allowed(query, Helpers.truthy?(Map.get(extensions, "allowWrite"))),
         {:ok, params} <- query_params(extensions, event.payload),
         {:ok, timeout} <- Helpers.timeout(extension),
         {:ok, result} <- run_query(query, params, timeout) do
      {:ok, shape_result(result, extension), %{executor: "built_in_database"}}
    end
  end

  defp run_query(query, params, timeout) do
    repo = Repo.active()

    case Ecto.Adapters.SQL.query(repo, query, params, timeout: timeout) do
      {:ok, %{columns: columns, rows: rows, num_rows: num_rows}} ->
        mapped_rows =
          Enum.map(rows, fn row ->
            columns
            |> Enum.zip(row)
            |> Map.new()
          end)

        {:ok, %{"columns" => columns, "rows" => mapped_rows, "numRows" => num_rows}}

      {:error, error} ->
        {:error, inspect(error)}
    end
  end

  defp query_params(extensions, payload) do
    params = Map.get(extensions, "params") || Map.get(extensions, "parameters") || []

    cond do
      is_list(params) -> {:ok, params}
      is_binary(params) -> Helpers.render_json_params(params, payload || %{})
      true -> {:error, "query params must be a list"}
    end
  end

  defp ensure_sql_allowed(query, true), do: validate_single_statement(query)

  defp ensure_sql_allowed(query, false) do
    read_only? =
      query
      |> String.trim_leading()
      |> String.downcase()
      |> String.starts_with?(["select", "with", "show", "describe", "explain"])

    if read_only? do
      validate_single_statement(query)
    else
      {:error, "database service tasks are read-only unless extensions.allowWrite is true"}
    end
  end

  defp validate_single_statement(query) do
    trimmed = String.trim(query)
    body = String.trim_trailing(trimmed, ";")

    if String.contains?(body, ";") do
      {:error, "database service tasks allow only one SQL statement"}
    else
      :ok
    end
  end

  defp shape_result(%{"rows" => rows} = result, extension) do
    shaped =
      case Helpers.result_mode(extension, "result") do
        "rows" -> rows
        "first" -> List.first(rows)
        "scalar" -> result |> Map.get("rows", []) |> List.first() |> first_value()
        _ -> result
      end

    Helpers.maybe_extract_result(shaped, extension)
  end

  defp first_value(nil), do: nil
  defp first_value(row) when is_map(row), do: row |> Map.values() |> List.first()
  defp first_value(row), do: row
end
