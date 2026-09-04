defmodule ToDo.Goals do
  @moduledoc """
  Long-running personal outcomes tasks can be tagged to. A goal is
  owned by one user; a task can be tagged with many goals via the
  `task_goals` join table. Sharing lives at the tag level, not the
  goal level — different users tag the same shared task with their
  own goals independently.
  """

  import Ecto.Query, warn: false

  alias ToDo.Repo
  alias ToDo.Goals.Goal
  alias ToDo.Boards.Task
  alias ToDo.Accounts.User

  # -- Goal CRUD --

  @doc """
  All of a user's goals ordered by position then inserted_at. Optional
  `:status` filter (single string or a list of strings).
  """
  def list_goals(user_id, opts \\ []) when is_integer(user_id) do
    q =
      from g in Goal,
        where: g.user_id == ^user_id,
        order_by: [asc: g.position, asc: g.inserted_at]

    q =
      case Keyword.get(opts, :status) do
        nil -> q
        s when is_binary(s) -> where(q, [g], g.status == ^s)
        list when is_list(list) -> where(q, [g], g.status in ^list)
      end

    Repo.all(q)
  end

  @doc "Fetch by id, scoped to `user_id`. Raises if not found or not the owner."
  def get_user_goal!(id, user_id) when is_integer(user_id) do
    from(g in Goal, where: g.id == ^id and g.user_id == ^user_id)
    |> Repo.one!()
  end

  @doc "Same as `get_user_goal!/2` but returns nil instead of raising."
  def get_user_goal(id, user_id) when is_integer(user_id) do
    from(g in Goal, where: g.id == ^id and g.user_id == ^user_id)
    |> Repo.one()
  end

  def create_goal(attrs) do
    attrs = Map.put_new_lazy(attrs, "position", fn -> next_goal_position(attrs) end)
    %Goal{} |> Goal.changeset(attrs) |> Repo.insert()
  end

  def update_goal(%Goal{} = goal, attrs) do
    goal |> Goal.changeset(attrs) |> Repo.update()
  end

  def delete_goal(%Goal{} = goal), do: Repo.delete(goal)

  defp next_goal_position(%{"user_id" => user_id}) do
    from(g in Goal, where: g.user_id == ^user_id, select: coalesce(max(g.position), -1) + 1)
    |> Repo.one()
  end

  defp next_goal_position(_), do: 0

  # -- Tagging (per-user) --

  @doc """
  Replaces the tags a specific user has attached to a task. Only touches
  rows whose goal belongs to that user, so collaborators' tags on the
  same task are untouched. `goal_ids` may include stringified integers
  from a form submission.
  """
  def replace_user_goal_tags(%Task{id: task_id}, user_id, goal_ids) when is_integer(user_id) do
    desired = normalize_goal_ids(goal_ids) |> filter_owned(user_id) |> MapSet.new()
    current = user_tags_for_task(task_id, user_id) |> MapSet.new()

    to_add = MapSet.difference(desired, current)
    to_remove = MapSet.difference(current, desired)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if MapSet.size(to_add) > 0 do
      rows =
        Enum.map(to_add, fn gid ->
          %{task_id: task_id, goal_id: gid, inserted_at: now}
        end)

      Repo.insert_all("task_goals", rows, on_conflict: :nothing)
    end

    if MapSet.size(to_remove) > 0 do
      ids = MapSet.to_list(to_remove)

      from(tg in "task_goals",
        where: tg.task_id == ^task_id and tg.goal_id in ^ids
      )
      |> Repo.delete_all()
    end

    :ok
  end

  # A user's tags on a task = task_goals rows joined against the user's goals.
  defp user_tags_for_task(task_id, user_id) do
    from(tg in "task_goals",
      join: g in Goal,
      on: g.id == tg.goal_id,
      where: tg.task_id == ^task_id and g.user_id == ^user_id,
      select: tg.goal_id
    )
    |> Repo.all()
  end

  defp normalize_goal_ids(nil), do: []

  defp normalize_goal_ids(list) when is_list(list) do
    list
    |> Enum.map(&to_int/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_goal_ids(map) when is_map(map) do
    # Phoenix form submissions with `phx-hook`-less checkboxes arrive as
    # a map `%{"0" => "12", "1" => "17"}`. Take the values.
    Map.values(map) |> normalize_goal_ids()
  end

  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil

  # Keep only goal ids the user actually owns — guards against a
  # tampered form submission trying to attach someone else's goal.
  defp filter_owned([], _user_id), do: []

  defp filter_owned(ids, user_id) do
    from(g in Goal, where: g.id in ^ids and g.user_id == ^user_id, select: g.id)
    |> Repo.all()
  end

  # -- Queries used by the UI --

  @doc """
  All goal ids currently tagged by `user_id` on the given task. Used
  by the task modal to preselect checkboxes.
  """
  def user_goal_ids_for_task(task_id, user_id) when is_integer(user_id) do
    user_tags_for_task(task_id, user_id)
  end

  @doc """
  Non-deleted tasks tagged to this goal, grouped by their board with
  the row shape smart-list views already consume. Returns:
    [%{board: %Board{}, tasks: [%{task: %Task{}, category: %Category{}, group: %Category{} | nil}]}]
  """
  def list_tasks_for_goal(%Goal{id: goal_id}) do
    q =
      from t in Task,
        join: tg in "task_goals",
        on: tg.task_id == t.id,
        join: c in ToDo.Boards.Category,
        on: c.id == t.category_id,
        join: b in ToDo.Boards.Board,
        on: b.id == c.board_id,
        left_join: g in ToDo.Boards.Category,
        on: g.id == c.parent_id,
        where: tg.goal_id == ^goal_id and is_nil(t.deleted_at),
        order_by: [asc: b.name, asc: t.done, asc: t.due_at, asc: t.inserted_at],
        select: %{task: t, category: c, board: b, group: g}

    rows = Repo.all(q)

    rows
    |> Enum.group_by(& &1.board.id)
    |> Enum.map(fn {_, board_rows} ->
      [%{board: board} | _] = board_rows
      %{board: board, tasks: board_rows}
    end)
    |> Enum.sort_by(& &1.board.name)
  end

  @doc """
  Progress fraction as `{completed, total}`. Counts non-deleted tasks.
  """
  def goal_progress(%Goal{id: goal_id}), do: goal_progress(goal_id)

  def goal_progress(goal_id) when is_integer(goal_id) do
    q =
      from t in Task,
        join: tg in "task_goals",
        on: tg.task_id == t.id,
        where: tg.goal_id == ^goal_id and is_nil(t.deleted_at),
        select: {sum(fragment("case when ? then 1 else 0 end", t.done)), count(t.id)}

    case Repo.one(q) do
      {nil, 0} -> {0, 0}
      {done, total} -> {done || 0, total}
    end
  end

  @doc """
  Batched progress lookup for a list of goals. Returns a map
  `%{goal_id => {completed, total}}` so the sidebar can render every
  goal's fraction in one query instead of N+1.
  """
  def progress_for_goals([]), do: %{}

  def progress_for_goals(goal_ids) when is_list(goal_ids) do
    q =
      from t in Task,
        join: tg in "task_goals",
        on: tg.task_id == t.id,
        where: tg.goal_id in ^goal_ids and is_nil(t.deleted_at),
        group_by: tg.goal_id,
        select: {tg.goal_id, sum(fragment("case when ? then 1 else 0 end", t.done)), count(t.id)}

    counts =
      q
      |> Repo.all()
      |> Map.new(fn {gid, done, total} -> {gid, {done || 0, total}} end)

    # Any goal with zero tasks won't appear in the aggregate result; fill it in.
    Enum.reduce(goal_ids, counts, fn gid, acc -> Map.put_new(acc, gid, {0, 0}) end)
  end

  @doc """
  Batched chip lookup: all goals tagged on each of the given tasks (any
  user's — a shared task shows every collaborator's tags as context).
  Returns `%{task_id => [%Goal{}]}`; tasks with no tags are absent.
  """
  def goals_by_task_ids([]), do: %{}

  def goals_by_task_ids(task_ids) when is_list(task_ids) do
    from(g in Goal,
      join: tg in "task_goals",
      on: tg.goal_id == g.id,
      where: tg.task_id in ^task_ids,
      order_by: [asc: g.name],
      select: {tg.task_id, g}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # -- Convenience --

  @doc "Goals for the current user, active only, ordered by position."
  def list_active_goals(%User{id: user_id}), do: list_active_goals(user_id)

  def list_active_goals(user_id) when is_integer(user_id) do
    list_goals(user_id, status: "active")
  end
end
