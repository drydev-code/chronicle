defmodule DryDev.Workflow.Persistence.EventStore do
  @moduledoc "Append-only event store for process instance persistence."
  alias DryDev.Workflow.Persistence.Repo
  alias DryDev.Workflow.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}
  import Ecto.Query

  def create(instance_id, initial_event) do
    data = Jason.encode!([DryDev.Workflow.Engine.PersistentData.encode(initial_event)])
    %ActiveInstance{}
    |> ActiveInstance.changeset(%{process_instance_id: instance_id, data: data})
    |> Repo.insert()
  end

  def append(instance_id, event) do
    encoded = DryDev.Workflow.Engine.PersistentData.encode(event)
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
          |> Enum.map(&DryDev.Workflow.Engine.PersistentData.decode/1)
        {:ok, events}
    end
  end

  def complete(instance_id, events) do
    data = events
      |> Enum.map(&DryDev.Workflow.Engine.PersistentData.encode/1)
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
      |> Enum.map(&DryDev.Workflow.Engine.PersistentData.encode/1)
      |> Jason.encode!()

    Repo.transaction(fn ->
      Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
      %TerminatedInstance{}
      |> TerminatedInstance.changeset(%{process_instance_id: instance_id, data: data})
      |> Repo.insert!()
    end)
  end

  def append_batch(instance_id, events) when is_list(events) do
    case Repo.get(ActiveInstance, instance_id) do
      nil ->
        data = events
          |> Enum.map(&DryDev.Workflow.Engine.PersistentData.encode/1)
          |> Jason.encode!()
        %ActiveInstance{}
        |> ActiveInstance.changeset(%{process_instance_id: instance_id, data: data})
        |> Repo.insert()

      active ->
        existing = Jason.decode!(active.data)
        new_encoded = Enum.map(events, &DryDev.Workflow.Engine.PersistentData.encode/1)
        updated = existing ++ new_encoded
        active
        |> ActiveInstance.changeset(%{data: Jason.encode!(updated)})
        |> Repo.update()
    end
  end

  def delete_active(instance_id) do
    Repo.delete_all(from a in ActiveInstance, where: a.process_instance_id == ^instance_id)
  end

  def list_active_ids do
    Repo.all(from a in ActiveInstance, select: a.process_instance_id)
  end
end
