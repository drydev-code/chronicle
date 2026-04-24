defmodule Chronicle.Persistence.DeploymentQueriesTest do
  use ExUnit.Case, async: false

  alias Chronicle.Persistence.Queries
  alias Chronicle.Persistence.Schemas.Deployment
  alias Chronicle.Persistence.Repo

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(Deployment)

      on_exit(fn ->
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

  describe "save_deployment/5 and load_deployment/4" do
    @tag :integration
    test "roundtrips a bpmn deployment" do
      assert {:ok, _} =
               Queries.save_deployment("tenant-a", "proc", 1, "bpmn", "{\"payload\":true}")

      loaded = Queries.load_deployment("tenant-a", "proc", 1, "bpmn")
      assert loaded.name == "proc"
      assert loaded.tenant_id == "tenant-a"
      assert loaded.version == 1
      assert loaded.kind == "bpmn"
      assert loaded.content == "{\"payload\":true}"
      assert %DateTime{} = loaded.deployed_at
    end

    @tag :integration
    test "roundtrips a dmn deployment" do
      assert {:ok, _} = Queries.save_deployment("tenant-b", "rules", 2, "dmn", "<dmn/>")
      loaded = Queries.load_deployment("tenant-b", "rules", 2, "dmn")
      assert loaded.kind == "dmn"
      assert loaded.content == "<dmn/>"
    end

    @tag :integration
    test "nil tenant is normalized to a default sentinel so the unique key fires" do
      assert {:ok, _} = Queries.save_deployment(nil, "proc", 1, "bpmn", "v1")
      assert {:ok, _} = Queries.save_deployment(nil, "proc", 1, "bpmn", "v2")

      loaded = Queries.load_deployment(nil, "proc", 1, "bpmn")
      assert loaded.content == "v2"
      assert loaded.tenant_id == Queries.default_tenant_key()
    end
  end

  describe "on_conflict upsert" do
    @tag :integration
    test "saving the same tenant/name/version/kind twice replaces content — one row" do
      assert {:ok, _} = Queries.save_deployment("t", "p", 1, "bpmn", "first")
      assert {:ok, _} = Queries.save_deployment("t", "p", 1, "bpmn", "second")

      loaded = Queries.load_deployment("t", "p", 1, "bpmn")
      assert loaded.content == "second"

      all = Queries.load_all_deployments()
      matching = Enum.filter(all, fn d -> d.name == "p" and d.tenant_id == "t" end)
      assert length(matching) == 1
    end

    @tag :integration
    test "different kind with same name/version/tenant creates a separate row" do
      assert {:ok, _} = Queries.save_deployment("t2", "shared", 1, "bpmn", "bpmn-body")
      assert {:ok, _} = Queries.save_deployment("t2", "shared", 1, "dmn", "dmn-body")

      all = Queries.load_all_deployments()
      same = Enum.filter(all, fn d -> d.name == "shared" and d.tenant_id == "t2" end)
      assert length(same) == 2
      kinds = same |> Enum.map(& &1.kind) |> Enum.sort()
      assert kinds == ["bpmn", "dmn"]
    end
  end

  describe "load_all_deployments/0" do
    @tag :integration
    test "returns deployments of all kinds, ordered by deployed_at" do
      {:ok, _} = Queries.save_deployment("t", "a", 1, "bpmn", "b1")
      Process.sleep(2)
      {:ok, _} = Queries.save_deployment("t", "b", 1, "dmn", "d1")
      Process.sleep(2)
      {:ok, _} = Queries.save_deployment("t", "c", 1, "bpmn", "b2")

      all = Queries.load_all_deployments()
      names = Enum.map(all, & &1.name)
      assert names == ["a", "b", "c"]

      kinds = all |> Enum.map(& &1.kind) |> Enum.sort() |> Enum.uniq()
      assert kinds == ["bpmn", "dmn"]
    end
  end

  describe "validation" do
    test "only bpmn and dmn kinds are accepted" do
      assert_raise FunctionClauseError, fn ->
        Queries.save_deployment("t", "p", 1, "xml", "x")
      end
    end
  end

  describe "concurrent saves" do
    @tag :integration
    test "two concurrent saves of the same key do not race — exactly one row remains" do
      # Without `on_conflict`, the previous get_by/insert-or-update sequence
      # could race so both callers attempted the insert path and one raised
      # a unique-constraint violation. The upsert path must survive this.
      tasks =
        for n <- 1..10 do
          Task.async(fn ->
            Queries.save_deployment("race-tenant", "same-proc", 1, "bpmn", "body-#{n}")
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5_000))

      # Every save should have succeeded (no exceptions, no {:error, ...}).
      refute Enum.any?(results, &match?({:error, _}, &1)),
             "expected every concurrent save to succeed, got: #{inspect(results)}"

      all = Queries.load_all_deployments()
      matching = Enum.filter(all, fn d -> d.name == "same-proc" end)

      assert length(matching) == 1,
             "expected exactly one row after concurrent upserts, saw #{length(matching)}"
    end
  end
end
