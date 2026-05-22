defmodule ToDo.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :to_do

  require Logger

  def migrate do
    load_app()
    wait_for_dns()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end

  # Fly's release_command machine boots faster than its internal DNS
  # (.internal / .flycast) service. Erlang's inet resolver caches nxdomain
  # and doesn't share NSS state with the system, so a successful `getent` at
  # shell level doesn't mean Postgrex can resolve the host. Poll the Erlang
  # resolver directly before letting the migrator try.
  defp wait_for_dns do
    case database_host() do
      nil ->
        :ok

      host ->
        Logger.info("[Release] waiting for Erlang resolver to find #{host}...")
        attempts = 30

        Enum.reduce_while(1..attempts, nil, fn i, _ ->
          case :inet.gethostbyname(String.to_charlist(host)) do
            {:ok, _} ->
              Logger.info("[Release] resolved #{host} after #{i}s")
              {:halt, :ok}

            {:error, _} when i == attempts ->
              Logger.warning("[Release] #{host} unresolved after #{attempts}s — proceeding")
              {:halt, :timeout}

            {:error, _} ->
              Process.sleep(1_000)
              {:cont, nil}
          end
        end)
    end
  end

  defp database_host do
    case System.get_env("DATABASE_URL") do
      nil ->
        nil

      url ->
        case URI.parse(url) do
          %URI{host: host} when is_binary(host) -> host
          _ -> nil
        end
    end
  end
end
