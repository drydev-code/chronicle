defmodule DryDev.Workflow.Persistence.Repo.Postgres do
  use Ecto.Repo,
    otp_app: :drydev_workflow,
    adapter: Ecto.Adapters.Postgres
end
