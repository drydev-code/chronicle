defmodule Chronicle.Server.Web.Controllers.ExternalTaskController do
  use Phoenix.Controller, formats: [:json]

  alias Chronicle.Server.Host.ExternalTaskRouter

  def complete(conn, %{"task_id" => task_id} = params) do
    payload = Map.get(params, "payload", %{})
    result = Map.get(params, "result")

    reply(conn, ExternalTaskRouter.complete_task(task_id, payload, result), %{status: "completed", taskId: task_id})
  end

  def fail(conn, %{"task_id" => task_id} = params) do
    error =
      Map.get(params, "error") ||
        %{
          "error_message" => Map.get(params, "message", "Task failed"),
          "error_type" => Map.get(params, "type", "ExternalTaskFailed")
        }

    retry? = truthy?(Map.get(params, "retry", false))
    backoff_ms = positive_int(Map.get(params, "backoffMs", 0), 0)

    reply(conn, ExternalTaskRouter.fail_task(task_id, error, retry?, backoff_ms), %{status: "failed", taskId: task_id})
  end

  def cancel(conn, %{"task_id" => task_id} = params) do
    reason = Map.get(params, "reason", "Cancelled")
    continuation_node_id = Map.get(params, "continuationNodeId")

    reply(conn, ExternalTaskRouter.cancel_task(task_id, reason, continuation_node_id), %{
      status: "cancelled",
      taskId: task_id
    })
  end

  def execute_user_task(conn, %{"task_id" => task_id} = params) do
    payload = Map.get(params, "payload", %{})

    actor = %{
      type: Map.get(params, "actorType", "Actor"),
      id: Map.get(params, "userId") || conn.assigns[:user_id]
    }

    payload = Map.put(payload, "__actor", actor)
    reply(conn, ExternalTaskRouter.complete_task(task_id, payload, nil), %{status: "executed", taskId: task_id})
  end

  def reject_user_task(conn, %{"task_id" => task_id} = params) do
    reason = Map.get(params, "reason", "Rejected")
    error = %{"error_message" => reason, "error_type" => "UserTaskRejected"}

    reply(conn, ExternalTaskRouter.fail_task(task_id, error, false, 0), %{status: "rejected", taskId: task_id})
  end

  defp reply(conn, :ok, body), do: json(conn, body)

  defp reply(conn, {:error, reason}, _body) do
    conn
    |> put_status(409)
    |> json(%{error: inspect(reason)})
  end

  defp truthy?(value), do: value in [true, "true", "True", "TRUE", 1, "1"]

  defp positive_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> default
    end
  end

  defp positive_int(_value, default), do: default
end
