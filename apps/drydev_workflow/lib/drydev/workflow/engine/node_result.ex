defmodule DryDev.Workflow.Engine.NodeResult do
  @moduledoc """
  All possible results from node execution.
  Tagged union mapping to NodeResultKind from .NET engine.
  """

  @type t ::
    {:next, non_neg_integer()} |
    {:next_with_params, non_neg_integer(), map()} |
    {:fork, [non_neg_integer()], [non_neg_integer()]} |
    {:wait_for_timer, String.t(), non_neg_integer()} |
    {:wait_for_message, String.t()} |
    {:wait_for_signal, String.t()} |
    {:wait_for_script, reference()} |
    {:wait_for_external_task, String.t(), atom()} |
    {:wait_for_call, String.t()} |
    {:wait_for_join} |
    {:wait_for_expressions, reference()} |
    {:wait_for_rules, reference()} |
    {:complete, term()} |
    {:throw_message, String.t(), map(), non_neg_integer()} |
    {:throw_signal, String.t(), non_neg_integer()} |
    {:call, map()} |
    {:retry, non_neg_integer()} |
    {:step} |
    {:simulation_barrier_then_execute} |
    {:simulation_barrier_then_wait, atom()}

  def next(node_id), do: {:next, node_id}
  def next_with_params(node_id, params), do: {:next_with_params, node_id, params}
  def fork(paths, params \\ []), do: {:fork, paths, params}
  def wait_for_timer(timer_id, delay_ms), do: {:wait_for_timer, timer_id, delay_ms}
  def wait_for_message(name), do: {:wait_for_message, name}
  def wait_for_signal(name), do: {:wait_for_signal, name}
  def wait_for_script(ref), do: {:wait_for_script, ref}
  def wait_for_external_task(task_id, kind), do: {:wait_for_external_task, task_id, kind}
  def wait_for_call(child_id), do: {:wait_for_call, child_id}
  def wait_for_join(), do: {:wait_for_join}
  def wait_for_expressions(ref), do: {:wait_for_expressions, ref}
  def wait_for_rules(ref), do: {:wait_for_rules, ref}
  def complete(data), do: {:complete, data}
  def throw_message(name, payload, next_node), do: {:throw_message, name, payload, next_node}
  def throw_signal(name, next_node), do: {:throw_signal, name, next_node}
  def call(params), do: {:call, params}
  def retry(backoff_ms), do: {:retry, backoff_ms}
  def step(), do: {:step}
  def simulation_barrier_then_execute(), do: {:simulation_barrier_then_execute}
  def simulation_barrier_then_wait(wait_type), do: {:simulation_barrier_then_wait, wait_type}
end
