defmodule Chronicle.Persistence.MigrationSafetyTest do
  use ExUnit.Case, async: true

  test "process-instance table migration is additive and never drops event logs" do
    path =
      Path.expand(
        "../../../priv/repo/migrations/20260310000002_create_process_instance_tables.exs",
        __DIR__
      )

    source = File.read!(path)

    refute source =~ "DROP TABLE"
    assert source =~ "create_if_not_exists table(:ActiveProcessInstances"
    assert source =~ "create_if_not_exists table(:CompletedProcessInstances"
    assert source =~ "create_if_not_exists table(:TerminatedProcessInstances"
  end
end
