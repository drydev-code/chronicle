defmodule Chronicle.Server.Host.ExternalTasks.Template do
  @moduledoc "Handlebars template rendering using bbmustache."

  def render(nil, _data), do: {:ok, nil}
  def render(template, data) when is_binary(template) do
    try do
      # Convert data keys to binaries for bbmustache
      context = to_bbmustache_context(data)
      result = :bbmustache.render(template, context, key_type: :binary)
      {:ok, result}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
  def render(value, _data), do: {:ok, value}

  defp to_bbmustache_context(data) when is_map(data) do
    Map.new(data, fn
      {k, v} when is_binary(k) -> {k, to_bbmustache_value(v)}
      {k, v} when is_atom(k) -> {Atom.to_string(k), to_bbmustache_value(v)}
      {k, v} -> {to_string(k), to_bbmustache_value(v)}
    end)
  end
  defp to_bbmustache_context(data), do: data

  defp to_bbmustache_value(v) when is_map(v), do: to_bbmustache_context(v)
  defp to_bbmustache_value(v) when is_list(v), do: Enum.map(v, &to_bbmustache_value/1)
  defp to_bbmustache_value(v), do: v
end
