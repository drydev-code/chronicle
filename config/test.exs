import Config

config :engine, Chronicle.Persistence.Repo.MySQL,
  username: System.get_env("DB_USER", "root"),
  password: System.get_env("DB_PASS", "root"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DB_NAME", "chronicle_test"),
  port: String.to_integer(System.get_env("DB_PORT", "3306")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :engine, Chronicle.Persistence.DataBusRepo.MySQL,
  username: System.get_env("DATABUS_DB_USER", "databus"),
  password: System.get_env("DATABUS_DB_PASS", "databus"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: System.get_env("DATABUS_DB_NAME", "databus_test"),
  port: String.to_integer(System.get_env("DB_PORT", "3306")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :server, Chronicle.Server.Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test_secret_key_base_at_least_64_bytes_long_for_phoenix_endpoint_config_placeholder_test",
  server: false

config :server, :rabbitmq,
  host: System.get_env("RABBITMQ_HOST", "localhost"),
  port: String.to_integer(System.get_env("RABBITMQ_PORT", "5672")),
  username: System.get_env("RABBITMQ_USER", "guest"),
  password: System.get_env("RABBITMQ_PASS", "guest"),
  virtual_host: System.get_env("RABBITMQ_VHOST", "/")

config :server, enable_mock_deployment: true

config :logger, level: :warning
