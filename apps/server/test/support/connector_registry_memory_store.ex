defmodule Chronicle.Server.TestSupport.ConnectorRegistryMemoryStore do
  @moduledoc false

  use Agent

  def start_link(entries \\ []) do
    Agent.start_link(
      fn -> Map.new(entries, &{normalize_id(&1["id"] || &1[:id]), stringify_keys(&1)}) end,
      name: __MODULE__
    )
  end

  def child_spec(entries) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [entries]}
    }
  end

  def all do
    {:ok, Agent.get(__MODULE__, &Map.values/1)}
  end

  def upsert(id, entry) do
    entry = stringify_keys(entry)
    id = normalize_id(id)

    Agent.update(__MODULE__, &Map.put(&1, id, entry))
    {:ok, entry}
  end

  def delete(id) do
    id = normalize_id(id)

    deleted =
      Agent.get_and_update(__MODULE__, fn entries ->
        {if(Map.has_key?(entries, id), do: 1, else: 0), Map.delete(entries, id)}
      end)

    {:ok, %{deleted: deleted}}
  end

  defp normalize_id(value), do: value |> to_string() |> String.downcase()

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(value) when is_map(value), do: stringify_keys(value)
  defp stringify_nested(value) when is_list(value), do: Enum.map(value, &stringify_nested/1)
  defp stringify_nested(value), do: value
end
