defmodule Chronicle.Persistence.Repo.Migrations.CreateProcessInstanceTables do
  use Ecto.Migration

  def up do
    # Additive/idempotent creation only. Event logs are the source of truth for
    # active and historical process instances, so migrations must never drop
    # these tables implicitly.
    create_if_not_exists table(:ActiveProcessInstances, primary_key: false) do
      add :process_instance_id, :binary_id, primary_key: true
      add :data, :text, null: false
    end

    create_if_not_exists table(:CompletedProcessInstances, primary_key: false) do
      add :process_instance_id, :binary_id, primary_key: true
      add :data, :text, null: false
    end

    create_if_not_exists table(:TerminatedProcessInstances, primary_key: false) do
      add :process_instance_id, :binary_id, primary_key: true
      add :data, :text, null: false
    end
  end

  def down do
    drop table(:ActiveProcessInstances)
    drop table(:CompletedProcessInstances)
    drop table(:TerminatedProcessInstances)
  end
end
