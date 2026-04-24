defmodule DryDev.Workflow.Persistence.DataBusRepo.Postgres do
  use Ecto.Repo,
    otp_app: :engine,
    adapter: Ecto.Adapters.Postgres
end
