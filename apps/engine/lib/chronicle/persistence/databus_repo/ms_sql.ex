defmodule Chronicle.Persistence.DataBusRepo.MsSql do
  use Ecto.Repo,
    otp_app: :engine,
    adapter: Ecto.Adapters.Tds
end
