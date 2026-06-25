defmodule Chronicle.Engine.PersistentData do
  @moduledoc """
  All 17 PersistentData types for event sourcing.
  Each struct carries the data needed for restoration/replay.

  ## ADDITIVE-ONLY field discipline (rolling-deploy / schema-evolution invariant)

  Event struct fields may ONLY be ADDED. They must NEVER be removed, renamed, or
  retyped, and a newly added field must NEVER become *required* for replay — every
  field must remain optional (decode to `nil` when absent) and replay must tolerate
  a `nil` value for it. This discipline, together with the tolerant codec below,
  keeps schema evolution forward- AND backward-safe across a mixed-version fleet:

    * NEW reads OLD — a struct missing a freshly added field decodes with that field
      `nil` (`struct/2` defaults missing keys), and replay handles the `nil`.
    * OLD reads NEW — `decode/1` is tolerant of UNKNOWN map KEYS (dropped via
      `atomize_keys/1` instead of raising, equivalent to "old code ignores fields it
      does not know") and of UNKNOWN event TYPES (an `%Unknown{}` sentinel instead of
      `UndefinedFunctionError`), so an old release never crashes on a newer release's
      events. Replay/fold log-and-skip an `%Unknown{}` event without mutating state.

  A genuinely NON-additive change would require an explicit per-event version tag
  (insertion point noted in `encode/1`) and a migration — it is NOT covered by the
  tolerant codec.
  """

  defmodule Base do
    @moduledoc "Common fields for persistent data."
    defstruct [:token, :family, :current_node, :timestamp]
  end

  defmodule Unknown do
    @moduledoc """
    Sentinel for an event whose `"type"` this release does not know (e.g. a newer
    version's struct). `decode/1` returns `%Unknown{}` instead of raising
    `UndefinedFunctionError`, and replay/fold log-and-skip it without mutating state.
    Carries the original `raw` map so it can be re-encoded losslessly if needed.
    """
    defstruct [:type, :raw]
  end

  defmodule ProcessInstanceStart do
    defstruct [
      :process_instance_id, :business_key, :tenant, :parent_id,
      :parent_business_key, :root_id, :root_business_key,
      :process_name, :process_version, :start_node_id,
      :started_by_engine, :start_parameters,
      :call_token, :call_family, :call_node,
      token: 0, family: 0, current_node: 0
    ]
  end

  defmodule TokenFamilyCreated do
    defstruct [:token, :family, :current_node, :start_params]
  end

  defmodule TokenFamilyRemoved do
    defstruct [:token, :family, :current_node]
  end

  defmodule ExternalTaskCreation do
    defstruct [:token, :family, :current_node, :external_task, :retry_counter, :actor_type]
  end

  defmodule ExternalTaskCompletion do
    defstruct [
      :token, :family, :current_node, :external_task,
      :successful, :next_node, :payload, :result, :error, :retry_counter
    ]
  end

  defmodule ExternalTaskCancellation do
    defstruct [
      :token, :family, :current_node, :external_task,
      :cancellation_reason, :continuation_node_id, :retry_counter
    ]
  end

  defmodule TimerCreated do
    defstruct [:token, :family, :current_node, :trigger_at, :timer_id, :target_node]
  end

  defmodule TimerElapsed do
    defstruct [:token, :family, :current_node, :target_node, :retry_counter, :timer_id, :triggered_at]
  end

  defmodule TimerCanceled do
    defstruct [:token, :family, :current_node, :target_node, :retry_counter, :timer_id]
  end

  defmodule MessageWaitCreated do
    defstruct [:token, :family, :current_node, :name, :business_key, :wait_id]
  end

  defmodule SignalWaitCreated do
    defstruct [:token, :family, :current_node, :signal_name]
  end

  defmodule EventGatewayActivated do
    defstruct [
      :token, :family, :current_node, :message_names, :signal_names,
      :timer_ids, :trigger_at_by_timer_id,
      # wait_id: durable wait-activation id minted once for this gateway
      # activation. The gateway's message/signal candidate waits share this id
      # (the gateway resolves to exactly one branch).
      :wait_id
    ]
  end

  defmodule EventGatewayResolved do
    defstruct [
      :token, :family, :current_node, :trigger_type, :trigger_name,
      :selected_node, :target_node, :payload, :triggered_at,
      # wait_id: the durable gateway wait occurrence this resolution consumed.
      # Carried so the retention store can write a per-occurrence consumption row
      # and replay can correlate by wait_id (NOT token_id, which a loop reuses).
      :wait_id
    ]
  end

  defmodule ConditionalEventWaitCreated do
    defstruct [:token, :family, :current_node, :condition, :condition_key]
  end

  defmodule ConditionalEventEvaluated do
    defstruct [:token, :family, :current_node, :condition, :matched, :target_node, :evaluated_at]
  end

  defmodule LoopConditionEvaluated do
    defstruct [
      :token, :family, :current_node, :condition, :iteration,
      :continue, :max_iterations, :target_node, :evaluated_at
    ]
  end

  defmodule VariablesUpdated do
    defstruct [:token, :family, :current_node, :variables, :updated_at]
  end

  defmodule LinkTraversed do
    defstruct [:token, :family, :current_node, :link_name, :target_node]
  end

  defmodule NoOpTaskCompleted do
    defstruct [:token, :family, :current_node, :task_type, :target_node]
  end

  defmodule BoundaryEventCreated do
    defstruct [
      :token, :family, :current_node, :boundary_node_id, :boundary_type,
      :interrupting, :name, :condition, :timer_id, :trigger_at,
      # wait_id: durable wait-activation id for a message boundary occurrence.
      :wait_id
    ]
  end

  defmodule BoundaryEventTriggered do
    defstruct [
      :token, :family, :current_node, :boundary_node_id, :boundary_type,
      :interrupting, :name, :condition, :timer_id, :triggered_at,
      # wait_id: the durable boundary wait occurrence this trigger consumed.
      :wait_id
    ]
  end

  defmodule BoundaryEventCancelled do
    defstruct [
      :token, :family, :current_node, :boundary_node_id, :boundary_type,
      :name, :condition, :timer_id
    ]
  end

  defmodule CompensationHandlerRegistered do
    defstruct [:token, :family, :current_node, :boundary_node_id, :handler_node_id]
  end

  defmodule CompensatableActivityCompleted do
    defstruct [:token, :family, :current_node, :activity_node_id, :handler_node_id, :activity_instance_key]
  end

  defmodule CompensationRequested do
    defstruct [:token, :family, :current_node, :eligible_activity_keys, :requested_at]
  end

  defmodule CompensationHandlerStarted do
    defstruct [:token, :family, :current_node, :activity_instance_key, :handler_node_id, :handler_token]
  end

  defmodule CompensationHandlerCompleted do
    defstruct [:token, :family, :current_node, :activity_instance_key, :handler_node_id]
  end

  defmodule MessageThrown do
    defstruct [:token, :family, :current_node, :name]
  end

  defmodule MessageHandled do
    defstruct [
      :token, :family, :current_node, :name, :target_node, :retry_counter, :payload,
      # wait_id: the durable wait occurrence this delivery consumed. Replay removes
      # the open wait by wait_id (NOT token_id) so a loop-back to the same catch is
      # not mistakenly closed.
      :wait_id,
      # selected_node: when the consumed wait belongs to an event-based gateway, the
      # branch node the message selected. On crash-replay of only MessageHandled,
      # replay closes the non-selected sibling gateway waits using this.
      :selected_node
    ]
  end

  defmodule SignalThrown do
    defstruct [:token, :family, :current_node, :signal_name]
  end

  defmodule SignalHandled do
    defstruct [:token, :family, :current_node, :signal_name, :target_node, :retry_counter]
  end

  defmodule EscalationThrown do
    defstruct [:token, :family, :current_node]
  end

  defmodule CallStarted do
    defstruct [:token, :family, :current_node, :started_process, :loop_index]
  end

  defmodule CallCompleted do
    defstruct [:token, :family, :current_node, :completion_context, :successful, :next_node, :loop_index]
  end

  defmodule CallCanceled do
    defstruct [:token, :family, :current_node, :next_node]
  end

  defmodule ProcessInstanceMigrated do
    defstruct [:from_version, :to_version, :node_mappings, :migrated_tokens]
  end

  @doc "Encode persistent data to a JSON-compatible map."
  def encode(%{__struct__: module} = data) do
    type = module |> Module.split() |> List.last()
    # (deferred) NON-additive schema-version insertion point: a future
    # non-additive change would stamp `|> Map.put(:v, <n>)` here and branch on it
    # in `decode/1`. Not added now — the codec is additive-only (see @moduledoc).
    data
    |> Map.from_struct()
    |> normalize_for_json()
    |> Map.put(:type, type)
  end

  @doc """
  Decode a map back to a persistent data struct.

  Tolerant of forward schema evolution: an UNKNOWN event `"type"` (a struct this
  release does not have) yields `%Unknown{}` rather than raising, and UNKNOWN map
  KEYS are dropped by `atomize_keys/1` rather than raising (see @moduledoc).
  """
  def decode(%{"type" => type} = map) do
    case safe_concat(type) do
      {:ok, module} ->
        module |> struct(atomize_keys(map)) |> restore_value_atoms()

      :error ->
        %Unknown{type: type, raw: map}
    end
  end

  # Resolve `type` to a compiled PersistentData submodule WITHOUT raising AND
  # WITHOUT interning a new atom from the untrusted persisted `"type"` string. An
  # unknown type (a newer release's event struct) returns `:error` so `decode/1`
  # falls back to `%Unknown{}` instead of `UndefinedFunctionError`.
  #
  # SECURITY (atom-table-exhaustion DoS): the prior `Module.concat/1` CREATED the
  # `Chronicle.Engine.PersistentData.<type>` atom before checking whether it was a
  # real module, so a corrupt/hostile event blob carrying many distinct unknown
  # `"type"` strings could exhaust the (non-GC'd) atom table. `Module.safe_concat/1`
  # builds the joined atom ONLY if it already exists, else raises `ArgumentError`,
  # which we rescue to `:error` — so an unknown/never-loaded type never mints a new
  # atom. `Code.ensure_loaded?` + `function_exported?` then confirm the resolved
  # atom is a real, compiled PersistentData struct. Known types still resolve.
  defp safe_concat(type) when is_binary(type) do
    module = Module.safe_concat([__MODULE__, type])

    if Code.ensure_loaded?(module) and function_exported?(module, :__struct__, 0) do
      {:ok, module}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  defp safe_concat(_), do: :error

  # `atomize_keys/1` atomizes map KEYS only; a few fields carry ATOM *values*
  # (encoded to JSON strings) that consumers pattern-match as atoms. Restore them
  # on decode so the durable form matches the in-memory form. `boundary_type`
  # (`:timer`/`:message`/`:signal`/`:conditional`/...) is pattern-matched as an
  # atom by the resident `EventReplayer` (event_replayer.ex ~496/~949), by
  # `boundary_lifecycle`, and by `EvictedWaitRestorer` — without this, a boundary
  # streamed back from storage carried `boundary_type: "message"` and silently
  # failed every `== :message` / `boundary_type: :message` match, so boundary
  # message/signal waits were NOT reconstructed on restore.
  defp restore_value_atoms(%mod{boundary_type: bt} = event)
       when mod in [BoundaryEventCreated, BoundaryEventTriggered, BoundaryEventCancelled] and
              is_binary(bt) do
    %{event | boundary_type: safe_to_atom(bt)}
  end

  defp restore_value_atoms(event), do: event

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp safe_to_atom(value), do: value

  # Atomize map KEYS for `struct/2`. UNKNOWN keys (a binary the running release
  # never compiled as an atom — e.g. a newer version's field) are DROPPED, not
  # raised: `struct/2` already ignores keys that aren't struct fields, so dropping
  # is exactly equivalent to "old code ignores fields it doesn't know about" and is
  # behaviour-preserving for every KNOWN key. We keep `to_existing_atom` (via
  # `safe_existing_atom/1`) and never fall back to `String.to_atom` — that would be
  # an atom-table-exhaustion DoS on attacker- or future-controlled keys.
  defp atomize_keys(map) do
    Enum.reduce(map, %{}, fn
      {"type", _}, acc ->
        acc

      {k, v}, acc when is_binary(k) ->
        case safe_existing_atom(k) do
          {:ok, atom} -> Map.put(acc, atom, v)
          :error -> acc
        end

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  defp safe_existing_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  defp normalize_for_json(%{__struct__: module} = data) do
    type = module |> Module.split() |> List.last()

    data
    |> Map.from_struct()
    |> normalize_for_json()
    |> Map.put(:type, type)
  end

  defp normalize_for_json(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, normalize_for_json(value)} end)
  end

  defp normalize_for_json(list) when is_list(list), do: Enum.map(list, &normalize_for_json/1)
  defp normalize_for_json(value), do: value
end
