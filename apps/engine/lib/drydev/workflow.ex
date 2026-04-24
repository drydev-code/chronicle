defmodule DryDev.Workflow do
  @moduledoc """
  Public entry point for the DryDev Workflow engine library.

  This package is a *library*, not an OTP application — it does not start a
  supervisor on its own. Consumers mount the engine into their own supervision
  tree via `child_spec/1` or `children/1`.

  ## Usage

      # In your host application:
      children = [
        {DryDev.Workflow, []}
        # or, if you want to extend the child list:
        # DryDev.Workflow.children(opts) ++ your_children
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  ## Options

    * `:run_migrations` — run Ecto migrations on startup (default: `true`)
    * `:restore_instances` — restore active process instances from the event
      store on startup (default: `true`)
    * `:eviction` — override eviction config (see `DryDev.Workflow.Engine.EvictionManager`)

  The engine reads the active repo + databus repo from `:engine`
  application config. See `config/runtime.exs` in the umbrella root for an
  example.
  """

  @doc """
  Returns the child spec that starts the entire engine supervision tree.
  Drop this into your supervisor's child list.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {DryDev.Workflow.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns the flat list of engine children. Use this if you want to interleave
  engine children with your own in a single supervisor, rather than nesting
  under a dedicated engine supervisor.
  """
  defdelegate children(opts \\ []), to: DryDev.Workflow.Supervisor, as: :children
end
