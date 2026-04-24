defmodule DryDev.Workflow.Application do
  @moduledoc """
  DryDev.Workflow OTP Application.
  Engine-only supervisor: persistence, registries, script pool, instance
  supervisor, eviction manager. Transport/host/web concerns belong to
  :drydev_workflow_server.
  """
  use Application
  require Logger

  alias DryDev.Workflow.Persistence.EventStore
  alias DryDev.Workflow.Engine.PersistentData

  @impl true
  def start(_type, _args) do
    run_migrations()

    active_repo = Application.get_env(:drydev_workflow, :active_repo)
    active_databus_repo = Application.get_env(:drydev_workflow, :active_databus_repo)

    children =
      Enum.reject(
        [
          active_repo,
          active_databus_repo,
          {Phoenix.PubSub, name: DryDev.Workflow.PubSub},
          {Registry, keys: :unique, name: :instances},
          {Registry, keys: :duplicate, name: :waits},
          {Registry, keys: :unique, name: :load_cells},
          {Registry, keys: :duplicate, name: :evicted_waits},
          DryDev.Workflow.Engine.Diagrams.DiagramStore,
          DryDev.Workflow.Engine.Dmn.DmnStore,
          DryDev.Workflow.Engine.Scripting.ScriptPool,
          {DynamicSupervisor,
           name: DryDev.Workflow.Engine.InstanceSupervisor,
           strategy: :one_for_one,
           max_restarts: 1000,
           max_seconds: 5},
          DryDev.Workflow.Engine.EvictionManager,
          {Task, fn -> restore_active_instances() end}
        ],
        &is_nil/1
      )

    opts = [strategy: :one_for_one, name: DryDev.Workflow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp restore_active_instances do
    active_ids = EventStore.list_active_ids()

    if active_ids == [] do
      Logger.info("Startup restoration: no active instances to restore")
    else
      Logger.info("Startup restoration: restoring #{length(active_ids)} active instance(s)")

      results =
        Enum.map(active_ids, fn instance_id ->
          try do
            restore_instance(instance_id)
          rescue
            e ->
              Logger.error(
                "Startup restoration: failed to restore instance #{instance_id}: #{inspect(e)}"
              )

              {:error, instance_id}
          end
        end)

      restored = Enum.count(results, &match?({:ok, _}, &1))
      failed = Enum.count(results, &match?({:error, _}, &1))
      Logger.info("Startup restoration complete: #{restored} restored, #{failed} failed")
    end
  end

  defp restore_instance(instance_id) do
    case EventStore.stream(instance_id) do
      {:ok, events} ->
        tenant_id = extract_tenant_id(events)

        {:ok, _pid} =
          DynamicSupervisor.start_child(
            DryDev.Workflow.Engine.InstanceSupervisor,
            {DryDev.Workflow.Engine.Instance, {:restore, instance_id, tenant_id, events}}
          )

        {:ok, instance_id}

      {:error, :not_found} ->
        Logger.error("Startup restoration: instance #{instance_id} not found in event store")
        {:error, instance_id}
    end
  end

  defp extract_tenant_id(events) do
    case Enum.find(events, &match?(%PersistentData.ProcessInstanceStart{}, &1)) do
      %PersistentData.ProcessInstanceStart{tenant: tenant} when not is_nil(tenant) ->
        tenant

      _ ->
        "00000000-0000-0000-0000-000000000000"
    end
  end

  defp run_migrations do
    Logger.info("Running database migrations...")
    repo = Application.get_env(:drydev_workflow, :active_repo)
    migrations_path = Application.app_dir(:drydev_workflow, "priv/repo/migrations")

    try do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, migrations_path, :up, all: true)
        end)

      Logger.info("Database migrations complete")
    rescue
      e ->
        Logger.warning("Migration failed (may already be applied): #{inspect(e)}")
    end
  end
end
