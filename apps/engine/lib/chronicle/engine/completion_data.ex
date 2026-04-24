defmodule Chronicle.Engine.CompletionData do
  @moduledoc "All token completion data types."

  defmodule Blank do
    defstruct [:end_event_key]
  end

  defmodule Error do
    defstruct [:error_message, :error_object, :end_event_key]
  end

  defmodule Message do
    defstruct [:message_name, :payload, :end_event_key]
  end

  defmodule Signal do
    defstruct [:signal, :end_event_key]
  end

  defmodule Escalation do
    defstruct [:escalation, :end_event_key]
  end

  defmodule Termination do
    defstruct [:reason, :end_event_key]
  end
end
