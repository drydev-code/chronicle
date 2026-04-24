defmodule Chronicle.Server.Host.LargeVariables do
  @moduledoc "Upload/download >1500 byte values to/from DataBus database."

  @behaviour Chronicle.Engine.LargeVariablesCleaner

  alias Chronicle.Server.Host.Deployment.DataBusClient

  @threshold 1500
  @databus_pattern ~r/<\|DataBus\|([^|]*)\|>/

  @doc "Check if DataBus is configured."
  def enabled?, do: DataBusClient.available?()

  def upload(data, tenant_id) when is_map(data) do
    walk_and_upload(data, tenant_id)
  end

  def download(data, tenant_id) when is_map(data) do
    walk_and_download(data, tenant_id)
  end

  def cleanup(data, tenant_id) do
    guids = extract_databus_guids(data)

    if length(guids) > 0 do
      DataBusClient.archive(guids, tenant_id)
    end

    :ok
  end

  defp walk_and_upload(map, tenant) when is_map(map) do
    Map.new(map, fn {k, v} ->
      {k, walk_and_upload(v, tenant)}
    end)
  end

  defp walk_and_upload(list, tenant) when is_list(list) do
    Enum.map(list, &walk_and_upload(&1, tenant))
  end

  defp walk_and_upload(str, tenant) when is_binary(str) and byte_size(str) > @threshold do
    case DataBusClient.put_string(str, tenant) do
      {:ok, guid} -> "<|DataBus|#{guid}|>"
      _ -> str
    end
  end

  defp walk_and_upload(value, _tenant), do: value

  defp walk_and_download(map, tenant) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, walk_and_download(v, tenant)} end)
  end

  defp walk_and_download(list, tenant) when is_list(list) do
    Enum.map(list, &walk_and_download(&1, tenant))
  end

  defp walk_and_download(str, tenant) when is_binary(str) do
    case Regex.run(@databus_pattern, str) do
      [_full, guid] ->
        case DataBusClient.get_string(guid, tenant) do
          {:ok, value} -> value
          _ -> str
        end

      _ ->
        str
    end
  end

  defp walk_and_download(value, _tenant), do: value

  defp extract_databus_guids(data) do
    data
    |> Jason.encode!()
    |> then(&Regex.scan(@databus_pattern, &1))
    |> Enum.map(fn [_, guid] -> guid end)
    |> Enum.uniq()
  end
end
