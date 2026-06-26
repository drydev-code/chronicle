defmodule Chronicle.Persistence.Repo.Migrations.AddInstanceLeaseColumns do
  use Ecto.Migration

  # Additive, idempotent lease + fencing columns on ActiveProcessInstances.
  #
  # These power the ownership-lease layer (feature 3b). They are all NULLable
  # or carry a DEFAULT, so existing rows and any pod that ignores the lease
  # (the N=1 single-pod path) keep working unchanged: a NULL owner_node means
  # "unowned", and fence_epoch defaults to 0 for every pre-existing row.
  #
  # MySQL 8.0 has no `ADD COLUMN IF NOT EXISTS`, so we guard each `add` with an
  # information_schema lookup to stay re-runnable.
  @table "ActiveProcessInstances"

  def up do
    add_column_if_missing(:owner_node, "VARCHAR(64) NULL")
    add_column_if_missing(:lease_expiry, "BIGINT NULL")
    add_column_if_missing(:fence_epoch, "BIGINT NOT NULL DEFAULT 0")
  end

  def down do
    drop_column_if_present(:fence_epoch)
    drop_column_if_present(:lease_expiry)
    drop_column_if_present(:owner_node)
  end

  defp add_column_if_missing(column, definition) do
    unless column_exists?(column) do
      execute("ALTER TABLE `#{@table}` ADD COLUMN `#{column}` #{definition}")
    end
  end

  defp drop_column_if_present(column) do
    if column_exists?(column) do
      execute("ALTER TABLE `#{@table}` DROP COLUMN `#{column}`")
    end
  end

  defp column_exists?(column) do
    %{rows: [[count]]} =
      repo().query!(
        """
        SELECT COUNT(*) FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = ?
          AND COLUMN_NAME = ?
        """,
        [@table, Atom.to_string(column)]
      )

    count > 0
  end
end
