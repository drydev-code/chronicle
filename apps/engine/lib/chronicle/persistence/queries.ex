defmodule Chronicle.Persistence.Queries do
  @moduledoc "Common query patterns for persistence layer."
  import Ecto.Query
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance, Deployment}

  def active_count do
    from(a in ActiveInstance, select: count(a.process_instance_id))
  end

  def completed_count do
    from(c in CompletedInstance, select: count(c.process_instance_id))
  end

  def terminated_count do
    from(t in TerminatedInstance, select: count(t.process_instance_id))
  end

  # --- Deployment persistence ---

  @default_tenant_key "__default__"

  @doc """
  Persist a deployment record. Tenants of `nil` / `""` are normalized to a
  sentinel string so MySQL's unique index (which allows multiple NULLs) still
  enforces idempotent re-deploys for the default tenant. Re-deploying the
  same (tenant, name, version, kind) replaces the stored content.

  Uses INSERT ... ON DUPLICATE KEY UPDATE on MySQL via Ecto's `on_conflict`
  so two concurrent deploys of the same key cannot race past each other and
  crash with a unique-constraint violation.
  """
  def save_deployment(tenant_id, name, version, kind, content)
      when kind in ["bpmn", "dmn"] do
    tenant = tenant_key(tenant_id)
    ver = version_int(version)

    attrs = %{
      tenant_id: tenant,
      name: name,
      version: ver,
      kind: kind,
      content: content,
      deployed_at: DateTime.utc_now()
    }

    %Deployment{}
    |> Deployment.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:content, :deployed_at]}
    )
  end

  @doc "Load every persisted deployment, ordered by deployed_at ascending."
  def load_all_deployments do
    Repo.all(from d in Deployment, order_by: [asc: d.deployed_at])
  end

  @doc """
  Load a single deployment by its unique key. `tenant_id` may be `nil` to
  reference the default tenant sentinel.
  """
  def load_deployment(tenant_id, name, version, kind) do
    tenant = tenant_key(tenant_id)
    ver = version_int(version)

    Repo.one(
      from d in Deployment,
        where:
          d.tenant_id == ^tenant and d.name == ^name and
            d.version == ^ver and d.kind == ^kind
    )
  end

  @doc "Expose the tenant sentinel so stores can denormalize consistently."
  def default_tenant_key, do: @default_tenant_key

  defp tenant_key(nil), do: @default_tenant_key
  defp tenant_key(""), do: @default_tenant_key
  defp tenant_key(tenant) when is_binary(tenant), do: tenant

  defp version_int(nil), do: 0
  defp version_int(v) when is_integer(v), do: v
  defp version_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> 0
    end
  end
end
