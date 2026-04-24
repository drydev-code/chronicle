defmodule DryDev.Workflow.Engine.Dmn.DmnStore do
  @moduledoc "GenServer + ETS cache for DMN decision tables."
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table = :ets.new(:dmn_store, [:named_table, :set, :public, read_concurrency: true])
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
            DryDev.Workflow.Engine.Dmn.DmnEvaluator.evaluate(content, inputs)

          {:error, :not_found} ->
            {:error, "DMN definition '#{dmn_name}' not found"}
        end

      GenServer.cast(caller_pid, {:rules_result, ref, result})
    end)
  end

  @impl true
  def handle_call({:register, name, version, tenant, content}, _from, state) do
    key = {name, version, tenant}
    :ets.insert(:dmn_store, {key, content})
    {:reply, :ok, state}
  end
end
