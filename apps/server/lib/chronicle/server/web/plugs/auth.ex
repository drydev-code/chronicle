defmodule Chronicle.Server.Web.Plugs.Auth do
  @moduledoc """
  Authentication plug (generic authentication).

  Can be disabled for tests via application config:

      config :server, Chronicle.Server.Web.Plugs.Auth, disabled_for_tests: true

  When `Mix.env() == :test` the plug also bypasses authentication by default
  so existing tests keep working without explicit opt-in.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      disabled?() ->
        # Still assign user_id if provided so downstream code can use it.
        user_id = conn |> get_req_header("x-user-id") |> List.first()
        assign(conn, :user_id, user_id)

      true ->
        case conn |> get_req_header("x-user-id") |> List.first() do
          nil ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, ~s({"error":"unauthorized"}))
            |> halt()

          "" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, ~s({"error":"unauthorized"}))
            |> halt()

          user_id ->
            assign(conn, :user_id, user_id)
        end
    end
  end

  defp disabled? do
    config = Application.get_env(:server, __MODULE__, [])

    Keyword.get(config, :disabled_for_tests, false) or
      (function_exported?(Mix, :env, 0) and Mix.env() == :test)
  end
end
