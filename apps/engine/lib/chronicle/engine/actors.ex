defmodule Chronicle.Engine.Actors do
  @moduledoc false

  @actor_keys ["__actor", "__ActorUpdate", "actor"]

  def extract_updates(payload) when is_map(payload) do
    {updates, rest} =
      Enum.reduce(@actor_keys, {[], payload}, fn key, {updates, rest} ->
        case Map.pop(rest, key) do
          {nil, rest} -> {updates, rest}
          {actor, rest} -> {[actor | updates], rest}
        end
      end)

    {Enum.reverse(updates), rest}
  end

  def extract_updates(payload), do: {[], payload}

  def put_update(payload, actor) when is_map(payload) do
    Map.put(payload, "__actor", normalize(actor))
  end

  def put_update(_payload, actor), do: %{"__actor" => normalize(actor)}

  def apply_updates(parameters, updates) when is_list(updates) do
    Enum.reduce(updates, parameters || %{}, &apply_update(&2, &1))
  end

  def apply_updates(parameters, update), do: apply_update(parameters || %{}, update)

  defp apply_update(parameters, nil), do: parameters

  defp apply_update(parameters, actor) when is_map(actor) do
    actor = normalize(actor)
    actor_type = actor["type"] || actor["name"] || "Actor"
    actors = Map.get(parameters, "Actors", %{})

    Map.put(parameters, "Actors", Map.put(actors, actor_type, actor))
  end

  defp apply_update(parameters, _actor), do: parameters

  defp normalize(actor) when is_map(actor) do
    actor
    |> stringify_keys()
    |> ensure_type()
  end

  defp normalize(actor), do: %{"type" => "Actor", "value" => actor}

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {string_key(key), value} end)
  end

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: to_string(key)

  defp ensure_type(actor) do
    actor_type = actor["type"] || actor["name"] || "Actor"
    Map.put(actor, "type", actor_type)
  end
end
