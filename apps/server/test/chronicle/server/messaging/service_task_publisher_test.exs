defmodule Chronicle.Server.Messaging.ServiceTaskPublisherTest do
  use ExUnit.Case, async: true

  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension
  alias Chronicle.Server.Messaging.ServiceTaskPublisher

  test "publishes process-defined execution metadata separately from transport retry" do
    extension =
      ServiceTaskExtension.from_properties(%{
        "topic" => "rest",
        "endpoint" => "https://example.test/api",
        "retries" => 4,
        "retry" => %{"backoffMs" => 500, "maxBackoffMs" => 5_000},
        "maxRuntime" => 60_000,
        "runtimeTimeout" => 45_000,
        "leaseTimeout" => 15_000,
        "extensions" => %{"execution" => %{"queue" => "satellite.rest"}}
      })

    body =
      ServiceTaskPublisher.wire_body(%{
        correlation_id: "instance-1",
        process_id: "instance-1",
        service_task_id: "call_vendor",
        external_task_id: "task-1",
        topic: "rest",
        retries: extension.retries,
        on_exception: "retry",
        task_properties: extension,
        execution: extension.execution,
        data: %{"input" => "value"},
        actor_type: "Worker",
        tenant_id: "tenant-1"
      })

    assert body["Retry"] == 5
    assert body["Retries"] == 4

    assert body["Execution"] == %{
             "queue" => "satellite.rest",
             "retries" => 4,
             "retry" => %{"backoffMs" => 500, "maxBackoffMs" => 5_000},
             "maxRuntime" => 60_000,
             "runtimeTimeout" => 45_000,
             "leaseTimeout" => 15_000
           }

    assert body["TaskProperties"]["execution"] == body["Execution"]
  end
end
