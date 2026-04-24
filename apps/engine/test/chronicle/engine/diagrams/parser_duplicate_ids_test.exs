defmodule Chronicle.Engine.Diagrams.ParserDuplicateIdsTest do
  use ExUnit.Case, async: true

  alias Chronicle.Engine.Diagrams.Parser

  describe "parse/1 with duplicate node IDs" do
    test "returns {:error, {:duplicate_node_ids, _}} when a diagram has duplicate ids" do
      json =
        Jason.encode!(%{
          "name" => "dup-process",
          "version" => 1,
          "nodes" => [
            %{"id" => 1, "type" => "blankStartEvent"},
            %{"id" => 1, "type" => "blankEndEvent"}
          ],
          "connections" => []
        })

      assert {:error, {:duplicate_node_ids, ids}} = Parser.parse(json)
      assert 1 in ids
    end

    test "accepts a diagram with unique ids" do
      json =
        Jason.encode!(%{
          "name" => "ok-process",
          "version" => 1,
          "nodes" => [
            %{"id" => 1, "type" => "blankStartEvent"},
            %{"id" => 2, "type" => "blankEndEvent"}
          ],
          "connections" => [%{"from" => 1, "to" => 2}]
        })

      assert {:ok, %{nodes: nodes}} = Parser.parse(json)
      assert Map.has_key?(nodes, 1)
      assert Map.has_key?(nodes, 2)
    end

    test "collects multiple distinct duplicate ids" do
      json =
        Jason.encode!(%{
          "name" => "multi-dup",
          "version" => 1,
          "nodes" => [
            %{"id" => 1, "type" => "blankStartEvent"},
            %{"id" => 1, "type" => "blankEndEvent"},
            %{"id" => 2, "type" => "blankEndEvent"},
            %{"id" => 2, "type" => "blankEndEvent"}
          ],
          "connections" => []
        })

      assert {:error, {:duplicate_node_ids, ids}} = Parser.parse(json)
      assert Enum.sort(ids) == [1, 2]
    end
  end
end
