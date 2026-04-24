defmodule Chronicle.Engine.Dmn.XmlHelpers do
  @moduledoc """
  Stateless XML utility functions for traversing xmerl-parsed documents.

  Wraps common operations on xmerl record tuples so callers do not need to
  pattern-match on the raw tuple shapes directly.
  """

  @doc """
  Recursively find all XML elements matching `tag_name` (by local name).
  Handles namespace-qualified names produced by :xmerl.
  """
  def find_elements(element, tag_name) do
    case element do
      {:xmlElement, name, _, _, _, _, _, _, content, _, _, _} ->
        direct =
          if local_name_match?(name, tag_name) do
            [element]
          else
            []
          end

        children =
          Enum.flat_map(content || [], fn child ->
            find_elements(child, tag_name)
          end)

        direct ++ children

      _ ->
        []
    end
  end

  @doc """
  Get the value of an attribute on an XML element.
  Returns `nil` when the element is not an xmlElement or the attribute is absent.
  """
  def get_attribute(element, attr_name) do
    case element do
      {:xmlElement, _, _, _, _, _, _, attributes, _, _, _, _} ->
        Enum.find_value(attributes, fn
          {:xmlAttribute, ^attr_name, _, _, _, _, _, _, value, _} ->
            to_string(value)

          _ ->
            nil
        end)

      _ ->
        nil
    end
  end

  @doc """
  Extract concatenated text content from an XML element's children.
  """
  def get_text_content(element) do
    case element do
      {:xmlElement, _, _, _, _, _, _, _, content, _, _, _} ->
        content
        |> Enum.map(fn
          {:xmlText, _, _, _, value, _} -> to_string(value)
          _ -> ""
        end)
        |> Enum.join()
        |> String.trim()

      _ ->
        ""
    end
  end

  @doc """
  Check whether an xmerl element name matches `tag_name` by local name.
  Handles both plain atoms and namespace-qualified names.
  """
  def local_name_match?(name, tag_name) when is_atom(name) do
    name == tag_name or
      String.ends_with?(Atom.to_string(name), Atom.to_string(tag_name))
  end

  def local_name_match?(_, _), do: false
end
