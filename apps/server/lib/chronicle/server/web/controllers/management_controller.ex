defmodule Chronicle.Server.Web.Controllers.ManagementController do
  use Phoenix.Controller, formats: [:json]

  alias Chronicle.Engine.Instance
  alias Chronicle.Engine.Nodes.StartEvents.TimerStartEvent

  def active_processes(conn, _params) do
    instances = Registry.select(:instances, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

    processes = Enum.map(instances, fn {{tenant, id}, pid} ->
      try do
        info = Instance.inspect_instance(pid)
        %{id: id, tenant: tenant, state: info.state, tokens: length(info.active_tokens)}
      catch
        _, _ -> %{id: id, tenant: tenant, state: :unknown}
      end
    end)

    json(conn, %{processes: processes})
  end

  def active_processes_count(conn, _params) do
    active = Registry.count(:instances)
    json(conn, %{active: active, hibernating: 0})
  end

  def inspect_instance(conn, %{"id" => id}) do
    tenant_id = conn.assigns[:tenant_id]

    case Instance.lookup(tenant_id, id) do
      {:ok, pid} ->
        info = Instance.inspect_instance(pid)
        json(conn, info)
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Instance not found"})
    end
  end

  def list_external_tasks(conn, _params) do
    # Collect external tasks from all instances
    tasks = Registry.select(:instances, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {{_tenant, _id}, pid} ->
      try do
        info = Instance.inspect_instance(pid)
        Enum.map(info.external_tasks, fn task_id ->
          %{task_id: task_id, instance_id: info.id, tenant: info.tenant_id}
        end)
      catch
        _, _ -> []
      end
    end)

    json(conn, %{tasks: tasks})
  end

  def cancel_external_task(conn, %{"task_id" => task_id} = params) do
    reason = Map.get(params, "reason", "Cancelled via API")
    continuation_node_id = Map.get(params, "continuationNodeId")

    case Chronicle.Server.Host.ExternalTaskRouter.cancel_task(task_id, reason, continuation_node_id) do
      :ok ->
        json(conn, %{status: "cancelled", taskId: task_id})

      {:error, :unknown_task} ->
        conn |> put_status(404) |> json(%{error: "External task not found"})

      {:error, reason} ->
        conn |> put_status(409) |> json(%{error: inspect(reason)})
    end
  end

  def terminate_all(conn, _params) do
    instances = Registry.select(:instances, [{{:_, :_, :"$1"}, [], [:"$1"]}])
    Enum.each(instances, fn pid ->
      Instance.terminate_instance(pid, "Terminated via API")
    end)

    json(conn, %{terminated: length(instances)})
  end

  def timer_start_events(conn, _params) do
    defs = Chronicle.Server.Host.TelemetryService.get_process_definitions()

    timer_defs =
      defs
      |> Enum.filter(fn {_name, definition} ->
        Enum.any?(Map.values(definition.nodes || %{}), fn node ->
          match?(%TimerStartEvent{}, node)
        end)
      end)
      |> Enum.map(fn {name, _def} -> name end)

    json(conn, %{definitions_waiting_for_timer: timer_defs})
  end

  def test_parse_diagram(conn, %{"filename" => filename}) do
    diagrams_dir = Application.app_dir(:engine, "priv/diagrams")
    path = Path.join(diagrams_dir, filename)

    case File.read(path) do
      {:ok, content} ->
        case Chronicle.Engine.Diagrams.Parser.parse(content) do
          {:ok, definition} ->
            json(conn, %{
              name: definition.name,
              version: definition.version,
              nodes: map_size(definition.nodes || %{}),
              connections: map_size(definition.connections || %{})
            })

          {:error, reason} ->
            conn |> put_status(400) |> json(%{error: inspect(reason)})
        end

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "File not found"})
    end
  end
end
