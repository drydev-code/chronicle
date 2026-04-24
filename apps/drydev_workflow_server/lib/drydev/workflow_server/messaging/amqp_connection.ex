defmodule DryDev.WorkflowServer.Messaging.AmqpConnection do
  @moduledoc """
  Manages AMQP connection and channel for publishing messages.
  Uses a GenServer to maintain a persistent connection with auto-reconnect.
  """
  use GenServer
  require Logger

  @reconnect_interval 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Publish a message to an exchange.

  Options:
    - headers: list of {key, value} tuples for AMQP headers
    - type: AMQP type property (message type string, used by Util.ServiceBus)
  """
  def publish(exchange, routing_key, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:publish, exchange, routing_key, payload, opts})
  end

  def get_connection_url do
    config = Application.get_env(:drydev_workflow_server, :rabbitmq, [])
    host = Keyword.get(config, :host, "localhost")
    port = Keyword.get(config, :port, 5672)
    username = Keyword.get(config, :username, "guest")
    password = Keyword.get(config, :password, "guest")
    vhost = Keyword.get(config, :virtual_host, "/")

    "amqp://#{username}:#{password}@#{host}:#{port}/#{URI.encode_www_form(vhost)}"
  end

  def get_amqp_config do
    config = Application.get_env(:drydev_workflow_server, :rabbitmq, [])
    [
      host: Keyword.get(config, :host, "localhost"),
      port: Keyword.get(config, :port, 5672),
      username: Keyword.get(config, :username, "guest"),
      password: Keyword.get(config, :password, "guest"),
      virtual_host: Keyword.get(config, :virtual_host, "/")
    ]
  end

  # -- Server callbacks --

  @impl true
  def init(_opts) do
    send(self(), :connect)
    {:ok, %{conn: nil, channel: nil}}
  end

  @impl true
  def handle_info(:connect, state) do
    case AMQP.Connection.open(get_connection_url()) do
      {:ok, conn} ->
        Process.monitor(conn.pid)
        {:ok, channel} = AMQP.Channel.open(conn)
        Logger.info("AMQP connected to #{get_amqp_config()[:host]}")
        {:noreply, %{state | conn: conn, channel: channel}}

      {:error, reason} ->
        Logger.warning("AMQP connection failed: #{inspect(reason)}, retrying in #{@reconnect_interval}ms")
        Process.send_after(self(), :connect, @reconnect_interval)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _, :process, _pid, reason}, state) do
    Logger.warning("AMQP connection lost: #{inspect(reason)}, reconnecting...")
    Process.send_after(self(), :connect, @reconnect_interval)
    {:noreply, %{state | conn: nil, channel: nil}}
  end

  @impl true
  def handle_call({:publish, _exchange, _routing_key, _payload, _opts}, _from, %{channel: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call({:publish, exchange, routing_key, payload, opts}, _from, %{channel: channel} = state) do
    {headers, opts} = Keyword.pop(opts, :headers, [])
    {message_type, _opts} = Keyword.pop(opts, :type, nil)

    amqp_headers = Enum.map(headers, fn {k, v} -> {to_string(k), :longstr, to_string(v)} end)

    publish_opts = [
      headers: amqp_headers,
      content_type: "application/json",
      persistent: true
    ]

    publish_opts = if message_type, do: Keyword.put(publish_opts, :type, message_type), else: publish_opts

    result = AMQP.Basic.publish(channel, exchange, routing_key, payload, publish_opts)
    {:reply, result, state}
  end
end
