defmodule Chronicle.Engine.Nodes.Activity do
  @moduledoc """
  Activity base module. Provides boundary event support for all activity nodes.
  Activities can have boundary events attached (timer, message, signal, error).
  """

  defstruct [
    :id, :key, :type, :boundary_events, :inputs, :outputs, :properties
  ]

  def get_boundary_event_to_error(%{boundary_events: events}, error_data) do
    Enum.find(events, fn be ->
      be.type == :error_boundary &&
      match_error_boundary?(be, error_data)
    end)
  end

  def get_boundary_event_to_exception(%{boundary_events: events}, exception) do
    Enum.find(events, fn be ->
      be.type == :error_boundary &&
      (be.exception_type == nil || be.exception_type == exception.__struct__)
    end)
  end

  defp match_error_boundary?(boundary_event, error_data) do
    cond do
      # Catch-all: both empty
      boundary_event.exception_type == nil and boundary_event.error_msg == nil -> true
      # Match by error message
      boundary_event.error_msg != nil and boundary_event.error_msg == error_data.error_message -> true
      # Match by exception type
      boundary_event.exception_type != nil and boundary_event.exception_type == error_data.error_type -> true
      true -> false
    end
  end
end
