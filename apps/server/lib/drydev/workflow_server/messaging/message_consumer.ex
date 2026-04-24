defmodule DryDev.WorkflowServer.Messaging.MessageConsumer do
  @moduledoc """
  Unified Broadway consumer for the workflow engine.
  Single queue bound to DryDev.Realm.Any (topic exchange) with per-message-type
  routing keys, matching the Util.ServiceBus topology.

  Topology:
    DryDev.Events (headers) → DryDev.Realm.Any (topic) → queue (via routing key)
    DryDev.{serviceName} (fanout) → queue (for commands)
  """
  use Broadway
  require Logger

  alias DryDev.WorkflowServer.Messaging.{WireFormat, AmqpConnection, DeploymentCommandPublisher}
  alias DryDev.Workflow.Engine.{Instance, Diagrams.DiagramStore}
  alias DryDev.WorkflowServer.Host.Deployment.Manager
  alias DryDev.WorkflowServer.Host.LargeVariables

  @default_queue "DryDev.Workflow.Engine"
  @default_realm_exchange "DryDev.Realm.Any"
  @default_service_exchange "DryDev.Workflow.Engine"
  @message_assembly "DryDev.Messages.Workflow"
  @max_retries 50
  @delay_bits 28

  # All message types this service subscribes to
  @subscribed_events [
    "ServiceTaskExecutedEvent",
    "ServiceTaskFailedEvent",
    "UserTaskExecutedEvent",
    "UserTaskRejectedEvent",
    "ProcessInstanceStartedEvent",
    "MessageCorrelatedEvent",
    "ProcessInstanceFinishedEvent",
    "ProcessInstanceFailedEvent",
    "ProcessInstanceCancelledEvent",
    "DeploymentUploadedEvent",
    "DeploymentDraftActivatedEvent",
    "DeploymentUpdatedEvent"
  ]

  def start_link(_opts) do
    config = Application.get_env(:server, :rabbitmq, [])
    queue = Keyword.get(config, :queue, @default_queue)
    realm_exchange = Keyword.get(config, :realm_exchange, @default_realm_exchange)
    service_exchange = Keyword.get(config, :service_exchange, @default_service_exchange)

    # Bind to realm topic exchange with routing key per message type
    event_bindings = Enum.map(@subscribed_events, fn event ->
      routing_key = "#{@message_assembly}+#{event}.#.#"
      {realm_exchange, [routing_key: routing_key]}
    end)

    # Also bind to service fanout exchange for commands sent directly to us
    command_binding = {service_exchange, []}

    # Declare exchanges before binding - captures exchange names in closure
    after_connect = fn channel ->
      declare_topology(channel, realm_exchange, service_exchange)
    end

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {BroadwayRabbitMQ.Producer,
          queue: queue,
          declare: [
            durable: true,
            arguments: [
              {"x-max-priority", :long, 9},
              {"x-queue-mode", :longstr, "lazy"},
              {"x-dead-letter-exchange", :longstr, "DryDev.Error"}
            ]
          ],
          bindings: [command_binding | event_bindings],
          after_connect: after_connect,
          connection: AmqpConnection.get_amqp_config(),
          on_failure: :reject,
          metadata: [:type, :headers, :content_type, :routing_key, :correlation_id]
        }
      ],
      processors: [
        default: [concurrency: 10]
      ]
    )
  end

  @doc "Declare the full Util.ServiceBus-compatible exchange topology."
  def declare_topology(channel, realm_exchange, service_exchange) do
    # Declare the headers exchange (DryDev.Events)
    AMQP.Exchange.declare(channel, "DryDev.Events", :headers, durable: true)

    # Declare the realm topic exchange (DryDev.Realm.Any)
    AMQP.Exchange.declare(channel, realm_exchange, :topic, durable: true)

    # Bind realm exchange to DryDev.Events headers exchange
    AMQP.Exchange.bind(channel, realm_exchange, "DryDev.Events",
      arguments: [{"DryDev.Realm.Any", :longstr, "True"}])

    # Declare the service fanout exchange (DryDev.Workflow.Engine)
    AMQP.Exchange.declare(channel, service_exchange, :fanout, durable: true)

    # Declare the dead letter exchange
    AMQP.Exchange.declare(channel, "DryDev.Error", :fanout, durable: true)

    # Declare the workflow service destination exchange (for deployment commands)
    workflow_dest = Keyword.get(
      Application.get_env(:server, :rabbitmq, []),
      :workflow_service_destination,
      "DryDev.Service.Workflow"
    )
    AMQP.Exchange.declare(channel, workflow_dest, :fanout, durable: true)

    # Ensure delay delivery binding exists (idempotent)
    # Messages delayed via x-DryDev.Delay binary tree arrive at x-DryDev.Delivery
    # and need routing back to our service exchange
    AMQP.Exchange.declare(channel, "x-DryDev.Delay", :topic, durable: true)
    AMQP.Exchange.declare(channel, "x-DryDev.Delivery", :topic, durable: true)
    AMQP.Exchange.bind(channel, service_exchange, "x-DryDev.Delivery",
      routing_key: "#.#{service_exchange}")

    :ok
  end

  @impl true
  def handle_message(_, %Broadway.Message{data: data, metadata: metadata} = message, _context) do
    decoded = WireFormat.decode(metadata, data)
    retry_count = get_retry_count(metadata)

    try do
      route_message(decoded)
      message
    rescue
      e ->
        if retry_count < @max_retries do
          delay_seconds = 10 * (retry_count + 1)
          Logger.warning("Transient error, retry #{retry_count + 1}/#{@max_retries} in #{delay_seconds}s: #{Exception.message(e)}")
          republish_to_delay(data, metadata, retry_count + 1, delay_seconds, e)
          message
        else
          Logger.error("Max retries (#{@max_retries}) exceeded: #{Exception.message(e)}")
          Broadway.Message.failed(message, Exception.message(e))
        end
    end
  end

  # -- Routing --

  defp route_message(decoded) do
    cond do
      # Service task results
      WireFormat.message_type_match?(decoded, "ServiceTaskExecutedEvent") ->
        handle_service_task_executed(decoded.body)

      WireFormat.message_type_match?(decoded, "ServiceTaskFailedEvent") ->
        handle_service_task_failed(decoded.body)

      # User task results
      WireFormat.message_type_match?(decoded, "UserTaskExecutedEvent") ->
        handle_user_task_executed(decoded.body)

      WireFormat.message_type_match?(decoded, "UserTaskRejectedEvent") ->
        handle_user_task_rejected(decoded.body)

      # Process instance lifecycle
      WireFormat.message_type_match?(decoded, "ProcessInstanceStartedEvent") ->
        handle_process_started(decoded.body)

      WireFormat.message_type_match?(decoded, "MessageCorrelatedEvent") ->
        handle_message_correlated(decoded.body)

      WireFormat.message_type_match?(decoded, "ProcessInstanceFinishedEvent") ->
        handle_process_finished(decoded.body)

      WireFormat.message_type_match?(decoded, "ProcessInstanceFailedEvent") ->
        handle_process_finished(decoded.body)

      WireFormat.message_type_match?(decoded, "ProcessInstanceCancelledEvent") ->
        handle_process_finished(decoded.body)

      # Deployment events
      WireFormat.message_type_match?(decoded, "DeploymentUploadedEvent") ->
        handle_deployment_uploaded(decoded.body)

      WireFormat.message_type_match?(decoded, "DeploymentDraftActivatedEvent") ->
        handle_deployment_uploaded(decoded.body)

      WireFormat.message_type_match?(decoded, "DeploymentUpdatedEvent") ->
        handle_deployment_updated(decoded.body)

      # Wire compatibility stubs (no-op commands from .NET host)
      WireFormat.message_type_match?(decoded, "ExecutionEngineCompileUnitsCommand") ->
        :noop

      WireFormat.message_type_match?(decoded, "ProcessInstanceDeleteCommand") ->
        handle_process_delete(decoded.body)

      true ->
        :ignored
    end
  end

  # -- Service task handlers --

  defp handle_service_task_executed(body) do
    task_id = Map.get(body, "externalTaskId")
    raw_payload = Map.get(body, "payload", %{})
    result = Map.get(body, "result")
    tenant_id = Map.get(body, "tenantId", "00000000-0000-0000-0000-000000000000")

    Logger.info("MessageConsumer: ServiceTaskExecutedEvent task_id=#{inspect(task_id)} body_keys=#{inspect(Map.keys(body))}")

    # Payload may arrive as a JSON string from the executor; parse if needed
    payload = case raw_payload do
      str when is_binary(str) ->
        case Jason.decode(str) do
          {:ok, decoded} -> decoded
          _ -> %{"_raw" => str}
        end
      map when is_map(map) -> map
      list when is_list(list) -> list
      _ -> %{}
    end

    # Upload large values to DataBus (keeps token parameters memory-efficient)
    payload = if LargeVariables.enabled?() and is_map(payload) do
      LargeVariables.upload(payload, tenant_id)
    else
      payload
    end

    Logger.info("MessageConsumer: broadcasting task_completed for task_id=#{inspect(task_id)}")
    Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "engine:external_tasks",
      {:task_completed, task_id, payload, result})
  end

  defp handle_service_task_failed(body) do
    if Map.get(body, "isDeletedTask", false) do
      :skip
    else
      task_id = Map.get(body, "externalTaskId")
      error = Map.get(body, "error") || Map.get(body, "message", "Unknown error")
      retries = Map.get(body, "retries", 0)

      Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "engine:external_tasks",
        {:task_failed, task_id, error, retries > 0, 1000})
    end
  end

  # -- User task handlers --

  defp handle_user_task_executed(body) do
    task_id = Map.get(body, "externalTaskId")
    payload = Map.get(body, "payload", %{})
    actor = %{
      type: Map.get(body, "actorType", "Actor"),
      id: Map.get(body, "userId")
    }

    merged_payload = Map.put(payload, "__actor", actor)

    Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "engine:external_tasks",
      {:task_completed, task_id, merged_payload, nil})
  end

  defp handle_user_task_rejected(body) do
    if Map.get(body, "isDeletedTask", false) do
      :skip
    else
      task_id = Map.get(body, "externalTaskId")
      error = %{error_message: Map.get(body, "reason", "Rejected"), error_type: "UserTaskRejected"}

      Phoenix.PubSub.broadcast(DryDev.Workflow.PubSub, "engine:external_tasks",
        {:task_failed, task_id, error, false, 0})
    end
  end

  # -- Process instance handlers --

  defp handle_process_started(body) do
    process_name = Map.get(body, "processName")
    tenant_id = Map.get(body, "tenantId", "00000000-0000-0000-0000-000000000000")
    business_key = Map.get(body, "businessKey", UUID.uuid4())
    params = Map.get(body, "parameters", %{})

    case DiagramStore.get_latest(process_name, tenant_id) do
      {:ok, definition} ->
        instance_params = %{
          id: UUID.uuid4(),
          business_key: business_key,
          tenant_id: tenant_id,
          start_parameters: params
        }

        DynamicSupervisor.start_child(
          DryDev.Workflow.Engine.InstanceSupervisor,
          {Instance, {definition, instance_params}}
        )

      _ -> :process_not_found
    end
  end

  defp handle_message_correlated(body) do
    tenant_id = Map.get(body, "tenantId", "00000000-0000-0000-0000-000000000000")
    business_key = Map.get(body, "businessKey")
    message_name = Map.get(body, "messageName")
    payload = Map.get(body, "payload", %{})

    # Dispatch to resident instances
    Registry.dispatch(:waits, {tenant_id, :message, message_name, business_key}, fn entries ->
      for {pid, _} <- entries do
        Instance.send_message(pid, message_name, payload)
      end
    end)

    # Also dispatch to evicted instances via LoadCell
    Registry.dispatch(:evicted_waits, {tenant_id, :message, message_name, business_key}, fn entries ->
      for {_pid, cell_pid} <- entries do
        GenServer.cast(cell_pid, {:wake, :message, message_name, payload})
      end
    end)
  end

  defp handle_process_finished(body) do
    instance_id = Map.get(body, "processInstanceId")
    tenant_id = Map.get(body, "tenantId", "00000000-0000-0000-0000-000000000000")

    case Instance.lookup(tenant_id, instance_id) do
      {:ok, pid} ->
        Instance.terminate_instance(pid, "External completion")
      _ ->
        # If evicted, the LoadCell can handle termination by removing the active instance from DB
        case DryDev.Workflow.Engine.InstanceLoadCell.lookup(tenant_id, instance_id) do
          {:ok, cell_pid} ->
            GenServer.stop(cell_pid, :normal)
            DryDev.Workflow.Persistence.EventStore.delete_active(instance_id)
          _ -> :ok
        end
    end
  end

  # -- Deployment handlers --

  defp handle_deployment_uploaded(body) do
    content = Map.get(body, "content", "")
    filename = Map.get(body, "filename", "unknown.bpmn")
    tenant_id = Map.get(body, "tenantId", "00000000-0000-0000-0000-000000000000")
    correlation_id = Map.get(body, "correlationId")

    case Manager.provision(content, filename, tenant_id) do
      {:ok, results} ->
        # Build process definition ID mapping from successful registrations
        process_ids = results
        |> Enum.filter(&match?({:ok, name} when is_binary(name), &1))
        |> Map.new(fn {:ok, name} -> {name, UUID.uuid4()} end)

        DeploymentCommandPublisher.send_update(
          external_id: filename,
          process_ids: process_ids,
          tenant_id: tenant_id,
          correlation_id: correlation_id
        )

      {:error, reason} ->
        DeploymentCommandPublisher.send_failure(
          error_message: inspect(reason),
          tenant_id: tenant_id,
          correlation_id: correlation_id
        )
    end
  end

  defp handle_process_delete(body) do
    instance_id = Map.get(body, "processInstanceId")
    if instance_id do
      DryDev.Workflow.Persistence.EventStore.delete_active(instance_id)
    end
  end

  defp handle_deployment_updated(_body) do
    :ok
  end

  # -- Retry helpers (Util.ServiceBus delay infrastructure) --

  defp get_retry_count(metadata) do
    headers = Map.get(metadata, :headers, [])
    case List.keyfind(headers, "DryDev.CurrentRetry", 0) do
      {"DryDev.CurrentRetry", _, count} -> count |> to_string() |> String.to_integer()
      _ -> 0
    end
  end

  defp build_delay_routing_key(delay_seconds, destination) do
    bits = Integer.to_string(delay_seconds, 2) |> String.graphemes()
    padding = List.duplicate("0", @delay_bits - length(bits))
    all_bits = padding ++ bits
    Enum.join(all_bits, ".") <> ".#{destination}"
  end

  defp republish_to_delay(data, metadata, retry_count, delay_seconds, exception) do
    destination = @default_service_exchange
    routing_key = build_delay_routing_key(delay_seconds, destination)

    AmqpConnection.publish("x-DryDev.Delay", routing_key, data,
      headers: [
        {"DryDev.CurrentRetry", to_string(retry_count)},
        {"DryDev.DelayDestination", destination},
        {"DryDev.LastException", Exception.message(exception)}
      ],
      type: Map.get(metadata, :type)
    )
  end
end
