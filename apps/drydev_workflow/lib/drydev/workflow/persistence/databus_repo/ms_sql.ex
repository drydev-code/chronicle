defmodule DryDev.Workflow.Persistence.DataBusRepo.MsSql do
  use Ecto.Repo,
    otp_app: :drydev_workflow,
    adapter: Ecto.Adapters.Tds
end
