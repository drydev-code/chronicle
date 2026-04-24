defmodule Chronicle.Server.Web.Controllers.ProcessInstanceController do
  use Phoenix.Controller, formats: [:json]

  alias Chronicle.Engine.{Instance, Diagrams.DiagramStore}
  alias Chronicle.Server.Web.Params

  def start(conn, params) do
    tenant_id = conn.assigns[:tenant_id]
    process_name = Map.get(params, "name") || Map.get(params, "processName")
    business_key = Map.get(params, "businessKey", UUID.uuid4())
    start_params = Map.get(params, "parameters", %{})

    case DiagramStore.get_latest(process_name, tenant_id) do
      {:ok, definition} ->
        instance_params = %{
          id: UUID.uuid4(),
          business_key: business_key,
          tenant_id: tenant_id,
          start_parameters: start_params
        }

        case DynamicSupervisor.start_child(
          Chronicle.Engine.InstanceSupervisor,
          {Instance, {definition, instance_params}}
        ) do
          {:ok, _pid} ->
            json(conn, %{processInstanceId: instance_params.id, status: "started"})
          {:error, reason} ->
            conn |> put_status(500) |> json(%{error: inspect(reason)})
        end

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Process '#{process_name}' not found"})
    end
  end

  def migrate(conn, %{"id" => id} = params) do
    tenant_id = conn.assigns[:tenant_id]
    target_name = Map.get(params, "targetName")
    raw_mappings = Map.get(params, "nodeMappings", %{})

    case parse_node_mappings(raw_mappings) do
      {:error, {field, reason}} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid parameter", field: field, reason: reason})

      {:ok, node_mappings} ->
        do_migrate(conn, tenant_id, id, target_name, node_mappings)
    end
  end

  def update_variables(conn, %{"id" => id} = params) do
    tenant_id = conn.assigns[:tenant_id]
    variables = Map.get(params, "variables") || Map.get(params, "parameters") || %{}

    if is_map(variables) do
      case Instance.lookup(tenant_id, id) do
        {:ok, pid} ->
          case Instance.update_variables_sync(pid, variables) do
            :ok -> json(conn, %{status: "updated", instanceId: id})
            {:error, reason} -> conn |> put_status(409) |> json(%{error: inspect(reason)})
          end

        {:error, :not_found} ->
          conn |> put_status(404) |> json(%{error: "Instance not found"})
      end
    else
      conn |> put_status(400) |> json(%{error: "variables must be an object"})
    end
  end

  defp do_migrate(conn, tenant_id, id, target_name, node_mappings) do
    case Instance.lookup(tenant_id, id) do
      {:ok, pid} ->
        target_def = if target_name do
          DiagramStore.get_latest(target_name, tenant_id)
        else
          state = Instance.get_state(pid)
          DiagramStore.get_latest(state.definition.name, tenant_id)
        end

        case target_def do
          {:ok, definition} ->
            case Instance.migrate(pid, definition, node_mappings) do
              :ok -> json(conn, %{status: "migrated", instanceId: id})
              {:error, reason} -> conn |> put_status(400) |> json(%{error: inspect(reason)})
            end
          {:error, :not_found} ->
            conn |> put_status(404) |> json(%{error: "Target definition not found"})
        end

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Instance not found"})
    end
  end

  defp parse_node_mappings(mappings) when is_map(mappings) do
    Enum.reduce_while(mappings, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, key} <- Params.positive_int(k, max: 1_000_000),
           {:ok, val} <- Params.positive_int(v, max: 1_000_000) do
        {:cont, {:ok, Map.put(acc, key, val)}}
      else
        {:error, reason} -> {:halt, {:error, {"nodeMappings", reason}}}
      end
    end)
  end

  defp parse_node_mappings(_), do: {:error, {"nodeMappings", :invalid}}

  def stress_test(conn, %{"count" => count_raw}) do
    case Params.positive_int(count_raw, max: 1_000) do
      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid parameter", field: "count", reason: reason})

      {:ok, count} ->
        do_stress_test(conn, count)
    end
  end

  defp do_stress_test(conn, count) do
    tenant_id = conn.assigns[:tenant_id]

    # Start N instances in parallel
    results = 1..count
    |> Enum.map(fn _ ->
      Task.async(fn ->
        # Use a simple test diagram if available
        case DiagramStore.get_latest("stress-test", tenant_id) do
          {:ok, def} ->
            params = %{id: UUID.uuid4(), tenant_id: tenant_id, business_key: UUID.uuid4()}
            DynamicSupervisor.start_child(
              Chronicle.Engine.InstanceSupervisor,
              {Instance, {def, params}}
            )
          _ -> {:error, :no_test_diagram}
        end
      end)
    end)
    |> Enum.map(&Task.await(&1, 30_000))

    success = Enum.count(results, &match?({:ok, _}, &1))
    json(conn, %{requested: count, started: success})
  end
end
