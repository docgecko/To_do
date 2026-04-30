defmodule ToDo.Notifications.Mailer do
  @moduledoc """
  Periodically sends email digests of unread/unsent notifications.

  Runs as a long-lived GenServer. Tick interval default is 30 minutes;
  configurable via `config :to_do, ToDo.Notifications.Mailer, interval_ms:`.
  Setting interval to `:disabled` keeps the process alive but stops emails
  (used in test config).

  Each tick:

    1. Look up all users with at least one unread, not-yet-emailed
       notification.
    2. For users with `email_notifications_enabled = true`, group their
       pending notifications, render a digest via `UserNotifier`, deliver
       it, and stamp `email_sent_at` on the notifications that were
       included.
    3. Skip users whose preference is off — their notifications stay
       in-app only.

  Throttling is implicit in the interval — a user can receive at most one
  digest per tick, no matter how many new notifications fired since the
  last one.
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias ToDo.Repo
  alias ToDo.Accounts.{User, UserNotifier}
  alias ToDo.Notifications

  # 30 minutes — long enough to amortise spam if many things go overdue at
  # once, short enough that the user doesn't feel notifications are stale.
  @default_interval_ms 30 * 60 * 1000

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send pending digests now (synchronously). Used by tests."
  def deliver_now, do: GenServer.call(__MODULE__, :deliver_now, 30_000)

  ## GenServer

  @impl true
  def init(_opts) do
    interval = configured_interval()

    case interval do
      :disabled ->
        Logger.info("[Notifications.Mailer] disabled by config")
        {:ok, %{interval: :disabled}}

      ms when is_integer(ms) and ms > 0 ->
        Process.send_after(self(), :deliver, ms)
        {:ok, %{interval: ms}}
    end
  end

  @impl true
  def handle_info(:deliver, %{interval: interval} = state) do
    safe_deliver()

    if is_integer(interval) and interval > 0 do
      Process.send_after(self(), :deliver, interval)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:deliver_now, _from, state) do
    {:reply, {:ok, safe_deliver()}, state}
  end

  ## Internals

  defp configured_interval do
    Application.get_env(:to_do, __MODULE__, []) |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp safe_deliver do
    try do
      do_deliver()
    rescue
      e ->
        Logger.error("[Notifications.Mailer] deliver failed: #{Exception.message(e)}")
        {0, 0}
    end
  end

  defp do_deliver do
    user_ids = users_with_pending()

    {sent, skipped} =
      Enum.reduce(user_ids, {0, 0}, fn user_id, {sent, skipped} ->
        case Repo.get(User, user_id) do
          %User{email_notifications_enabled: true} = user ->
            send_digest(user)
            {sent + 1, skipped}

          %User{} ->
            {sent, skipped + 1}

          nil ->
            {sent, skipped + 1}
        end
      end)

    if sent > 0 or skipped > 0 do
      Logger.info("[Notifications.Mailer] sent=#{sent} skipped=#{skipped}")
    end

    {sent, skipped}
  end

  defp users_with_pending do
    from(n in Notifications.Notification,
      where: is_nil(n.email_sent_at) and is_nil(n.read_at),
      distinct: true,
      select: n.user_id
    )
    |> Repo.all()
  end

  defp send_digest(user) do
    case Notifications.list_pending_email(user.id) do
      [] ->
        :ok

      notifications ->
        case UserNotifier.deliver_task_digest(user, notifications) do
          {:ok, _email} ->
            Notifications.mark_emailed(Enum.map(notifications, & &1.id))

          {:error, reason} ->
            Logger.warning("[Notifications.Mailer] delivery failed for user #{user.id}: #{inspect(reason)}")
        end
    end
  end
end
