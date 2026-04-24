defmodule Chronicle.Engine.Instance.WaitRegistryTest do
  use ExUnit.Case, async: false

  alias Chronicle.Engine.Instance.WaitRegistry

  setup do
    # Start a :duplicate Registry named :waits for this test. If a previous
    # test (or the engine supervisor) already started it, reuse it.
    case Registry.start_link(keys: :duplicate, name: :waits) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "unregister/3" do
    test "removes a previously registered wait by matching the token id value" do
      key = {"tenant-a", :message, "msg-1", "bk-1"}
      token_id = 42

      {:ok, _} = Registry.register(:waits, key, token_id)
      assert [{_pid, ^token_id}] = Registry.lookup(:waits, key)

      assert :ok = WaitRegistry.unregister(:waits, key, token_id)
      assert [] = Registry.lookup(:waits, key)
    end

    test "removes only the matching token entry when multiple entries share the key" do
      key = {"tenant-a", :signal, "sig-1"}

      {:ok, _} = Registry.register(:waits, key, 1)
      {:ok, _} = Registry.register(:waits, key, 2)

      assert Registry.lookup(:waits, key) |> length() == 2

      assert :ok = WaitRegistry.unregister(:waits, key, 1)

      remaining = Registry.lookup(:waits, key)
      assert length(remaining) == 1
      assert [{_pid, 2}] = remaining
    end

    test "is a no-op when the entry does not exist" do
      key = {"tenant-a", :message, "missing", "bk"}
      assert :ok = WaitRegistry.unregister(:waits, key, 999)
      assert [] = Registry.lookup(:waits, key)
    end
  end
end
