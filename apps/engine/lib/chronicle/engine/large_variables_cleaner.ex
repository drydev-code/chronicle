defmodule Chronicle.Engine.LargeVariablesCleaner do
  @moduledoc """
  Optional callback for releasing large-variable storage when an instance
  completes or terminates. Host applications (e.g., Chronicle.Server) can
  implement this and register via config `:engine, :large_variables_cleaner`.
  """
  @callback enabled?() :: boolean()
  @callback cleanup(instance_id :: String.t(), tenant_id :: String.t()) :: :ok

  @spec enabled?() :: boolean()
  def enabled? do
    case impl() do
      nil -> false
      mod -> mod.enabled?()
    end
  end

  @spec cleanup(String.t(), String.t()) :: :ok
  def cleanup(instance_id, tenant_id) do
    case impl() do
      nil -> :ok
      mod -> mod.cleanup(instance_id, tenant_id)
    end
  end

  defp impl, do: Application.get_env(:engine, :large_variables_cleaner)
end
