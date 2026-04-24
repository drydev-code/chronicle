defmodule DryDev.Workflow.Persistence.DataBusRepo do
  @moduledoc """
  Runtime dispatch facade for the DataBus database.

  Delegates all calls to the active backend repo module selected at runtime
  via the DATABUS_ADAPTER environment variable (falls back to DB_ADAPTER).
  """

  @doc "Returns the active backend DataBus repo module."
  def active, do: Application.get_env(:drydev_workflow, :active_databus_repo)

  # --- Ecto.Repo query API ---
  def all(queryable, opts \\ []), do: active().all(queryable, opts)
  def one(queryable, opts \\ []), do: active().one(queryable, opts)
  def one!(queryable, opts \\ []), do: active().one!(queryable, opts)
  def get(queryable, id, opts \\ []), do: active().get(queryable, id, opts)
  def get!(queryable, id, opts \\ []), do: active().get!(queryable, id, opts)

  # --- Ecto.Repo insert/update/delete API ---
  def insert(struct_or_changeset, opts \\ []), do: active().insert(struct_or_changeset, opts)
  def insert!(struct_or_changeset, opts \\ []), do: active().insert!(struct_or_changeset, opts)
  def update(changeset, opts \\ []), do: active().update(changeset, opts)
  def delete(struct_or_changeset, opts \\ []), do: active().delete(struct_or_changeset, opts)

  # --- Ecto.Repo bulk API ---
  def update_all(queryable, updates, opts \\ []), do: active().update_all(queryable, updates, opts)
  def delete_all(queryable, opts \\ []), do: active().delete_all(queryable, opts)

  # --- Transaction API ---
  def transaction(fun_or_multi, opts \\ []), do: active().transaction(fun_or_multi, opts)
end
