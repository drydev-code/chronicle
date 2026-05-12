defmodule Chronicle.Server.Host.Deployment.ManagerTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.Diagrams.DiagramStore
  alias Chronicle.Server.Host.Deployment.Manager

  test "direct .bpmn XML upload is explicitly unsupported" do
    assert {:error, {:xml_bpmn_not_supported, "process.bpmn"}} =
             Manager.provision("<definitions />", "process.bpmn", "tenant")
  end

  test "package validation failure prevents partial BPMN registration" do
    start_store(DiagramStore)

    valid =
      Jason.encode!(%{
        "name" => "valid-before-invalid",
        "version" => 1,
        "nodes" => [
          %{"id" => 1, "type" => "blankStartEvent"},
          %{"id" => 2, "type" => "blankEndEvent"}
        ],
        "connections" => [%{"from" => 1, "to" => 2}]
      })

    invalid =
      Jason.encode!(%{
        "name" => "invalid-after-valid",
        "version" => 1,
        "nodes" => [
          %{"id" => 1, "type" => "blankStartEvent"},
          %{"id" => 2, "type" => "externalTask", "kind" => "service"}
        ],
        "connections" => [%{"from" => 1, "to" => 2}]
      })

    {:ok, {_name, zip}} =
      :zip.create(
        ~c"deployment.zip",
        [{~c"valid.bpjs", valid}, {~c"invalid.bpjs", invalid}],
        [:memory]
      )

    assert {:error, [{:validation_failed, _errors}]} =
             Manager.provision(zip, "deployment.zip", "tenant-partial")

    assert {:error, :not_found} =
             DiagramStore.get("valid-before-invalid", 1, "tenant-partial")
  end

  defp start_store(mod) do
    case mod.start_link([]) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
