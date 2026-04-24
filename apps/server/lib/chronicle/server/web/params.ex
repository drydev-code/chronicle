defmodule Chronicle.Server.Web.Params do
  @moduledoc "Safe request parameter parsing helpers."

  @doc """
  Parse a positive integer with upper bound. Returns `{:ok, int}` or
  `{:error, reason}`. Bound defaults to 10_000.
  """
  def positive_int(value, opts \\ []) do
    max = Keyword.get(opts, :max, 10_000)

    case value do
      n when is_integer(n) and n > 0 and n <= max ->
        {:ok, n}

      n when is_integer(n) ->
        {:error, :out_of_range}

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n > 0 and n <= max -> {:ok, n}
          {_, ""} -> {:error, :out_of_range}
          _ -> {:error, :not_an_integer}
        end

      _ ->
        {:error, :invalid}
    end
  end
end
