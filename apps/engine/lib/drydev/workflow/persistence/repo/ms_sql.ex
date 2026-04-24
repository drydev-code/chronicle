defmodule DryDev.Workflow.Persistence.Repo.MsSql do
  use Ecto.Repo,
    otp_app: :engine,
    adapter: Ecto.Adapters.Tds
end
