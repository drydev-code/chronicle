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
    defstruct [:instance_id, :tenant_id, :message_name, :business_key, :token_id]
  end

  defmodule Signal do
    @moduledoc false
    defstruct [:instance_id, :tenant_id, :signal_name, :token_id]
  end

  defmodule Call do
    @moduledoc false
    defstruct [:instance_id, :tenant_id, :child_id, :token_id]
  end
end
