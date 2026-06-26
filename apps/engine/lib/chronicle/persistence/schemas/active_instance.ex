defmodule Chronicle.Persistence.Schemas.ActiveInstance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:process_instance_id, :binary_id, autogenerate: false}
  schema "ActiveProcessInstances" do
    field :data, :string
    # Ownership-lease / fencing columns (feature 3b). All optional so the
    # single-pod path that never touches the lease keeps working: an unowned
    # row has owner_node = nil, lease_expiry = nil, fence_epoch = 0.
    field :owner_node, :string
    field :lease_expiry, :integer
    field :fence_epoch, :integer, default: 0
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:process_instance_id, :data, :owner_node, :lease_expiry, :fence_epoch])
    |> validate_required([:process_instance_id, :data])
  end
end
