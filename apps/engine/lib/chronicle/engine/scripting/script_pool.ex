defmodule Chronicle.Engine.Scripting.ScriptPool do
  @moduledoc """
  Poolboy supervisor for N script workers (replaces ScriptRunnerV2 single thread).
  """
  use Supervisor

  @pool_name :script_worker_pool

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    pool_size = System.schedulers_online()

    pool_opts = [
      name: {:local, @pool_name},
      worker_module: Chronicle.Engine.Scripting.ScriptWorker,
      size: pool_size,
      max_overflow: pool_size
    ]

    children = [
      :poolboy.child_spec(@pool_name, pool_opts, [])
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Execute a JavaScript script asynchronously. Result sent back to caller_pid."
  def execute_script(ref, script, inputs, caller_pid) do
    Task.start(fn ->
      worker = :poolboy.checkout(@pool_name)
      try do
        result = GenServer.call(worker, {:execute_script, script, inputs}, 10_000)
        GenServer.cast(caller_pid, {:script_result, ref, result})
      after
        :poolboy.checkin(@pool_name, worker)
      end
    end)
  end

  @doc "Execute boolean expressions asynchronously."
  def execute_expressions(ref, expressions, inputs, caller_pid) do
    Task.start(fn ->
      worker = :poolboy.checkout(@pool_name)
      try do
        result = GenServer.call(worker, {:execute_expressions, expressions, inputs}, 10_000)
        GenServer.cast(caller_pid, {:expressions_result, ref, result})
      after
        :poolboy.checkin(@pool_name, worker)
      end
    end)
  end

  @doc "Execute boolean expressions synchronously."
  def evaluate_expressions(expressions, inputs, timeout \\ 10_000) do
    worker = :poolboy.checkout(@pool_name)

    try do
      GenServer.call(worker, {:execute_expressions, expressions, inputs}, timeout)
    after
      :poolboy.checkin(@pool_name, worker)
    end
  end
end
