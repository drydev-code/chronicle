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

    results = Enum.map(files, fn file ->
      case file.type do
        :bpmn -> register_bpmn(file, tenant_id, file_map)
        :dmn -> register_dmn(file, tenant_id)
        :bpmn_xml_unsupported -> {:error, {:xml_bpmn_not_supported, file.name}}
        _ -> {:ok, :skipped}
      end
    end)

    errors = Enum.filter(results, &match?({:error, _}, &1))
    if length(errors) > 0, do: {:error, errors}, else: {:ok, results}
  end

  defp register_bpmn(file, tenant_id, file_map) do
    # Update references
    content = ReferenceUpdater.update_references(file.content, file_map)

    # Parse
    case Parser.parse(content) do
      {:ok, definitions} when is_list(definitions) ->
        # Multi-process diagram (e.g., with subprocesses)
        register_definitions(definitions, tenant_id)

      {:ok, definition} ->
        register_single_definition(definition, tenant_id)

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  end

  defp register_definitions(definitions, tenant_id) do
    results = Enum.map(definitions, fn def -> register_single_definition(def, tenant_id) end)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    if length(errors) > 0 do
      {:error, errors}
    else
      names = Enum.map(results, fn {:ok, name} -> name end)
      {:ok, List.first(names)}
    end
  end

  defp register_single_definition(definition, tenant_id) do
    findings = Sanitizer.check(definition)
    errors = Enum.filter(findings, &(&1.severity == :error))

    if length(errors) > 0 do
      {:error, {:validation_failed, errors}}
    else
      DiagramStore.register(definition.name, definition.version, tenant_id, definition)
      {:ok, definition.name}
    end
  end

  defp register_dmn(file, tenant_id) do
    dmn_name = Path.rootname(file.name)
    Chronicle.Engine.Dmn.DmnStore.register(dmn_name, nil, tenant_id, file.content)
    {:ok, dmn_name}
  end
end
