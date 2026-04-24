defmodule DryDev.Workflow.Persistence.Schemas.FileEntity do
  @moduledoc """
  Ecto schema for the DataBus Files table.
  Maps to the .NET EF Core FileEntity with PascalCase column names.
  """
  use Ecto.Schema

  @primary_key false
  schema "Files" do
    field :id, :string, primary_key: true, source: :Id
    field :file_id, :string, source: :FileId
    field :tenant_id, :string, source: :TenantId
    field :data, :binary, source: :Data
    field :hash, :binary, source: :Hash
    field :write_date, :naive_datetime_usec, source: :WriteDate
    field :is_archived, :boolean, source: :IsArchived, default: false
    field :archival_date, :naive_datetime_usec, source: :ArchivalDate
    field :claim_id, :string, source: :ClaimId
  end
end
