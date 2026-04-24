defmodule DryDev.Workflow.Persistence.Repo.Migrations.CreateProcessInstanceTables do
  use Ecto.Migration

  def up do
    # Drop existing .NET tables that have incompatible column names (PascalCase)
    execute "DROP TABLE IF EXISTS `ActiveProcessInstances`"
    execute "DROP TABLE IF EXISTS `CompletedProcessInstances`"
    execute "DROP TABLE IF EXISTS `TerminatedProcessInstances`"

    # Recreate with Ecto-compatible snake_case columns
    create table(:ActiveProcessInstances, primary_key: false) do
      add :process_instance_id, :binary_id, primary_key: true
      add :data, :text, null: false
    end

    create table(:CompletedProcessInstances, primary_key: false) do
      add :process_instance_id, :binary_id, primary_key: true
      add :data, :text, null: false
    end

    create table(:TerminatedProcessInstances, primary_key: false) do
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
