defmodule Chronicle.Server.Web.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
    plug Chronicle.Server.Web.Plugs.Tenant
  end

  scope "/api", Chronicle.Server.Web.Controllers do
    pipe_through :api

    # Process Instance
    post "/process-instance", ProcessInstanceController, :start
    post "/process-instance/:id/migrate", ProcessInstanceController, :migrate
    post "/process-instance/stress-test", ProcessInstanceController, :stress_test

    # Deployment
    post "/deployment", DeploymentController, :upload
    post "/deployment/redeploy", DeploymentController, :redeploy
    post "/deployment/mock", DeploymentController, :deploy_mock

    # Management
    get "/management/active-processes", ManagementController, :active_processes
    get "/management/active-processes-count", ManagementController, :active_processes_count
    get "/management/inspect/:id", ManagementController, :inspect_instance
    get "/management/external-tasks", ManagementController, :list_external_tasks
    delete "/management/terminate-all", ManagementController, :terminate_all
    get "/management/timer-start-events", ManagementController, :timer_start_events
    get "/management/test-parse-diagram", ManagementController, :test_parse_diagram

    # Telemetry
    get "/telemetry/is-enabled", TelemetryController, :is_enabled
    post "/telemetry/start", TelemetryController, :start_telemetry
    post "/telemetry/stop", TelemetryController, :stop_telemetry
    get "/telemetry/process-instance-telemetries", TelemetryController, :process_instance_telemetries
    get "/telemetry/process-instance-telemetry", TelemetryController, :process_instance_telemetry
    get "/telemetry/terminated-instances", TelemetryController, :terminated_instances
    get "/telemetry/already-running-errors", TelemetryController, :already_running_errors
    get "/telemetry/start-not-found-errors", TelemetryController, :start_not_found_errors
    get "/telemetry/loaded-process-definitions", TelemetryController, :loaded_process_definitions
    get "/telemetry/get-process-definition", TelemetryController, :get_process_definition
    post "/telemetry/drop-successful", TelemetryController, :drop_successful
    delete "/telemetry/remove-completed", TelemetryController, :remove_completed

    # Database queries for historical data
    get "/telemetry/db-completed-instances", TelemetryController, :db_completed_instances
    get "/telemetry/db-terminated-instances", TelemetryController, :db_terminated_instances
    get "/telemetry/db-completed-instance/:id", TelemetryController, :db_completed_instance_data
    get "/telemetry/db-terminated-instance/:id", TelemetryController, :db_terminated_instance_data
  end
end
