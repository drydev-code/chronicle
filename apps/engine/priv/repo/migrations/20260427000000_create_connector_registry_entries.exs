defmodule Chronicle.Persistence.Repo.Migrations.CreateConnectorRegistryEntries do
  use Ecto.Migration

  def change do
    create table(:ConnectorRegistryEntries, primary_key: false) do
      add(:Id, :binary_id, primary_key: true)
      add(:ConnectorId, :string, size: 128, null: false)
      add(:EntryJson, :text, null: false)
      add(:Enabled, :boolean, null: false, default: true)
      add(:InsertedAt, :utc_datetime_usec, null: false)
      add(:UpdatedAt, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(:ConnectorRegistryEntries, [:ConnectorId],
        name: :connector_registry_entries_connector_id_index
      )
    )
  end
end
