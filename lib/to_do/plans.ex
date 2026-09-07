defmodule ToDo.Plans do
  @moduledoc """
  Daily planning: which tasks a user has committed to on a given day,
  in what order, plus the end-of-day wrap-up.

  A plan is personal — `task_plans` rows are keyed by user, so two
  people sharing a board each plan their own day. Deferring at wrap-up
  moves the plan row AND, if the task was due on or before the day
  being wrapped, reschedules its due date to the target day (same
  local time of day) — you've made a decision about it, so it should
  stop reading as overdue. Sending to Anytime clears the due date.
  """

  import Ecto.Query, warn: false

  alias ToDo.Repo
  alias ToDo.Plans.{TaskPlan, DayReview}
  alias ToDo.Boards
  alias ToDo.Boards.{Task, Category, Board}
  alias ToDo.Accounts.User

  @default_tz "Europe/London"

  # -- Time --

  def user_tz(%User{timezone: tz}) when is_binary(tz) and tz != "", do: tz
  def user_tz(_), do: @default_tz

  @doc "Today's date in the user's timezone."
  def today(%User{} = user), do: user |> user_tz() |> local_today()

  def local_today(tz), do: tz |> DateTime.now!() |> DateTime.to_date()

  @doc "Start of `date` in `tz`, as a UTC DateTime — for overdue splits."
  def start_of_local_day(tz, %Date{} = date) do
    DateTime.new!(date, ~T[00:00:00], tz) |> DateTime.shift_zone!("Etc/UTC")
  end

  # -- Reading a plan --

  @doc """
  Rows planned for `date`, in position order. Includes done tasks (they
  stay struck-through on Today until wrap-up) but not soft-deleted ones.
  Row shape matches the smart-list rows, plus `plan: %TaskPlan{}`.
  """
  def list_plan(user_id, %Date{} = date) when is_integer(user_id) do
    from(tp in TaskPlan,
      join: t in Task,
      on: t.id == tp.task_id,
      join: c in Category,
      on: c.id == t.category_id,
      join: b in Board,
      on: b.id == c.board_id,
      left_join: g in Category,
      on: g.id == c.parent_id,
      where: tp.user_id == ^user_id and tp.planned_on == ^date and is_nil(t.deleted_at),
      order_by: [asc: tp.position, asc: tp.inserted_at],
      select: %{task: t, board: b, category: c, group: g, plan: tp}
    )
    |> Repo.all()
  end

  def planned_task_ids(user_id, %Date{} = date) when is_integer(user_id) do
    from(tp in TaskPlan,
      where: tp.user_id == ^user_id and tp.planned_on == ^date,
      select: tp.task_id
    )
    |> Repo.all()
  end

  def has_plan?(user_id, %Date{} = date) when is_integer(user_id) do
    from(tp in TaskPlan, where: tp.user_id == ^user_id and tp.planned_on == ^date)
    |> Repo.exists?()
  end

  # -- Writing a plan --

  @doc """
  Puts a task at the end of the user's plan for `date`. Upserts on
  (user_id, task_id), so a task already planned for another day moves.
  Refuses tasks the user can't see.
  """
  def plan_task(user_id, task_id, %Date{} = date) when is_integer(user_id) do
    with %Task{} = task <- Repo.get(Task, to_int(task_id)),
         perm when perm != :none <- Boards.task_permission(task, user_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      pos = next_position(user_id, date)

      %TaskPlan{}
      |> TaskPlan.changeset(%{
        user_id: user_id,
        task_id: task.id,
        planned_on: date,
        position: pos
      })
      |> Repo.insert(
        on_conflict: [set: [planned_on: date, position: pos, updated_at: now]],
        conflict_target: [:user_id, :task_id]
      )
    else
      nil -> {:error, :not_found}
      :none -> {:error, :forbidden}
    end
  end

  def unplan_task(user_id, task_id) when is_integer(user_id) do
    from(tp in TaskPlan, where: tp.user_id == ^user_id and tp.task_id == ^to_int(task_id))
    |> Repo.delete_all()

    :ok
  end

  @doc "Alias for plan_task/3 with the intent spelled out: move to another day."
  def defer_task(user_id, task_id, %Date{} = target), do: plan_task(user_id, task_id, target)

  @doc """
  Rewrites positions for the user's `date` plan from an ordered id list.
  Ids not planned for that day are ignored.
  """
  def reorder_plan(user_id, %Date{} = date, ordered_task_ids)
      when is_integer(user_id) and is_list(ordered_task_ids) do
    ordered_task_ids
    |> Enum.map(&to_int/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index(1)
    |> Enum.each(fn {tid, pos} ->
      from(tp in TaskPlan,
        where: tp.user_id == ^user_id and tp.task_id == ^tid and tp.planned_on == ^date
      )
      |> Repo.update_all(set: [position: pos])
    end)

    :ok
  end

  defp next_position(user_id, date) do
    from(tp in TaskPlan,
      where: tp.user_id == ^user_id and tp.planned_on == ^date,
      select: coalesce(max(tp.position), 0) + 1
    )
    |> Repo.one()
  end

  # -- Candidates for planning mode --

  @doc """
  What the planning screen offers, minus anything already planned for
  `date`. Overdue is split from due-today using the user's local
  start-of-day. Upcoming is capped to the next 7 days.
  """
  def candidates(%User{id: user_id} = user, %Date{} = date) do
    tz = user_tz(user)
    planned = MapSet.new(planned_task_ids(user_id, date))
    sod = start_of_local_day(tz, date)
    week_out = DateTime.add(Boards.end_of_local_day(tz, date), 7 * 24 * 60 * 60, :second)

    unplanned = fn rows -> Enum.reject(rows, &MapSet.member?(planned, &1.task.id)) end

    today_rows = Boards.list_smart_tasks(user_id, :today, tz: tz) |> unplanned.()

    {overdue, due_today} =
      Enum.split_with(today_rows, fn r -> DateTime.compare(r.task.due_at, sod) == :lt end)

    upcoming =
      Boards.list_smart_tasks(user_id, :upcoming, tz: tz)
      |> unplanned.()
      |> Enum.filter(fn r -> DateTime.compare(r.task.due_at, week_out) != :gt end)

    %{
      overdue: overdue,
      due_today: due_today,
      upcoming: upcoming,
      anytime: Boards.list_smart_tasks(user_id, :anytime, tz: tz) |> unplanned.(),
      waiting: Boards.list_smart_tasks(user_id, :waiting, tz: tz) |> unplanned.()
    }
  end

  # -- Coverage / "plan strength" --

  @doc """
  Plain facts about a plan, for the header under the capacity bar.
  Only open (not done) rows count toward minutes. `task_goals` is the
  `%{task_id => [goal]}` map from `Goals.goals_by_task_ids/1`.
  """
  def coverage(rows, task_goals) when is_list(rows) and is_map(task_goals) do
    open = Enum.reject(rows, & &1.task.done)
    total = length(open)
    est = fn r -> r.task.estimated_minutes || 0 end

    estimated = Enum.count(open, &(not is_nil(&1.task.estimated_minutes)))
    with_goal = Enum.count(open, &(Map.get(task_goals, &1.task.id, []) != []))
    total_minutes = open |> Enum.map(est) |> Enum.sum()

    minutes_by_goal =
      open
      |> Enum.flat_map(fn r ->
        Enum.map(Map.get(task_goals, r.task.id, []), fn g -> {g, est.(r)} end)
      end)
      |> Enum.group_by(fn {g, _} -> g.id end, fn {g, m} -> {g, m} end)
      |> Enum.map(fn {_, pairs} ->
        [{g, _} | _] = pairs
        {g, pairs |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
      end)
      |> Enum.sort_by(fn {_, m} -> -m end)

    goal_minutes = minutes_by_goal |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    %{
      total: total,
      estimated: estimated,
      with_goal: with_goal,
      unestimated: total - estimated,
      total_minutes: total_minutes,
      minutes_by_goal: minutes_by_goal,
      goal_share: if(total_minutes > 0, do: goal_minutes / total_minutes, else: 0.0),
      done: Enum.count(rows, & &1.task.done),
      done_minutes: rows |> Enum.filter(& &1.task.done) |> Enum.map(est) |> Enum.sum()
    }
  end

  # -- Wrap-up --

  @doc """
  Ends the user's `date`. `decisions` maps task_id (int or string) to
  either "keep" or an ISO date string for where to defer it. Done
  tasks leave the plan; kept tasks leave the plan (their due date is
  untouched, so they surface under "Also due today" tomorrow if still
  due); deferred tasks move to the target day. A DayReview snapshot
  is written first so the counts reflect the day as it ended.
  """
  def wrap_up(%User{id: user_id} = user, %Date{} = date, decisions, reflection)
      when is_map(decisions) do
    tz = user_tz(user)
    rows = list_plan(user_id, date)
    cov = coverage(rows, %{})

    review_attrs = %{
      user_id: user_id,
      date: date,
      planned_count: length(rows),
      done_count: cov.done,
      planned_minutes: cov.total_minutes + cov.done_minutes,
      done_minutes: cov.done_minutes,
      reflection: blank_to_nil(reflection)
    }

    Repo.transaction(fn ->
      {:ok, review} =
        %DayReview{}
        |> DayReview.changeset(review_attrs)
        |> Repo.insert(
          on_conflict: {:replace, [:planned_count, :done_count, :planned_minutes, :done_minutes, :reflection, :updated_at]},
          conflict_target: [:user_id, :date]
        )

      Enum.each(rows, fn %{task: task} ->
        case decision_for(decisions, task.id) do
          {:defer, target} when not task.done ->
            {:ok, _} = defer_task(user_id, task.id, target)
            maybe_shift_due(task, target, tz, date)

          :anytime when not task.done ->
            unplan_task(user_id, task.id)
            {:ok, _} = Boards.update_task(task, %{"due_at" => nil})

          _ ->
            unplan_task(user_id, task.id)
        end
      end)

      review
    end)
  end

  # Reschedule the due date to `target` only when the task was due on or
  # before the day being wrapped (overdue or due today). Future-dated
  # tasks that were pulled into today keep their own due date. Time of
  # day is preserved in the user's zone so a 16:00 meeting stays 16:00.
  defp maybe_shift_due(%Task{due_at: nil}, _target, _tz, _date), do: :ok

  defp maybe_shift_due(%Task{due_at: due_at} = task, %Date{} = target, tz, %Date{} = date) do
    if DateTime.compare(due_at, Boards.end_of_local_day(tz, date)) != :gt do
      local_time = due_at |> DateTime.shift_zone!(tz) |> DateTime.to_time()
      new_due = DateTime.new!(target, local_time, tz) |> DateTime.shift_zone!("Etc/UTC")
      {:ok, _} = Boards.update_task(task, %{"due_at" => new_due})
    end

    :ok
  end

  defp decision_for(decisions, task_id) do
    raw = Map.get(decisions, to_string(task_id)) || Map.get(decisions, task_id)

    case raw do
      nil -> :keep
      "keep" -> :keep
      "" -> :keep
      "anytime" -> :anytime
      %Date{} = d -> {:defer, d}
      iso when is_binary(iso) ->
        case Date.from_iso8601(iso) do
          {:ok, d} -> {:defer, d}
          _ -> :keep
        end
    end
  end

  def get_review(user_id, %Date{} = date) when is_integer(user_id) do
    Repo.get_by(DayReview, user_id: user_id, date: date)
  end

  # -- helpers --

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
