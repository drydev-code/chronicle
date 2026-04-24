defmodule DryDev.WorkflowServer.Web.Controllers.ProcessInstanceController do
  use Phoenix.Controller, formats: [:json]

  alias DryDev.Workflow.Engine.{Instance, Diagrams.DiagramStore}

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
          DryDev.Workflow.Engine.InstanceSupervisor,
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
    node_mappings = Map.get(params, "nodeMappings", %{})
      |> Map.new(fn {k, v} -> {parse_int(k), parse_int(v)} end)

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

  defp parse_int(val) when is_integer(val), do: val
  defp parse_int(val) when is_binary(val), do: String.to_integer(val)

  def stress_test(conn, %{"count" => count_str}) do
    count = String.to_integer(count_str)
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
              DryDev.Workflow.Engine.InstanceSupervisor,
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
