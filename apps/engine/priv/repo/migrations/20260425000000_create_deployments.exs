defmodule Chronicle.Persistence.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:Deployments, primary_key: false) do
      add :Id, :binary_id, primary_key: true
      add :TenantId, :string, size: 64, null: false
      add :Name, :string, size: 255, null: false
      add :Version, :integer, null: false
      add :Kind, :string, size: 16, null: false
      add :Content, :text, null: false
      add :DeployedAt, :utc_datetime_usec, null: false
    end

    create unique_index(:Deployments, [:TenantId, :Name, :Version, :Kind],
             name: :deployments_tenant_name_version_kind_index
           )

    create index(:Deployments, [:TenantId, :Name, :Kind],
             name: :deployments_tenant_name_kind_index
           )
  end
end
