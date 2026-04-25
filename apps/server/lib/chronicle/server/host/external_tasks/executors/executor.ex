defmodule Chronicle.Server.Host.ExternalTasks.Executors.Executor do
  @moduledoc "Behaviour implemented by built-in service task executor plugins."

  @callback topics() :: [String.t()]
  @callback execute(map(), struct()) ::
              {:ok, map() | list() | String.t() | number() | boolean() | nil, map()} |
              {:error, term()}
end
