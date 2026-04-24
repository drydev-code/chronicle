defmodule Chronicle.Engine.DmnName do
  @moduledoc "Parse DMN names in format: name@version!tenant"

  @type t :: %__MODULE__{
    name: String.t(),
    version: String.t() | nil,
    tenant: String.t() | nil
  }

  defstruct [:name, :version, :tenant]

  def parse(raw) when is_binary(raw) do
    {name_part, rest} = case String.split(raw, "@", parts: 2) do
      [n, r] -> {n, r}
      [n] -> {n, nil}
    end

    {version, tenant} = if rest do
      case String.split(rest, "!", parts: 2) do
        [v, t] -> {v, t}
        [v] -> {v, nil}
      end
    else
      {nil, nil}
    end

    %__MODULE__{name: name_part, version: version, tenant: tenant}
  end
end
