defmodule Chronicle.Engine.Scripting.ScriptWorker do
  @moduledoc """
  Port worker to Node.js runtime for JavaScript execution.
  Communicates via JSON lines over stdin/stdout.
  """
  use GenServer

  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(_args) do
    js_path = Path.join(:code.priv_dir(:engine), "js/evaluator.js")

    case System.find_executable("node") do
      nil ->
        Logger.error(
          "ScriptWorker: Node.js binary not on PATH. " <>
            "Install Node.js 18+ to enable script tasks."
        )

        {:stop,
         {:node_not_found,
          "Node.js binary not on PATH. Install Node.js 18+ to enable script tasks."}}

      node_path ->
        port = Port.open(
          {:spawn_executable, node_path},
          [
            :binary,
            :exit_status,
            {:args, [js_path]},
            {:line, 1_048_576},
            {:env, [
              {~c"NODE_OPTIONS", ~c"--max-old-space-size=64"}
            ]}
          ]
        )

        {:ok, %{port: port, pending: %{}}}
    end
  end

  @impl true
  def handle_call({:execute_script, script, inputs}, from, state) do
    id = UUID.uuid4()
    request = Jason.encode!(%{type: "script", id: id, script: script, inputs: inputs})
    Port.command(state.port, request <> "\n")
    {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_call({:execute_expressions, expressions, inputs}, from, state) do
    id = UUID.uuid4()
    expr_list = Enum.map(expressions, fn {node_id, expr} -> %{node_id: node_id, expr: expr} end)
    request = Jason.encode!(%{type: "expressions", id: id, expressions: expr_list, inputs: inputs})
    Port.command(state.port, request <> "\n")
    {:noreply, %{state | pending: Map.put(state.pending, id, from)}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "ok" => true} = response} ->
        case Map.pop(state.pending, id) do
          {nil, _} -> {:noreply, state}
          {from, pending} ->
            result = if Map.has_key?(response, "outputs") do
              {:ok, response["outputs"]}
            else
              {:ok, response["results"]}
            end
            GenServer.reply(from, result)
            {:noreply, %{state | pending: pending}}
        end

      {:ok, %{"id" => id, "ok" => false, "error" => error, "type" => error_type}} ->
        case Map.pop(state.pending, id) do
          {nil, _} -> {:noreply, state}
          {from, pending} ->
            GenServer.reply(from, {:error, %{message: error, type: error_type}})
            {:noreply, %{state | pending: pending}}
        end

      {:error, _} ->
        Logger.warning("ScriptWorker: unparseable response: #{line}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error("ScriptWorker: Node.js process exited with status #{status}")
    # Reply error to all pending
    Enum.each(state.pending, fn {_id, from} ->
      GenServer.reply(from, {:error, %{message: "Script worker crashed", type: "crash"}})
    end)
    {:stop, :worker_crashed, %{state | pending: %{}}}
  end

  @impl true
  def terminate(_reason, %{port: port}) do
    Port.close(port)
  catch
    _, _ -> :ok
  end
end
