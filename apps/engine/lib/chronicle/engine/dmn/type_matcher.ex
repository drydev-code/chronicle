defmodule Chronicle.Engine.Dmn.TypeMatcher do
  @moduledoc """
  Expression matching and type coercion for DMN input entries.

  Handles comparison operators, range expressions, boolean/string/number
  literals, and the value normalization needed to compare heterogeneous
  input types.
  """

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Returns `true` when `value` satisfies the DMN input entry expression `expr`.

  Empty or dash expressions always match.
  """
  def matches_entry?(expr, value) do
    trimmed = String.trim(expr)

    if trimmed == "" or trimmed == "-" do
      true
    else
      match_expression(trimmed, value)
    end
  end

  @doc """
  Parse a raw output text value into an appropriate Elixir term.
  """
  def parse_output_value(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> nil
      trimmed == "true" -> true
      trimmed == "false" -> false
      Regex.match?(~r/^".*"$/, trimmed) -> String.slice(trimmed, 1..-2//1)
      Regex.match?(~r/^-?\d+\.\d+$/, trimmed) -> String.to_float(trimmed)
      Regex.match?(~r/^-?\d+$/, trimmed) -> String.to_integer(trimmed)
      true -> trimmed
    end
  end

  # -------------------------------------------------------------------
  # Expression dispatch
  # -------------------------------------------------------------------

  defp match_expression(expr, value) do
    cond do
      # Range: [1..10], ]1..10[, [1..10[, ]1..10]
      Regex.match?(~r/^[\[\]]\s*-?\d+\.?\d*\s*\.\.\s*-?\d+\.?\d*\s*[\[\]]$/, expr) ->
        match_range(expr, value)

      # Comparison operators: >= 18, <= 5, > 10, < 3, == "val", != "val"
      String.starts_with?(expr, ">=") ->
        match_comparison(:gte, String.trim(String.slice(expr, 2..-1//1)), value)

      String.starts_with?(expr, "<=") ->
        match_comparison(:lte, String.trim(String.slice(expr, 2..-1//1)), value)

      String.starts_with?(expr, "!=") ->
        match_comparison(:neq, String.trim(String.slice(expr, 2..-1//1)), value)

      String.starts_with?(expr, "==") ->
        match_comparison(:eq, String.trim(String.slice(expr, 2..-1//1)), value)

      String.starts_with?(expr, ">") ->
        match_comparison(:gt, String.trim(String.slice(expr, 1..-1//1)), value)

      String.starts_with?(expr, "<") ->
        match_comparison(:lt, String.trim(String.slice(expr, 1..-1//1)), value)

      # Boolean
      expr == "true" ->
        value == true or value == "true"

      expr == "false" ->
        value == false or value == "false"

      # Quoted string literal
      Regex.match?(~r/^".*"$/, expr) ->
        unquoted = String.slice(expr, 1..-2//1)
        to_string(value) == unquoted

      # Number literal
      Regex.match?(~r/^-?\d+\.?\d*$/, expr) ->
        match_number_literal(expr, value)

      true ->
        to_string(value) == expr
    end
  end

  # -------------------------------------------------------------------
  # Comparison helpers
  # -------------------------------------------------------------------

  defp match_comparison(op, operand_str, value) do
    operand = parse_comparable(operand_str)
    val = normalize_for_comparison(value)

    case {val, operand} do
      {nil, _} -> false
      {v, o} when is_number(v) and is_number(o) -> compare_numbers(op, v, o)
      {v, o} -> compare_strings(op, to_string(v), to_string(o))
    end
  end

  defp compare_numbers(:gt, a, b), do: a > b
  defp compare_numbers(:gte, a, b), do: a >= b
  defp compare_numbers(:lt, a, b), do: a < b
  defp compare_numbers(:lte, a, b), do: a <= b
  defp compare_numbers(:eq, a, b), do: a == b
  defp compare_numbers(:neq, a, b), do: a != b

  defp compare_strings(:eq, a, b), do: a == b
  defp compare_strings(:neq, a, b), do: a != b
  defp compare_strings(:gt, a, b), do: a > b
  defp compare_strings(:gte, a, b), do: a >= b
  defp compare_strings(:lt, a, b), do: a < b
  defp compare_strings(:lte, a, b), do: a <= b

  defp match_range(expr, value) do
    case Regex.run(~r/^([\[\]])\s*(-?\d+\.?\d*)\s*\.\.\s*(-?\d+\.?\d*)\s*([\[\]])$/, expr) do
      [_, left_bracket, low_str, high_str, right_bracket] ->
        low = parse_number(low_str)
        high = parse_number(high_str)
        val = normalize_for_comparison(value)

        case val do
          nil ->
            false

          v when is_number(v) ->
            left_ok = if left_bracket == "[", do: v >= low, else: v > low
            right_ok = if right_bracket == "]", do: v <= high, else: v < high
            left_ok and right_ok

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp match_number_literal(expr, value) do
    num = parse_number(expr)
    val = normalize_for_comparison(value)
    val == num
  end

  # -------------------------------------------------------------------
  # Value parsing / normalization
  # -------------------------------------------------------------------

  defp parse_comparable(str) do
    stripped =
      if Regex.match?(~r/^".*"$/, str) do
        String.slice(str, 1..-2//1)
      else
        str
      end

    case parse_number_safe(stripped) do
      {:ok, n} -> n
      :error -> stripped
    end
  end

  defp normalize_for_comparison(nil), do: nil
  defp normalize_for_comparison(value) when is_number(value), do: value

  defp normalize_for_comparison(value) when is_binary(value) do
    case parse_number_safe(value) do
      {:ok, n} -> n
      :error -> value
    end
  end

  defp normalize_for_comparison(value), do: value

  defp parse_number(str) do
    if String.contains?(str, ".") do
      String.to_float(str)
    else
      String.to_integer(str)
    end
  end

  defp parse_number_safe(str) do
    cond do
      Regex.match?(~r/^-?\d+\.\d+$/, str) -> {:ok, String.to_float(str)}
      Regex.match?(~r/^-?\d+$/, str) -> {:ok, String.to_integer(str)}
      true -> :error
    end
  end
end
