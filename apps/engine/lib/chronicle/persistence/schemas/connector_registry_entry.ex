defmodule Chronicle.Persistence.Schemas.ConnectorRegistryEntry do
  @moduledoc """
  Durable connector registry row.

  The connector document is stored as JSON text rather than adapter-specific
  JSON so the same migration works across MySQL, PostgreSQL, and MS SQL.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true, source: :Id}
  schema "ConnectorRegistryEntries" do
    field(:connector_id, :string, source: :ConnectorId)
    field(:entry_json, :string, source: :EntryJson)
    field(:enabled, :boolean, source: :Enabled, default: true)
    field(:inserted_at, :utc_datetime_usec, source: :InsertedAt)
    field(:updated_at, :utc_datetime_usec, source: :UpdatedAt)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:connector_id, :entry_json, :enabled, :inserted_at, :updated_at])
    |> validate_required([:connector_id, :entry_json, :enabled, :updated_at])
    |> validate_length(:connector_id, max: 128)
  end

  def to_connector_entry(%__MODULE__{entry_json: json, connector_id: connector_id}) do
    case Jason.decode(json || "") do
      {:ok, entry} when is_map(entry) -> Map.put_new(entry, "id", connector_id)
      _ -> %{"id" => connector_id}
    end
  end
end
