defmodule Chronicle.Engine.Instance.Migration do
  @moduledoc """
  Handles process instance migration from one definition version to another.
  Maps token positions from old node IDs to new node IDs using the provided
  node_mappings, and persists the migration event.
  """

  require Logger

  alias Chronicle.Engine.Diagrams.Definition
  alias Chronicle.Engine.PersistentData

  @doc """
  Migrates a process instance to a new definition version.
  Maps all tokens to new positions using node_mappings.
  Returns the updated state with the migration event appended.
  """
  def migrate(state, new_definition, node_mappings) do
    old_version = state.definition.version
    new_version = new_definition.version

    {migrated_count, new_tokens} = Enum.reduce(state.tokens, {0, state.tokens}, fn {token_id, token}, {count, tokens} ->
      new_node = Map.get(node_mappings, token.current_node, token.current_node)
      if Definition.get_node(new_definition, new_node) do
        token = %{token | current_node: new_node}
        {count + 1, Map.put(tokens, token_id, token)}
      else
        Logger.warning("Migration: node #{token.current_node} not found in new definition, keeping position")
        {count, tokens}
      end
    end)

    state = %{state | tokens: new_tokens, definition: new_definition}

    event = %PersistentData.ProcessInstanceMigrated{
      from_version: old_version,
      to_version: new_version,
      node_mappings: node_mappings,
      migrated_tokens: migrated_count
    }
    state = append_event(state, event)

    Logger.info("Migration: #{state.id} from v#{old_version} to v#{new_version}, #{migrated_count} tokens migrated")
    state
  end

  defp append_event(state, event) do
    %{state | persistent_events: state.persistent_events ++ [event]}
  end
end
