defmodule Chronicle.Engine.InstanceTimerElapsedTest do
  @moduledoc """
  Finding 9: when a timer fires the Instance must append a TimerElapsed
  event to its persistent log. Before this fix the token resumed but the
  event was lost, so replay could not distinguish a fired timer from a
  pending one.
  """
  use ExUnit.Case, async: false

  alias Chronicle.Engine.Instance
  alias Chronicle.Engine.PersistentData
  alias Chronicle.Persistence.EventStore
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.ActiveInstance

  # A minimal BPMN flow that parks the token on an intermediate timer.
  # We use a short duration so the timer fires without long waits, but we
  # do not rely on the exact firing time — we manually send the
  # :timer_elapsed message to deterministically exercise the handler.
  @bpjs %{
    "name" => "timer-elapsed-test",
    "version" => 1,
    "nodes" => [
      %{"id" => 1, "type" => "blankStartEvent"},
      %{
        "id" => 2,
        "type" => "intermediateCatchTimerEvent",
        "timer" => %{"durationMs" => 60_000}
      },
      %{"id" => 3, "type" => "externalTask", "kind" => "service"},
      %{"id" => 4, "type" => "blankEndEvent"}
    ],
    "connections" => [
      %{"from" => 1, "to" => 2},
      %{"from" => 2, "to" => 3},
      %{"from" => 3, "to" => 4}
    ]
  }

  setup do
    repo = Application.get_env(:engine, :active_repo)

    if repo do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo)
      Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
      Repo.delete_all(ActiveInstance)

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

  describe "timer_elapsed appends TimerElapsed event" do
    @tag :integration
    test "firing the timer produces a persisted TimerElapsed event" do
      {:ok, definition} = Chronicle.Engine.Diagrams.Parser.parse(Jason.encode!(@bpjs))
      instance_id = UUID.uuid4()

      {:ok, pid} = Instance.start_link({definition, %{id: instance_id, tenant_id: "t-timer"}})

      # Wait for the instance to park on the intermediate timer.
      state = wait_for_timer_wait(pid)
      [{timer_ref, token_id}] = Enum.to_list(state.timer_refs)
      assert MapSet.member?(state.waiting_tokens, token_id)

      before_count = length(state.persistent_events)
      refute has_event?(state.persistent_events, PersistentData.TimerElapsed)

      # Simulate the timer firing by sending the same message the
      # Process.send_after would have delivered. Cancel the real timer
      # first so we don't get a double-fire.
      Process.cancel_timer(timer_ref)
      send(pid, {:timer_elapsed, token_id, timer_ref})

      # Let the message be processed.
      final_state = :sys.get_state(pid)

      after_events = final_state.persistent_events
      assert length(after_events) > before_count
      assert has_event?(after_events, PersistentData.TimerElapsed),
             "TimerElapsed must be appended when the timer fires"

      # It must also be durable in the EventStore.
      {:ok, durable_events} = EventStore.stream(instance_id)
      assert has_event?(durable_events, PersistentData.TimerElapsed),
             "TimerElapsed must be flushed to EventStore synchronously"

      # Assert the stored event has meaningful fields populated.
      te = Enum.find(durable_events, &match?(%PersistentData.TimerElapsed{}, &1))
      assert te.token == token_id
      assert is_integer(te.triggered_at)

      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  end

  # --- helpers ---

  defp has_event?(events, struct_module) do
    Enum.any?(events, fn
      %{__struct__: ^struct_module} -> true
      _ -> false
    end)
  end

  # Poll :sys.get_state until the instance has parked on its timer.
  defp wait_for_timer_wait(pid, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    state = :sys.get_state(pid)

    cond do
      map_size(state.timer_refs) > 0 and MapSet.size(state.waiting_tokens) > 0 ->
        state

      System.monotonic_time(:millisecond) > deadline ->
        flunk("Instance did not reach timer wait state within 2s; state=#{inspect(state.instance_state)}")

      true ->
        Process.sleep(20)
        wait_for_timer_wait(pid, deadline)
    end
  end
end
