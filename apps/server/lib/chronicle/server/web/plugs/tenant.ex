defmodule Chronicle.Server.Web.Plugs.Tenant do
  @moduledoc "Extract tenant ID from request headers or params."
  import Plug.Conn

  @default_tenant "00000000-0000-0000-0000-000000000000"

  def init(opts), do: opts

  def call(conn, _opts) do
    tenant_id =
      get_req_header(conn, "x-tenant-id")
      |> List.first()
      |> normalize_tenant()

    assign(conn, :tenant_id, tenant_id)
  end

  defp normalize_tenant(nil), do: @default_tenant
  defp normalize_tenant(""), do: @default_tenant
  defp normalize_tenant(id), do: id
end
