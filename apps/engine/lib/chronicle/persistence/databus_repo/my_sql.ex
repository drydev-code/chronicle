defmodule Chronicle.Persistence.DataBusRepo.MySQL do
  use Ecto.Repo,
    otp_app: :engine,
    adapter: Ecto.Adapters.MyXQL
end
