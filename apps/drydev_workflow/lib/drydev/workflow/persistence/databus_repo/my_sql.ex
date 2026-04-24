defmodule DryDev.Workflow.Persistence.DataBusRepo.MySQL do
  use Ecto.Repo,
    otp_app: :drydev_workflow,
    adapter: Ecto.Adapters.MyXQL
end
