defmodule Chronicle.Engine.LargeVariablesCleanerTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.LargeVariablesCleaner

  setup do
    original = Application.get_env(:engine, :large_variables_cleaner)
    Application.delete_env(:engine, :large_variables_cleaner)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:engine, :large_variables_cleaner)
        mod -> Application.put_env(:engine, :large_variables_cleaner, mod)
      end
    end)

    :ok
  end

  test "enabled?/0 returns false when no implementation is configured" do
    refute LargeVariablesCleaner.enabled?()
  end

  test "cleanup/2 returns :ok when no implementation is configured" do
    assert LargeVariablesCleaner.cleanup("instance-id", "tenant-id") == :ok
  end
end
