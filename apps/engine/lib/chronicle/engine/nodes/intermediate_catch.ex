defmodule Chronicle.Engine.Nodes.IntermediateCatch do
  @moduledoc "Intermediate catching events: Timer, Message, Signal, Conditional, Link."

  defmodule TimerEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :timer_config, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      if context.simulation_mode do
        handle_simulation(context)
      else
        timer_id = UUID.uuid4()
        delay_ms = compute_delay(context.node.timer_config)
        NodeResult.wait_for_timer(timer_id, delay_ms)
      end
    end

    @impl true
    def continue_after_wait(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end

    defp compute_delay(%{duration_ms: ms}), do: ms
    defp compute_delay(%{period: period}), do: period_to_ms(period)
    defp compute_delay(_), do: 1000

    defp period_to_ms(%{hours: h, minutes: m, seconds: s}),
      do: (h || 0) * 3_600_000 + (m || 0) * 60_000 + (s || 0) * 1000
    defp period_to_ms(_), do: 1000

    defp handle_simulation(context) do
      {event, _ctx} = ExecutionContext.next_simulation_event(context)
      case event do
        %Chronicle.Engine.PersistentData.TimerElapsed{} ->
          first_output = List.first(context.node.outputs || [])
          NodeResult.next(first_output)
        _ ->
          NodeResult.simulation_barrier_then_wait(:waiting_for_timer)
      end
    end
  end

  defmodule MessageEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :message, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      if context.simulation_mode do
        handle_simulation(context)
      else
        name = resolve_message_name(context.node.message, context.token.parameters)
        NodeResult.wait_for_message(name)
      end
    end

    @impl true
    def continue_after_wait(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end

    defp resolve_message_name(%{static_text: text, variable_content: var}, params) when not is_nil(var) do
      variable_value = Map.get(params, var, "")
      "#{text}##{variable_value}"
    end
    defp resolve_message_name(%{name: name}, _params), do: name
    defp resolve_message_name(name, _params) when is_binary(name), do: name

    defp handle_simulation(context) do
      {event, _ctx} = ExecutionContext.next_simulation_event(context)
      case event do
        %Chronicle.Engine.PersistentData.MessageHandled{} ->
          first_output = List.first(context.node.outputs || [])
          NodeResult.next(first_output)
        _ ->
          NodeResult.simulation_barrier_then_wait(:waiting_for_message)
      end
    end
  end

  defmodule SignalEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :signal, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      if context.simulation_mode do
        handle_simulation(context)
      else
        NodeResult.wait_for_signal(context.node.signal)
      end
    end

    @impl true
    def continue_after_wait(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end

    defp handle_simulation(context) do
      {event, _ctx} = ExecutionContext.next_simulation_event(context)
      case event do
        %Chronicle.Engine.PersistentData.SignalHandled{} ->
          first_output = List.first(context.node.outputs || [])
          NodeResult.next(first_output)
        _ ->
          NodeResult.simulation_barrier_then_wait(:waiting_for_signal)
      end
    end
  end

  defmodule ConditionalEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :condition, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      condition = context.node.condition

      if condition in [nil, "", true] do
        first_output = List.first(context.node.outputs || [])
        {:conditional_event_evaluated, condition, true, first_output}
      else
        ref = make_ref()

        Chronicle.Engine.Scripting.ScriptPool.execute_expressions(
          ref,
          [{context.node.id, condition}],
          context.token.parameters,
          context.instance_pid
        )

        NodeResult.wait_for_expressions(ref)
      end
    end

    @impl true
    def continue_after_wait(context) do
      matched? =
        context.token.context.continuation_context
        |> normalize_result(context.node.id)

      first_output = List.first(context.node.outputs || [])
      {:conditional_event_evaluated, context.node.condition, matched?, first_output}
    end

    defp normalize_result({:ok, results}, node_id), do: normalize_result(results, node_id)

    defp normalize_result(results, node_id) when is_list(results) do
      Enum.any?(results, fn
        %{"node_id" => ^node_id, "result" => true} -> true
        {^node_id, true} -> true
        true -> true
        _ -> false
      end)
    end

    defp normalize_result(true, _node_id), do: true
    defp normalize_result(_, _node_id), do: false
  end

  defmodule LinkEvent do
    use Chronicle.Engine.Nodes.Node
    defstruct [:id, :key, :link_name, :inputs, :outputs, :properties]

    @impl true
    def process(context) do
      first_output = List.first(context.node.outputs || [])
      NodeResult.next(first_output)
    end
  end
end
