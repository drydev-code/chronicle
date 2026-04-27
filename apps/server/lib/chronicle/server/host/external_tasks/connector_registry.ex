defmodule Chronicle.Server.Host.ExternalTasks.ConnectorRegistry do
  @moduledoc """
  Resolves service task execution placement from the connector registry.

  Production deployments read durable connector rows through the configured
  store module and merge them with JSON supplied through application config,
  typically from `CONNECTOR_REGISTRY_JSON`. The env JSON remains a seed and
  fallback path so existing deployments keep working without a database row.

  Supported seed shapes are:

      [%{"id" => "rest", "topics" => ["rest"], "placement" => "satellite"}]
      %{"connectors" => [...]}
      %{"rest" => %{"topics" => ["rest"], "placement" => "satellite"}}
  """

  require Logger

  alias Chronicle.Server.Host.VendorExtensions.ServiceTaskExtension

  @cache_key {__MODULE__, :cache}
  @default_placement :builtin_or_amqp
  @store Chronicle.Server.Host.ExternalTasks.ConnectorRegistry.EctoStore

  @placements %{
    "amqp" => :amqp,
    "external" => :amqp,
    "local" => :local,
    "builtin" => :local,
    "built_in" => :local,
    "satellite" => :satellite
  }

  @placement_names Map.keys(@placements)

  @type connector_entry :: map()

  @doc "Resolve a service task extension to placement and merged metadata."
  def resolve(%ServiceTaskExtension{} = extension) do
    execution = map_or_empty(extension.execution)
    connector = map_or_empty(extension.connector)

    registry_entry =
      registry()
      |> Enum.find(&matches?(&1, extension, connector))

    placement =
      placement_from(execution) ||
        placement_from(connector) ||
        placement_from(registry_entry || %{}) ||
        @default_placement

    %{
      placement: placement,
      connector: merge_metadata(registry_entry, connector),
      execution: merge_metadata(registry_entry && Map.get(registry_entry, "execution"), execution)
    }
  end

  @doc "Returns the cached registry, loading durable rows and seed JSON on first read."
  def registry do
    cache().connectors
  end

  @doc "Returns the cached connector registry entry for `id`, if present."
  def get(id) do
    normalized_id = normalize_id(id)
    Enum.find(registry(), &(normalize_id(&1["id"]) == normalized_id))
  end

  @doc "Returns cache metadata useful for management APIs."
  def info do
    Map.delete(cache(), :connectors)
  end

  @doc "Reloads the cache from durable storage and env seed JSON."
  def reload do
    cache = load_cache()
    :persistent_term.put(@cache_key, cache)
    {:ok, cache}
  end

  @doc "Validates and persists a connector entry, then reloads the cache."
  def upsert(id, attrs) when is_map(attrs) do
    entry_attrs = attrs |> unwrap_connector_payload() |> Map.put("id", id)

    with {:ok, entry} <- validate_entry(entry_attrs),
         {:ok, persisted} <- store().upsert(entry["id"], entry),
         {:ok, _cache} <- reload() do
      {:ok, persisted}
    end
  end

  @doc "Deletes a durable connector entry, then reloads the cache."
  def delete(id) do
    with {:ok, result} <- store().delete(to_string(id)),
         {:ok, _cache} <- reload() do
      {:ok, result}
    end
  end

  @doc false
  def clear_cache do
    :persistent_term.erase(@cache_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def validate_entry(entry) when is_map(entry) do
    entry = entry |> stringify_keys() |> normalize_aliases()

    raw_id = Map.get(entry, "id")
    raw_placement = Map.get(entry, "placement")

    id = normalize_connector_id(raw_id)
    topics = normalize_topics(Map.get(entry, "topics", Map.get(entry, "topic", [])))
    placement = normalize_placement_name(raw_placement)
    capabilities = normalize_metadata_map(Map.get(entry, "capabilities"), "capabilities")

    placement_metadata =
      normalize_metadata_map(Map.get(entry, "placementMetadata"), "placementMetadata")

    execution = normalize_metadata_map(Map.get(entry, "execution"), "execution")

    errors =
      []
      |> validate_connector_id(raw_id, id)
      |> validate_placement(raw_placement, placement)
      |> append_metadata_error(capabilities)
      |> append_metadata_error(placement_metadata)
      |> append_metadata_error(execution)

    if errors == [] do
      {:ok,
       entry
       |> Map.put("id", id)
       |> Map.put("topics", topics)
       |> Map.put("placement", placement)
       |> Map.put("capabilities", elem(capabilities, 1))
       |> Map.put("placementMetadata", elem(placement_metadata, 1))
       |> Map.put("execution", elem(execution, 1))
       |> Map.delete("topic")
       |> Map.delete("placement_metadata")}
    else
      {:error, %{errors: Enum.reverse(errors)}}
    end
  end

  def validate_entry(_entry), do: {:error, %{errors: ["connector must be an object"]}}

  @doc false
  def decode_seed(value) do
    value
    |> decode_registry()
    |> validate_entries(:seed)
  end

  defp cache do
    :persistent_term.get(@cache_key)
  rescue
    ArgumentError ->
      {:ok, cache} = reload()
      cache
  end

  defp load_cache do
    {seed_entries, seed_errors} =
      case decode_seed(Application.get_env(:server, :connector_registry, [])) do
        {:ok, entries} -> {entries, []}
        {:error, errors, entries} -> {entries, errors}
      end

    {durable_entries, durable_errors} =
      case store().all() do
        {:ok, entries} ->
          case validate_entries(entries, :durable) do
            {:ok, valid_entries} -> {valid_entries, []}
            {:error, errors, valid_entries} -> {valid_entries, errors}
          end

        {:error, reason} ->
          Logger.debug("Connector registry durable store unavailable: #{inspect(reason)}")
          {[], [%{source: :durable, error: inspect(reason)}]}
      end

    connectors = merge_entries(seed_entries, durable_entries)

    %{
      connectors: connectors,
      loaded_at: DateTime.utc_now(),
      sources: %{seed: length(seed_entries), durable: length(durable_entries)},
      errors: seed_errors ++ durable_errors
    }
  end

  defp validate_entries(entries, source) when is_list(entries) do
    {valid, errors} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {entry, index}, {valid, errors} ->
        case validate_entry(entry) do
          {:ok, normalized} ->
            {[normalized | valid], errors}

          {:error, %{errors: entry_errors}} ->
            error = %{source: source, index: index, errors: entry_errors}
            {valid, [error | errors]}
        end
      end)

    valid = Enum.reverse(valid)
    errors = Enum.reverse(errors)

    if errors == [], do: {:ok, valid}, else: {:error, errors, valid}
  end

  defp validate_entries(_entries, source) do
    {:error, [%{source: source, errors: ["registry must be a list"]}], []}
  end

  defp merge_entries(seed_entries, durable_entries) do
    seed_entries
    |> Enum.concat(durable_entries)
    |> Enum.reduce(%{}, fn entry, acc -> Map.put(acc, normalize_id(entry["id"]), entry) end)
    |> Map.values()
    |> Enum.sort_by(&normalize_id(&1["id"]))
  end

  defp decode_registry(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      []
    else
      case Jason.decode(value) do
        {:ok, decoded} -> decode_registry(decoded)
        {:error, error} -> [%{"id" => "", "decode_error" => Exception.message(error)}]
      end
    end
  end

  defp decode_registry(%{"connectors" => connectors}), do: decode_registry(connectors)
  defp decode_registry(%{connectors: connectors}), do: decode_registry(connectors)

  defp decode_registry(connectors) when is_list(connectors) do
    connectors
    |> Enum.filter(&is_map/1)
    |> Enum.map(&stringify_keys/1)
  end

  defp decode_registry(connectors) when is_map(connectors) do
    connectors
    |> Enum.map(fn {id, config} ->
      config
      |> map_or_empty()
      |> stringify_keys()
      |> Map.put_new("id", to_string(id))
    end)
  end

  defp decode_registry(_), do: []

  defp matches?(entry, %ServiceTaskExtension{} = extension, connector) do
    topic = normalize(extension.topic)
    connector_id = normalize(connector["id"] || connector["name"] || extension.service)
    entry_id = normalize(entry["id"] || entry["name"])

    topic_match? =
      entry
      |> topics()
      |> Enum.any?(&(&1 == "*" or &1 == topic))

    id_match? = connector_id != "" and connector_id == entry_id

    topic_match? or id_match?
  end

  defp topics(entry) do
    entry
    |> Map.get("topics", Map.get(entry, "topic", []))
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp placement_from(nil), do: nil

  defp placement_from(map) when is_map(map) do
    value =
      Map.get(map, "placement") ||
        Map.get(map, "type") ||
        Map.get(map, "mode") ||
        get_in(map, ["execution", "placement"]) ||
        get_in(map, ["execution", "mode"])

    placement_from(value)
  end

  defp placement_from(value), do: Map.get(@placements, normalize(value))

  defp merge_metadata(nil, right), do: stringify_keys(right || %{})
  defp merge_metadata(left, nil), do: stringify_keys(left)

  defp merge_metadata(left, right) do
    Map.merge(stringify_keys(left), stringify_keys(right))
  end

  defp normalize_aliases(entry) do
    entry
    |> copy_key("placement_metadata", "placementMetadata")
  end

  defp copy_key(entry, from, to) do
    case {Map.has_key?(entry, from), Map.has_key?(entry, to)} do
      {true, false} -> Map.put(entry, to, Map.get(entry, from))
      _ -> entry
    end
  end

  defp normalize_connector_id(nil), do: nil

  defp normalize_connector_id(value) do
    value = value |> to_string() |> String.trim()

    cond do
      value == "" -> nil
      Regex.match?(~r/^[A-Za-z0-9_.:-]+$/, value) -> value
      true -> nil
    end
  end

  defp normalize_topics(value) do
    value
    |> List.wrap()
    |> Enum.map(&(to_string(&1) |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp normalize_placement_name(value) do
    normalized = normalize(value)
    if normalized in @placement_names, do: normalized
  end

  defp normalize_metadata_map(nil, _field), do: {:ok, %{}}
  defp normalize_metadata_map(value, _field) when is_map(value), do: {:ok, stringify_keys(value)}
  defp normalize_metadata_map(_value, field), do: {:error, "#{field} must be an object"}

  defp validate_connector_id(errors, raw_id, nil) do
    if blank?(raw_id) do
      ["id is required" | errors]
    else
      ["id may only contain letters, numbers, dot, underscore, colon, and dash" | errors]
    end
  end

  defp validate_connector_id(errors, _raw_id, _id), do: errors

  defp validate_placement(errors, raw_placement, nil) do
    if blank?(raw_placement) do
      ["placement is required" | errors]
    else
      ["placement must be one of #{Enum.join(@placement_names, ", ")}" | errors]
    end
  end

  defp validate_placement(errors, _raw_placement, _placement), do: errors

  defp blank?(nil), do: true
  defp blank?(value), do: value |> to_string() |> String.trim() == ""

  defp append_metadata_error(errors, {:ok, _value}), do: errors
  defp append_metadata_error(errors, {:error, error}), do: [error | errors]

  defp unwrap_connector_payload(%{"connector" => connector}) when is_map(connector), do: connector
  defp unwrap_connector_payload(%{connector: connector}) when is_map(connector), do: connector
  defp unwrap_connector_payload(payload), do: payload

  defp store do
    Application.get_env(:server, :connector_registry_store, @store)
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_nested(value)}
      {key, value} -> {to_string(key), stringify_nested(value)}
    end)
  end

  defp stringify_nested(value) when is_map(value), do: stringify_keys(value)
  defp stringify_nested(value) when is_list(value), do: Enum.map(value, &stringify_nested/1)
  defp stringify_nested(value), do: value

  defp normalize_id(value), do: value |> to_string() |> String.trim() |> String.downcase()
  defp normalize(nil), do: ""
  defp normalize(value), do: value |> to_string() |> String.trim() |> String.downcase()
end

defmodule Chronicle.Server.Host.ExternalTasks.ConnectorRegistry.EctoStore do
  @moduledoc false

  import Ecto.Query

  alias Chronicle.Persistence.Repo
  alias Chronicle.Persistence.Schemas.ConnectorRegistryEntry

  def all do
    query =
      from(entry in ConnectorRegistryEntry,
        where: entry.enabled == true,
        order_by: [asc: entry.connector_id]
      )

    entries =
      query
      |> Repo.all()
      |> Enum.map(&ConnectorRegistryEntry.to_connector_entry/1)

    {:ok, entries}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  def upsert(id, entry) do
    now = DateTime.utc_now()

    attrs = %{
      connector_id: id,
      entry_json: Jason.encode!(entry),
      enabled: Map.get(entry, "enabled", true),
      inserted_at: now,
      updated_at: now
    }

    result =
      case Repo.get_by(ConnectorRegistryEntry, connector_id: id) do
        nil ->
          %ConnectorRegistryEntry{}
          |> ConnectorRegistryEntry.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> ConnectorRegistryEntry.changeset(Map.delete(attrs, :inserted_at))
          |> Repo.update()
      end

    case result do
      {:ok, saved} -> {:ok, ConnectorRegistryEntry.to_connector_entry(saved)}
      {:error, changeset} -> {:error, changeset}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  def delete(id) do
    {count, _} =
      from(entry in ConnectorRegistryEntry, where: entry.connector_id == ^id)
      |> Repo.delete_all()

    {:ok, %{deleted: count}}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end
