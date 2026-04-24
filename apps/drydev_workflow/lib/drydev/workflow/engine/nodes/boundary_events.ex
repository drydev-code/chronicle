defmodule DryDev.Workflow.Engine.Nodes.BoundaryEvents do
  @moduledoc """
  All boundary event types: Timer, Message, Signal, Error.
  Both interrupting and non-interrupting variants.
  """

  defmodule TimerBoundary do
    @moduledoc "Interrupting timer boundary event."
    defstruct [:id, :key, :timer_config, :variable_name, :attached_to, :outputs, :properties]
  end

  defmodule MessageBoundary do
    @moduledoc "Interrupting message boundary event."
    defstruct [:id, :key, :message, :attached_to, :outputs, :properties]
  end

  defmodule SignalBoundary do
    @moduledoc "Interrupting signal boundary event."
    defstruct [:id, :key, :signal, :attached_to, :outputs, :properties]
  end

  defmodule ErrorBoundary do
    @moduledoc "Error boundary event (always interrupting)."
    defstruct [:id, :key, :exception_type, :error_msg, :attached_to, :outputs, :properties]
  end

  defmodule EscalationBoundary do
    @moduledoc "Escalation boundary event (interrupting)."
    defstruct [:id, :key, :escalation, :attached_to, :outputs, :properties]
  end

  defmodule NonInterruptingTimerBoundary do
    @moduledoc "Non-interrupting timer boundary event (recurring)."
    defstruct [:id, :key, :timer_config, :variable_name, :repetition_count, :attached_to, :outputs, :properties]
  end

  defmodule NonInterruptingMessageBoundary do
    @moduledoc "Non-interrupting message boundary event."
    defstruct [:id, :key, :message, :attached_to, :outputs, :properties]
  end

  defmodule NonInterruptingSignalBoundary do
    @moduledoc "Non-interrupting signal boundary event."
    defstruct [:id, :key, :signal, :attached_to, :outputs, :properties]
  end

  @doc "Get the output path from a boundary event."
  def output_path(boundary_event) do
    List.first(boundary_event.outputs || [])
  end

  @doc "Check if a boundary event is interrupting."
  def interrupting?(%TimerBoundary{}), do: true
  def interrupting?(%MessageBoundary{}), do: true
  def interrupting?(%SignalBoundary{}), do: true
  def interrupting?(%ErrorBoundary{}), do: true
  def interrupting?(%EscalationBoundary{}), do: true
  def interrupting?(_), do: false

  @doc "Compute timer delay from boundary event config."
  def compute_timer_delay(%{timer_config: config, variable_name: var_name}, params) do
    if var_name do
      # Dynamic timer from variables
      case Map.get(params, var_name) do
        ms when is_integer(ms) -> ms
        str when is_binary(str) -> String.to_integer(str)
        _ -> compute_from_config(config)
      end
    else
      compute_from_config(config)
    end
  end

  defp compute_from_config(%{duration_ms: ms}), do: ms
  defp compute_from_config(%{interval_ms: ms}), do: ms
  defp compute_from_config(%{period: %{hours: h, minutes: m, seconds: s}}),
    do: (h || 0) * 3_600_000 + (m || 0) * 60_000 + (s || 0) * 1000
  defp compute_from_config(_), do: 1000
end
