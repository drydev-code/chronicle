defmodule Chronicle.Engine.Instance.WaitRegistryTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.{Token, Nodes}
  alias Chronicle.Engine.Instance.TokenState
  alias Chronicle.Engine.Instance.WaitRegistry

  setup do
    # Start a :duplicate Registry named :waits for this test. If a previous
    # test (or the engine supervisor) already started it, reuse it.
    case Registry.start_link(keys: :duplicate, name: :waits) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case Chronicle.Engine.Scripting.ScriptPool.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "unregister/3" do
    test "removes a previously registered wait by matching the token id value" do
      key = {"tenant-a", :message, "msg-1", "bk-1"}
      token_id = 42

      {:ok, _} = Registry.register(:waits, key, token_id)
      assert [{_pid, ^token_id}] = Registry.lookup(:waits, key)

      assert :ok = WaitRegistry.unregister(:waits, key, token_id)
      assert [] = Registry.lookup(:waits, key)
    end

    test "removes only the matching token entry when multiple entries share the key" do
      key = {"tenant-a", :signal, "sig-1"}

      {:ok, _} = Registry.register(:waits, key, 1)
      {:ok, _} = Registry.register(:waits, key, 2)

      assert Registry.lookup(:waits, key) |> length() == 2

      assert :ok = WaitRegistry.unregister(:waits, key, 1)

      remaining = Registry.lookup(:waits, key)
      assert length(remaining) == 1
      assert [{_pid, 2}] = remaining
    end

    test "is a no-op when the entry does not exist" do
      key = {"tenant-a", :message, "missing", "bk"}
      assert :ok = WaitRegistry.unregister(:waits, key, 999)
      assert [] = Registry.lookup(:waits, key)
    end
  end

  describe "boundary lifecycle cleanup" do
    test "message wait ignores payloads that fail correlation and consumes payloads that match" do
      token =
        Token.new(1, 0, 10, %{"expected" => "approved"})
        |> Token.set_waiting(:waiting_for_message)

      state =
        Map.merge(TokenState.base_state(), %{
          id: "inst-1",
          tenant_id: "tenant-a",
          business_key: "bk-1",
          definition: %Chronicle.Engine.Diagrams.Definition{
            nodes: %{
              10 => %Nodes.IntermediateCatch.MessageEvent{
                id: 10,
                message: %{
                  name: "reply",
                  correlation: "message.status === expected"
                },
                outputs: [11]
              }
            }
          },
          tokens: %{1 => token},
          waiting_tokens: MapSet.new([1]),
          message_waits: %{"reply" => [1]}
        })

      assert {:ignored, ^state} =
               WaitRegistry.handle_message(state, "reply", %{"status" => "rejected"})

      assert {:resumed, state} =
               WaitRegistry.handle_message(state, "reply", %{"status" => "approved"})

      assert state.message_waits == %{}

      assert state.tokens[1].context.continuation_context ==
               {:message, "reply", %{"status" => "approved"}}
    end

    test "interrupting boundary trigger removes sibling boundary waits and timers" do
      ref = make_ref()

      message_boundary = %Nodes.BoundaryEvents.MessageBoundary{
        id: 20,
        message: "cancel",
        outputs: [30]
      }

      signal_boundary = %Nodes.BoundaryEvents.SignalBoundary{id: 21, signal: "sig", outputs: [31]}

      state =
        boundary_state(%{
          boundary_index: %{
            1 => [
              %{type: :message, boundary_node_id: 20, name: "cancel", interrupting: true},
              %{type: :signal, boundary_node_id: 21, name: "sig", interrupting: true},
              %{
                type: :timer,
                boundary_node_id: 22,
                timer_id: "timer-1",
                timer_ref: ref,
                interrupting: true
              }
            ]
          },
          message_boundaries: %{"cancel" => [{1, message_boundary}]},
          signal_boundaries: %{"sig" => [{1, signal_boundary}]},
          timer_refs: %{ref => 1},
          timer_ref_ids: %{ref => "timer-1"}
        })

      # Message-boundary registry value now carries the wait_id as a 4th element.
      Registry.register(:waits, {"tenant-a", :message, "cancel", "bk-1"}, {:boundary, 1, 20, "wait-msg-1"})
      Registry.register(:waits, {"tenant-a", :signal, "sig"}, {:boundary, 1, 21})

      assert {:boundary, state} = WaitRegistry.handle_message(state, "cancel", %{})

      assert state.tokens[1].current_node == 20
      assert state.tokens[1].state == :execute_current_node
      assert state.boundary_index == %{}
      assert state.signal_boundaries == %{}
      assert state.timer_refs == %{}
      assert Registry.lookup(:waits, {"tenant-a", :signal, "sig"}) == []
    end

    test "non-interrupting boundary trigger keeps activity wait and registrations open" do
      message_boundary = %Nodes.BoundaryEvents.NonInterruptingMessageBoundary{
        id: 20,
        message: "notify",
        outputs: [30]
      }

      state =
        boundary_state(%{
          boundary_index: %{
            1 => [
              %{type: :message, boundary_node_id: 20, name: "notify", interrupting: false}
            ]
          },
          ni_message_boundaries: %{"notify" => [{1, message_boundary}]}
        })

      assert {:boundary, state} = WaitRegistry.handle_message(state, "notify", %{})

      assert state.tokens[1].state == :waiting_for_external_task
      assert MapSet.member?(state.waiting_tokens, 1)
      assert state.boundary_index[1] != []
      assert state.ni_message_boundaries == %{"notify" => [{1, message_boundary}]}
      assert state.tokens[2].current_node == 20
      assert MapSet.member?(state.active_tokens, 2)
    end

    test "message boundary ignores payloads that fail correlation" do
      message_boundary = %Nodes.BoundaryEvents.MessageBoundary{
        id: 20,
        message: %{name: "cancel", correlation: "message.reason === 'abort'"},
        outputs: [30]
      }

      state =
        boundary_state(%{
          message_boundaries: %{"cancel" => [{1, message_boundary}]}
        })

      assert {:ignored, ^state} =
               WaitRegistry.handle_message(state, "cancel", %{"reason" => "retry"})

      assert {:boundary, state} =
               WaitRegistry.handle_message(state, "cancel", %{"reason" => "abort"})

      assert state.tokens[1].current_node == 20
      assert state.tokens[1].state == :execute_current_node
    end

    test "event gateway selects the message branch whose correlation matches" do
      token =
        Token.new(1, 0, 10, %{})
        |> Token.set_waiting(:waiting_for_event_gateway)
        |> Token.set_context(:event_gateway_candidates, [
          %{type: :message, name: "reply", node_id: 11},
          %{type: :message, name: "reply", node_id: 12}
        ])

      state =
        Map.merge(TokenState.base_state(), %{
          id: "inst-1",
          tenant_id: "tenant-a",
          business_key: "bk-1",
          definition: %Chronicle.Engine.Diagrams.Definition{
            nodes: %{
              10 => %Nodes.Gateway{id: 10, kind: :event_based},
              11 => %Nodes.IntermediateCatch.MessageEvent{
                id: 11,
                message: %{name: "reply", correlation: "message.kind === 'first'"},
                outputs: [20]
              },
              12 => %Nodes.IntermediateCatch.MessageEvent{
                id: 12,
                message: %{name: "reply", correlation: "message.kind === 'second'"},
                outputs: [21]
              }
            }
          },
          tokens: %{1 => token},
          waiting_tokens: MapSet.new([1]),
          message_waits: %{"reply" => [1]}
        })

      assert {:resumed, state} =
               WaitRegistry.handle_message(state, "reply", %{"kind" => "second"})

      assert state.tokens[1].context.continuation_context ==
               {:message, "reply", %{"kind" => "second"}, 12}
    end
  end

  defp boundary_state(overrides) do
    token =
      Token.new(1, 0, 10)
      |> Token.set_waiting(:waiting_for_external_task)

    Map.merge(TokenState.base_state(), %{
      id: "inst-1",
      tenant_id: "tenant-a",
      business_key: "bk-1",
      tokens: %{1 => token},
      waiting_tokens: MapSet.new([1]),
      next_token_id: 2
    })
    |> Map.merge(overrides)
  end
end
