defmodule Chronicle.Engine.EvictedWaitRestorer do
  @moduledoc """
  Reconstructs open wait handles from a persisted event stream.

  NOT currently wired into startup. `Chronicle.Supervisor.restore_active_instances/0`
  brings active instances back resident, covering their waits via the normal
  `InstanceLoadCell` registration path. This module is used by the high-scale
  evicted-only restore path (opt-in `restore_mode: :evicted`) to restart without
  re-materialising every instance: `restore_all/0` starts a supervised, evicted
  `InstanceLoadCell` per active instance, which registers its open waits (registry
  value = cell pid) and timers from its own `init/1`.

  The LIVE restore path derives the evicted cell's open waits from the FULL
  replayed state (`EventReplayer.replay_open_state/2` → `state_derived_waits/3`),
  reusing the SAME resident reconstruction the on-demand restore uses — explicit,
  implicit, event-gateway, boundary, external-task, timer and call waits all come
  from one source, so the evicted path can never diverge from resident semantics.
  The pure event fold `collect_open_waits/2` is retained as the conservative
  fallback when the replay cannot classify (e.g. the diagram is not yet loaded)
  and as the primary unit-test surface.
  """

  require Logger

  alias Chronicle.Engine.{InstanceLoadCell, PersistentData, WaitingHandle}
  alias Chronicle.Engine.Diagrams.{Definition, DiagramStore}
  alias Chronicle.Engine.Instance.{EventReplayer, TokenState}
  alias Chronicle.Persistence.EventStore

  @type wait ::
          WaitingHandle.ExternalTask.t()
          | WaitingHandle.Timer.t()
          | WaitingHandle.Message.t()
          | WaitingHandle.Signal.t()
          | WaitingHandle.Call.t()

  @doc """
  Scan every active instance and start a supervised evicted `InstanceLoadCell`
  for each, registering its outstanding waits in `:evicted_waits` (registry
  value = cell pid).

  Idempotent: instances that already have a live load cell are skipped, so this
  is safe to call repeatedly.
  """
  def restore_all do
    ids = safe_list_active_ids()

    if ids == [] do
      Logger.info("EvictedWaitRestorer: no active instances to restore waits for")
      :ok
    else
      Logger.info("EvictedWaitRestorer: restoring waits for #{length(ids)} active instance(s)")

      Enum.each(ids, fn instance_id ->
        try do
          restore_waits_for(instance_id)
        rescue
          e ->
            Logger.error(
              "EvictedWaitRestorer: failed to restore waits for #{instance_id}: #{inspect(e)}"
            )
        end
      end)

      :ok
    end
  end

  @doc """
  Restore a single active instance at evicted boot, routing on its replayed
  token state:

    * If the instance has any ACTIVE (in-flight, non-waiting) token — e.g. its
      durable log ended at a WAKE event (`MessageHandled` / `TimerElapsed` /
      `ExternalTaskCompletion` / `CallCompleted`) but it crashed before
      `:process_tokens` wrote the next wait/completion — it is brought back
      RESIDENT (the existing `restore_instance` path), which processes the active
      token immediately. A passive evicted cell would strand it: with no open
      wait there is no `:evicted_waits` row and no future external trigger to
      wake it.

    * If the instance is PURELY WAITING, an evicted-from-inception
      `InstanceLoadCell` is started under the load-cell supervisor. The cell
      registers the open waits (registry value = cell pid) and timers from its
      own `init/1` and restores on demand when a trigger arrives. This is the
      scale win — idle/long-lived instances stay passive.

  Idempotent: a live load cell OR a live resident instance for the id short-
  circuits to `:already_started`. Returns the number of waits registered on a
  fresh evicted start, `:restored_resident` when started resident, or
  `{:error, reason}` when the instance cannot be read.
  """
  def restore_waits_for(instance_id) do
    case EventStore.stream(instance_id) do
      {:ok, events} ->
        {tenant_id, business_key} = identity(events)

        cond do
          resident_instance_exists?(tenant_id, instance_id) ->
            :already_started

          true ->
            # Single authoritative replay (side-effect-free): the SAME resident
            # reconstruction the on-demand restore uses, including implicit waits.
            # Routing on its classified tokens AND deriving the evicted handles
            # from its open-wait maps means the evicted cell can never again
            # diverge from resident semantics.
            case replay_state(events, tenant_id) do
              {:ok, {state, open_timers}} ->
                if MapSet.size(state.active_tokens) > 0 do
                  restore_resident(instance_id, tenant_id, events)
                else
                  waits = waits_from_state(state, open_timers, instance_id)
                  start_evicted_cell(instance_id, tenant_id, business_key, waits)
                end

              {:error, reason} ->
                # The replay could not classify (e.g. the diagram is not loaded
                # yet). Fall back to the pure event fold so a transient lookup
                # failure never blocks restore — an instance kept reachable on a
                # conservative wait list still recovers; one lost is not.
                Logger.debug(
                  "EvictedWaitRestorer: state replay fell back to collect_open_waits for #{instance_id}: #{inspect(reason)}"
                )

                waits = collect_open_waits(events, resolve_definition(events))
                start_evicted_cell(instance_id, tenant_id, business_key, waits)
            end
        end

      {:error, reason} ->
        Logger.warning(
          "EvictedWaitRestorer: cannot stream #{instance_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  # Replay the durable log once (side-effect-free) into the SAME classified
  # token/wait state the resident on-demand restore builds — including the
  # implicit message/signal waits `EventReplayer.detect_implicit_waits` adds for a
  # token that durably reached a catch but crashed before its `MessageWaitCreated`
  # was persisted. The caller routes on `state.active_tokens` and derives the
  # evicted handles from this state's open-wait maps, so the evicted path stays
  # bit-for-bit in step with resident semantics. `{:error, reason}` lets the
  # caller fall back to the conservative pure fold on a transient diagram miss.
  defp replay_state(events, tenant_id) do
    base_state = %{TokenState.base_state() | tenant_id: tenant_id}
    EventReplayer.replay_open_state(events, base_state)
  end

  @doc """
  Enumerate every OPEN wait from a fully-replayed state
  (`EventReplayer.replay_open_state/2`) as the `WaitingHandle` list the evicted
  cell registers. Reading the resident open-wait maps (message_waits /
  signal_waits — both already carrying implicit + gateway waits — the boundary
  maps, external_tasks, call_wait_list) and the open-timer map means this list is,
  by construction, identical to what the resident restore would re-register:
  explicit + implicit + gateway + boundary + external-task + timer + call. No
  parallel reconstruction can drift from it.

  Public so the boot-restore derivation is directly unit-testable against a
  replayed state.
  """
  def waits_from_state(state, open_timers, instance_id) do
    tenant_id = state.tenant_id
    business_key = state.business_key

    ext_handles =
      Enum.map(state.external_tasks, fn {task_id, token_id} ->
        %WaitingHandle.ExternalTask{
          instance_id: instance_id,
          tenant_id: tenant_id,
          task_id: task_id,
          token_id: token_id
        }
      end)

    timer_handles =
      Enum.map(open_timers, fn {_timer_id, info} ->
        %WaitingHandle.Timer{
          instance_id: instance_id,
          tenant_id: tenant_id,
          token_id: info.token_id,
          trigger_at: info.trigger_at,
          # Carry the DURABLE timer_id (the marker the resident path re-arms with)
          # so the evicted cell's send_after / sweeper fire with the same JSON-safe
          # id the persisted TimerElapsed carries.
          timer_ref: info[:timer_id],
          boundary_node_id: info[:boundary_node_id],
          is_boundary: not is_nil(info[:boundary_node_id])
        }
      end)

    call_handles =
      Enum.map(state.call_wait_list, fn {child_id, token_id} ->
        %WaitingHandle.Call{
          instance_id: instance_id,
          tenant_id: tenant_id,
          child_id: child_id,
          token_id: token_id
        }
      end)

    # Plain message/signal catch waits (state.message_waits / signal_waits already
    # include the implicit and event-gateway-candidate waits). Keyless is resolved
    # off the resident opt-in test so the `:no_key` route matches exactly.
    msg_handles =
      Enum.flat_map(state.message_waits, fn {name, token_ids} ->
        Enum.map(token_ids, fn token_id ->
          %WaitingHandle.Message{
            instance_id: instance_id,
            tenant_id: tenant_id,
            message_name: name,
            business_key: business_key,
            token_id: token_id,
            keyless: EventReplayer.wait_keyless?(state, name, token_id)
          }
        end)
      end)

    sig_handles =
      Enum.flat_map(state.signal_waits, fn {name, token_ids} ->
        Enum.map(token_ids, fn token_id ->
          %WaitingHandle.Signal{
            instance_id: instance_id,
            tenant_id: tenant_id,
            signal_name: name,
            token_id: token_id
          }
        end)
      end)

    # Message/signal BOUNDARY waits (interrupting + non-interrupting). The boundary
    # maps are `%{name => [{token_id, boundary_node_struct}]}`; the boundary node
    # carries its own id and the `message.allow_keyless` annotation.
    msg_boundary_handles =
      boundary_message_handles(state, instance_id, tenant_id, business_key)

    sig_boundary_handles =
      boundary_signal_handles(state, instance_id, tenant_id)

    ext_handles ++
      timer_handles ++
      call_handles ++ msg_handles ++ sig_handles ++ msg_boundary_handles ++ sig_boundary_handles
  end

  defp boundary_message_handles(state, instance_id, tenant_id, business_key) do
    [state.message_boundaries, state.ni_message_boundaries]
    |> Enum.flat_map(fn boundaries ->
      Enum.flat_map(boundaries || %{}, fn {name, occurrences} ->
        Enum.map(occurrences, fn {token_id, boundary_node} ->
          %WaitingHandle.Message{
            instance_id: instance_id,
            tenant_id: tenant_id,
            message_name: name,
            business_key: business_key,
            token_id: token_id,
            boundary_node_id: boundary_node.id,
            is_boundary: true,
            keyless: boundary_node_keyless?(boundary_node)
          }
        end)
      end)
    end)
  end

  defp boundary_signal_handles(state, instance_id, tenant_id) do
    [state.signal_boundaries, state.ni_signal_boundaries]
    |> Enum.flat_map(fn boundaries ->
      Enum.flat_map(boundaries || %{}, fn {name, occurrences} ->
        Enum.map(occurrences, fn {token_id, boundary_node} ->
          %WaitingHandle.Signal{
            instance_id: instance_id,
            tenant_id: tenant_id,
            signal_name: name,
            token_id: token_id,
            boundary_node_id: boundary_node.id,
            is_boundary: true
          }
        end)
      end)
    end)
  end

  # Mirror the resident `boundary_node_keyless?/2` (event_replayer.ex ~1213): the
  # boundary node carries the `message.allow_keyless` annotation directly.
  defp boundary_node_keyless?(boundary_node) do
    match?(%{allow_keyless: true}, Map.get(boundary_node, :message) || %{})
  end

  defp resident_instance_exists?(tenant_id, instance_id) do
    match?({:ok, _pid}, Chronicle.Engine.Instance.lookup(tenant_id, instance_id))
  end

  # Bring the instance back RESIDENT via the same contract the default
  # :resident boot path uses (`{:restore, ...}` Instance), so its active token is
  # processed immediately. The instance re-evicts later via EvictionManager.
  defp restore_resident(instance_id, tenant_id, events) do
    case DynamicSupervisor.start_child(
           Chronicle.Engine.InstanceSupervisor,
           {Chronicle.Engine.Instance, {:restore, instance_id, tenant_id, events}}
         ) do
      {:ok, _pid} ->
        :restored_resident

      {:error, {:already_started, _pid}} ->
        :already_started

      {:error, reason} ->
        Logger.error(
          "EvictedWaitRestorer: failed to restore resident instance #{instance_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp start_evicted_cell(instance_id, tenant_id, business_key, waits) do
    case DynamicSupervisor.start_child(
           Chronicle.Engine.LoadCellSupervisor,
           {InstanceLoadCell, {:evicted, instance_id, tenant_id, business_key, waits}}
         ) do
      {:ok, _cell_pid} ->
        length(waits)

      {:error, {:already_started, _cell_pid}} ->
        :already_started

      {:error, reason} ->
        Logger.error(
          "EvictedWaitRestorer: failed to start evicted cell for #{instance_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Pure function: walk a list of `PersistentData` events and return the list
  of still-open wait handles.

  An external task is open if we saw an `ExternalTaskCreation` without a
  matching `ExternalTaskCompletion`/`ExternalTaskCancellation`. A timer is
  open if `TimerCreated` has no matching `TimerElapsed`/`TimerCanceled`.
  Call waits follow the same rule with `CallStarted` / `CallCompleted` /
  `CallCanceled`.

  Message and signal waits are reconstructed from *explicit* wait creation
  events (`MessageWaitCreated`, `SignalWaitCreated`) AND from the candidate
  names carried by `EventGatewayActivated` — an event-based gateway parks its
  token on message/signal/timer candidates without emitting per-candidate
  explicit wait events, so the gateway activation is the only source for its
  message/signal candidate waits (the timer candidate emits its own
  `TimerCreated`). `EventGatewayResolved` closes all of a token's gateway
  candidate waits.

  Message/signal BOUNDARY events (`BoundaryEventCreated` with
  `boundary_type: :message`/`:signal`) are also reconstructed — they park their
  activity token on a message/signal wait exactly like a plain catch and are
  closed by the matching `BoundaryEventTriggered`/`BoundaryEventCancelled`. They
  surface as `WaitingHandle.Message`/`WaitingHandle.Signal` with `is_boundary:
  true` and the `boundary_node_id` set, mirroring the boundary-timer path and the
  resident `EventReplayer` (event_replayer.ex ~492 / ~1147). Events of unknown
  type are ignored.
  """
  def collect_open_waits(events, definition \\ nil) when is_list(events) do
    start = find_start_event(events)
    instance_id = start && start.process_instance_id
    tenant_id = (start && start.tenant) || "00000000-0000-0000-0000-000000000000"
    business_key = start && start.business_key

    acc = %{
      ext: %{},
      timer: %{},
      call: %{},
      msg: %{},
      # {name, token_id} => current_node, so msg handles can resolve the catch
      # node's keyless opt-in (B'.5) when a `definition` is supplied.
      msg_node: %{},
      sig: %{},
      # Message/signal BOUNDARY waits, kept SEPARATE from `msg`/`sig` (mirroring
      # the resident `message_boundaries`/`signal_boundaries` vs `message_waits`
      # split) so a plain MessageHandled/SignalHandled or EventGatewayResolved
      # never accidentally drops a boundary. Keyed by `{name, token_id,
      # boundary_node_id}` => true; removed on the matching
      # BoundaryEventTriggered/BoundaryEventCancelled. Resident parallel:
      # event_replayer.ex BoundaryEventCreated (~492) +
      # reregister_boundaries_in_registry (~1147).
      msg_boundary: %{},
      sig_boundary: %{},
      # NEW-1: tokens currently parked on an OPEN event-based gateway (added on
      # EventGatewayActivated, dropped on EventGatewayResolved or on a winning
      # delivery). Used so a winner event (MessageHandled / SignalHandled /
      # TimerElapsed) that resolves a gateway closes ALL the gateway's sibling
      # candidate waits — not just the winning name — even when the crash happened
      # AFTER the durable winner but BEFORE EventGatewayResolved was persisted.
      gw_tokens: MapSet.new(),
      # token_id => MapSet of the gateway's timer-candidate timer_ids, so a winning
      # message/signal delivery can also close the gateway's sibling timer waits.
      gw_timer_ids: %{}
    }

    acc = Enum.reduce(events, acc, &fold/2)

    ext_handles =
      Enum.map(acc.ext, fn {task_id, %{token_id: token_id}} ->
        %WaitingHandle.ExternalTask{
          instance_id: instance_id,
          tenant_id: tenant_id,
          task_id: task_id,
          token_id: token_id
        }
      end)

    timer_handles =
      Enum.map(acc.timer, fn {timer_id, info} ->
        %WaitingHandle.Timer{
          instance_id: instance_id,
          tenant_id: tenant_id,
          token_id: info.token_id,
          trigger_at: info.trigger_at,
          # Carry the DURABLE timer_id (the `TimerCreated.timer_id`) so the
          # evicted cell's fast-path `send_after` fires with the same marker the
          # resident path uses (`token_processor` arms `{:timer_elapsed, token,
          # timer_id}`). A `make_ref()` marker would leak a non-JSON-encodable
          # Reference into the persisted `TimerElapsed.timer_id`.
          timer_ref: timer_id,
          boundary_node_id: info[:boundary_node_id],
          is_boundary: info[:is_boundary] || false
        }
      end)

    call_handles =
      Enum.map(acc.call, fn {child_id, token_id} ->
        %WaitingHandle.Call{
          instance_id: instance_id,
          tenant_id: tenant_id,
          child_id: child_id,
          token_id: token_id
        }
      end)

    msg_handles =
      Enum.flat_map(acc.msg, fn {name, token_ids} ->
        Enum.map(token_ids, fn token_id ->
          %WaitingHandle.Message{
            instance_id: instance_id,
            tenant_id: tenant_id,
            message_name: name,
            business_key: business_key,
            token_id: token_id,
            keyless:
              message_wait_keyless?(definition, Map.get(acc.msg_node, {name, token_id}))
          }
        end)
      end)

    sig_handles =
      Enum.flat_map(acc.sig, fn {name, token_ids} ->
        Enum.map(token_ids, fn token_id ->
          %WaitingHandle.Signal{
            instance_id: instance_id,
            tenant_id: tenant_id,
            signal_name: name,
            token_id: token_id
          }
        end)
      end)

    # Message/signal BOUNDARY waits. Same registry key as a plain catch
    # (`{tenant, :message, name, business_key}` + `:no_key` for keyless
    # boundaries; `{tenant, :signal, name}`), carrying the boundary metadata the
    # `Timer` boundary path carries. Keyless is resolved off the BOUNDARY node
    # (mirrors event_replayer.ex `boundary_node_keyless?/2`, ~1213) — the boundary
    # node itself carries the `message.allow_keyless` annotation.
    msg_boundary_handles =
      Enum.map(acc.msg_boundary, fn {{name, token_id, boundary_node_id}, _true} ->
        %WaitingHandle.Message{
          instance_id: instance_id,
          tenant_id: tenant_id,
          message_name: name,
          business_key: business_key,
          token_id: token_id,
          boundary_node_id: boundary_node_id,
          is_boundary: true,
          keyless: message_wait_keyless?(definition, boundary_node_id)
        }
      end)

    sig_boundary_handles =
      Enum.map(acc.sig_boundary, fn {{name, token_id, boundary_node_id}, _true} ->
        %WaitingHandle.Signal{
          instance_id: instance_id,
          tenant_id: tenant_id,
          signal_name: name,
          token_id: token_id,
          boundary_node_id: boundary_node_id,
          is_boundary: true
        }
      end)

    ext_handles ++
      timer_handles ++
      call_handles ++ msg_handles ++ sig_handles ++ msg_boundary_handles ++ sig_boundary_handles
  end

  # --- Private ---

  defp safe_list_active_ids do
    try do
      EventStore.list_active_ids()
    rescue
      e ->
        Logger.error("EvictedWaitRestorer: list_active_ids failed: #{inspect(e)}")
        []
    end
  end

  defp find_start_event(events) do
    Enum.find(events, &match?(%PersistentData.ProcessInstanceStart{}, &1))
  end

  defp fold(%PersistentData.ExternalTaskCreation{} = e, acc) do
    put_in(acc.ext[e.external_task], %{token_id: e.token})
  end

  defp fold(%PersistentData.ExternalTaskCompletion{} = e, acc) do
    update_in(acc.ext, &Map.delete(&1, e.external_task))
  end

  defp fold(%PersistentData.ExternalTaskCancellation{} = e, acc) do
    update_in(acc.ext, &Map.delete(&1, e.external_task))
  end

  defp fold(%PersistentData.TimerCreated{} = e, acc) do
    put_in(
      acc.timer[e.timer_id],
      %{token_id: e.token, trigger_at: e.trigger_at}
    )
  end

  defp fold(%PersistentData.TimerElapsed{} = e, acc) do
    acc = update_in(acc.timer, &Map.delete(&1, e.timer_id))
    # NEW-1: a timer-candidate firing resolves its event gateway — close every
    # sibling candidate (message/signal/other timers) of the gateway's token.
    resolve_gateway_if_parked(acc, e.token)
  end

  defp fold(%PersistentData.TimerCanceled{} = e, acc) do
    update_in(acc.timer, &Map.delete(&1, e.timer_id))
  end

  defp fold(%PersistentData.BoundaryEventCreated{boundary_type: :timer} = e, acc) do
    put_in(
      acc.timer[e.timer_id],
      %{
        token_id: e.token,
        trigger_at: e.trigger_at,
        boundary_node_id: e.boundary_node_id,
        is_boundary: true
      }
    )
  end

  defp fold(%PersistentData.BoundaryEventTriggered{boundary_type: :timer} = e, acc) do
    update_in(acc.timer, &Map.delete(&1, e.timer_id))
  end

  defp fold(%PersistentData.BoundaryEventCancelled{boundary_type: :timer} = e, acc) do
    update_in(acc.timer, &Map.delete(&1, e.timer_id))
  end

  # Message/signal BOUNDARY events. A boundary parks its activity token on a
  # message/signal wait the SAME way a plain catch does, but it must be tracked
  # separately so a plain MessageHandled/SignalHandled (or EventGatewayResolved)
  # never drops it. Mirrors event_replayer.ex `BoundaryEventCreated` (~492) /
  # `delete_boundary_wait` (~955): keyed by `{name, token, boundary_node_id}` so
  # interrupting + non-interrupting boundaries on one token stay distinct, and
  # closed by the matching Triggered/Cancelled. The boundary `name` is the
  # message/signal name (`PersistentData.BoundaryEventCreated.name`).
  #
  # The `:timer` clauses above match the ATOM only because they are only reached
  # for in-memory events; these clauses run on DURABLE events streamed back from
  # the event store, where `PersistentData.decode/1` leaves `boundary_type` as a
  # STRING (it atomizes keys, not values). `boundary_kind/1` normalizes both forms
  # so a real (string) durable boundary and a fabricated (atom) unit-test boundary
  # route identically — the timer-atom clauses above still claim in-memory timer
  # boundaries first, and a durable `"timer"` boundary falls here and is ignored
  # (its open state is recovered via its own `TimerCreated`/timer fold).
  defp fold(%PersistentData.BoundaryEventCreated{} = e, acc) do
    case boundary_kind(e.boundary_type) do
      :message -> put_in(acc.msg_boundary[{e.name, e.token, e.boundary_node_id}], true)
      :signal -> put_in(acc.sig_boundary[{e.name, e.token, e.boundary_node_id}], true)
      _ -> acc
    end
  end

  # A message/signal boundary trigger only CLOSES the boundary wait when the
  # boundary is INTERRUPTING. A NON-INTERRUPTING boundary stays registered and
  # can fire again while the activity is still waiting, so it must remain OPEN
  # across restore — mirror the resident `EventReplayer`
  # (event_replayer.ex:545-582): `event.interrupting != false` drops the wait
  # (interrupting; `nil`/`true`), an explicit `false` keeps it. `interrupting` is
  # a plain boolean that survives `PersistentData.decode/1` unchanged (only
  # `boundary_type` is string→atom restored), so this test is identical on durable
  # and in-memory events. Cancellation below always drops it regardless.
  defp fold(%PersistentData.BoundaryEventTriggered{interrupting: false}, acc), do: acc

  defp fold(%PersistentData.BoundaryEventTriggered{} = e, acc) do
    case boundary_kind(e.boundary_type) do
      :message ->
        update_in(acc.msg_boundary, &Map.delete(&1, {e.name, e.token, e.boundary_node_id}))

      :signal ->
        update_in(acc.sig_boundary, &Map.delete(&1, {e.name, e.token, e.boundary_node_id}))

      _ ->
        acc
    end
  end

  defp fold(%PersistentData.BoundaryEventCancelled{} = e, acc) do
    case boundary_kind(e.boundary_type) do
      :message ->
        update_in(acc.msg_boundary, &Map.delete(&1, {e.name, e.token, e.boundary_node_id}))

      :signal ->
        update_in(acc.sig_boundary, &Map.delete(&1, {e.name, e.token, e.boundary_node_id}))

      _ ->
        acc
    end
  end

  defp fold(%PersistentData.CallStarted{} = e, acc) do
    put_in(acc.call[e.started_process], e.token)
  end

  defp fold(%PersistentData.CallCompleted{} = e, acc) do
    # CallCompleted/Canceled don't carry child_id directly — resolve via token.
    update_in(acc.call, fn calls ->
      Enum.reject(calls, fn {_child, token} -> token == e.token end) |> Map.new()
    end)
  end

  defp fold(%PersistentData.CallCanceled{} = e, acc) do
    update_in(acc.call, fn calls ->
      Enum.reject(calls, fn {_child, token} -> token == e.token end) |> Map.new()
    end)
  end

  defp fold(%PersistentData.MessageHandled{} = e, acc) do
    # NEW-1: when this delivery WON an event gateway (token still parked on an
    # OPEN gateway, or the event carries a selected_node), the durable winner may
    # have been persisted BEFORE EventGatewayResolved. Mirror the resident
    # EventReplayer (event_replayer.ex:601-611) and close ALL of the gateway's
    # sibling candidates (message/signal/timer), not just `e.name`.
    if not is_nil(e.selected_node) or MapSet.member?(acc.gw_tokens, e.token) do
      resolve_gateway_if_parked(acc, e.token)
    else
      update_in(acc.msg, fn m ->
        case Map.get(m, e.name) do
          nil -> m
          token_ids -> put_or_delete(m, e.name, List.delete(token_ids, e.token))
        end
      end)
    end
  end

  defp fold(%PersistentData.SignalHandled{} = e, acc) do
    # NEW-1: SignalHandled carries no selected_node, so detect a gateway win purely
    # from the parked-token set. A gateway-winning signal closes all siblings.
    if MapSet.member?(acc.gw_tokens, e.token) do
      resolve_gateway_if_parked(acc, e.token)
    else
      update_in(acc.sig, fn s ->
        case Map.get(s, e.signal_name) do
          nil -> s
          token_ids -> put_or_delete(s, e.signal_name, List.delete(token_ids, e.token))
        end
      end)
    end
  end

  # An event-based gateway does NOT emit per-candidate MessageWaitCreated /
  # SignalWaitCreated events — its message/signal candidate waits live ONLY in
  # `EventGatewayActivated.{message_names, signal_names}` (token_processor.ex
  # ~595). Mirror the resident `EventReplayer` (event_replayer.ex:326-334): open a
  # message/signal candidate wait for the gateway's token under each candidate
  # name. The timer candidate already emits its own `TimerCreated`, so it is
  # covered by the timer fold above. `current_node` is recorded per (name, token)
  # so the keyless `:no_key` opt-in can resolve the catch node, matching the
  # explicit-wait path.
  defp fold(%PersistentData.EventGatewayActivated{} = e, acc) do
    token_id = e.token

    acc =
      Enum.reduce(e.message_names || [], acc, fn name, acc ->
        acc
        |> update_in([:msg], fn m -> Map.update(m, name, [token_id], &[token_id | &1]) end)
        |> put_in([:msg_node, {name, token_id}], e.current_node)
      end)

    acc =
      Enum.reduce(e.signal_names || [], acc, fn name, acc ->
        update_in(acc.sig, fn s -> Map.update(s, name, [token_id], &[token_id | &1]) end)
      end)

    # NEW-1: remember this token is parked on an OPEN gateway and which timer_ids
    # are its candidates, so a winning delivery can close the whole gateway.
    acc
    |> Map.update!(:gw_tokens, &MapSet.put(&1, token_id))
    |> put_in([:gw_timer_ids, token_id], MapSet.new(e.timer_ids || []))
  end

  # A resolved gateway closes EVERY candidate branch for its token (exactly one
  # branch wins). Mirror `EventReplayer` (event_replayer.ex:362-363): drop the
  # token from all message AND signal candidate waits. The timer candidate is
  # closed by its own `TimerElapsed`/`TimerCanceled`. A token is parked in at
  # most one wait construct at a time, so removing it from every name is safe.
  defp fold(%PersistentData.EventGatewayResolved{} = e, acc) do
    resolve_gateway_if_parked(acc, e.token)
  end

  # Explicit wait-creation events (from per-transition persistence, agent 1).
  # We match by struct name so we don't require the struct to exist in this
  # codebase at compile time.
  defp fold(%{__struct__: mod} = e, acc) do
    case Module.split(mod) |> List.last() do
      "MessageWaitCreated" ->
        name = Map.get(e, :name) || Map.get(e, :message_name)
        token_id = Map.get(e, :token)

        if name && token_id do
          acc
          |> update_in([:msg], fn m ->
            Map.update(m, name, [token_id], &[token_id | &1])
          end)
          |> put_in([:msg_node, {name, token_id}], Map.get(e, :current_node))
        else
          acc
        end

      "SignalWaitCreated" ->
        name = Map.get(e, :signal_name) || Map.get(e, :name)
        token_id = Map.get(e, :token)

        if name && token_id do
          update_in(acc.sig, fn s ->
            Map.update(s, name, [token_id], &[token_id | &1])
          end)
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp fold(_other, acc), do: acc

  defp put_or_delete(map, key, []), do: Map.delete(map, key)
  defp put_or_delete(map, key, list), do: Map.put(map, key, list)

  # Normalize a `boundary_type` that may be an ATOM (fabricated/in-memory event)
  # or a STRING (durable event decoded from JSON — `PersistentData.decode/1`
  # atomizes keys, not values). Only `:message`/`:signal` are routed here; timer
  # boundaries are handled by their atom-specific clauses / the timer fold.
  defp boundary_kind(:message), do: :message
  defp boundary_kind("message"), do: :message
  defp boundary_kind(:signal), do: :signal
  defp boundary_kind("signal"), do: :signal
  defp boundary_kind(_), do: :other

  # NEW-1: close every candidate wait of an event gateway for `token_id`. Mirrors
  # the resident sibling-close (EventReplayer EventGatewayResolved / E4
  # MessageHandled): exactly one branch wins, so all message + signal candidates,
  # and the gateway's timer candidates, are cancelled. Un-parks the token so a
  # later loop re-activation is unaffected. Safe to call when the token is not
  # tracked (no timer candidates removed) — preserves the prior unconditional
  # msg/sig close on EventGatewayResolved.
  defp resolve_gateway_if_parked(acc, token_id) do
    gw_timer_ids = Map.get(acc.gw_timer_ids, token_id, MapSet.new())

    acc
    |> Map.update!(:msg, &remove_token_from_all_waits(&1, token_id))
    |> Map.update!(:sig, &remove_token_from_all_waits(&1, token_id))
    |> Map.update!(:timer, fn timers ->
      Map.reject(timers, fn {timer_id, _info} -> MapSet.member?(gw_timer_ids, timer_id) end)
    end)
    |> Map.update!(:gw_tokens, &MapSet.delete(&1, token_id))
    |> Map.update!(:gw_timer_ids, &Map.delete(&1, token_id))
  end

  # Drop `token_id` from every name in a `%{name => [token_ids]}` wait map,
  # pruning names whose list becomes empty. Used to close all candidate waits of
  # an event gateway when it resolves.
  defp remove_token_from_all_waits(map, token_id) do
    Enum.reduce(map, %{}, fn {name, token_ids}, acc ->
      case List.delete(token_ids, token_id) do
        [] -> acc
        remaining -> Map.put(acc, name, remaining)
      end
    end)
  end

  # Tenant + business key for the evicted cell, taken from the start event.
  # Tenant defaults to the same nil-uuid `collect_open_waits/1` uses so the
  # registered wait keys agree with the reconstructed handles.
  defp identity(events) do
    start = find_start_event(events)
    tenant_id = (start && start.tenant) || "00000000-0000-0000-0000-000000000000"
    business_key = start && start.business_key
    {tenant_id, business_key}
  end

  # Load the instance's Definition (for the keyless `:no_key` opt-in) from the
  # start event's process name/version. Returns nil if the diagram is unknown —
  # `collect_open_waits/2` then treats every message wait as keyed, which is the
  # safe default (a keyed wait simply never joins `:no_key`).
  defp resolve_definition(events) do
    case find_start_event(events) do
      %PersistentData.ProcessInstanceStart{
        process_name: name,
        process_version: version,
        tenant: tenant
      }
      when is_binary(name) ->
        case DiagramStore.get(name, version, tenant || "00000000-0000-0000-0000-000000000000") do
          {:ok, definition} -> definition
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  # B'.5 keyless opt-in on boot-restore. Mirrors event_replayer.ex
  # `node_message_keyless?/1`: a plain message catch joins `:no_key` only when its
  # node carries `message.allow_keyless: true`. Without a definition (or node id)
  # we default to keyed — never mis-route a keyed wait under `:no_key`.
  defp message_wait_keyless?(nil, _node_id), do: false
  defp message_wait_keyless?(_definition, nil), do: false

  defp message_wait_keyless?(definition, node_id) do
    case Definition.get_node(definition, node_id) do
      nil -> false
      node -> match?(%{allow_keyless: true}, Map.get(node, :message) || %{})
    end
  end
end
