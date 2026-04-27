defmodule Chronicle.Server.Host.ExternalTasks.ConnectorRegistryTest do
  use ExUnit.Case, async: false

  alias Chronicle.Server.Host.ExternalTasks.ConnectorRegistry
  alias Chronicle.Server.TestSupport.ConnectorRegistryMemoryStore
  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

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

  test "defaults to built-in or AMQP placement" do
    Application.put_env(:server, :connector_registry, [])

    assert %{placement: :builtin_or_amqp} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "rest"})
  end

  test "matches configured connector topics case-insensitively from JSON" do
    Application.put_env(
      :server,
      :connector_registry,
      ~s({"connectors":[{"id":"http-satellite","topics":["rest","AI"],"placement":"satellite"}]})
    )

    assert %{placement: :satellite, connector: %{"id" => "http-satellite"}} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "REST"})

    assert %{placement: :satellite} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "ai"})

    assert %{placement: :builtin_or_amqp} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "database"})
  end

  test "supports wildcard and keyed registry map shapes" do
    Application.put_env(
      :server,
      :connector_registry,
      %{"default-satellite" => %{"topics" => ["*"], "placement" => "satellite"}}
    )

    assert %{placement: :satellite, connector: %{"id" => "default-satellite"}} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "billing"})
  end

  test "matches explicit connector ids without requiring topics" do
    Application.put_env(
      :server,
      :connector_registry,
      [%{"id" => "vendor.crm", "placement" => "satellite"}]
    )

    assert {:ok, %{"id" => "vendor.crm", "topics" => []}} =
             ConnectorRegistry.validate_entry(%{"id" => "vendor.crm", "placement" => "satellite"})

    assert %{placement: :satellite, connector: %{"id" => "vendor.crm"}} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{
               topic: "unknown",
               connector: %{"id" => "vendor.crm"}
             })
  end

  test "BPJS execution and connector fields override registry placement and pass through" do
    Application.put_env(
      :server,
      :connector_registry,
      [
        %{
          "id" => "payments",
          "topics" => ["billing"],
          "placement" => "satellite",
          "execution" => %{"queue" => "satellite.payments"}
        }
      ]
    )

    extension = %ServiceTaskExtension{
      topic: "billing",
      connector: %{"id" => "payments", "version" => "2026-04"},
      execution: %{"placement" => "amqp", "priority" => 7}
    }

    assert %{
             placement: :amqp,
             connector: %{"id" => "payments", "version" => "2026-04"},
             execution: %{"placement" => "amqp", "priority" => 7, "queue" => "satellite.payments"}
           } = ConnectorRegistry.resolve(extension)
  end

  test "durable rows are loaded with env JSON as seed and durable entries override by id" do
    Application.put_env(
      :server,
      :connector_registry,
      [
        %{
          "id" => "seed-rest",
          "topics" => ["rest"],
          "placement" => "satellite",
          "capabilities" => %{"protocol" => "http"}
        },
        %{"id" => "payments", "topics" => ["billing"], "placement" => "amqp"}
      ]
    )

    assert {:ok, _} =
             ConnectorRegistryMemoryStore.upsert("payments", %{
               "id" => "payments",
               "topics" => ["billing"],
               "placement" => "local",
               "placementMetadata" => %{"node" => "primary"},
               "capabilities" => %{"domain" => "payments"}
             })

    assert {:ok, cache} = ConnectorRegistry.reload()

    assert cache.sources == %{seed: 2, durable: 1}
    assert Enum.map(cache.connectors, & &1["id"]) == ["payments", "seed-rest"]

    assert %{
             placement: :local,
             connector: %{
               "id" => "payments",
               "capabilities" => %{"domain" => "payments"},
               "placementMetadata" => %{"node" => "primary"}
             }
           } = ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "billing"})
  end

  test "upsert validates connector shape and reloads the cache" do
    assert {:error, %{errors: errors}} =
             ConnectorRegistry.upsert("bad id!", %{
               "topics" => ["billing"],
               "placement" => "local"
             })

    assert "id may only contain letters, numbers, dot, underscore, colon, and dash" in errors

    assert {:ok, %{"id" => "billing", "placement" => "satellite"}} =
             ConnectorRegistry.upsert("billing", %{
               "topics" => "billing",
               "placement" => "satellite",
               "capabilities" => %{"version" => "2026-04"}
             })

    assert %{placement: :satellite} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "billing"})
  end

  test "delete removes durable entries and falls back to seed entries" do
    Application.put_env(
      :server,
      :connector_registry,
      [%{"id" => "billing", "topics" => ["billing"], "placement" => "amqp"}]
    )

    assert {:ok, _} =
             ConnectorRegistry.upsert("billing", %{
               "topics" => ["billing"],
               "placement" => "local"
             })

    assert %{placement: :local} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "billing"})

    assert {:ok, %{deleted: 1}} = ConnectorRegistry.delete("billing")

    assert %{placement: :amqp} =
             ConnectorRegistry.resolve(%ServiceTaskExtension{topic: "billing"})
  end

  defp restore_store(nil), do: Application.delete_env(:server, :connector_registry_store)
  defp restore_store(store), do: Application.put_env(:server, :connector_registry_store, store)
end
