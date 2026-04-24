defmodule Chronicle.Persistence.Schemas.Deployment do
  @moduledoc """
  Persisted record of a deployed BPMN process definition or DMN decision table.

  Each row is uniquely identified by (tenant_id, name, version, kind) where
  kind is either `"bpmn"` or `"dmn"`. `content` stores the raw source
  (JSON for BPMN .bpjs definitions, XML for DMN). In-memory stores
  (`Chronicle.Engine.Diagrams.DiagramStore`, `Chronicle.Engine.Dmn.DmnStore`)
  write through to this table so active instance restoration after a service
  restart can re-hydrate deployed definitions.

  Elixir field names use snake_case, but map onto the existing PascalCase
  `.NET`-style column layout via `:source` overrides so the migration matches
  the rest of the schema (`ActiveProcessInstances`, etc.).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true, source: :Id}
  schema "Deployments" do
    field :tenant_id, :string, source: :TenantId
    field :name, :string, source: :Name
    field :version, :integer, source: :Version
    field :kind, :string, source: :Kind
    field :content, :string, source: :Content
    field :deployed_at, :utc_datetime_usec, source: :DeployedAt
  end

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:tenant_id, :name, :version, :kind, :content, :deployed_at])
    |> validate_required([:tenant_id, :name, :version, :kind, :content, :deployed_at])
    |> validate_inclusion(:kind, ["bpmn", "dmn"])
  end
end
