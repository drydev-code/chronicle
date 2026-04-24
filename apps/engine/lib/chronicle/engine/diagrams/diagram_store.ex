defmodule Chronicle.Engine.Diagrams.DiagramStore do
  @moduledoc """
  GenServer + ETS for diagram storage with tenant/version resolution.
  Supports lazy loading and start event registration.

  On init, rehydrates ETS from the persisted Deployments table so active
  instance restoration can find definitions after a service restart.
  Every `register/4,5` call writes through to the table so subsequent restarts
  see the latest deployment. Pass `raw_content` (the original .bpjs JSON)
  to `register/5` to enable cold-restart rehydration; when absent, ETS is
  populated for the current process lifetime only.
  """
  use GenServer

  require Logger

  alias Chronicle.Engine.Diagrams.{Definition, Parser}
  alias Chronicle.Persistence.Queries

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table = :ets.new(:diagram_store, [:named_table, :set, :public, read_concurrency: true])
    msg_table = :ets.new(:diagram_message_starts, [:named_table, :bag, :public, read_concurrency: true])
    sig_table = :ets.new(:diagram_signal_starts, [:named_table, :bag, :public, read_concurrency: true])
    cond_table = :ets.new(:diagram_conditional_starts, [:named_table, :bag, :public, read_concurrency: true])

    rehydrate_from_db()

    {:ok, %{table: table, msg_table: msg_table, sig_table: sig_table, cond_table: cond_table}}
  end

  def register(name, version, tenant, definition, raw_content \\ nil) do
    GenServer.call(__MODULE__, {:register, name, version, tenant, definition, raw_content})
  end

  def get(name, version, tenant) do
    key = {name, version, tenant}
    case :ets.lookup(:diagram_store, key) do
      [{^key, %{state: :loaded, definition: def}}] -> {:ok, def}
      [{^key, %{state: :not_loaded}}] -> {:loading, key}
      [] ->
        # Fallback to default tenant
        default_key = {name, version, nil}
        case :ets.lookup(:diagram_store, default_key) do
          [{^default_key, %{state: :loaded, definition: def}}] -> {:ok, def}
          [] -> {:error, :not_found}
        end
    end
  end

  def get_latest(name, tenant) do
    # Find highest version for name+tenant
    pattern = {{name, :_, tenant}, :_}
    matches = :ets.match_object(:diagram_store, pattern)
    case Enum.sort_by(matches, fn {{_, v, _}, _} -> v end, :desc) do
      [{_key, %{state: :loaded, definition: def}} | _] -> {:ok, def}
      _ -> get(name, nil, tenant)
    end
  end

  def get_process_names_for_message(message, tenant) do
    :ets.lookup(:diagram_message_starts, {message, tenant})
    |> Enum.map(fn {_, process_name} -> process_name end)
  end

  def get_process_names_for_signal(signal, tenant) do
    :ets.lookup(:diagram_signal_starts, {signal, tenant})
    |> Enum.map(fn {_, process_name} -> process_name end)
  end

  def get_definitions_with_conditional_starts(tenant) do
    :ets.lookup(:diagram_conditional_starts, tenant)
    |> Enum.flat_map(fn {_, {name, version}} ->
      case get(name, version, tenant) do
        {:ok, definition} -> [definition]
        _ -> []
      end
    end)
    |> Enum.uniq_by(&{&1.name, &1.version, &1.tenant})
  end

  @impl true
  def handle_call({:register, name, version, tenant, definition, raw_content}, _from, state) do
    # Persist first, populate ETS only after durable success. Reversed
    # ordering would leave callers with a memory-only entry that silently
    # vanishes on restart if the DB write failed.
    case persist(name, version, tenant, raw_content) do
      :ok ->
        insert_into_ets(name, version, tenant, definition)
        Logger.info("DiagramStore: registered #{name}@#{version || "latest"} for tenant #{tenant || "default"}")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error(
          "DiagramStore: persist failed for #{name}@#{version || "latest"}: #{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  end

  # ---- Private helpers ----

  defp insert_into_ets(name, version, tenant, definition) do
    key = {name, version, tenant}
    entry = %{state: :loaded, definition: definition, registered_at: System.monotonic_time()}
    :ets.insert(:diagram_store, {key, entry})

    for msg_start <- Definition.get_message_start_events(definition) do
      :ets.insert(:diagram_message_starts, {{msg_start.message, tenant}, name})
    end

    for sig_start <- Definition.get_signal_start_events(definition) do
      :ets.insert(:diagram_signal_starts, {{sig_start.signal, tenant}, name})
    end

    case Definition.get_conditional_start_events(definition) do
      [] -> :ok
      _ -> :ets.insert(:diagram_conditional_starts, {tenant, {name, version}})
    end
  end

  # No raw content provided — caller opted into memory-only registration
  # (legacy 4-arity path). Return :ok so ETS still gets populated.
  defp persist(_name, _version, _tenant, nil), do: :ok

  defp persist(name, version, tenant, raw_content) when is_binary(raw_content) do
    case Queries.save_deployment(tenant, name, version, "bpmn", raw_content) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp rehydrate_from_db do
    deployments = Queries.load_all_deployments()

    bpmn_deployments = Enum.filter(deployments, fn d -> d.kind == "bpmn" end)

    Enum.each(bpmn_deployments, fn d ->
      version = unpack_version(d.version)

      case restore_definition(d.content, d.name, version) do
        {:ok, definition} ->
          tenant = unpack_tenant(d.tenant_id)
          insert_into_ets(d.name, version, tenant, definition)

        {:error, reason} ->
          Logger.warning(
            "DiagramStore: rehydrate skipped #{d.name}@#{d.version}: #{inspect(reason)}"
          )
      end
    end)

    if bpmn_deployments != [] do
      Logger.info(
        "DiagramStore: rehydrated #{length(bpmn_deployments)} BPMN deployment(s) from DB"
      )
    end
  rescue
    e ->
      # DB not yet migrated / unreachable — start with empty store.
      Logger.debug("DiagramStore: rehydrate skipped: #{inspect(e)}")
      :ok
  end

  # Picks the definition matching this persisted row's (name, version) when
  # the source .bpjs contains multiple definitions (e.g. subprocess / call-activity
  # bundles). Naively using `List.first/1` would overwrite every row with the
  # same first parsed definition.
  defp restore_definition(content, row_name, row_version) do
    case Parser.parse(content) do
      {:ok, %Definition{} = single} ->
        {:ok, single}

      {:ok, defs} when is_list(defs) ->
        case Enum.find(defs, fn d -> d.name == row_name and d.version == row_version end) do
          %Definition{} = match -> {:ok, match}
          nil -> {:error, {:definition_not_found, row_name, row_version}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp unpack_tenant(tenant) do
    if tenant == Queries.default_tenant_key(), do: nil, else: tenant
  end

  defp unpack_version(0), do: nil
  defp unpack_version(v), do: v
end
