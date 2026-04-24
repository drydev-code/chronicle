defmodule Chronicle.Server.Web.ParamsTest do
  use ExUnit.Case, async: true

  alias Chronicle.Server.Web.Params

  describe "positive_int/2" do
    test "valid integer in range returns {:ok, n}" do
      assert {:ok, 5} = Params.positive_int(5)
      assert {:ok, 100} = Params.positive_int("100")
      assert {:ok, 10_000} = Params.positive_int(10_000)
    end

    test "zero returns {:error, :out_of_range}" do
      assert {:error, :out_of_range} = Params.positive_int(0)
      assert {:error, :out_of_range} = Params.positive_int("0")
    end

    test "negative integer returns {:error, :out_of_range}" do
      assert {:error, :out_of_range} = Params.positive_int(-1)
      assert {:error, :out_of_range} = Params.positive_int("-5")
    end

    test "value over max returns {:error, :out_of_range}" do
      assert {:error, :out_of_range} = Params.positive_int(10_001)
      assert {:error, :out_of_range} = Params.positive_int("10001")
      assert {:error, :out_of_range} = Params.positive_int(1001, max: 1000)
      assert {:error, :out_of_range} = Params.positive_int("1001", max: 1000)
    end

    test "non-numeric string returns {:error, :not_an_integer}" do
      assert {:error, :not_an_integer} = Params.positive_int("abc")
      assert {:error, :not_an_integer} = Params.positive_int("12abc")
      assert {:error, :not_an_integer} = Params.positive_int("")
    end

    test "nil returns {:error, :invalid}" do
      assert {:error, :invalid} = Params.positive_int(nil)
    end

    test "other invalid types return {:error, :invalid}" do
      assert {:error, :invalid} = Params.positive_int(%{})
      assert {:error, :invalid} = Params.positive_int([])
      assert {:error, :invalid} = Params.positive_int(1.5)
    end

    test "custom max is respected" do
      assert {:ok, 1000} = Params.positive_int(1000, max: 1000)
      assert {:ok, 1000} = Params.positive_int("1000", max: 1000)
      assert {:error, :out_of_range} = Params.positive_int(1001, max: 1000)
    end
  end
end
