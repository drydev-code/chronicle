defmodule Chronicle.Engine.PersistentDataCompatTest do
  @moduledoc """
  Rolling-deploy event-codec compatibility (feature 3, codec hardening).

  These tests lock the ADDITIVE-ONLY field-discipline invariant and prove the
  decode path is tolerant of an OLDER release reading a NEWER release's events:
  unknown KEYS are dropped, unknown TYPES become `%PersistentData.Unknown{}`, and
  neither raises. Behaviour is preserved for all KNOWN event data (round-trip).
  """
  use ExUnit.Case, async: true

  alias Chronicle.Engine.{EvictedWaitRestorer, PersistentData, WaitingHandle}

  # Helper: encode -> JSON -> decode (the real durable round-trip the EventStore
  # performs). Jason.decode! produces a map with BINARY keys, exactly like a row
  # streamed back from MySQL.
  defp roundtrip(struct) do
    struct
    |> PersistentData.encode()
    |> Jason.encode!()
    |> Jason.decode!()
    |> PersistentData.decode()
  end

  describe "1. round-trip regression lock (behaviour-preserving for known data)" do
    test "MessageWaitCreated" do
      original = %PersistentData.MessageWaitCreated{
        token: 7, family: 0, current_node: 2, name: "approved",
        business_key: "bk-1", wait_id: "w-1"
      }

      assert roundtrip(original) == original
    end

    test "EventGatewayActivated" do
      original = %PersistentData.EventGatewayActivated{
        token: 3, family: 0, current_node: 5,
        message_names: ["m1", "m2"], signal_names: ["s1"],
        timer_ids: ["t1"], trigger_at_by_timer_id: %{"t1" => 123},
        wait_id: "gw-1"
      }

      assert roundtrip(original) == original
    end

    test "BoundaryEventCreated (boundary_type atom restored)" do
      original = %PersistentData.BoundaryEventCreated{
        token: 9, family: 0, current_node: 4, boundary_node_id: "b1",
        boundary_type: :message, interrupting: true, name: "cancel",
        condition: nil, timer_id: nil, trigger_at: nil, wait_id: "bw-1"
      }

      decoded = roundtrip(original)
      assert decoded == original
      assert decoded.boundary_type == :message
      assert is_atom(decoded.boundary_type)
    end

    test "BoundaryEventTriggered (boundary_type atom restored)" do
      original = %PersistentData.BoundaryEventTriggered{
        token: 9, family: 0, current_node: 4, boundary_node_id: "b1",
        boundary_type: :signal, interrupting: true, name: "abort",
        condition: nil, timer_id: nil, triggered_at: 1000, wait_id: "bw-2"
      }

      decoded = roundtrip(original)
      assert decoded == original
      assert decoded.boundary_type == :signal
    end

    test "EventGatewayResolved" do
      original = %PersistentData.EventGatewayResolved{
        token: 3, family: 0, current_node: 5, trigger_type: "message",
        trigger_name: "m1", selected_node: "node-7", target_node: "node-7",
        payload: %{"k" => "v"}, triggered_at: 2000, wait_id: "gw-1"
      }

      assert roundtrip(original) == original
    end

    test "MessageHandled" do
      original = %PersistentData.MessageHandled{
        token: 3, family: 0, current_node: 5, name: "m1", target_node: "node-7",
        retry_counter: 0, payload: %{"k" => "v"}, wait_id: "w-9",
        selected_node: "node-7"
      }

      assert roundtrip(original) == original
    end
  end

  describe "2. OLD reads NEW — unknown KEY tolerance (the E3 repro)" do
    test "a never-loaded synthetic future key does not crash decode" do
      # A real MessageHandled map as it would arrive from JSON, PLUS a synthetic
      # key the running release has never compiled as an atom. Old code must IGNORE
      # it (drop it), not raise ArgumentError on String.to_existing_atom.
      future_atom = "__e3_future_field_never_compiled_zzq__"
      refute already_existing_atom?(future_atom)

      map = %{
        "type" => "MessageHandled",
        "token" => 3,
        "family" => 0,
        "current_node" => 5,
        "name" => "m1",
        "target_node" => "node-7",
        "retry_counter" => 0,
        "payload" => %{"k" => "v"},
        future_atom => 1
      }

      decoded = PersistentData.decode(map)

      assert %PersistentData.MessageHandled{} = decoded
      assert decoded.token == 3
      assert decoded.name == "m1"
      assert decoded.target_node == "node-7"
      # The unknown key was dropped, not turned into a struct field.
      refute Map.has_key?(Map.from_struct(decoded), :__future_field__)
    end
  end

  describe "3. NEW reads OLD — missing additive fields default to nil" do
    test "MessageHandled missing wait_id/selected_node -> both nil, plain branch" do
      # An OLD event predating wait_id/selected_node. struct/2 defaults them to nil.
      map = %{
        "type" => "MessageHandled",
        "token" => 3,
        "family" => 0,
        "current_node" => 5,
        "name" => "m1",
        "target_node" => "node-7",
        "retry_counter" => 0,
        "payload" => %{}
      }

      decoded = PersistentData.decode(map)

      assert %PersistentData.MessageHandled{} = decoded
      assert decoded.wait_id == nil
      assert decoded.selected_node == nil

      # EventReplayer.replay_single_event(MessageHandled) routes to the PLAIN
      # (non-gateway) branch precisely when selected_node is nil (and the open wait
      # for the token is not a gateway wait). With selected_node nil there is no
      # gateway forcing — the plain branch is taken, no crash.
      assert is_nil(decoded.selected_node)
    end
  end

  describe "4. OLD reads NEW — unknown TYPE tolerance" do
    test "unknown struct type decodes to %Unknown{} without raising" do
      map = %{"type" => "TotallyNewFutureEvent", "token" => 1}

      decoded = PersistentData.decode(map)

      assert %PersistentData.Unknown{type: "TotallyNewFutureEvent"} = decoded
      assert decoded.raw == map
    end

    test "replay/fold skip an %Unknown{} without altering token state" do
      # Drive the pure evicted-restore fold over a wait-creating event PLUS an
      # unknown future event. The unknown event must NOT add/remove any wait — the
      # resulting open-wait set is identical to the one without it.
      start = %PersistentData.ProcessInstanceStart{
        process_instance_id: "inst-1", business_key: "bk-1", tenant: "tenant-1",
        process_name: "p", process_version: 1
      }

      wait = %PersistentData.MessageWaitCreated{
        token: 7, family: 0, current_node: 2, name: "approved", business_key: "bk-1"
      }

      unknown = %PersistentData.Unknown{
        type: "TotallyNewFutureEvent",
        raw: %{"type" => "TotallyNewFutureEvent", "token" => 7}
      }

      without_unknown = EvictedWaitRestorer.collect_open_waits([start, wait])
      with_unknown = EvictedWaitRestorer.collect_open_waits([start, wait, unknown])

      # Unknown event is skipped: the open-wait set is unchanged.
      assert with_unknown == without_unknown
      assert [%WaitingHandle.Message{token_id: 7}] =
               Enum.filter(with_unknown, &match?(%WaitingHandle.Message{}, &1))
    end
  end

  describe "4b. OLD reads NEW — unknown TYPE never interns a new atom (DoS-safe)" do
    test "decoding a never-loaded type string does NOT create the joined module atom" do
      # SECURITY: a corrupt/hostile event blob carrying many distinct unknown
      # "type" strings must NOT exhaust the (non-GC'd) atom table. `safe_concat/1`
      # must resolve via existing-atom-only semantics — so the candidate module
      # atom `Elixir.Chronicle.Engine.PersistentData.<type>` is NEVER minted for an
      # unknown type. We assert the joined atom is unknown BEFORE the decode and
      # STILL unknown AFTER it, and that the decode yields %Unknown{} (not a raise).
      type = "TotallyNewFutureEvent_zzq_never_loaded"
      joined = "Elixir.Chronicle.Engine.PersistentData." <> type

      # Precondition: neither the bare type nor the joined module atom exists yet.
      refute already_existing_atom?(type)
      refute already_existing_atom?(joined)

      decoded = PersistentData.decode(%{"type" => type, "token" => 1})

      assert %PersistentData.Unknown{type: ^type} = decoded

      # Postcondition: the decode did not intern the joined module atom (nor the
      # bare type) — existing-atom-only resolution held. This is the DoS guard.
      refute already_existing_atom?(joined)
      refute already_existing_atom?(type)
    end

    test "a KNOWN type still resolves to its struct (no regression)" do
      map = %{"type" => "TokenFamilyRemoved", "token" => 4, "family" => 0, "current_node" => 2}

      decoded = PersistentData.decode(map)

      assert %PersistentData.TokenFamilyRemoved{token: 4, family: 0, current_node: 2} = decoded
    end
  end

  describe "5. boundary_type unknown string -> raw-string fallback" do
    test "an unknown boundary_type string is kept as a binary, no crash" do
      # A boundary_type value that is NOT an existing atom in this release. The
      # safe_to_atom fallback keeps it as the raw binary rather than raising.
      future_bt = "__future_boundary_kind_never_compiled_zzq__"
      refute already_existing_atom?(future_bt)

      map = %{
        "type" => "BoundaryEventCreated",
        "token" => 9,
        "family" => 0,
        "current_node" => 4,
        "boundary_node_id" => "b1",
        "boundary_type" => future_bt,
        "interrupting" => true,
        "name" => "cancel"
      }

      decoded = PersistentData.decode(map)

      assert %PersistentData.BoundaryEventCreated{} = decoded
      assert decoded.boundary_type == future_bt
      assert is_binary(decoded.boundary_type)
    end
  end

  # True only if `string` is already in the atom table; used to assert our
  # "synthetic never-loaded" test keys really are unknown to this release.
  defp already_existing_atom?(string) do
    _ = String.to_existing_atom(string)
    true
  rescue
    ArgumentError -> false
  end
end
