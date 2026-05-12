defmodule Chronicle.Server.Host.Deployment.Manager do
  @moduledoc "Deployment management: upload, extract, register, validate."

  alias Chronicle.Engine.Diagrams.{DiagramStore, Parser, Sanitizer, ReferenceUpdater}

  def provision(content, filename, tenant_id) do
    with {:ok, files} <- extract_files(content, filename),
         {:ok, results} <- register_files(files, tenant_id) do
      {:ok, results}
    end
  end

  def redeploy_all(deployments, tenant_id) do
    Enum.map(deployments, fn deployment ->
      provision(deployment.content, deployment.filename, tenant_id)
    end)
  end

  defp extract_files(content, filename) do
    cond do
      String.ends_with?(filename, ".zip") ->
        Chronicle.Server.Host.Deployment.Package.extract(content)

      String.ends_with?(filename, ".bpmn") ->
        {:error, {:xml_bpmn_not_supported, filename}}

      String.ends_with?(filename, ".bpjs") ->
        {:ok, [%{name: filename, content: content, type: :bpmn}]}

      String.ends_with?(filename, ".dmn") ->
        {:ok, [%{name: filename, content: content, type: :dmn}]}

      true ->
        {:error, :unsupported_file_type}
    end
  end

  defp register_files(files, tenant_id) do
    # Build file map for reference resolution
    file_map = Map.new(files, fn f -> {f.name, UUID.uuid4()} end)

    with {:ok, prepared} <- prepare_files(files, file_map) do
      results = Enum.map(prepared, &register_prepared_file(&1, tenant_id))
      errors = Enum.filter(results, &match?({:error, _}, &1))
      if length(errors) > 0, do: {:error, errors}, else: {:ok, results}
    end
  end

  defp prepare_files(files, file_map) do
    result =
      Enum.reduce_while(files, {:ok, []}, fn file, {:ok, prepared} ->
        case prepare_file(file, file_map) do
          {:ok, entry} -> {:cont, {:ok, [entry | prepared]}}
          {:error, reason} -> {:halt, {:error, [reason]}}
        end
      end)

    case result do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, reasons} -> {:error, reasons}
    end
  end

  defp prepare_file(%{type: :bpmn} = file, file_map) do
    # Update references
    content = ReferenceUpdater.update_references(file.content, file_map)

    # Parse
    case Parser.parse(content) do
      {:ok, definitions} when is_list(definitions) ->
        validate_definitions(definitions, content)

      {:ok, definition} ->
        validate_definitions([definition], content)

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp prepare_file(%{type: :dmn} = file, _file_map), do: {:ok, {:dmn, file}}

  defp prepare_file(%{type: :bpmn_xml_unsupported} = file, _file_map),
    do: {:error, {:xml_bpmn_not_supported, file.name}}

  defp prepare_file(_file, _file_map), do: {:ok, :skipped}

  defp validate_definitions(definitions, raw_content) do
    errors =
      definitions
      |> Enum.flat_map(fn definition ->
        definition
        |> Sanitizer.check()
        |> Enum.filter(&(&1.severity == :error))
        |> Enum.map(fn finding -> {:validation_failed, definition.name, finding} end)
      end)

    if errors == [] do
      {:ok, {:bpmn, definitions, raw_content}}
    else
      {:error, {:validation_failed, errors}}
    end
  end

  defp register_prepared_file({:bpmn, definitions, raw_content}, tenant_id) do
    results =
      Enum.map(definitions, fn definition ->
        register_single_definition(definition, tenant_id, raw_content)
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      names = Enum.map(results, fn {:ok, name} -> name end)
      {:ok, List.first(names)}
    else
      {:error, errors}
    end
  end

  defp register_prepared_file({:dmn, file}, tenant_id), do: register_dmn(file, tenant_id)
  defp register_prepared_file(:skipped, _tenant_id), do: {:ok, :skipped}

  defp register_single_definition(definition, tenant_id, raw_content) do
    case DiagramStore.register(
           definition.name,
           definition.version,
           tenant_id,
           definition,
           raw_content
         ) do
      :ok -> {:ok, definition.name}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end

  defp register_dmn(file, tenant_id) do
    dmn_name = Path.rootname(file.name)

    case Chronicle.Engine.Dmn.DmnStore.register(dmn_name, nil, tenant_id, file.content) do
      :ok -> {:ok, dmn_name}
      {:error, reason} -> {:error, {:persist_failed, reason}}
    end
  end
end
