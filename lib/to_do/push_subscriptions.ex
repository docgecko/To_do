defmodule ToDo.PushSubscriptions do
  @moduledoc """
  Stores per-device Web Push subscriptions and dispatches push payloads
  through the Web Push Protocol (RFC 8030 + VAPID).

  Each row is one device's "I want push notifications from this app"
  agreement: the push-service endpoint URL plus the keys needed to
  encrypt payloads. A user can have multiple subscriptions (one per
  device they install the PWA on).

  Re-subscription from the same device produces the same endpoint URL,
  so we upsert rather than accumulate duplicates.

  Payloads are sent best-effort. A non-success response from the push
  service is logged and (for 404/410 — "gone") triggers deletion of the
  stale row.
  """

  import Ecto.Query, warn: false
  require Logger

  alias ToDo.Repo
  alias ToDo.PushSubscriptions.Subscription

  ## Reads

  def list_for_user(user_id) do
    from(s in Subscription, where: s.user_id == ^user_id) |> Repo.all()
  end

  ## Writes

  @doc """
  Insert or refresh a subscription. Browsers may rotate keys when they
  refresh a subscription, so on conflict we update the keys + user_agent.
  """
  def upsert(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(Subscription, endpoint: attrs["endpoint"]) do
      nil ->
        %Subscription{} |> Subscription.changeset(attrs) |> Repo.insert()

      existing ->
        existing
        |> Subscription.changeset(Map.put(attrs, "updated_at", now))
        |> Repo.update()
    end
  end

  def delete_by_endpoint(endpoint) when is_binary(endpoint) do
    from(s in Subscription, where: s.endpoint == ^endpoint) |> Repo.delete_all()
  end

  def delete_by_id(id) when is_integer(id) or is_binary(id) do
    case Repo.get(Subscription, id) do
      nil -> :ok
      sub -> Repo.delete(sub)
    end
  end

  ## Sending

  @doc """
  Send a push payload to every subscription the user has. `payload` is
  serialised to JSON and decoded by the service worker's `push` event
  handler.
  """
  def push_to_user(user_id, payload) when is_map(payload) do
    subs = list_for_user(user_id)
    Logger.info("[PushSubscriptions] push_to_user user_id=#{user_id} subs=#{length(subs)}")
    Enum.each(subs, &send_one(&1, payload))
  end

  defp send_one(%Subscription{} = sub, payload) do
    body = Jason.encode!(payload)

    push_sub = %{
      endpoint: sub.endpoint,
      keys: %{p256dh: sub.p256dh_key, auth: sub.auth_key}
    }

    case WebPushEncryption.send_web_push(body, push_sub) do
      {:ok, %{status_code: code}} when code in 200..299 ->
        :ok

      {:ok, %{status_code: code}} when code in [404, 410] ->
        # Push service says the endpoint is gone — the user revoked
        # permission or uninstalled the PWA. Drop the stale row so we
        # don't keep trying.
        Logger.info("[PushSubscriptions] purging gone endpoint (HTTP #{code})")
        Repo.delete(sub)

      {:ok, %{status_code: code, body: body}} ->
        Logger.warning(
          "[PushSubscriptions] push failed HTTP #{code} for sub id=#{sub.id}: #{inspect(body)}"
        )

      {:error, reason} ->
        Logger.warning("[PushSubscriptions] push errored for sub id=#{sub.id}: #{inspect(reason)}")
    end
  end
end
