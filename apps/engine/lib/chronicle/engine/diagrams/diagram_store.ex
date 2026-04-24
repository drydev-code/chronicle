defmodule Chronicle.Engine.Diagrams.DiagramStore do
  @moduledoc """
  GenServer + ETS for diagram storage with tenant/version resolution.
  Supports lazy loading and start event registration.
  """
  use GenServer

  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table = :ets.new(:diagram_store, [:named_table, :set, :public, read_concurrency: true])
    msg_table = :ets.new(:diagram_message_starts, [:named_table, :bag, :public, read_concurrency: true])
    sig_table = :ets.new(:diagram_signal_starts, [:named_table, :bag, :public, read_concurrency: true])
    {:ok, %{table: table, msg_table: msg_table, sig_table: sig_table}}
  end

  def register(name, version, tenant, definition) do
    GenServer.call(__MODULE__, {:register, name, version, tenant, definition})
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

  @impl true
  def handle_call({:register, name, version, tenant, definition}, _from, state) do
    key = {name, version, tenant}
    entry = %{state: :loaded, definition: definition, registered_at: System.monotonic_time()}
    :ets.insert(:diagram_store, {key, entry})

    # Register message start events
    for msg_start <- Chronicle.Engine.Diagrams.Definition.get_message_start_events(definition) do
      :ets.insert(:diagram_message_starts, {{msg_start.message, tenant}, name})
    end

    # Register signal start events
    for sig_start <- Chronicle.Engine.Diagrams.Definition.get_signal_start_events(definition) do
      :ets.insert(:diagram_signal_starts, {{sig_start.signal, tenant}, name})
    end

    Logger.info("DiagramStore: registered #{name}@#{version || "latest"} for tenant #{tenant || "default"}")
    {:reply, :ok, state}
  end
end
