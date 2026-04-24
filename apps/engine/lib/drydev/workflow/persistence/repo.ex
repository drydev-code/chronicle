defmodule DryDev.Workflow.Persistence.Repo do
  @moduledoc """
  Runtime dispatch facade for the main WFE database.

  Delegates all calls to the active backend repo module selected at runtime
  via the DB_ADAPTER environment variable. The concrete adapter-specific repos
  (Repo.MySQL, Repo.Postgres, Repo.MsSql) are all compiled into the release;
  only the one matching DB_ADAPTER is started in the supervision tree.
  """

  @doc "Returns the active backend repo module."
  def active, do: Application.get_env(:engine, :active_repo)

  # --- Ecto.Repo query API ---
  def all(queryable, opts \\ []), do: active().all(queryable, opts)
  def one(queryable, opts \\ []), do: active().one(queryable, opts)
  def one!(queryable, opts \\ []), do: active().one!(queryable, opts)
  def get(queryable, id, opts \\ []), do: active().get(queryable, id, opts)
  def get!(queryable, id, opts \\ []), do: active().get!(queryable, id, opts)
  def get_by(queryable, clauses, opts \\ []), do: active().get_by(queryable, clauses, opts)

  # --- Ecto.Repo insert/update/delete API ---
  def insert(struct_or_changeset, opts \\ []), do: active().insert(struct_or_changeset, opts)
  def insert!(struct_or_changeset, opts \\ []), do: active().insert!(struct_or_changeset, opts)
  def update(changeset, opts \\ []), do: active().update(changeset, opts)
  def update!(changeset, opts \\ []), do: active().update!(changeset, opts)
  def delete(struct_or_changeset, opts \\ []), do: active().delete(struct_or_changeset, opts)
  def delete!(struct_or_changeset, opts \\ []), do: active().delete!(struct_or_changeset, opts)

  # --- Ecto.Repo bulk API ---
  def insert_all(schema, entries, opts \\ []), do: active().insert_all(schema, entries, opts)
  def update_all(queryable, updates, opts \\ []), do: active().update_all(queryable, updates, opts)
  def delete_all(queryable, opts \\ []), do: active().delete_all(queryable, opts)

  # --- Transaction API ---
  def transaction(fun_or_multi, opts \\ []), do: active().transaction(fun_or_multi, opts)
end
