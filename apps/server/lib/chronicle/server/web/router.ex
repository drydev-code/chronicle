defmodule Chronicle.Server.Web.Router do
  use Phoenix.Router, helpers: false

  import Plug.Conn
  import Phoenix.Controller

  pipeline :api do
    plug :accepts, ["json"]
    plug Chronicle.Server.Web.Plugs.Tenant
  end

  pipeline :authenticated do
    plug Chronicle.Server.Web.Plugs.Auth
  end

  pipeline :admin do
    plug Chronicle.Server.Web.Plugs.Auth
    # future: add role check
  end

  # Public scope: endpoints safe for unauthenticated callers.
  # Currently none of the existing routes are safe-by-default; keep this
  # scope empty until genuinely public endpoints (e.g. health checks) are
  # added.
  scope "/api", Chronicle.Server.Web.Controllers do
    pipe_through :api

    # (intentionally empty — no public endpoints today)
  end

  # Authenticated scope: everything that reads state or starts a normal
  # workflow operation.
  scope "/api", Chronicle.Server.Web.Controllers do
    pipe_through [:api, :authenticated]

    # Process Instance (read + non-destructive start)
    post "/process-instance", ProcessInstanceController, :start
    post "/process-instance/conditional-starts", ProcessInstanceController, :evaluate_conditional_starts
    post "/process-instance/:id/variables", ProcessInstanceController, :update_variables

    # Deployment (non-destructive)
    post "/deployment/redeploy", DeploymentController, :redeploy

    # Management (read-only)
    get "/management/active-processes", ManagementController, :active_processes
    get "/management/active-processes-count", ManagementController, :active_processes_count
    get "/management/inspect/:id", ManagementController, :inspect_instance
    get "/management/external-tasks", ManagementController, :list_external_tasks
    post "/management/external-tasks/:task_id/cancel", ManagementController, :cancel_external_task
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

  # Admin scope: destructive / high-impact operations.
  scope "/api", Chronicle.Server.Web.Controllers do
    pipe_through [:api, :admin]

    # Process Instance — migrations + stress test
    post "/process-instance/:id/migrate", ProcessInstanceController, :migrate
    post "/process-instance/stress-test", ProcessInstanceController, :stress_test

    # Deployment — uploads + mock
    post "/deployment", DeploymentController, :upload
    post "/deployment/mock", DeploymentController, :deploy_mock

    # Management — terminate-all
    delete "/management/terminate-all", ManagementController, :terminate_all
  end
end
