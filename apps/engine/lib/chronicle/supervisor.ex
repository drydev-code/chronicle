defmodule Chronicle.Supervisor do
  @moduledoc """
  Supervisor assembling the Chronicle engine runtime.

  Not started automatically — the library exposes `Chronicle.child_spec/1`
  so consumers mount it explicitly in their own supervision tree.
  """
  use Supervisor
  require Logger

  alias Chronicle.Persistence.EventStore
  alias Chronicle.Engine.PersistentData

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :run_migrations, true), do: run_migrations()

    children = children(opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Flat list of engine children. Exposed for consumers that want to interleave
  engine children with their own rather than supervising under this module.
  """
  def children(opts \\ []) do
    active_repo = Application.get_env(:engine, :active_repo)
    active_databus_repo = Application.get_env(:engine, :active_databus_repo)

    restore? = Keyword.get(opts, :restore_instances, true)

    base = [
      active_repo,
      active_databus_repo,
      {Phoenix.PubSub, name: Chronicle.PubSub},
      {Registry, keys: :unique, name: :instances},
      {Registry, keys: :duplicate, name: :waits},
      {Registry, keys: :unique, name: :load_cells},
      {Registry, keys: :duplicate, name: :evicted_waits},
      Chronicle.Engine.Diagrams.DiagramStore,
      Chronicle.Engine.Dmn.DmnStore,
      Chronicle.Engine.Scripting.ScriptPool,
      {DynamicSupervisor,
       name: Chronicle.Engine.LoadCellSupervisor,
       strategy: :one_for_one,
       max_restarts: 1000,
       max_seconds: 5},
      {DynamicSupervisor,
       name: Chronicle.Engine.InstanceSupervisor,
       strategy: :one_for_one,
       max_restarts: 1000,
       max_seconds: 5},
      Chronicle.Engine.EvictionManager,
      # Crash-durable safety net for evicted-instance timers. Dormant on the
      # default :resident path (it only scans :evicted_waits timer rows, of
      # which there are none there); independent of EvictionManager.enabled.
      Chronicle.Engine.TimerSweeper,
      # Crash-durable safety net for call returns to an evicted parent: the
      # child->parent wake cast is volatile, so a crash between the child
      # persisting its completion and the parent recording its CallCompleted
      # loses the wake. Dormant on the default :resident path (no evicted :call
      # rows exist there); independent of EvictionManager.enabled. See
      # Chronicle.Engine.CallReturnSweeper (CODEX FINDING #5).
      Chronicle.Engine.CallReturnSweeper,
      # Bounds concurrent on-demand restores so an :evicted boot does not
      # stampede InstanceSupervisor when many woken cells restore at once.
      # Unbounded by default (config :engine, restore_max_concurrency: N to
      # bound) — a no-op on the :resident path, so the existing suite is
      # unaffected. See Chronicle.Engine.RestoreLimiter.
      Chronicle.Engine.RestoreLimiter
    ]

    restore_mode = Application.get_env(:engine, :restore_mode, :resident)

    restore_child =
      if restore? do
        [restore_task(restore_mode)]
      else
        []
      end

    Enum.reject(base ++ restore_child, &is_nil/1)
  end

  # Boot-restore routing. Default :resident is the UNCHANGED existing path:
  # `restore_active_instances/0` brings instances back resident, re-registering
  # their waits via the normal `InstanceLoadCell` path. Opt-in :evicted instead
  # starts a lightweight evicted cell per active instance via
  # `EvictedWaitRestorer.restore_all/0`; those cells restore on-demand (bounded
  # by `RestoreLimiter`) when a trigger arrives.
  #
  # NOTE: in :evicted mode `EvictionManager` MUST be enabled (it defaults to
  # enabled: false, eviction_manager.ex) — otherwise instances restored
  # on-demand are never re-evicted and the engine drifts back to fully resident.
  defp restore_task(:evicted) do
    {Task, fn -> Chronicle.Engine.EvictedWaitRestorer.restore_all() end}
  end

  defp restore_task(_resident) do
    {Task,
     fn ->
       # `EvictedWaitRestorer.restore_all/0` is intentionally NOT called on this
       # default path — it would double-register waits against the resident
       # instances started here.
       restore_active_instances()
     end}
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
            Chronicle.Engine.InstanceSupervisor,
            {Chronicle.Engine.Instance, {:restore, instance_id, tenant_id, events}}
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
    repo = Application.get_env(:engine, :active_repo)
    migrations_path = Application.app_dir(:engine, "priv/repo/migrations")

    # Migrations must succeed on startup; re-applying existing migrations is
    # safe because Ecto tracks schema_migrations. Swallowing errors here can
    # mask schema drift that corrupts later event replay.
    {:ok, _, _} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    Logger.info("Database migrations complete")
  end
end
