defmodule Chronicle.Engine.Token do
  @moduledoc """
  Token struct and state machine (pure functions).
  Represents a single execution thread within a process instance.
  Maps to TokenV2 from the .NET engine.
  """

  @type state ::
    :execute_current_node | :move_to_next_node | :continue |
    :waiting_for_timer | :waiting_for_message | :waiting_for_signal |
    :waiting_for_script | :waiting_for_call | :waiting_for_external_task |
    :waiting_for_join | :waiting_for_rules | :waiting_for_expressions |
    :interrupted | :crashed | :terminated | :joined | :completed |
    :simulation_barrier_then_execute | :simulation_barrier_then_wait

  @type t :: %__MODULE__{
    id: non_neg_integer(),
    family: non_neg_integer(),
    state: state(),
    current_node: non_neg_integer(),
    next_node: non_neg_integer() | nil,
    parameters: map(),
    context: context()
  }

  @type context :: %{
    step: non_neg_integer(),
    retries: non_neg_integer(),
    continuation_context: term() | nil,
    script_state: String.t() | nil,
    external_task_id: String.t() | nil,
    intermediate_timer_id: String.t() | nil,
    boundary_timers: [{String.t(), non_neg_integer()}],
    is_awaitable_script_waiting: boolean()
  }

  defstruct [
    :id,
    :family,
    state: :execute_current_node,
    current_node: 0,
    next_node: nil,
    parameters: %{},
    context: %{
      step: 0,
      retries: 0,
      continuation_context: nil,
      script_state: nil,
      external_task_id: nil,
      intermediate_timer_id: nil,
      boundary_timers: [],
      is_awaitable_script_waiting: false
    }
  ]

  def new(id, family, node_id, params \\ %{}) do
    %__MODULE__{
      id: id,
      family: family,
      state: :execute_current_node,
      current_node: node_id,
      parameters: params
    }
  end

  def move_to(%__MODULE__{} = token, next_node_id) do
    %{token | state: :move_to_next_node, next_node: next_node_id}
  end

  def advance(%__MODULE__{} = token) do
    %{token |
      state: :execute_current_node,
      current_node: token.next_node,
      next_node: nil
    }
  end

  def set_waiting(%__MODULE__{} = token, wait_type) do
    %{token | state: wait_type}
  end

  def continue(%__MODULE__{} = token) do
    %{token | state: :continue}
  end

  def complete(%__MODULE__{} = token) do
    %{token | state: :completed}
  end

  def crash(%__MODULE__{} = token) do
    %{token | state: :crashed}
  end

  def terminate(%__MODULE__{} = token) do
    %{token | state: :terminated}
  end

  def interrupt(%__MODULE__{} = token) do
    %{token | state: :interrupted}
  end

  def join(%__MODULE__{} = token) do
    %{token | state: :joined}
  end

  def set_context(%__MODULE__{} = token, key, value) do
    %{token | context: Map.put(token.context, key, value)}
  end

  def increment_step(%__MODULE__{} = token) do
    %{token | context: Map.update!(token.context, :step, &(&1 + 1))}
  end

  def increment_retries(%__MODULE__{} = token) do
    %{token | context: Map.update!(token.context, :retries, &(&1 + 1))}
  end

  def active?(token), do: token.state in [:execute_current_node, :move_to_next_node, :continue]

  def waiting?(token), do: token.state in [
    :waiting_for_timer, :waiting_for_message, :waiting_for_signal,
    :waiting_for_script, :waiting_for_call, :waiting_for_external_task,
    :waiting_for_join, :waiting_for_rules, :waiting_for_expressions
  ]

  def terminal?(token), do: token.state in [:crashed, :terminated, :completed, :joined]
end
