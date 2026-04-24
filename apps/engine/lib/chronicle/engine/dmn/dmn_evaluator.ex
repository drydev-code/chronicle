defmodule Chronicle.Engine.Dmn.DmnEvaluator do
  @moduledoc """
  DMN decision table evaluator using Erlang's built-in :xmerl XML parser.

  Supports hit policies: FIRST, UNIQUE, ANY, COLLECT.

  Input entry expression patterns:
    - Comparison: >= 18, < 10, == "value", != "other"
    - Range: [1..10] (inclusive), ]1..10[ (exclusive), [1..10[ (mixed)
    - String literal: "value" (exact match)
    - Number literal: 42 (exact match)
    - Boolean: true, false
    - Empty/dash: "-" or empty string (always matches)
  """

  alias Chronicle.Engine.Dmn.XmlHelpers
  alias Chronicle.Engine.Dmn.TypeMatcher

  require Logger

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Evaluate DMN XML content against the given inputs map.

  Returns `{:ok, result}` where result is a map (FIRST/UNIQUE/ANY)
  or a list of maps (COLLECT).
  """
  def evaluate(dmn_content, inputs) when is_binary(dmn_content) do
    try do
      {doc, _rest} = :xmerl_scan.string(String.to_charlist(dmn_content), [])
      tables = extract_decision_tables(doc)

      case tables do
        [] ->
          {:ok, %{}}

        [table | _] ->
          result = evaluate_table(table, inputs)
          {:ok, result}
      end
    rescue
      e ->
        Logger.error("DMN evaluation failed: #{inspect(e)}")
        {:error, "DMN evaluation failed: #{inspect(e)}"}
    catch
      :exit, reason ->
        Logger.error("DMN XML parsing failed: #{inspect(reason)}")
        {:error, "DMN XML parsing failed: #{inspect(reason)}"}
    end
  end

  # -------------------------------------------------------------------
  # XML Extraction
  # -------------------------------------------------------------------

  defp extract_decision_tables(doc) do
    XmlHelpers.find_elements(doc, :decisionTable)
    |> Enum.map(&parse_decision_table/1)
  end

  defp parse_decision_table(dt_element) do
    hit_policy =
      XmlHelpers.get_attribute(dt_element, :hitPolicy)
      |> normalize_hit_policy()

    inputs = XmlHelpers.find_elements(dt_element, :input) |> Enum.map(&parse_input/1)
    outputs = XmlHelpers.find_elements(dt_element, :output) |> Enum.map(&parse_output/1)
    rules = XmlHelpers.find_elements(dt_element, :rule) |> Enum.map(&parse_rule/1)

    %{
      hit_policy: hit_policy,
      inputs: inputs,
      outputs: outputs,
      rules: rules
    }
  end

  defp parse_input(input_element) do
    label = XmlHelpers.get_attribute(input_element, :label) || ""

    expr_text =
      case XmlHelpers.find_elements(input_element, :inputExpression) do
        [expr | _] ->
          case XmlHelpers.find_elements(expr, :text) do
            [text_el | _] -> XmlHelpers.get_text_content(text_el)
            [] -> label
          end

        [] ->
          label
      end

    %{label: label, expression: expr_text}
  end

  defp parse_output(output_element) do
    %{
      name: XmlHelpers.get_attribute(output_element, :name) || XmlHelpers.get_attribute(output_element, :label) || "result",
      label: XmlHelpers.get_attribute(output_element, :label) || ""
    }
  end

  defp parse_rule(rule_element) do
    input_entries =
      XmlHelpers.find_elements(rule_element, :inputEntry)
      |> Enum.map(fn entry ->
        case XmlHelpers.find_elements(entry, :text) do
          [text_el | _] -> XmlHelpers.get_text_content(text_el)
          [] -> "-"
        end
      end)

    output_entries =
      XmlHelpers.find_elements(rule_element, :outputEntry)
      |> Enum.map(fn entry ->
        case XmlHelpers.find_elements(entry, :text) do
          [text_el | _] -> XmlHelpers.get_text_content(text_el)
          [] -> ""
        end
      end)

    %{input_entries: input_entries, output_entries: output_entries}
  end

  # -------------------------------------------------------------------
  # Evaluation
  # -------------------------------------------------------------------

  defp evaluate_table(%{hit_policy: hit_policy, inputs: inputs, outputs: outputs, rules: rules}, input_values) do
    input_keys = Enum.map(inputs, & &1.expression)

    matching_rules =
      Enum.filter(rules, fn rule ->
        rule_matches?(rule.input_entries, input_keys, input_values)
      end)

    case hit_policy do
      :collect ->
        Enum.map(matching_rules, fn rule ->
          build_output(outputs, rule.output_entries)
        end)

      _first_or_unique_or_any ->
        case matching_rules do
          [] -> %{}
          [first | _] -> build_output(outputs, first.output_entries)
        end
    end
  end

  defp rule_matches?(input_entries, input_keys, input_values) do
    input_entries
    |> Enum.zip(input_keys)
    |> Enum.all?(fn {entry_expr, key} ->
      value = resolve_input(key, input_values)
      TypeMatcher.matches_entry?(entry_expr, value)
    end)
  end

  defp resolve_input(key, input_values) when is_map(input_values) do
    case Map.get(input_values, key) do
      nil -> Map.get(input_values, String.to_atom(key), nil)
      val -> val
    end
  rescue
    ArgumentError -> Map.get(input_values, key)
  end

  defp build_output(outputs, output_entries) do
    outputs
    |> Enum.zip(output_entries)
    |> Enum.into(%{}, fn {output, entry_text} ->
      {output.name, TypeMatcher.parse_output_value(entry_text)}
    end)
  end

  # -------------------------------------------------------------------
  # Hit policy normalization
  # -------------------------------------------------------------------

  defp normalize_hit_policy(nil), do: :first
  defp normalize_hit_policy(""), do: :first

  defp normalize_hit_policy(policy) do
    case String.upcase(to_string(policy)) do
      "FIRST" -> :first
      "UNIQUE" -> :unique
      "ANY" -> :any
      "COLLECT" -> :collect
      _ -> :first
    end
  end
end
