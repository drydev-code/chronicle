defmodule Chronicle.Server.Web.Controllers.TelemetryController do
  use Phoenix.Controller, formats: [:json]

  alias Chronicle.Server.Host.TelemetryService
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{CompletedInstance, TerminatedInstance}
  alias Chronicle.Server.Web.Params
  import Ecto.Query

  def is_enabled(conn, _params) do
    json(conn, TelemetryService.enabled?())
  end

  def start_telemetry(conn, _params) do
    TelemetryService.start_collection()
    json(conn, %{status: "started"})
  end

  def stop_telemetry(conn, _params) do
    TelemetryService.stop_collection()
    json(conn, %{status: "stopped"})
  end

  def process_instance_telemetries(conn, _params) do
    instances = TelemetryService.get_all_instances()
    json(conn, instances)
  end

  def process_instance_telemetry(conn, %{"processInstance" => id}) do
    case TelemetryService.get_instance(id) do
      {:ok, instance} -> json(conn, instance)
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not found"})
    end
  end

  def terminated_instances(conn, _params) do
    json(conn, TelemetryService.get_terminated_instances())
  end

  def db_completed_instances(conn, params) do
    case Params.positive_int(Map.get(params, "limit", 100)) do
      {:ok, limit} ->
        instances =
          from(c in CompletedInstance, select: c.process_instance_id, limit: ^limit)
          |> Repo.all()
        json(conn, instances)

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid parameter", field: "limit", reason: reason})
    end
  end

  def db_terminated_instances(conn, params) do
    case Params.positive_int(Map.get(params, "limit", 100)) do
      {:ok, limit} ->
        instances =
          from(t in TerminatedInstance, select: t.process_instance_id, limit: ^limit)
          |> Repo.all()
        json(conn, instances)

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: "invalid parameter", field: "limit", reason: reason})
    end
  end

  def db_completed_instance_data(conn, %{"id" => id}) do
    case Repo.get(CompletedInstance, id) do
      nil -> conn |> put_status(404) |> json(%{error: "Not found"})
      instance -> json(conn, instance.data)
    end
  end

  def db_terminated_instance_data(conn, %{"id" => id}) do
    case Repo.get(TerminatedInstance, id) do
      nil -> conn |> put_status(404) |> json(%{error: "Not found"})
      instance -> json(conn, instance.data)
    end
  end

  def already_running_errors(conn, _params) do
    json(conn, TelemetryService.get_already_running_errors())
  end

  def start_not_found_errors(conn, _params) do
    json(conn, TelemetryService.get_start_not_found_errors())
  end

  def loaded_process_definitions(conn, _params) do
    defs = TelemetryService.get_process_definitions()
    json(conn, Map.keys(defs))
  end

  def get_process_definition(conn, %{"key" => key}) do
    case TelemetryService.get_process_definition(key) do
      {:ok, definition} -> json(conn, inspect_definition(definition))
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Not found"})
    end
  end

  def drop_successful(conn, %{"value" => value}) do
    bool = value in ["true", "1", true]
    TelemetryService.set_drop_successful(bool)
    json(conn, %{dropSuccessfullyCompletedProcessInstanceTelemetry: bool})
  end

  def remove_completed(conn, params) do
    remove_successful = Map.get(params, "removeSuccessful", "true") in ["true", "1", true]
    remove_failed = Map.get(params, "removeFailed", "false") in ["true", "1", true]
    TelemetryService.remove_completed(remove_successful, remove_failed)
    json(conn, %{status: "cleaned"})
  end

  defp inspect_definition(definition) do
    %{
      name: definition.name,
      version: definition.version,
      nodes: map_size(definition.nodes || %{}),
      connections: map_size(definition.connections || %{})
    }
  end
end
