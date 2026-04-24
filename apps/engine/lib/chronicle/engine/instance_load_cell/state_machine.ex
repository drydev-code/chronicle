defmodule Chronicle.Engine.InstanceLoadCell.StateMachine do
  @moduledoc """
  Pure state transition logic for InstanceLoadCell.

  State machine:
    :resident -> :evicting -> :evicted -> :restore_requested -> :restoring -> :resident

  All functions are pure - they validate transitions and return new states
  without performing side effects.
  """

  @type cell_state :: :resident | :evicting | :evicted | :restore_requested | :restoring

  @valid_transitions %{
    resident: [:evicting],
    evicting: [:evicted],
    evicted: [:restore_requested],
    restore_requested: [:restoring],
    restoring: [:resident]
  }

  @doc "Attempt a state transition. Returns {:ok, new_state} or {:error, reason}."
  @spec transition(cell_state(), cell_state()) :: {:ok, cell_state()} | {:error, term()}
  def transition(current, target) do
    allowed = Map.get(@valid_transitions, current, [])

    if target in allowed do
      {:ok, target}
    else
      {:error, {:invalid_transition, current, target}}
    end
  end

  @doc "Returns true if the cell is in a state where messages should be queued."
  @spec queuing?(cell_state()) :: boolean()
  def queuing?(state) when state in [:evicted, :restore_requested, :restoring, :evicting], do: true
  def queuing?(_), do: false

  @doc "Returns true if a restore should be triggered (only from :evicted)."
  @spec should_restore?(cell_state()) :: boolean()
  def should_restore?(:evicted), do: true
  def should_restore?(_), do: false

  @doc "Returns true if the cell is in a state that accepts restore completion."
  @spec restore_completable?(cell_state()) :: boolean()
  def restore_completable?(state) when state in [:restoring, :restore_requested], do: true
  def restore_completable?(_), do: false

  @doc "Returns true if the cell can be evicted (only from :resident)."
  @spec evictable?(cell_state()) :: boolean()
  def evictable?(:resident), do: true
  def evictable?(_), do: false

  @doc "Returns true when the instance is resident and messages pass through directly."
  @spec resident?(cell_state()) :: boolean()
  def resident?(:resident), do: true
  def resident?(_), do: false
end
