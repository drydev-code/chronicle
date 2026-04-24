defmodule Chronicle.Persistence.Schemas.ActiveInstance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:process_instance_id, :binary_id, autogenerate: false}
  schema "ActiveProcessInstances" do
    field :data, :string
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:process_instance_id, :data])
    |> validate_required([:process_instance_id, :data])
  end
end
