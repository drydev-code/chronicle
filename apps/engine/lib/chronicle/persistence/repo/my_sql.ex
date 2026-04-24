defmodule Chronicle.Persistence.Repo.MySQL do
  use Ecto.Repo,
    otp_app: :engine,
    adapter: Ecto.Adapters.MyXQL
end
