defmodule DryDev.Workflow.Persistence.Repo.MySQL do
  use Ecto.Repo,
    otp_app: :drydev_workflow,
    adapter: Ecto.Adapters.MyXQL
end
