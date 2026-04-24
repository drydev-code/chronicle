defmodule Chronicle.Server.Host.Deployment.ManagerTest do
  use ExUnit.Case, async: true

  alias Chronicle.Server.Host.Deployment.Manager

  test "direct .bpmn XML upload is explicitly unsupported" do
    assert {:error, {:xml_bpmn_not_supported, "process.bpmn"}} =
             Manager.provision("<definitions />", "process.bpmn", "tenant")
  end
end
