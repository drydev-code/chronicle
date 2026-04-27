import Config

csv = fn value ->
  value
  |> to_string()
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
end

cert_pems = fn value ->
  value
  |> to_string()
  |> String.split("-----END CERTIFICATE-----", trim: true)
  |> Enum.map(&(&1 <> "-----END CERTIFICATE-----"))
end

config :server,
       :connector_registry,
       System.get_env(
         "CONNECTOR_REGISTRY_JSON",
         System.get_env("CHRONICLE_CONNECTOR_REGISTRY_JSON", "")
       )

signer_private_key_path =
  System.get_env("AMQP_SIGNER_PRIVATE_KEY_PATH", System.get_env("AMQP_SIGNING_PRIVATE_KEY_PATH"))

signer_certificate_path =
  System.get_env("AMQP_SIGNER_CERTIFICATE_PATH", System.get_env("AMQP_SIGNING_CERTIFICATE_PATH"))

trusted_certificate_paths =
  System.get_env("AMQP_TRUSTED_CERTIFICATE_PATHS", "")
  |> csv.()

trusted_certificate_fingerprints =
  System.get_env("AMQP_TRUSTED_CERTIFICATE_FINGERPRINTS", "")
  |> csv.()

config :server, :amqp_signing,
  enabled: System.get_env("AMQP_SIGNING_ENABLED", "false") == "true",
  require_signatures: System.get_env("AMQP_REQUIRE_SIGNATURES", "false") == "true",
  private_key_path: signer_private_key_path,
  certificate_path: signer_certificate_path,
  signer: [
    private_key_path: signer_private_key_path,
    certificate_path: signer_certificate_path
  ],
  trust: [
    certificate_paths: trusted_certificate_paths,
    certificate_fingerprints: trusted_certificate_fingerprints
  ],
  trusted_certificate_paths: trusted_certificate_paths,
  trusted_certificate_fingerprints: trusted_certificate_fingerprints,
  trusted_certificates:
    System.get_env("AMQP_TRUSTED_CERTIFICATES_PEM", "")
    |> cert_pems.(),
  validate_certificate_dates:
    System.get_env("AMQP_VALIDATE_CERTIFICATE_DATES", "true") != "false",
  certificate_expiry_warning_days:
    System.get_env("AMQP_CERTIFICATE_EXPIRY_WARNING_DAYS", "30")
    |> String.to_integer(),
  require_signature_message_types:
    System.get_env("AMQP_REQUIRE_SIGNATURE_MESSAGE_TYPES", "")
    |> csv.(),
  require_signature_directions:
    System.get_env("AMQP_REQUIRE_SIGNATURE_DIRECTIONS", "")
    |> csv.()

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
      "postgres" -> {Chronicle.Persistence.Repo.Postgres, "5432"}
      "mssql" -> {Chronicle.Persistence.Repo.MsSql, "1433"}
      _ -> {Chronicle.Persistence.Repo.MySQL, "3306"}
    end

  db_adapter_name = System.get_env("DATABUS_ADAPTER", System.get_env("DB_ADAPTER", "mysql"))

  {active_databus_repo, default_databus_port} =
    case db_adapter_name do
      "postgres" -> {Chronicle.Persistence.DataBusRepo.Postgres, "5432"}
      "mssql" -> {Chronicle.Persistence.DataBusRepo.MsSql, "1433"}
      _ -> {Chronicle.Persistence.DataBusRepo.MySQL, "3306"}
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

  config :server, Chronicle.Server.Web.Endpoint,
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
