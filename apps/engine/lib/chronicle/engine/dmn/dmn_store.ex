defmodule Chronicle.Engine.Dmn.DmnStore do
  @moduledoc """
  GenServer + ETS cache for DMN decision tables.

  Writes through to the persisted Deployments table on every register and
  rehydrates on init so DMN lookups survive a service restart.
  """
  use GenServer

  require Logger

  alias Chronicle.Persistence.Queries

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table = :ets.new(:dmn_store, [:named_table, :set, :public, read_concurrency: true])
    rehydrate_from_db()
    {:ok, %{table: table}}
  end

  def register(name, version, tenant, dmn_content) do
    GenServer.call(__MODULE__, {:register, name, version, tenant, dmn_content})
  end

  def get(name, version, tenant) do
    key = {name, version, tenant}
    case :ets.lookup(:dmn_store, key) do
      [{^key, content}] -> {:ok, content}
      [] ->
        # Fallback to default tenant
        default_key = {name, version, nil}
        case :ets.lookup(:dmn_store, default_key) do
          [{^default_key, content}] -> {:ok, content}
          [] -> {:error, :not_found}
        end
    end
  end

  def evaluate(ref, dmn_name, inputs, caller_pid, tenant_id) do
    Task.start(fn ->
      result =
        case get(dmn_name, nil, tenant_id) do
          {:ok, content} ->
            Chronicle.Engine.Dmn.DmnEvaluator.evaluate(content, inputs)

          {:error, :not_found} ->
            {:error, "DMN definition '#{dmn_name}' not found"}
        end

      GenServer.cast(caller_pid, {:rules_result, ref, result})
    end)
  end

  @impl true
  def handle_call({:register, name, version, tenant, content}, _from, state) do
    # Persist first, populate ETS only after durable success. Reversed
    # ordering would leave callers with a memory-only entry that silently
    # vanishes on restart if the DB write failed.
    case persist(name, version, tenant, content) do
      :ok ->
        key = {name, version, tenant}
        :ets.insert(:dmn_store, {key, content})
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error(
          "DmnStore: persist failed for #{name}@#{version || "latest"}: #{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  end

  # ---- Private helpers ----

  defp persist(name, version, tenant, content) when is_binary(content) do
    case Queries.save_deployment(tenant, name, version, "dmn", content) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # Non-binary content path — nothing to persist, still report success so
  # the caller can populate the in-memory cache.
  defp persist(_name, _version, _tenant, _content), do: :ok

  defp rehydrate_from_db do
    deployments = Queries.load_all_deployments()

    dmn_deployments = Enum.filter(deployments, fn d -> d.kind == "dmn" end)

    Enum.each(dmn_deployments, fn d ->
      tenant = unpack_tenant(d.tenant_id)
      version = unpack_version(d.version)
      :ets.insert(:dmn_store, {{d.name, version, tenant}, d.content})
    end)

    if dmn_deployments != [] do
      Logger.info("DmnStore: rehydrated #{length(dmn_deployments)} DMN deployment(s) from DB")
    end
  rescue
    e ->
      Logger.debug("DmnStore: rehydrate skipped: #{inspect(e)}")
      :ok
  end

  defp unpack_tenant(tenant) do
    if tenant == Queries.default_tenant_key(), do: nil, else: tenant
  end

  defp unpack_version(0), do: nil
  defp unpack_version(v), do: v
end
