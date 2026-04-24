defmodule DryDev.WorkflowServer.Host.Deployment.Package do
  @moduledoc "ZIP archive handling for deployment packages."

  def extract(zip_binary) when is_binary(zip_binary) do
    case :zip.unzip(zip_binary, [:memory]) do
      {:ok, entries} ->
        files = Enum.map(entries, fn {name, content} ->
          name_str = to_string(name)
          %{
            name: name_str,
            content: to_string(content),
            type: detect_type(name_str)
          }
        end)
        |> Enum.filter(fn f -> f.type != :unknown end)
        {:ok, files}

      {:error, reason} ->
        {:error, {:zip_extraction_failed, reason}}
    end
  end

  defp detect_type(name) do
    cond do
      String.ends_with?(name, ".bpmn") -> :bpmn
      String.ends_with?(name, ".bpjs") -> :bpmn
      String.ends_with?(name, ".dmn") -> :dmn
      String.ends_with?(name, ".cmmn") -> :cmmn
      true -> :unknown
    end
  end
end
