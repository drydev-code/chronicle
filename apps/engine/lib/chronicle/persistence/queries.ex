defmodule Chronicle.Persistence.Queries do
  @moduledoc "Common query patterns for persistence layer."
  import Ecto.Query
  alias Chronicle.Persistence.Schemas.{ActiveInstance, CompletedInstance, TerminatedInstance}

  def active_count do
    from(a in ActiveInstance, select: count(a.process_instance_id))
  end

  def completed_count do
    from(c in CompletedInstance, select: count(c.process_instance_id))
  end

  def terminated_count do
    from(t in TerminatedInstance, select: count(t.process_instance_id))
  end
end
