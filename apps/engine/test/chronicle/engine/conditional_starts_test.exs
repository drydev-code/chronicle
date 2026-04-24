defmodule Chronicle.Engine.ConditionalStartsTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.ConditionalStarts
  alias Chronicle.Engine.Diagrams.{DiagramStore, Parser}
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.ActiveInstance

  @bpjs %{
    "name" => "conditional-start-test",
    "version" => 1,
    "nodes" => [
      %{"id" => 10, "type" => "conditionalStartEvent", "condition" => "ready === true"},
      %{"id" => 20, "type" => "externalTask", "kind" => "service"},
      %{"id" => 30, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 10, "to" => 20},
      %{"from" => 20, "to" => 30}
    ]
  }

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)

      on_exit(fn ->
        try do
          Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
        rescue
          _ -> :ok
        end
      end)
    end

    ensure_started(DiagramStore)
    ensure_started(Chronicle.Engine.Scripting.ScriptPool)
    ensure_started({DynamicSupervisor, name: Chronicle.Engine.InstanceSupervisor, strategy: :one_for_one})

    {:ok, definition} = Parser.parse(Jason.encode!(@bpjs))
    :ok = DiagramStore.register(definition.name, definition.version, "tenant-a", definition)

    {:ok, repo: repo}
  end

  @tag :integration
  test "false conditional start does not create an instance", %{repo: repo} do
    assert [] =
             ConditionalStarts.evaluate("tenant-a", %{"ready" => false},
               business_key: "bk-false",
               process_name: "conditional-start-test"
             )

    if repo do
      assert Repo.all(ActiveInstance) == []
    end
  end

  @tag :integration
  test "true conditional start persists selected start node", %{repo: repo} do
    assert [{:ok, result}] =
             ConditionalStarts.evaluate("tenant-a", %{"ready" => true},
               business_key: "bk-true",
               process_name: "conditional-start-test"
             )

    assert result.start_node_id == 10

    if repo do
      row = Repo.get(ActiveInstance, result.process_instance_id)
      assert row
      [start_event | _] = Jason.decode!(row.data)
      assert start_event["type"] == "ProcessInstanceStart"
      assert start_event["start_node_id"] == 10
      assert start_event["business_key"] == "bk-true"
    end

    case Chronicle.Engine.Instance.lookup("tenant-a", result.process_instance_id) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      _ -> :ok
    end
  end

  defp ensure_started({module, opts}) do
    case module.start_link(opts) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp ensure_started(module) do
    case module.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
