defmodule ToDo.Notifications.Scanner do
  @moduledoc """
  Periodically scans the tasks table for due-soon and overdue tasks and emits
  notifications for everyone with visibility on each task.

  Runs as a long-lived GenServer. Tick interval is configurable via
  `config :to_do, ToDo.Notifications.Scanner, interval_ms: <ms>` (default
  60_000). Setting interval to `:disabled` keeps the process alive but stops
  it from scanning — useful in tests so it doesn't run during async cases.

  Visibility rule: a task is "visible" to its category's board owner, anyone
  the task is directly shared with, and anyone the parent board is shared
  with. Each visible user gets one notification per task per kind.

  Idempotency comes from the partial unique indexes on the notifications
  table — a redundant scan is a no-op.
  """

  use GenServer
  require Logger

  import Ecto.Query
  alias ToDo.Repo
  alias ToDo.Boards.{Board, BoardShare, Category, Task, TaskShare}
  alias ToDo.Notifications

  @default_interval_ms 60_000
  # "Due soon" = due_at within the next 24 hours and not yet overdue.
  @due_soon_window_hours 24

  ## Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run a scan immediately (synchronously). Used by tests and when the
  process boots so the user doesn't wait a full interval for the first
  pass.
  """
  def scan_now, do: GenServer.call(__MODULE__, :scan_now, 30_000)

  ## GenServer

  @impl true
  def init(_opts) do
    interval = configured_interval()

    case interval do
      :disabled ->
        Logger.info("[Notifications.Scanner] disabled by config")
        {:ok, %{interval: :disabled, timer: nil}}

      ms when is_integer(ms) and ms > 0 ->
        # Run a scan immediately so a fresh boot doesn't lag a whole interval
        # before notifications appear; subsequent ticks use send_after.
        send(self(), :scan)
        {:ok, %{interval: ms, timer: nil}}
    end
  end

  @impl true
  def handle_info(:scan, %{interval: interval} = state) do
    safe_scan()

    timer =
      if is_integer(interval) and interval > 0 do
        Process.send_after(self(), :scan, interval)
      else
        nil
      end

    {:noreply, %{state | timer: timer}}
  end

  @impl true
  def handle_call(:scan_now, _from, state) do
    {count_due, count_over} = safe_scan()
    {:reply, {:ok, %{due_soon: count_due, overdue: count_over}}, state}
  end

  ## Internals

  defp configured_interval do
    Application.get_env(:to_do, __MODULE__, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp safe_scan do
    try do
      do_scan()
    rescue
      e ->
        Logger.error("[Notifications.Scanner] scan failed: #{Exception.message(e)}")
        {0, 0}
    end
  end

  defp do_scan do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    soon_cutoff = DateTime.add(now, @due_soon_window_hours, :hour)

    due_soon_tasks = candidate_tasks(now, soon_cutoff, :due_soon)
    overdue_tasks = candidate_tasks(now, soon_cutoff, :overdue)

    due_count = Enum.reduce(due_soon_tasks, 0, &emit_for_task(&1, "task_due_soon", &2))
    over_count = Enum.reduce(overdue_tasks, 0, &emit_for_task(&1, "task_overdue", &2))

    if due_count > 0 or over_count > 0 do
      Logger.info(
        "[Notifications.Scanner] emitted due_soon=#{due_count} overdue=#{over_count}"
      )
    end

    {due_count, over_count}
  end

  # Pulls non-deleted, undone tasks within (overdue) or (due-soon) windows,
  # joining through Category → Board so we know the board owner.
  defp candidate_tasks(now, soon_cutoff, window) do
    base =
      from(t in Task,
        join: c in Category, on: c.id == t.category_id,
        join: b in Board, on: b.id == c.board_id,
        where: is_nil(t.deleted_at) and not t.done and not is_nil(t.due_at),
        select: %{id: t.id, title: t.title, due_at: t.due_at, board_id: b.id, owner_id: b.owner_id}
      )

    case window do
      :overdue ->
        from([t, _c, _b] in base, where: t.due_at < ^now)

      :due_soon ->
        from([t, _c, _b] in base,
          where: t.due_at >= ^now and t.due_at < ^soon_cutoff
        )
    end
    |> Repo.all()
  end

  defp emit_for_task(%{id: task_id, title: title, due_at: due_at, board_id: board_id, owner_id: owner_id}, kind, acc) do
    body = render_body(kind, title, due_at)

    user_ids =
      [owner_id | direct_share_user_ids(task_id) ++ board_share_user_ids(board_id)]
      |> Enum.uniq()

    Enum.reduce(user_ids, acc, fn user_id, acc ->
      case Notifications.create_or_skip(%{
             user_id: user_id,
             kind: kind,
             task_id: task_id,
             body: body
           }) do
        {:ok, _} -> acc + 1
        :skipped -> acc
        {:error, _} -> acc
      end
    end)
  end

  defp direct_share_user_ids(task_id) do
    from(s in TaskShare, where: s.task_id == ^task_id, select: s.user_id) |> Repo.all()
  end

  defp board_share_user_ids(board_id) do
    from(s in BoardShare, where: s.board_id == ^board_id, select: s.user_id) |> Repo.all()
  end

  # ----- Body rendering -----

  defp render_body("task_due_soon", title, due_at) do
    "“#{truncate(title)}” is due #{relative_when(due_at)}."
  end

  defp render_body("task_overdue", title, due_at) do
    "“#{truncate(title)}” is overdue (was due #{relative_when(due_at)})."
  end

  defp truncate(t) when is_binary(t) and byte_size(t) > 80, do: String.slice(t, 0, 77) <> "…"
  defp truncate(t), do: t

  defp relative_when(due_at) do
    diff_min = DateTime.diff(due_at, DateTime.utc_now(), :minute)

    cond do
      diff_min < -1440 -> "#{div(-diff_min, 1440)}d ago"
      diff_min < -60 -> "#{div(-diff_min, 60)}h ago"
      diff_min < 0 -> "#{-diff_min}m ago"
      diff_min < 60 -> "in #{diff_min}m"
      diff_min < 1440 -> "in #{div(diff_min, 60)}h"
      true -> "in #{div(diff_min, 1440)}d"
    end
  end
end
