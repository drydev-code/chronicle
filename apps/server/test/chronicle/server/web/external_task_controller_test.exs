defmodule Chronicle.Server.Web.ExternalTaskControllerTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint Chronicle.Server.Web.Endpoint

  setup do
    case start_supervised({Phoenix.PubSub, name: Chronicle.PubSub}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case start_supervised(Chronicle.Server.Host.ExternalTaskRouter) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "external task complete command is exposed through REST" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/external-tasks/missing-task/complete", %{payload: %{ok: true}})

    assert json_response(conn, 409)["error"] == ":unknown_task"
  end

  test "user task reject command is exposed through REST" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/api/user-tasks/missing-task/reject", %{reason: "not enough data"})

    assert json_response(conn, 409)["error"] == ":unknown_task"
  end
end
