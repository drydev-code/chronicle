defmodule Chronicle.Persistence.EventStore do
  @moduledoc "Append-only event store for process instance persistence."
  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}
  import Ecto.Query

  def create(instance_id, initial_event) do
    data = Jason.encode!([Chronicle.Engine.PersistentData.encode(initial_event)])
    %ActiveInstance{}
    |> ActiveInstance.changeset(%{process_instance_id: instance_id, data: data})
    |> Repo.insert()
  end

  def append(instance_id, event) do
    encoded = Chronicle.Engine.PersistentData.encode(event)
    case Repo.get(ActiveInstance, instance_id) do
      nil ->
        create(instance_id, event)
      active ->
        existing = Jason.decode!(active.data)
        updated = existing ++ [encoded]
        active
        |> ActiveInstance.changeset(%{data: Jason.encode!(updated)})
        |> Repo.update()
    end
  end

  def stream(instance_id) do
    case Repo.get(ActiveInstance, instance_id) do
      nil -> {:error, :not_found}
      active ->
        events = active.data
          |> Jason.decode!()
          |> Enum.map(&Chronicle.Engine.PersistentData.decode/1)
        {:ok, events}
    end
  end

  def complete(instance_id, events) do
    data = events
      |> Enum.map(&Chronicle.Engine.PersistentData.encode/1)
      |> Jason.encode!()

    Repo.transaction(fn ->
      Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
      %CompletedInstance{}
      |> CompletedInstance.changeset(%{process_instance_id: instance_id, data: data})
      |> Repo.insert!()
    end)
  end

  def terminate(instance_id, events, _reason) do
    data = events
      |> Enum.map(&Chronicle.Engine.PersistentData.encode/1)
      |> Jason.encode!()

    Repo.transaction(fn ->
      Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
      %TerminatedInstance{}
      |> TerminatedInstance.changeset(%{process_instance_id: instance_id, data: data})
      |> Repo.insert!()
    end)
  end

  def append_batch(_instance_id, []), do: {:ok, :noop}
  def append_batch(instance_id, events) when is_list(events) do
    # Wrap read-modify-write in a transaction with a row-level lock so
    # concurrent appends for the same instance cannot trample each other.
    # Without the lock, two appenders could both read the same `existing`
    # list, each append their delta, and the later writer would clobber
    # the earlier one.
    Repo.transaction(fn ->
      row =
        from(a in ActiveInstance,
          where: a.process_instance_id == ^instance_id,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      new_encoded = Enum.map(events, &Chronicle.Engine.PersistentData.encode/1)

      case row do
        nil ->
          data = Jason.encode!(new_encoded)

          case %ActiveInstance{}
               |> ActiveInstance.changeset(%{process_instance_id: instance_id, data: data})
               |> Repo.insert() do
            {:ok, inserted} -> inserted
            {:error, changeset} -> Repo.rollback(changeset)
          end

        active ->
          existing = Jason.decode!(active.data)
          updated = existing ++ new_encoded

          case active
               |> ActiveInstance.changeset(%{data: Jason.encode!(updated)})
               |> Repo.update() do
            {:ok, updated_row} -> updated_row
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc """
  Returns the count of events already persisted for an instance.
  Returns 0 if no active row exists for this instance.
  """
  def current_sequence(instance_id) do
    case Repo.get(ActiveInstance, instance_id) do
      nil -> 0
      active ->
        case Jason.decode(active.data) do
          {:ok, list} when is_list(list) -> length(list)
          _ -> 0
        end
    end
  end

  def delete_active(instance_id) do
    Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
  end

  def list_active_ids do
    Repo.all(from a in ActiveInstance, select: a.process_instance_id)
  end
end
