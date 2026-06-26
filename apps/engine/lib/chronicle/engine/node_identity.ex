defmodule Chronicle.Engine.NodeIdentity do
  @moduledoc """
  Stable per-pod identity for the ownership-lease layer (feature 3b).

  Each running BEAM (pod) needs a single, stable string that uniquely names it
  as the owner of an instance lease. It is minted once — lazily on first use,
  or eagerly at boot via `start_link/1` — and cached in `:persistent_term` so
  every later read is allocation-free and returns the identical value for the
  lifetime of the node.

  The id is `"<hostname>-<boot-nonce>"`. The hostname makes it human-readable
  in the lease table; the boot nonce (random, minted once per process start)
  guarantees that a crashed-and-restarted pod which reuses the same hostname
  still gets a *fresh* identity, so its stale leases age out instead of being
  silently re-adopted as if nothing happened.

  At N=1 this is just "the one pod's name": it acquires everything, renews
  forever, and always fences with its own epoch — a pure no-op.
  """

  @key {__MODULE__, :node_id}

  @doc """
  Optional supervised entry point. Mints the id eagerly at boot and returns
  `:ignore` so it occupies no slot in the supervision tree — the work is the
  side effect of writing `:persistent_term` once. Lazy `node_id/0` callers get
  the same value whether or not this ran.
  """
  def start_link(_opts \\ []) do
    _ = node_id()
    :ignore
  end

  @doc "Child spec so the module can be listed directly in a supervisor."
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @doc """
  Return this pod's stable identity, minting and caching it on first call.

  The mint is guarded so two racing first-callers cannot install different
  values: whoever wins `persistent_term.put` wins, and the loser re-reads it.
  """
  @spec node_id() :: String.t()
  def node_id do
    case :persistent_term.get(@key, :undefined) do
      :undefined ->
        minted = mint()
        # put/get race: only install if still absent, then read the winner.
        case :persistent_term.get(@key, :undefined) do
          :undefined ->
            :persistent_term.put(@key, minted)
            :persistent_term.get(@key, minted)

          existing ->
            existing
        end

      id ->
        id
    end
  end

  defp mint do
    nonce =
      :crypto.strong_rand_bytes(8)
      |> Base.url_encode64(padding: false)

    "#{hostname()}-#{nonce}"
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _ -> "unknown-host"
    end
  end
end
