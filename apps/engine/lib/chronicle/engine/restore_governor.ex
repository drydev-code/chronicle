defmodule Chronicle.Engine.RestoreGovernor do
  @moduledoc """
  Caps the number of CONCURRENT instance restores (event-store replay + GenServer start).

  Under a mass-eviction burst (thousands of evicted instances each woken by an arriving
  reply), the restore path used to spawn an unbounded Task per wake. On a small host that
  saturates CPU + the event-store DB, the InboxDriver starves, the inbox backlog grows, and
  the engine livelocks — replies pile up while nothing completes. Bounding concurrency keeps
  each restore fast and lets work drain steadily.

  When at capacity `try_acquire/0` returns false and the caller simply does NOT start the
  restore; the wake stays queued on the load cell and the inbox's at-least-once retry
  re-triggers it once a slot frees — no restore is lost, just deferred.
  """
  use GenServer

  @table :restore_governor
  @default_max 12

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Reserve a restore slot. Returns true if acquired, false if at capacity."
  def try_acquire do
    case :ets.whereis(@table) do
      :undefined ->
        true

      _ ->
        n = :ets.update_counter(@table, :inflight, 1)

        if n <= max() do
          true
        else
          :ets.update_counter(@table, :inflight, {2, -1, 0, 0})
          false
        end
    end
  end

  @doc "Release a restore slot (on restore completion or failure)."
  def release do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.update_counter(@table, :inflight, {2, -1, 0, 0}); :ok
    end
  end

  defp max, do: Application.get_env(:engine, :max_concurrent_restores, @default_max)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(@table, {:inflight, 0})
    {:ok, %{}}
  end
end
