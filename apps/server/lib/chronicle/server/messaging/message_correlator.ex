defmodule Chronicle.Server.Messaging.MessageCorrelator do
  @moduledoc "Message correlation - route messages to correct instances."

  alias Chronicle.Engine.Instance

  def correlate(tenant_id, message_name, business_key, payload \\ %{}) do
    # Route to instances waiting for this message
    Registry.dispatch(:waits, {tenant_id, :message, message_name, business_key}, fn entries ->
      for {pid, _} <- entries do
        Instance.send_message(pid, message_name, payload)
      end
    end)

    # Check for message start events
    process_names = Chronicle.Engine.Diagrams.DiagramStore.get_process_names_for_message(
      message_name, tenant_id
    )

    Enum.each(process_names, fn name ->
      case Chronicle.Engine.Diagrams.DiagramStore.get_latest(name, tenant_id) do
        {:ok, definition} ->
          params = %{
            id: UUID.uuid4(),
            business_key: business_key || UUID.uuid4(),
            tenant_id: tenant_id,
            start_parameters: payload
          }
          DynamicSupervisor.start_child(
            Chronicle.Engine.InstanceSupervisor,
            {Instance, {definition, params}}
          )
        _ -> :ok
      end
    end)
  end

  def broadcast_signal(tenant_id, signal_name) do
    Registry.dispatch(:waits, {tenant_id, :signal, signal_name}, fn entries ->
      for {pid, _} <- entries do
        Instance.send_signal(pid, signal_name)
      end
    end)

    # Check for signal start events
    process_names = Chronicle.Engine.Diagrams.DiagramStore.get_process_names_for_signal(
      signal_name, tenant_id
    )

    Enum.each(process_names, fn name ->
      case Chronicle.Engine.Diagrams.DiagramStore.get_latest(name, tenant_id) do
        {:ok, definition} ->
          params = %{
            id: UUID.uuid4(),
            business_key: UUID.uuid4(),
            tenant_id: tenant_id,
            start_parameters: %{}
          }
          DynamicSupervisor.start_child(
            Chronicle.Engine.InstanceSupervisor,
            {Instance, {definition, params}}
          )
        _ -> :ok
      end
    end)
  end
end
