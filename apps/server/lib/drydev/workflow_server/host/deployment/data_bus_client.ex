defmodule DryDev.WorkflowServer.Host.Deployment.DataBusClient do
  @moduledoc """
  Database client for DataBus large variable storage.

  Mirrors the .NET IManagedDataBus / DataBusExtensions pattern:
  - Files table in the `databus` database
  - Id = MD5("{fileId}+{tenantId}") formatted as .NET Guid string
  - Supports MySQL/MariaDB, PostgreSQL, and MS SQL via Ecto adapters
  - Adapter selected at compile time via DB_ADAPTER / DATABUS_ADAPTER env vars
  """

  import Ecto.Query

  alias DryDev.Workflow.Persistence.DataBusRepo
  alias DryDev.Workflow.Persistence.Schemas.FileEntity

  @doc "Store a string value, returns {:ok, file_id} with the generated GUID."
  def put_string(value, tenant_id) do
    file_id = UUID.uuid4()
    entity_id = compute_entity_id(file_id, tenant_id)

    entity = %FileEntity{
      id: entity_id,
      file_id: file_id,
      tenant_id: tenant_id,
      data: value,
      hash: :crypto.hash(:sha256, value),
      write_date: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond),
      is_archived: false
    }

    case DataBusRepo.insert(entity) do
      {:ok, _} -> {:ok, file_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Load a string value by file GUID and tenant."
  def get_string(file_id, tenant_id) do
    query =
      from f in FileEntity,
        where: f.file_id == ^file_id and f.tenant_id == ^tenant_id and f.is_archived == false,
        select: f.data,
        limit: 1

    case DataBusRepo.one(query) do
      nil ->
        # Fallback: try without tenant (matches .NET GetTenantedFile fallback)
        fallback =
          from f in FileEntity,
            where: f.file_id == ^file_id and is_nil(f.tenant_id) and f.is_archived == false,
            select: f.data,
            limit: 1

        case DataBusRepo.one(fallback) do
          nil -> {:error, :not_found}
          data -> {:ok, to_string(data)}
        end

      data ->
        {:ok, to_string(data)}
    end
  end

  @doc "Soft-delete files by marking them as archived."
  def archive(guids, tenant_id) when is_list(guids) do
    if guids == [] do
      :ok
    else
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:microsecond)

      from(f in FileEntity,
        where: f.file_id in ^guids and f.tenant_id == ^tenant_id
      )
      |> DataBusRepo.update_all(set: [is_archived: true, archival_date: now])

      :ok
    end
  end

  @doc "Check if the DataBusRepo is configured and available."
  def available? do
    case Application.get_env(:engine, DataBusRepo) do
      nil -> false
      [] -> false
      _config -> true
    end
  end

  # Compute the entity ID matching .NET's MD5("{fileId}+{tenantId}").ToGuid()
  # .NET Guid constructor interprets bytes in mixed-endian order:
  #   bytes 0-3: little-endian int32
  #   bytes 4-5: little-endian int16
  #   bytes 6-7: little-endian int16
  #   bytes 8-15: big-endian (as-is)
  defp compute_entity_id(file_id, nil), do: md5_to_dotnet_guid(file_id)
  defp compute_entity_id(file_id, tenant_id), do: md5_to_dotnet_guid("#{file_id}+#{tenant_id}")

  defp md5_to_dotnet_guid(source) do
    <<a::little-unsigned-32, b::little-unsigned-16, c::little-unsigned-16,
      d::binary-size(2), e::binary-size(6)>> = :crypto.hash(:md5, source)

    a_hex = Integer.to_string(a, 16) |> String.downcase() |> String.pad_leading(8, "0")
    b_hex = Integer.to_string(b, 16) |> String.downcase() |> String.pad_leading(4, "0")
    c_hex = Integer.to_string(c, 16) |> String.downcase() |> String.pad_leading(4, "0")
    d_hex = Base.encode16(d, case: :lower)
    e_hex = Base.encode16(e, case: :lower)

    "#{a_hex}-#{b_hex}-#{c_hex}-#{d_hex}-#{e_hex}"
  end
end
