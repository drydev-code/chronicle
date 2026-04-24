defmodule Chronicle.Engine.Diagrams.ReferenceUpdater do
  @moduledoc """
  Replace artifact://, object://, ${object://} URIs with computed GUIDs.
  """

  @artifact_pattern ~r/artifact:\/\/([^\s"']+)/
  @object_pattern ~r/object:\/\/([^\s"']+)/
  @dollar_object_pattern ~r/\$\{object:\/\/([^\s"'}]+)\}/

  def update_references(content, file_map \\ %{}) when is_binary(content) do
    content
    |> replace_pattern(@artifact_pattern, file_map, "artifact")
    |> replace_pattern(@object_pattern, file_map, "object")
    |> replace_pattern(@dollar_object_pattern, file_map, "object")
  end

  defp replace_pattern(content, pattern, file_map, _type) do
    Regex.replace(pattern, content, fn _full_match, filename ->
      case Map.get(file_map, filename) do
        nil -> compute_guid(filename)
        guid -> guid
      end
    end)
  end

  defp compute_guid(filename) do
    :crypto.hash(:md5, filename)
    |> Base.encode16(case: :lower)
    |> format_as_guid()
  end

  defp format_as_guid(hex) do
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12), _::binary>> = hex
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
