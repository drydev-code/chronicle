defmodule Chronicle.Server.Web.ConnectorRegistryControllerTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  alias Chronicle.Server.Host.ExternalTasks.ConnectorRegistry
  alias Chronicle.Server.TestSupport.ConnectorRegistryMemoryStore

  @endpoint Chronicle.Server.Web.Endpoint

  setup do
    previous = Application.get_env(:server, :connector_registry)
    previous_store = Application.get_env(:server, :connector_registry_store)

    start_supervised!({ConnectorRegistryMemoryStore, []})
    Application.put_env(:server, :connector_registry_store, ConnectorRegistryMemoryStore)
    ConnectorRegistry.clear_cache()

    on_exit(fn ->
      Application.put_env(:server, :connector_registry, previous || [])
      restore_store(previous_store)
      ConnectorRegistry.clear_cache()
    end)

    :ok
  end

  test "lists connector registry entries and cache metadata" do
    Application.put_env(
      :server,
      :connector_registry,
      [%{"id" => "rest", "topics" => ["rest"], "placement" => "satellite"}]
    )

    response =
      build_conn()
      |> get("/api/management/connectors")
      |> json_response(200)

    assert [%{"id" => "rest"}] = response["connectors"]
    assert response["registry"]["sources"] == %{"durable" => 0, "seed" => 1}
    assert is_binary(response["registry"]["loaded_at"])
  end

  test "upserts, reloads, shows, and deletes durable connector entries" do
    connector = %{
      "topics" => ["billing"],
      "placement" => "local",
      "capabilities" => %{"domain" => "payments"},
      "placementMetadata" => %{"node" => "primary"}
    }

    upsert_response =
      build_conn()
      |> put("/api/management/connectors/payments", connector)
      |> json_response(200)

    assert upsert_response["connector"]["id"] == "payments"

    show_response =
      build_conn()
      |> get("/api/management/connectors/payments")
      |> json_response(200)

    assert show_response["connector"]["capabilities"] == %{"domain" => "payments"}

    reload_response =
      build_conn()
      |> post("/api/management/connectors/reload")
      |> json_response(200)

    assert reload_response["registry"]["sources"] == %{"durable" => 1, "seed" => 0}

    delete_response =
      build_conn()
      |> delete("/api/management/connectors/payments")
      |> json_response(200)

    assert delete_response == %{"deleted" => 1}

    build_conn()
    |> get("/api/management/connectors/payments")
    |> json_response(404)
  end

  test "rejects invalid connector entries through the API" do
    response =
      build_conn()
      |> put("/api/management/connectors/billing", %{
        "topics" => ["billing"],
        "placement" => "not-a-placement"
      })
      |> json_response(422)

    assert Enum.any?(response["errors"], &String.starts_with?(&1, "placement must be one of "))
  end

  defp restore_store(nil), do: Application.delete_env(:server, :connector_registry_store)
  defp restore_store(store), do: Application.put_env(:server, :connector_registry_store, store)
end
