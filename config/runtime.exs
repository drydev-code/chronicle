import Config

if System.get_env("EVICTION_ENABLED") do
  eviction_max = System.get_env("EVICTION_MAX_RESIDENT")
  eviction_max_int = if eviction_max, do: String.to_integer(eviction_max), else: nil

  config :engine, :eviction,
    enabled: System.get_env("EVICTION_ENABLED", "false") == "true",
    idle_threshold_ms: String.to_integer(System.get_env("EVICTION_IDLE_MS", "300000")),
    scan_interval_ms: String.to_integer(System.get_env("EVICTION_SCAN_MS", "60000")),
    max_resident: eviction_max_int
end

if config_env() == :prod do
  {active_repo, default_db_port} =
    case System.get_env("DB_ADAPTER", "mysql") do
      "postgres" -> {DryDev.Workflow.Persistence.Repo.Postgres, "5432"}
      "mssql" -> {DryDev.Workflow.Persistence.Repo.MsSql, "1433"}
      _ -> {DryDev.Workflow.Persistence.Repo.MySQL, "3306"}
    end

  db_adapter_name = System.get_env("DATABUS_ADAPTER", System.get_env("DB_ADAPTER", "mysql"))

  {active_databus_repo, default_databus_port} =
    case db_adapter_name do
      "postgres" -> {DryDev.Workflow.Persistence.DataBusRepo.Postgres, "5432"}
      "mssql" -> {DryDev.Workflow.Persistence.DataBusRepo.MsSql, "1433"}
      _ -> {DryDev.Workflow.Persistence.DataBusRepo.MySQL, "3306"}
    end

  config :engine,
    active_repo: active_repo,
    active_databus_repo: active_databus_repo

  config :engine, active_repo,
    username: System.fetch_env!("DB_USER"),
    password: System.fetch_env!("DB_PASS"),
    hostname: System.fetch_env!("DB_HOST"),
    database: System.fetch_env!("DB_NAME"),
    port: String.to_integer(System.get_env("DB_PORT", default_db_port)),
    pool_size: String.to_integer(System.get_env("DB_POOL_SIZE", "20"))

  config :engine, active_databus_repo,
    username: System.get_env("DATABUS_DB_USER", "databus"),
    password: System.get_env("DATABUS_DB_PASS", "databus"),
    hostname: System.get_env("DATABUS_DB_HOST", System.get_env("DB_HOST", "localhost")),
    database: System.get_env("DATABUS_DB_NAME", "databus"),
    port: String.to_integer(System.get_env("DATABUS_DB_PORT", default_databus_port)),
    pool_size: String.to_integer(System.get_env("DATABUS_DB_POOL_SIZE", "5"))

  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

  config :server, DryDev.WorkflowServer.Web.Endpoint,
    http: [
      ip: {0, 0, 0, 0},
      port: String.to_integer(System.get_env("PORT", "4000"))
    ],
    secret_key_base: secret_key_base,
    server: true

  config :server, :rabbitmq,
    host: System.get_env("RABBITMQ_HOST", "localhost"),
    port: String.to_integer(System.get_env("RABBITMQ_PORT", "5672")),
    username: System.get_env("RABBITMQ_USER", "guest"),
    password: System.get_env("RABBITMQ_PASS", "guest"),
    virtual_host: System.get_env("RABBITMQ_VHOST", "/")
end
