defmodule Chronicle.Engine.Diagrams.DiagramStorePersistenceTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.Diagrams.DiagramStore
  alias Chronicle.Engine.Dmn.DmnStore
  alias Chronicle.Persistence.Queries
  alias Chronicle.Persistence.Schemas.Deployment
  alias Chronicle.Persistence.Repo

  @sample_bpjs Jason.encode!(%{
                 "name" => "persistent-proc",
                 "version" => 7,
                 "nodes" => [
                   %{"id" => 1, "type" => "blankStartEvent"},
                   %{"id" => 2, "type" => "blankEndEvent"}
                 ],
                 "connections" => [%{"from" => 1, "to" => 2}]
               })

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      # Use :shared sandbox mode so the DiagramStore GenServer (another pid)
      # sees the same sandboxed connection.
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(Deployment)

      on_exit(fn ->
        # Best-effort: restore manual mode for other tests.
        try do
          Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
        rescue
          _ -> :ok
        end
      end)

      {:ok, repo: repo}
    else
      {:ok, repo: nil}
    end
  end

  describe "DiagramStore write-through" do
    @tag :integration
    test "register/5 with raw content persists a bpmn row" do
      start_store(DiagramStore)

      {:ok, definition} = Chronicle.Engine.Diagrams.Parser.parse(@sample_bpjs)
      :ok = DiagramStore.register(definition.name, definition.version, "tenant-x", definition, @sample_bpjs)

      loaded = Queries.load_deployment("tenant-x", "persistent-proc", 7, "bpmn")
      assert loaded, "expected a persisted Deployment row"
      assert loaded.kind == "bpmn"
      assert loaded.content == @sample_bpjs
    end

    @tag :integration
    test "restart rehydrates the in-memory store from DB" do
      # Stage a row via the write-through path, then stop & restart the store.
      start_store(DiagramStore)
      {:ok, definition} = Chronicle.Engine.Diagrams.Parser.parse(@sample_bpjs)
      :ok = DiagramStore.register(definition.name, definition.version, "tenant-x", definition, @sample_bpjs)

      stop_store(DiagramStore)
      start_store(DiagramStore)

      assert {:ok, restored} = DiagramStore.get("persistent-proc", 7, "tenant-x")
      assert restored.name == "persistent-proc"
      assert restored.version == 7
    end
  end

  describe "DmnStore write-through" do
    @tag :integration
    test "register/4 persists a dmn row and rehydrates after restart" do
      start_store(DmnStore)
      dmn_xml = "<dmn><rule>1</rule></dmn>"

      :ok = DmnStore.register("rules-table", nil, "tenant-y", dmn_xml)

      loaded = Queries.load_deployment("tenant-y", "rules-table", nil, "dmn")
      assert loaded.content == dmn_xml

      stop_store(DmnStore)
      start_store(DmnStore)

      assert {:ok, ^dmn_xml} = DmnStore.get("rules-table", nil, "tenant-y")
    end
  end

  describe "backwards compatibility" do
    @tag :integration
    test "register/4 without raw content still populates ETS but does not persist" do
      start_store(DiagramStore)
      {:ok, definition} = Chronicle.Engine.Diagrams.Parser.parse(@sample_bpjs)

      :ok = DiagramStore.register(definition.name, definition.version, "legacy", definition)

      assert {:ok, _} = DiagramStore.get("persistent-proc", 7, "legacy")
      refute Queries.load_deployment("legacy", "persistent-proc", 7, "bpmn")
    end
  end

  # ---- helpers ----

  defp start_store(mod) do
    case mod.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp stop_store(mod) do
    case Process.whereis(mod) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        GenServer.stop(pid, :normal, 1000)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2000 -> :ok
        end
    end
  end
end
