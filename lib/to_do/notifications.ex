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

  @recent_window 20
  @max_rows 50

  @doc """
  The bell's list, newest first: the user's most recent notifications
  (`:limit`, default #{@recent_window}) plus every unread one regardless of
  age, so nothing awaiting attention hides below the fold.

  Rows keep their chronological position when flipped read/unread, and
  `:keep` (ids currently on screen) are retained even if they'd otherwise
  fall outside the window — a row the user just marked read must not
  vanish from under the cursor. Capped at #{@max_rows} rows.
  """
  def list_recent(user_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @recent_window)
    keep = Keyword.get(opts, :keep, [])

    recent_ids =
      from(n in Notification,
        where: n.user_id == ^user_id,
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^limit,
        select: n.id
      )

    from(n in Notification,
      where: n.user_id == ^user_id,
      where: is_nil(n.read_at) or n.id in subquery(recent_ids) or n.id in ^keep,
      order_by: [desc: n.inserted_at, desc: n.id],
      limit: @max_rows
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

  @doc """
  Scoped fetch — returns the notification only if it belongs to `user_id`.
  `nil` otherwise. Use this in any handler that takes a notification id
  from the client; the unscoped `get!/1` is for trusted callers only
  (mailer, scanner).
  """
  def get_for_user(user_id, id) do
    from(n in Notification, where: n.id == ^id and n.user_id == ^user_id)
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
        # Also ship a Web Push so the bell update lands on the user's
        # phone lock screen — not just in any open browser tab. Async so
        # the network round-trip doesn't block the caller (scanner /
        # share helper). VAPID-unset envs (dev) make this a no-op.
        Task.Supervisor.start_child(ToDo.TaskSupervisor, fn ->
          push_payload(notif) |> then(&ToDo.PushSubscriptions.push_to_user(notif.user_id, &1))
        end)

        {:ok, notif}

      {:error, %Ecto.Changeset{errors: errors}} = error ->
        if Enum.any?(errors, fn {_, {_, opts}} -> Keyword.get(opts, :constraint) == :unique end) do
          :skipped
        else
          error
        end
    end
  end

  # Already read: leave the original read_at alone (re-stamping it would
  # reshuffle nothing now, but there's no reason to touch the row either).
  def mark_read(%Notification{read_at: %DateTime{}} = notif), do: {:ok, notif}

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

  @doc "Flip a notification back to unread (clears `read_at`)."
  def mark_unread(%Notification{} = notif) do
    notif
    |> Ecto.Changeset.change(read_at: nil)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast(updated, :unread)
      _ -> :ok
    end)
  end

  @doc "Toggle a single notification between read and unread."
  def toggle_read(%Notification{read_at: nil} = notif), do: mark_read(notif)
  def toggle_read(%Notification{} = notif), do: mark_unread(notif)

  def mark_all_read(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: now, updated_at: now])

    Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:notifications, :all_read})
    {:ok, count}
  end

  ## Push payload helpers

  # Shape the service worker's `push` event listener expects. Title +
  # body line up with the lock-screen notification layout; `url` is the
  # deep-link followed when the user taps the notification.
  defp push_payload(%Notification{} = notif) do
    %{
      "title" => push_title(notif.kind),
      "body" => notif.body,
      "tag" => "orelle-notif-#{notif.id}",
      "url" => push_url(notif),
      "icon" => "/icons/icon-192.png",
      "badge" => "/icons/icon-192.png"
    }
  end

  defp push_title("task_due_soon"), do: "Task due soon"
  defp push_title("task_overdue"), do: "Task overdue"
  defp push_title("task_shared"), do: "Task shared with you"
  defp push_title("board_shared"), do: "Board shared with you"
  defp push_title(_), do: "Orelle"

  defp push_url(%Notification{kind: "board_shared", board_id: id}) when not is_nil(id),
    do: "/boards/#{id}"

  defp push_url(%Notification{task_id: id}) when not is_nil(id), do: "/today?edit=task:#{id}"
  defp push_url(_), do: "/today"

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
