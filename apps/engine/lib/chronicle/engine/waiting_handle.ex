defmodule Chronicle.Engine.WaitingHandle do
  @moduledoc """
  Lightweight structs representing what an evicted process instance is waiting for.
  When an instance is evicted from memory, WaitingHandles are kept in the
  InstanceLoadCell so that incoming events can trigger a restore.
  """

  defmodule Timer do
    @moduledoc false
    defstruct [:instance_id, :tenant_id, :token_id, :trigger_at, :timer_ref,
               :boundary_node_id, :is_boundary]
  end

  defmodule ExternalTask do
    @moduledoc false
    defstruct [:instance_id, :tenant_id, :task_id, :token_id]
  end

  defmodule Message do
    @moduledoc false
    # `keyless` mirrors the resident `:waits` opt-in (B'.5): a catch declared
    # keyless (`message.allow_keyless: true`) ALSO registers under the
    # `{tenant, :message, name, :no_key}` secondary index so a nil-key inbound
    # can correlate. Keyed catches keep `keyless: false` and never join `:no_key`.
    #
    # `boundary_node_id`/`is_boundary` carry the same boundary metadata the
    # `Timer` handle does: when this wait is a message BOUNDARY (vs a plain
    # intermediate catch) `is_boundary` is true and `boundary_node_id` names the
    # boundary node. Registration keys are identical to a plain catch
    # (`{tenant, :message, name, business_key}` + the `:no_key` opt-in), so the
    # boundary metadata is informational only — the wake still restores the
    # instance, whose replay reconstructs the boundary registration.
    defstruct [:instance_id, :tenant_id, :message_name, :business_key, :token_id, :wait_id,
               :boundary_node_id, keyless: false, is_boundary: false]
  end

  defmodule Signal do
    @moduledoc false
    # `boundary_node_id`/`is_boundary` mirror the `Message` handle for a signal
    # BOUNDARY event (see the `Message` doc above).
    defstruct [:instance_id, :tenant_id, :signal_name, :token_id,
               :boundary_node_id, is_boundary: false]
  end

  defmodule Call do
    @moduledoc false
    defstruct [:instance_id, :tenant_id, :child_id, :token_id]
  end
end
