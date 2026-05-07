defmodule ToDoWeb.Plugs.CanonicalHost do
  @moduledoc """
  Issues a 301 to the canonical host when the incoming request hits a
  non-canonical hostname (e.g. `orelle.fly.dev`, `www.orelle.app`). Real users
  always end up on `https://orelle.app/...` regardless of how they typed it.

  Configured via:

      config :to_do, ToDoWeb.Plugs.CanonicalHost,
        canonical: "orelle.app",
        redirect_from: ["orelle.fly.dev", "www.orelle.app"]

  Both keys are optional. When `:canonical` is unset (dev/test) the plug is a
  no-op. The whitelist is intentional — Fly's internal HTTP health checks hit
  the machine via its IP, so we *don't* want to redirect everything that
  doesn't match `orelle.app`. Listing the hosts we care about avoids
  trampling those.
  """

  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cfg = Application.get_env(:to_do, __MODULE__, [])
    canonical = Keyword.get(cfg, :canonical)
    redirect_from = Keyword.get(cfg, :redirect_from, [])

    cond do
      is_nil(canonical) -> conn
      conn.host == canonical -> conn
      conn.host in redirect_from -> redirect_to_canonical(conn, canonical)
      true -> conn
    end
  end

  defp redirect_to_canonical(conn, canonical) do
    qs = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    location = "https://#{canonical}#{conn.request_path}#{qs}"

    conn
    |> put_resp_header("location", location)
    |> resp(301, "")
    |> halt()
  end
end
