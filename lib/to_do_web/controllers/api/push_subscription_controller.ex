defmodule ToDoWeb.Api.PushSubscriptionController do
  @moduledoc """
  Receives and revokes Web Push subscriptions from the in-browser
  PushManager. Used by the client-side push registration flow.
  """

  use ToDoWeb, :controller

  alias ToDo.PushSubscriptions

  # POST /api/push/subscribe
  #   { "endpoint": "...", "keys": { "p256dh": "...", "auth": "..." } }
  def subscribe(conn, params) do
    user_id = conn.assigns.current_scope.user.id

    attrs = %{
      "user_id" => user_id,
      "endpoint" => params["endpoint"],
      "p256dh_key" => get_in(params, ["keys", "p256dh"]),
      "auth_key" => get_in(params, ["keys", "auth"]),
      "user_agent" => get_user_agent(conn)
    }

    case PushSubscriptions.upsert(attrs) do
      {:ok, _sub} ->
        json(conn, %{ok: true})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{ok: false, error: "invalid subscription"})
    end
  end

  # DELETE /api/push/unsubscribe?endpoint=...
  #   or POST  /api/push/unsubscribe  { "endpoint": "..." }
  #
  # Only deletes if the endpoint belongs to the current user — even
  # though endpoint URLs are effectively unguessable, we still scope.
  def unsubscribe(conn, params) do
    user_id = conn.assigns.current_scope.user.id

    case params["endpoint"] do
      endpoint when is_binary(endpoint) ->
        # Scoped delete — verify ownership via the user_id column.
        import Ecto.Query
        ToDo.Repo.delete_all(
          from s in ToDo.PushSubscriptions.Subscription,
            where: s.endpoint == ^endpoint and s.user_id == ^user_id
        )

        json(conn, %{ok: true})

      _ ->
        conn |> put_status(:bad_request) |> json(%{ok: false, error: "missing endpoint"})
    end
  end

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> String.slice(ua, 0, 255)
      _ -> nil
    end
  end
end
