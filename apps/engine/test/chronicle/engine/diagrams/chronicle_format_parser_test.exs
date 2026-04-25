defmodule Chronicle.Engine.Diagrams.ChronicleFormatParserTest do
  use ExUnit.Case, async: true

  alias Chronicle.Engine.Diagrams.Parser
  alias Chronicle.Engine.Nodes

  @external_diagrams_path System.get_env("CHRONICLE_TEST_DIAGRAMS")

  test "parses Chronicle top-level diagram format and keeps top-level version" do
    json = """
    {
      "Name": "ChronicleCompat",
      "Version": 7,
      "Resources": {},
      "Processes": [
        {
          "Name": "ChronicleCompatMain",
          "Nodes": [
            {"Id": 1, "type": "BlankStartEvent", "Extensions": []},
            {"Id": 2, "type": "ServiceTask", "ResultVariable": "result", "ErrorBehaviour": 2, "Extensions": []},
            {"Id": 3, "type": "BlankEndEvent", "ExportAll": true, "ExportScripts": [], "Extensions": []}
          ],
          "Connections": [{"From": 1, "To": 2}, {"From": 2, "To": 3}],
          "RecursiveConnections": []
        }
      ]
    }
    """

    assert {:ok, definition} = Parser.parse(json)
    assert definition.name == "ChronicleCompatMain"
    assert definition.version == 7
    assert %Nodes.ExternalTask{result_variable: "result", error_behaviour: :retry} = definition.nodes[2]
  end

  test "parses Chronicle resources into script task source" do
    json = """
    {
      "Name": "ChronicleScriptCompat",
      "Version": 1,
      "Resources": {
        "2": {"Source": "Math.sqrt(x*x + y*y);", "ReturnVariable": "length", "Kind": 5}
      },
      "Processes": [
        {
          "Name": "ChronicleScriptCompat",
          "Nodes": [
            {"Id": 1, "type": "BlankStartEvent", "Extensions": []},
            {
              "Id": 2,
              "type": "ScriptTask",
              "Script": 999,
              "InputScripts": [2],
              "OutputScripts": [],
              "ExportAllToTokenContext": true,
              "BoundaryEvents": [],
              "Extensions": []
            },
            {"Id": 3, "type": "BlankEndEvent", "ExportAll": true, "ExportScripts": [], "Extensions": []}
          ],
          "Connections": [{"From": 1, "To": 2}, {"From": 2, "To": 3}],
          "RecursiveConnections": []
        }
      ]
    }
    """

    assert {:ok, definition} = Parser.parse(json)
    assert definition.nodes[2].script =~ "KeepAll();"
    assert definition.nodes[2].script =~ "Set(\"length\", (Math.sqrt(x*x + y*y)));"
  end

  test "maps Chronicle service extensions and editor-specific task types" do
    json = """
    {
      "Name": "ChronicleExtensionCompat",
      "Version": 1,
      "Resources": {},
      "Processes": [
        {
          "Name": "ChronicleExtensionCompat",
          "Nodes": [
            {"Id": 1, "type": "BlankStartEvent", "Extensions": []},
            {
              "Id": 2,
              "type": "ServiceTaskREST",
              "ResultVariable": "response",
              "Extensions": [
                {
                  "Key": "Chronicle.RestTask",
                  "Value": "{\\"endpoint\\":\\"https://example.test\\",\\"method\\":\\"GET\\",\\"resultPath\\":\\"data.id\\"}"
                }
              ]
            },
            {
              "Id": 3,
              "type": "ServiceTaskDB",
              "Properties": {"query": "select 1", "resultVariable": "rows"}
            },
            {"Id": 4, "type": "BlankEndEvent", "ExportAll": true, "ExportScripts": [], "Extensions": []}
          ],
          "Connections": [{"From": 1, "To": 2}, {"From": 2, "To": 3}, {"From": 3, "To": 4}],
          "RecursiveConnections": []
        }
      ]
    }
    """

    assert {:ok, definition} = Parser.parse(json)
    assert definition.nodes[2].properties["topic"] == "rest"
    assert definition.nodes[2].properties["endpoint"] == "https://example.test"
    assert definition.nodes[2].properties["extensions"]["resultPath"] == "data.id"
    assert definition.nodes[3].properties["topic"] == "database"
    assert definition.nodes[3].result_variable == "rows"
  end

  test "external Chronicle diagrams parse for the Chronicle-supported subset" do
    if is_binary(@external_diagrams_path) and File.dir?(@external_diagrams_path) do
      files =
        @external_diagrams_path
        |> Path.join("**/*.json")
        |> Path.wildcard()

      results =
        Enum.map(files, fn path ->
          case path |> File.read!() |> Parser.parse() do
            {:ok, _} -> {:ok, path}
            {:error, {:unsupported_node_type, type, _reason}} -> {:unsupported, type, path}
            {:error, other} -> {:error, other, path}
          end
        end)

      errors = Enum.filter(results, &match?({:error, _, _}, &1))

      assert errors == []
      assert Enum.count(results, &match?({:ok, _}, &1)) > 0
    else
      assert true
    end
  end
end
