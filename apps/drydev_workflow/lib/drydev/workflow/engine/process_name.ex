defmodule DryDev.Workflow.Engine.ProcessName do
  @moduledoc """
  Parse process names in format: collection@version!tenant/name
  Supports Latest/Current version specifiers.
  """

  @type t :: %__MODULE__{
    collection: String.t() | nil,
    version: String.t() | nil,
    tenant: String.t() | nil,
    name: String.t()
  }

  defstruct [:collection, :version, :tenant, :name]

  @doc "Parse a process name string into struct."
  def parse(raw) when is_binary(raw) do
    {collection, rest} = extract_collection(raw)
    {version, rest} = extract_version(rest)
    {tenant, name} = extract_tenant(rest)

    %__MODULE__{
      collection: collection,
      version: version,
      tenant: tenant,
      name: name
    }
  end

  defp extract_collection(str) do
    case String.split(str, "@", parts: 2) do
      [collection, rest] -> {collection, rest}
      [rest] -> {nil, rest}
    end
  end

  defp extract_version(str) do
    case String.split(str, "!", parts: 2) do
      [version, rest] -> {version, rest}
      [rest] -> {nil, rest}
    end
  end

  defp extract_tenant(str) do
    case String.split(str, "/", parts: 2) do
      [tenant, name] -> {tenant, name}
      [name] -> {nil, name}
    end
  end

  def to_string(%__MODULE__{} = pn) do
    parts = []
    parts = if pn.collection, do: [pn.collection, "@" | parts], else: parts
    parts = if pn.version, do: parts ++ [pn.version, "!"], else: parts
    parts = if pn.tenant, do: parts ++ [pn.tenant, "/"], else: parts
    parts = parts ++ [pn.name]
    IO.iodata_to_binary(parts)
  end
end
