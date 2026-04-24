ExUnit.start(exclude: [])

# PubSub and the registries the engine uses at runtime. Individual tests that
# start Instance GenServers (e.g. instance persistence / timer_elapsed tests)
# need these to be running.
case Phoenix.PubSub.Supervisor.start_link(name: Chronicle.PubSub) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

Enum.each(
  [
    {:instances, :unique},
    {:waits, :duplicate},
    {:load_cells, :unique},
    {:evicted_waits, :duplicate}
  ],
  fn {name, keys} ->
    case Registry.start_link(keys: keys, name: name) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
)

# Start the active repo(s) for tests that exercise persistence. The repo is
# configured with the SQL Sandbox pool in config/test.exs; tests that need DB
# access call Ecto.Adapters.SQL.Sandbox.checkout/1 in their setup.
active_repo = Application.get_env(:engine, :active_repo)

if active_repo do
  case active_repo.start_link(pool: Ecto.Adapters.SQL.Sandbox) do
    {:ok, _} ->
      :ok

    {:error, {:already_started, _}} ->
      :ok

    {:error, _reason} ->
      :ok
  end

  # Ensure migrations are up before any test runs.
  try do
    migrations_path = Application.app_dir(:engine, "priv/repo/migrations")
    Ecto.Migrator.run(active_repo, migrations_path, :up, all: true, log: false)
  rescue
    _ -> :ok
  end

  try do
    Ecto.Adapters.SQL.Sandbox.mode(active_repo, :manual)
  rescue
    _ -> :ok
  end
end
