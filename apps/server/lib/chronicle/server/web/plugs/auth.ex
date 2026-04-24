defmodule Chronicle.Server.Web.Plugs.Auth do
  @moduledoc "Authentication plug (generic authentication)."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    # Placeholder: extract user from JWT/header
    user_id = get_req_header(conn, "x-user-id") |> List.first()
    assign(conn, :user_id, user_id)
  end
end
