defmodule Chronicle.Server.Web.Controllers.ConnectorRegistryController do
  use Phoenix.Controller, formats: [:json]

  alias Chronicle.Server.Host.ExternalTasks.ConnectorRegistry

  def index(conn, _params) do
    json(conn, %{
      connectors: ConnectorRegistry.registry(),
      registry: serialize_info(ConnectorRegistry.info())
    })
  end

  def show(conn, %{"id" => id}) do
    case ConnectorRegistry.get(id) do
      nil -> conn |> put_status(404) |> json(%{error: "Connector not found"})
      connector -> json(conn, %{connector: connector})
    end
  end

  def reload(conn, _params) do
    {:ok, cache} = ConnectorRegistry.reload()

    json(conn, %{
      connectors: cache.connectors,
      registry: serialize_info(Map.delete(cache, :connectors))
    })
  end

  def upsert(conn, %{"id" => id} = params) do
    case ConnectorRegistry.upsert(id, Map.delete(params, "id")) do
      {:ok, connector} ->
        json(conn, %{connector: connector})

      {:error, %{errors: errors}} ->
        conn |> put_status(422) |> json(%{errors: errors})

      {:error, reason} ->
        conn |> put_status(503) |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case ConnectorRegistry.delete(id) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> conn |> put_status(503) |> json(%{error: inspect(reason)})
    end
  end

  defp serialize_info(info) do
    Map.update(info, :loaded_at, nil, fn
      %DateTime{} = loaded_at -> DateTime.to_iso8601(loaded_at)
      other -> other
    end)
  end
end
