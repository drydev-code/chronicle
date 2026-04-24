defmodule Chronicle.Engine.EvictedWaitRestorer do
  @moduledoc """
  Reconstructs open wait handles from a persisted event stream.

  NOT currently wired into startup. `Chronicle.Supervisor.restore_active_instances/0`
  brings active instances back resident, covering their waits via the normal
  `InstanceLoadCell` registration path. This module will be revisited when
  high-scale deployments need to restart with evicted-only routing (without
  re-materialising every instance). At that point, restoration must:

  1. Start a supervised evicted `InstanceLoadCell` per instance.
  2. Register waits from the load cell GenServer (registry value = cell pid).
  3. Cover external task, timer, and call waits — not just message/signal.

  The pure collection logic — `collect_open_waits/1` — is already covered by
  unit tests and is the primary test surface.
  """

  require Logger

  alias Chronicle.Engine.{PersistentData, WaitingHandle}
  alias Chronicle.Persistence.EventStore

  @type wait ::
          WaitingHandle.ExternalTask.t()
          | WaitingHandle.Timer.t()
          | WaitingHandle.Message.t()
          | WaitingHandle.Signal.t()
          | WaitingHandle.Call.t()

  @doc """
  Scan every active instance and re-register its outstanding waits in
  `:evicted_waits`.

  Safe to call repeatedly — `Registry.register/3` for duplicate-key registries
  allows the same pid to register the same key multiple times (entries are
  keyed by `{key, pid}`); duplicates are harmless because dispatch only cares
  about the value.
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
  Restore waits for a single active instance.

  Returns the number of waits registered, or `{:error, reason}` when the
  instance cannot be read.
  """
  def restore_waits_for(instance_id) do
    case EventStore.stream(instance_id) do
      {:ok, events} ->
        waits = collect_open_waits(events)
        register_waits(waits)
        length(waits)

      {:error, reason} ->
        Logger.warning(
          "EvictedWaitRestorer: cannot stream #{instance_id}: #{inspect(reason)}"
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

  Message and signal waits are only reconstructed from *explicit* wait
  creation events (`MessageWaitCreated`, `SignalWaitCreated`) — these are
  produced by the per-transition persistence change owned by another agent.
  Events of unknown type are ignored.
  """
  def collect_open_waits(events) when is_list(events) do
    start = find_start_event(events)
    instance_id = start && start.process_instance_id
    tenant_id = (start && start.tenant) || "00000000-0000-0000-0000-000000000000"
    business_key = start && start.business_key

    acc = %{
      ext: %{},
      timer: %{},
      call: %{},
      msg: %{},
      sig: %{}
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
      Enum.map(acc.timer, fn {_timer_id, info} ->
        %WaitingHandle.Timer{
          instance_id: instance_id,
          tenant_id: tenant_id,
          token_id: info.token_id,
          trigger_at: info.trigger_at,
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
            token_id: token_id
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

    ext_handles ++ timer_handles ++ call_handles ++ msg_handles ++ sig_handles
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
    update_in(acc.timer, &Map.delete(&1, e.timer_id))
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
    update_in(acc.msg, fn m ->
      case Map.get(m, e.name) do
        nil -> m
        token_ids -> put_or_delete(m, e.name, List.delete(token_ids, e.token))
      end
    end)
  end

  defp fold(%PersistentData.SignalHandled{} = e, acc) do
    update_in(acc.sig, fn s ->
      case Map.get(s, e.signal_name) do
        nil -> s
        token_ids -> put_or_delete(s, e.signal_name, List.delete(token_ids, e.token))
      end
    end)
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
          update_in(acc.msg, fn m ->
            Map.update(m, name, [token_id], &[token_id | &1])
          end)
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

  defp register_waits(waits) do
    Enum.each(waits, fn
      %WaitingHandle.Message{} = h ->
        safe_register(
          {h.tenant_id, :message, h.message_name, h.business_key},
          {h.instance_id, h}
        )

      %WaitingHandle.Signal{} = h ->
        safe_register({h.tenant_id, :signal, h.signal_name}, {h.instance_id, h})

      _ ->
        :ok
    end)
  end

  defp safe_register(key, value) do
    try do
      Registry.register(:evicted_waits, key, value)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
