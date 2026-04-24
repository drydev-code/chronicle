defmodule DryDev.WorkflowServer.Host.Tenant do
  @moduledoc "Multi-tenant context management."

  @default_tenant "00000000-0000-0000-0000-000000000000"

  def normalize(nil), do: @default_tenant
  def normalize(""), do: @default_tenant
  def normalize(tenant_id), do: tenant_id

  def default_tenant, do: @default_tenant
end
