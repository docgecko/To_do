defmodule ToDo.Repo.SyncGate do
  @moduledoc """
  Blocks application startup until the libsql embedded replica has synced
  the latest schema from the Turso primary. Without this gate, the
  Endpoint can begin serving traffic against a partially-synced replica
  that's still missing recent migrations, producing transient
  `SQLite failure: no such column: ...` errors.

  How it works:

    * `init/1` runs synchronously inside the supervision tree. The
      supervisor blocks here before starting the next child (the
      Endpoint), so by the time HTTP traffic is accepted, the sync has
      finished.
    * Inspects the local migration files on disk to find the highest
      version, then polls `schema_migrations` until it sees that row.
      libsql's sync is what's *being* waited on — when the latest
      migration appears in `schema_migrations`, the schema has been
      pulled from Turso and the replica is current.
    * No-op when TURSO_DATABASE_URL is unset (local dev / test).
    * Bounded by a 15-second timeout: if sync somehow stalls forever
      we'd rather start the app serving stale data than fail to boot,
      because the manual recovery (`flyctl machine restart`) is the same
      either way.
  """

  use GenServer, restart: :transient

  require Logger

  @poll_interval_ms 250
  @max_attempts 60

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    if turso_mode?() do
      wait_for_sync()
    end

    # `:ignore` tells the supervisor "this child intentionally has no
    # process to monitor" — the gate ran, did its job, no need to stick
    # around. Supervisor moves on to the next child (the Endpoint).
    :ignore
  end

  defp turso_mode?, do: not is_nil(System.get_env("TURSO_DATABASE_URL"))

  defp wait_for_sync do
    expected = latest_migration_version()
    started = System.monotonic_time(:millisecond)

    Logger.info(
      "[Repo.SyncGate] waiting for replica to catch up to migration #{expected}…"
    )

    result = poll_until_synced(expected, @max_attempts)
    elapsed = System.monotonic_time(:millisecond) - started

    case result do
      :ok ->
        Logger.info("[Repo.SyncGate] replica synced (took #{elapsed}ms)")

      :timeout ->
        Logger.error(
          "[Repo.SyncGate] timed out after #{elapsed}ms waiting for migration " <>
            "#{expected}. Booting anyway — expect transient `no such column` " <>
            "errors until libsql catches up."
        )
    end
  end

  defp poll_until_synced(_expected, 0), do: :timeout

  defp poll_until_synced(expected, attempts_left) do
    case current_replica_version() do
      n when is_integer(n) and n >= expected ->
        :ok

      _ ->
        Process.sleep(@poll_interval_ms)
        poll_until_synced(expected, attempts_left - 1)
    end
  end

  # Highest version in `priv/repo/migrations/<ver>_<name>.exs`. Done at
  # boot rather than compile time so a release's bundled migrations always
  # match the one the code expects.
  defp latest_migration_version do
    pattern = Path.join([Application.app_dir(:to_do, "priv"), "repo", "migrations", "*.exs"])

    pattern
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path |> Path.basename() |> String.split("_") |> List.first()
    end)
    |> Enum.map(&safe_parse_int/1)
    |> Enum.max(fn -> 0 end)
  end

  defp safe_parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Highest version Ecto has recorded as applied. nil if the table or
  # query isn't reachable (replica still mid-sync).
  defp current_replica_version do
    try do
      case Ecto.Adapters.SQL.query(
             ToDo.Repo,
             "SELECT MAX(version) FROM schema_migrations",
             [],
             timeout: 5_000
           ) do
        {:ok, %{rows: [[n]]}} when is_integer(n) -> n
        _ -> nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end
end
