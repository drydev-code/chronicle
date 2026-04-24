defmodule DryDev.Workflow.Persistence.Repo.MySQL do
  use Ecto.Repo,
    otp_app: :engine,
    adapter: Ecto.Adapters.MyXQL
end
