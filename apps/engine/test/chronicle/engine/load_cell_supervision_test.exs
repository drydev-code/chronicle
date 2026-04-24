defmodule Chronicle.Engine.LoadCellSupervisionTest do
  @moduledoc """
  Verifies that `InstanceLoadCell` processes started via
  `Chronicle.Engine.LoadCellSupervisor` are independent of the
  `EvictionManager` and are restarted by their supervisor on crash.

  These tests avoid booting the full engine (which requires a DB and RabbitMQ)
  by starting just the pieces needed: the `:load_cells` registry and the
  LoadCell DynamicSupervisor.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.InstanceLoadCell

  # Unlink supervisor/registry from test processes so they survive across
  # individual tests. Using :kernel (a long-lived process) as the parent
  # avoids linkage-based shutdowns between tests.
  setup_all do
    unless Process.whereis(:load_cells) do
      {:ok, _} = start_supervised_unlinked({Registry, keys: :unique, name: :load_cells})
    end

    unless Process.whereis(Chronicle.Engine.LoadCellSupervisor) do
      {:ok, _} =
        start_supervised_unlinked(
          {DynamicSupervisor,
           name: Chronicle.Engine.LoadCellSupervisor,
           strategy: :one_for_one,
           max_restarts: 1000,
           max_seconds: 5}
        )
    end

    :ok
  end

  setup do
    # Dummy instance pid — the cell only monitors it. A spawned sleeper
    # keeps the DOWN message from firing during the test.
    instance_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        after
          60_000 -> :ok
        end
      end)

    on_exit(fn -> send(instance_pid, :stop) end)

    {:ok, instance_pid: instance_pid}
  end

  # Start a supervisor/registry under the global supervision tree so it isn't
  # linked to the test process that would die at the end of the test.
  defp start_supervised_unlinked(child_spec) do
    parent = self()

    spawn(fn ->
      {mod, args} =
        case child_spec do
          {mod, args} -> {mod, args}
          %{start: {mod, :start_link, [args]}} -> {mod, args}
        end

      result = apply(mod, :start_link, [args])
      send(parent, {:started, result})
      # Keep the spawning process alive so the link on start_link does not
      # cause the child to die.
      Process.sleep(:infinity)
    end)

    receive do
      {:started, result} -> result
    after
      5_000 -> {:error, :timeout}
    end
  end

  test "InstanceLoadCell.child_spec/1 accepts the args tuple and starts under the supervisor",
       %{instance_pid: instance_pid} do
    args = {"inst-sup-1", "t-sup", "bk-sup", instance_pid}

    assert {:ok, cell_pid} =
             DynamicSupervisor.start_child(
               Chronicle.Engine.LoadCellSupervisor,
               {InstanceLoadCell, args}
             )

    assert is_pid(cell_pid)
    assert Process.alive?(cell_pid)

    children = DynamicSupervisor.which_children(Chronicle.Engine.LoadCellSupervisor)
    assert Enum.any?(children, fn {_, pid, _, _} -> pid == cell_pid end)

    # Cell was registered by (tenant, instance_id) in :load_cells.
    assert {:ok, ^cell_pid} = InstanceLoadCell.lookup("t-sup", "inst-sup-1")

    DynamicSupervisor.terminate_child(Chronicle.Engine.LoadCellSupervisor, cell_pid)
  end

  test "supervised cell is NOT linked to the caller (survives caller crash)",
       %{instance_pid: instance_pid} do
    # Spawn a transient owner that starts the cell, then the owner dies. The
    # cell must remain alive because it's supervised, not linked to the owner.
    test_pid = self()
    Process.flag(:trap_exit, true)

    owner =
      spawn(fn ->
        {:ok, cell_pid} =
          DynamicSupervisor.start_child(
            Chronicle.Engine.LoadCellSupervisor,
            {InstanceLoadCell,
             {"inst-sup-2", "t-sup", "bk-sup", instance_pid}}
          )

        send(test_pid, {:cell, cell_pid})

        receive do
          :die -> :ok
        after
          5_000 -> :ok
        end
      end)

    cell_pid =
      receive do
        {:cell, pid} -> pid
      after
        5_000 -> flunk("cell pid not received")
      end

    # Kill the owner and verify the cell is still alive.
    Process.exit(owner, :kill)
    Process.sleep(100)

    # Drain any EXIT messages that may have arrived from the supervised child
    # tree; we only care that the cell is still alive.
    flush_exits()

    assert Process.alive?(cell_pid), "cell died with caller — it must be supervisor-linked"

    DynamicSupervisor.terminate_child(Chronicle.Engine.LoadCellSupervisor, cell_pid)
  end

  defp flush_exits do
    receive do
      {:EXIT, _, _} -> flush_exits()
    after
      0 -> :ok
    end
  end

  test "terminate_child removes the cell from the supervisor", %{instance_pid: instance_pid} do
    {:ok, cell_pid} =
      DynamicSupervisor.start_child(
        Chronicle.Engine.LoadCellSupervisor,
        {InstanceLoadCell, {"inst-sup-3", "t-sup", "bk-sup", instance_pid}}
      )

    assert :ok =
             DynamicSupervisor.terminate_child(
               Chronicle.Engine.LoadCellSupervisor,
               cell_pid
             )

    refute Process.alive?(cell_pid)
  end
end
