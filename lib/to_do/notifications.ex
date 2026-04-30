defmodule ToDo.Notifications do
  @moduledoc """
  In-app + email notifications.

  Four kinds:

    * `task_due_soon`  — a task with `due_at` within the next 24h.
    * `task_overdue`   — a task whose `due_at` is in the past.
    * `task_shared`    — someone shared an individual task with the user.
    * `board_shared`   — someone shared a whole board with the user.

  The first two are emitted by `ToDo.Notifications.Scanner` on a timer; the
  last two are emitted synchronously from `ToDo.Boards` share helpers.

  Inserts are idempotent — partial unique indexes on `(user_id, kind, task_id)`
  and `(user_id, kind, board_id)` mean the scanner can run as often as we like
  without producing duplicates. `create_or_skip/1` returns `{:ok, notif}` for
  fresh inserts and `:skipped` for collisions.

  Each successful insert broadcasts on `Phoenix.PubSub` topic
  `"notifications:user:\#{user_id}"`, so any LiveView subscribed to that topic
  picks up real-time updates.
  """

  import Ecto.Query, warn: false
  alias ToDo.Repo
  alias ToDo.Notifications.Notification

  @pubsub ToDo.PubSub

  ## Subscriptions

  @doc "Subscribe the calling process to a user's notification stream."
  def subscribe(user_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(user_id))
  end

  defp topic(user_id), do: "notifications:user:#{user_id}"

  defp broadcast(%Notification{user_id: user_id} = notif, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:notification, event, notif})
  end

  ## Reads

  @doc "Most recent N notifications for a user (default 10), unread first."
  def list_recent(user_id, limit \\ 10) do
    from(n in Notification,
      where: n.user_id == ^user_id,
      order_by: [asc_nulls_first: n.read_at, desc: n.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  def unread_count(user_id) do
    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.read_at),
      select: count(n.id)
    )
    |> Repo.one()
  end

  def get!(id), do: Repo.get!(Notification, id)

  ## Writes

  @doc """
  Insert a notification, or skip if a conflicting one already exists.

  Returns `{:ok, %Notification{}}` for a new row, `:skipped` for a unique-index
  collision, or `{:error, changeset}` for any other validation issue.
  """
  def create_or_skip(attrs) do
    case %Notification{} |> Notification.changeset(attrs) |> Repo.insert() do
      {:ok, notif} ->
        broadcast(notif, :created)
        {:ok, notif}

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Enum.any?(errors, fn {_, {_, opts}} -> Keyword.get(opts, :constraint) == :unique end) do
          :skipped
        else
          error
        end
    end
  end

  def mark_read(%Notification{} = notif) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    notif
    |> Ecto.Changeset.change(read_at: now)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast(updated, :read)
      _ -> :ok
    end)
  end

  def mark_all_read(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: now, updated_at: now])

    Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:notifications, :all_read})
    {:ok, count}
  end

  ## Email batching

  @doc """
  Returns notifications ready to be emailed: not yet emailed and not already
  read in-app. Caller is responsible for grouping per user.
  """
  def list_pending_email(user_id) do
    from(n in Notification,
      where: n.user_id == ^user_id and is_nil(n.email_sent_at) and is_nil(n.read_at),
      order_by: [asc: n.inserted_at]
    )
    |> Repo.all()
  end

  def mark_emailed(notification_ids) when is_list(notification_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(n in Notification, where: n.id in ^notification_ids)
      |> Repo.update_all(set: [email_sent_at: now, updated_at: now])

    {:ok, count}
  end
end
