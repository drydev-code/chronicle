defmodule DryDev.Workflow.Persistence.DataBusRepo.Postgres do
  use Ecto.Repo,
    otp_app: :drydev_workflow,
    adapter: Ecto.Adapters.Postgres
end
