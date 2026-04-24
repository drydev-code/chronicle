defmodule Chronicle.Engine.Scripting.ExpressionEvaluator do
  @moduledoc "Boolean expression evaluation for gateways."

  def evaluate(expressions, inputs) when is_list(expressions) do
    Enum.map(expressions, fn {node_id, expr} ->
      result = evaluate_single(expr, inputs)
      {node_id, result}
    end)
  end

  defp evaluate_single(expr, _inputs) do
    # Simple inline evaluation for common patterns
    # Falls back to ScriptWorker for complex expressions
    case expr do
      "true" -> true
      "false" -> false
      _ -> :needs_js_eval
    end
  end
end
