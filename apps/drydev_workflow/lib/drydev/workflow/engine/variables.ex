defmodule DryDev.Workflow.Engine.Variables do
  @moduledoc """
  ExecutionDictionary equivalent - Map wrapper for workflow variables.
  Supports Get/Set/Keep operations matching the .NET API.
  """

  @type t :: %__MODULE__{data: map()}
  defstruct data: %{}

  def new(data \\ %{}), do: %__MODULE__{data: data}

  def get(%__MODULE__{data: data}, name), do: Map.get(data, name)

  def get(%__MODULE__{data: data}, name, default), do: Map.get(data, name, default)

  def set(%__MODULE__{data: data} = vars, name, value),
    do: %{vars | data: Map.put(data, name, value)}

  def keep(%__MODULE__{} = _vars, input_vars, name) do
    value = get(input_vars, name)
    if value != nil, do: {name, value}, else: nil
  end

  def keep_all(%__MODULE__{data: input_data}), do: input_data

  def keep_all_except(%__MODULE__{data: input_data}, except_names) do
    Map.drop(input_data, except_names)
  end

  def merge(%__MODULE__{data: data} = vars, new_data) when is_map(new_data),
    do: %{vars | data: Map.merge(data, new_data)}

  def to_map(%__MODULE__{data: data}), do: data

  def from_map(map) when is_map(map), do: %__MODULE__{data: map}
end
