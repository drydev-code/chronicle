defmodule DryDev.Workflow.Persistence.Repo.Postgres do
  use Ecto.Repo,
    otp_app: :engine,
    adapter: Ecto.Adapters.Postgres
end
