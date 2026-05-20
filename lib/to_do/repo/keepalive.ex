defmodule ToDo.Repo.Keepalive do
  @moduledoc """
  Preemptive process-restart to dodge libsql Hrana stream invalidation.

  Background: with `ecto_libsql 0.9` and a Turso-backed embedded replica,
  the HTTP/2 streams the adapter caches get silently recycled server-side
  after enough uptime — empirically ~16-24 hours of continuous run. The
  pool doesn't notice until a query is already failing, so the first user
  request after staleness gets a `Hrana: status=404 stream not found`
  error. We've hit this twice in three days.

  This GenServer schedules a clean self-restart well below that window
  (12 hours by default). On the tick it calls `System.halt(0)`, the Fly
  machine restarts, the boot script wipes /tmp/to_do.db*, the SyncGate
  blocks until the replica resyncs, and traffic resumes against fresh
  streams. Total downtime per cycle is a few seconds, all hidden by Fly's
  edge proxy retrying the request when the machine's healthy again.

  Disabled when `TURSO_DATABASE_URL` isn't set (no upstream to go stale).
  Disabled by default in test (the interval would never fire anyway, but
  belt-and-braces).

  Configurable via `:interval_ms`; set to `:disabled` to skip the schedule.
  """

  use GenServer
  require Logger

  @default_interval_ms :timer.hours(12)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    interval = configured_interval()

    cond do
      interval == :disabled ->
        Logger.info("[Repo.Keepalive] disabled by config")
        {:ok, %{interval: :disabled, timer: nil}}

      not turso_mode?() ->
        Logger.info("[Repo.Keepalive] no TURSO_DATABASE_URL — keepalive not needed")
        {:ok, %{interval: :disabled, timer: nil}}

      is_integer(interval) and interval > 0 ->
        timer = Process.send_after(self(), :restart, interval)
        Logger.info("[Repo.Keepalive] scheduled self-restart in #{interval}ms")
        {:ok, %{interval: interval, timer: timer}}
    end
  end

  @impl true
  def handle_info(:restart, state) do
    Logger.warning(
      "[Repo.Keepalive] preemptive restart to refresh libsql connections (dodges Hrana stream staleness)"
    )

    # System.halt/1 exits the BEAM immediately. Fly's machine sees the
    # process exit and restarts the container. boot script + SyncGate
    # bring the new instance back up cleanly.
    System.halt(0)
    {:noreply, state}
  end

  defp configured_interval do
    Application.get_env(:to_do, __MODULE__, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp turso_mode?, do: not is_nil(System.get_env("TURSO_DATABASE_URL"))
end
