defmodule Chronicle.Server.Host.ExternalTasks.BuiltInExecutorTest do
  use ExUnit.Case, async: true

  alias Chronicle.Server.Host.ExternalTasks.BuiltInExecutor
  alias Chronicle.Server.Host.ExternalTasks.Executors
  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

  setup_all do
    case :inets.start() do
      :ok -> :ok
      {:error, {:already_started, :inets}} -> :ok
    end

    :ok
  end

  test "supports built-in REST, database, and AI topics" do
    assert BuiltInExecutor.supported?(%ServiceTaskExtension{topic: "rest"})
    assert BuiltInExecutor.supported?(%ServiceTaskExtension{topic: "database"})
    assert BuiltInExecutor.supported?(%ServiceTaskExtension{topic: "ai"})
    assert BuiltInExecutor.supported?(%ServiceTaskExtension{topic: "email"})
    assert BuiltInExecutor.supported?(%ServiceTaskExtension{topic: "transform"})
  end

  test "leaves unknown topics for AMQP workers" do
    refute BuiltInExecutor.supported?(%ServiceTaskExtension{topic: "billing"})
    refute BuiltInExecutor.supported?(%ServiceTaskExtension{topic: nil})
  end

  test "resolves concrete executor plugins through the registry" do
    assert Executors.Registry.executor_for(%ServiceTaskExtension{topic: "rest"}) == Executors.Rest
    assert Executors.Registry.executor_for(%ServiceTaskExtension{topic: "database"}) == Executors.Database
    assert Executors.Registry.executor_for(%ServiceTaskExtension{topic: "ai"}) == Executors.AI
    assert Executors.Registry.executor_for(%ServiceTaskExtension{topic: "email"}) == Executors.Email
    assert Executors.Registry.executor_for(%ServiceTaskExtension{topic: "transform"}) == Executors.Transform
  end

  test "REST executor fails HTTP error statuses with response context" do
    url = start_http_server(404, ~s({"message":"missing"}))

    assert {:error, error} =
             Executors.Rest.execute(%{payload: %{}}, %ServiceTaskExtension{
               topic: "rest",
               endpoint: url,
               method: :get,
               extensions: %{}
             })

    assert error["error_type"] == "HttpStatusError"
    assert error["status"] == 404
    assert error["response"]["body"] == %{"message" => "missing"}
  end

  test "REST executor extracts configured result path from JSON response body" do
    url = start_http_server(200, ~s({"data":{"total":42}}))

    assert {:ok, 42, %{executor: "built_in_rest", status: 200}} =
             Executors.Rest.execute(%{payload: %{}}, %ServiceTaskExtension{
               topic: "rest",
               endpoint: url,
               method: :get,
               extensions: %{"resultMode" => "body", "resultPath" => "data.total"}
             })
  end

  test "database executor rejects writes unless explicitly allowed" do
    assert {:error, reason} =
             Executors.Database.execute(%{payload: %{}}, %ServiceTaskExtension{
               topic: "database",
               extensions: %{"query" => "delete from process_instances"}
             })

    assert reason =~ "read-only"
  end

  test "AI executor requires endpoint" do
    assert {:error, reason} =
             Executors.AI.execute(%{payload: %{"prompt" => "hello"}}, %ServiceTaskExtension{
               topic: "ai",
               extensions: %{"prompt" => "Say {{prompt}}"}
             })

    assert String.downcase(reason) =~ "require an endpoint"
  end

  test "transform executor renders JSON into result payload" do
    assert {:ok, %{"greeting" => "Hello Ada"}, %{executor: "built_in_transform"}} =
             Executors.Transform.execute(%{payload: %{"name" => "Ada"}}, %ServiceTaskExtension{
               topic: "transform",
               body: ~s({"greeting":"Hello {{name}}"}),
               extensions: %{}
             })
  end

  test "email executor prepares normalized email command" do
    assert {:ok, email, %{executor: "built_in_email"}} =
             Executors.Email.execute(%{payload: %{}}, %ServiceTaskExtension{
               topic: "email",
               extensions: %{
                 "to" => "a@example.test; b@example.test",
                 "subject" => "Hello",
                 "body" => "Body"
               }
             })

    assert email["to"] == ["a@example.test", "b@example.test"]
    assert email["status"] == "prepared"
  end

  defp start_http_server(status, body) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen_socket)

    parent = self()

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

      response = """
      HTTP/1.1 #{status} Test\r
      content-type: application/json\r
      content-length: #{byte_size(body)}\r
      connection: close\r
      \r
      #{body}
      """

      :ok = :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen_socket)
      send(parent, :served)
    end)

    "http://127.0.0.1:#{port}/test"
  end
end
