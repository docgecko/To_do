defmodule ToDo.Boards do
  @moduledoc """
  The Boards context — boards, categories, tasks, and sharing.

  Permission resolution (most specific wins):
    1. owner    — owner_id matches
    2. task     — direct task_share row
    3. board    — board_share row (covers all tasks on the board)
    4. none
  """

  import Ecto.Query, warn: false
  alias ToDo.Repo
  alias ToDo.Accounts
  alias ToDo.Accounts.User
  alias ToDo.Boards.{Board, BoardShare, Category, Invitation, Task, TaskListPosition, TaskShare}

  # -- Boards CRUD --

  def list_boards_for_user(user_id) do
    Board
    |> where([b], b.owner_id == ^user_id)
    |> order_by([b], asc: b.position, asc: b.inserted_at)
    |> Repo.all()
  end

  @doc """
  Records the most recently visited board for the user. Used to keep the
  sidebar's "current board" context in sync as the user moves around.
  """
  def remember_last_board(%User{} = user, board_id) when is_integer(board_id) do
    if user.last_board_id == board_id do
      {:ok, user}
    else
      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(set: [last_board_id: board_id])

      {:ok, %{user | last_board_id: board_id}}
    end
  end

  @doc """
  Returns the board the sidebar should treat as "current" for a given user.
  Prefers the user's `last_board_id` when it points at a still-visible
  board that HAS AT LEAST ONE GROUP — otherwise the sidebar's "Board: X
  > All" block would render with no group items below it and hide the
  user's real work behind the wrong board. Falls back to the first
  populated board they can see, then any accessible board, then nil.
  """
  def sidebar_board_for_user(%User{id: user_id}), do: sidebar_board_for_user(user_id)

  def sidebar_board_for_user(user_id) when is_integer(user_id) do
    # Re-read last_board_id from the DB so we don't trip on a stale cached
    # user struct (LiveView's current_scope is set via assign_new and persists
    # across navigations within the same live_session).
    last_id =
      from(u in User, where: u.id == ^user_id, select: u.last_board_id)
      |> Repo.one()

    with id when not is_nil(id) <- last_id,
         %Board{} = board <- visible_board(id, user_id),
         true <- board_has_groups?(board.id) do
      board
    else
      _ -> first_populated_board(user_id) || first_accessible_board(user_id)
    end
  end

  defp visible_board(board_id, user_id) do
    case Repo.get(Board, board_id) do
      nil -> nil
      board -> if board_permission(board, user_id) == :none, do: nil, else: board
    end
  end

  defp board_has_groups?(board_id) do
    from(c in Category,
      where: c.board_id == ^board_id and is_nil(c.parent_id),
      select: 1,
      limit: 1
    )
    |> Repo.one()
    |> is_integer()
  end

  # Prefer a board with at least one group. Own boards first (by
  # position, then inserted_at); if none of the owned boards are
  # populated, try shared ones (alphabetical by name). Returns nil if
  # no accessible board has any groups.
  defp first_populated_board(user_id) do
    owned =
      from(b in Board,
        join: c in Category,
        on: c.board_id == b.id and is_nil(c.parent_id),
        where: b.owner_id == ^user_id,
        distinct: b.id,
        order_by: [asc: b.position, asc: b.inserted_at],
        limit: 1
      )
      |> Repo.one()

    owned ||
      from(b in Board,
        join: s in BoardShare,
        on: s.board_id == b.id,
        join: c in Category,
        on: c.board_id == b.id and is_nil(c.parent_id),
        where: s.user_id == ^user_id,
        distinct: b.id,
        select: %{b | permission: s.permission},
        order_by: [asc: b.name],
        limit: 1
      )
      |> Repo.one()
  end

  defp first_accessible_board(user_id) do
    case list_boards_for_user(user_id) do
      [first | _] ->
        first

      [] ->
        case list_shared_boards(user_id) do
          [first | _] -> first
          [] -> nil
        end
    end
  end

  def list_shared_boards(user_id) do
    from(b in Board,
      join: s in BoardShare, on: s.board_id == b.id,
      where: s.user_id == ^user_id,
      select: %{b | permission: s.permission},
      order_by: [asc: b.name]
    )
    |> Repo.all()
  end

  def get_board!(id), do: Repo.get!(Board, id)

  def get_board_for_user!(id, user_id) do
    Board
    |> where([b], b.id == ^id and b.owner_id == ^user_id)
    |> Repo.one!()
  end

  @doc """
  Fetches a board if the user owns it or has a BoardShare on it. Raises if not.
  """
  def get_visible_board!(id, user_id) do
    board = get_board!(id)

    case board_permission(board, user_id) do
      :none -> raise Ecto.NoResultsError, queryable: Board
      perm -> %{board | permission: Atom.to_string(perm)}
    end
  end

  def load_board(%Board{} = board) do
    tasks_q =
      from(t in Task,
        where: is_nil(t.deleted_at) and t.done == false,
        order_by: [asc: t.position]
      )

    Repo.preload(board, groups: [children: [tasks: {tasks_q, [:created_by]}]])
  end

  def create_board(attrs) do
    %Board{} |> Board.changeset(attrs) |> Repo.insert()
  end

  def update_board(%Board{} = board, attrs) do
    board |> Board.changeset(attrs) |> Repo.update()
  end

  def delete_board(%Board{} = board), do: Repo.delete(board)

  # -- Categories --

  def create_category(attrs) do
    attrs = maybe_reparent_column_to_waiting(nil, attrs)
    attrs = Map.put_new_lazy(attrs, "position", fn -> next_category_position(attrs) end)
    %Category{} |> Category.changeset(attrs) |> Repo.insert()
  end

  defp next_category_position(%{"board_id" => board_id, "parent_id" => parent_id}) do
    query =
      case parent_id do
        nil -> from(c in Category, where: c.board_id == ^board_id and is_nil(c.parent_id))
        id -> from(c in Category, where: c.parent_id == ^id)
      end

    query |> select([c], coalesce(max(c.position), -1) + 1) |> Repo.one()
  end

  defp next_category_position(_), do: 0

  def update_category(%Category{} = category, attrs) do
    attrs = maybe_reparent_column_to_waiting(category, attrs)
    category |> Category.changeset(attrs) |> Repo.update()
  end

  # Column-level Waiting flag: when a column (parent_id present) is
  # saved with `waiting: true` AND its parent is NOT the board's
  # Waiting group, re-parent it under the Waiting group. The group is
  # created on demand. Top-level categories (groups themselves) are
  # untouched — a group with waiting=true IS the Waiting group, not a
  # column that wants to live inside one.
  defp maybe_reparent_column_to_waiting(existing, attrs) do
    if truthy_waiting?(attrs) do
      parent_id =
        case Map.get(attrs, "parent_id") || Map.get(attrs, :parent_id) do
          nil -> existing && existing.parent_id
          "" -> existing && existing.parent_id
          id -> to_int(id)
        end

      board_id =
        case Map.get(attrs, "board_id") || Map.get(attrs, :board_id) do
          nil -> existing && existing.board_id
          "" -> existing && existing.board_id
          id -> to_int(id)
        end

      cond do
        is_nil(parent_id) ->
          # Top-level category — this IS a group, not a column. Leave alone.
          attrs

        is_nil(board_id) ->
          attrs

        true ->
          waiting_group = find_or_create_waiting_group(board_id)

          if parent_id == waiting_group.id do
            attrs
          else
            attrs
            |> Map.put("parent_id", to_string(waiting_group.id))
            |> Map.put("position", next_category_position(%{
              "board_id" => board_id,
              "parent_id" => waiting_group.id
            }))
          end
      end
    else
      attrs
    end
  end

  def delete_category(%Category{} = category), do: Repo.delete(category)

  def get_category!(id), do: Repo.get!(Category, id)

  # -- Tasks --

  def create_task(attrs) do
    attrs = maybe_relocate_to_waiting(nil, attrs)
    attrs = Map.put_new_lazy(attrs, "position", fn -> next_task_position(attrs) end)
    %Task{} |> Task.changeset(attrs) |> Repo.insert()
  end

  defp next_task_position(%{"category_id" => category_id}) do
    from(t in Task, where: t.category_id == ^category_id, select: coalesce(max(t.position), -1) + 1)
    |> Repo.one()
  end

  defp next_task_position(_), do: 0

  def update_task(%Task{} = task, attrs) do
    attrs = maybe_relocate_to_waiting(task, attrs)
    attrs = maybe_relocate_from_waiting(task, attrs)
    attrs = maybe_assign_position(task, attrs)

    case task |> Task.changeset(attrs) |> Repo.update() do
      {:ok, updated} = ok ->
        cleanup_emptied_waiting_mirror(task.category_id, updated.category_id)
        ok

      error ->
        error
    end
  end

  # When a task moves OUT of a mirror column under the Waiting group
  # and that mirror is now empty (no tasks of any kind — including
  # soft-deleted ones in Trash, which still hold the FK), prune the
  # mirror. Mirror = non-waiting column whose parent group is the
  # Waiting group. User-created columns flagged waiting=true are left
  # alone, and we never touch the Waiting group itself.
  defp cleanup_emptied_waiting_mirror(old_cat_id, new_cat_id)
       when not is_nil(old_cat_id) and old_cat_id != new_cat_id do
    with %Category{parent_id: parent_id, waiting: false} = col when not is_nil(parent_id) <-
           Repo.get(Category, old_cat_id),
         %Category{waiting: true} <- Repo.get(Category, parent_id),
         0 <- count_tasks_in_category(col.id) do
      Repo.delete(col)
    end

    :ok
  end

  defp cleanup_emptied_waiting_mirror(_, _), do: :ok

  defp count_tasks_in_category(category_id) do
    Repo.aggregate(from(t in Task, where: t.category_id == ^category_id), :count)
  end

  # When a task is being saved with `waiting: true` AND it isn't already
  # inside a waiting group, re-home it to the board's Waiting group
  # (creating that group on demand) under a column that mirrors the
  # source column's name (also created on demand). The source
  # category_id is stashed in `prior_category_id` so unticking waiting
  # later can restore the task to its origin column.
  # Idempotent for tasks already in a waiting group.
  defp maybe_relocate_to_waiting(task_or_nil, attrs) do
    if truthy_waiting?(attrs) do
      source_cat_id =
        case Map.get(attrs, "category_id") || Map.get(attrs, :category_id) do
          nil -> task_or_nil && task_or_nil.category_id
          "" -> task_or_nil && task_or_nil.category_id
          id -> to_int(id)
        end

      case source_cat_id && Repo.get(Category, source_cat_id) do
        nil ->
          attrs

        %Category{} = source_cat ->
          if in_waiting_group?(source_cat) do
            attrs
          else
            waiting_col = find_or_create_waiting_column(source_cat)

            attrs
            |> Map.put("category_id", to_string(waiting_col.id))
            |> Map.put("prior_category_id", to_string(source_cat.id))
          end
      end
    else
      attrs
    end
  end

  # Inverse: when a task is being saved with `waiting: false` AND the
  # task is currently inside a waiting group, move it back to its
  # origin column. Prefers the stored `prior_category_id`; falls back
  # to a same-named non-waiting column on the same board for tasks
  # that pre-date the prior-tracking column (or for users restoring
  # tasks through other paths). Clears `prior_category_id` once moved.
  defp maybe_relocate_from_waiting(%Task{} = task, attrs) do
    if explicit_unwait?(attrs) and currently_in_waiting?(task) do
      destination = restore_target(task)

      if destination do
        attrs
        |> Map.put("category_id", to_string(destination.id))
        |> Map.put("prior_category_id", nil)
      else
        attrs
      end
    else
      attrs
    end
  end

  # Was the task in a waiting group at the moment of save? We check the
  # current `category_id` from attrs (if the user is moving columns AND
  # un-waiting at the same time) or fall back to the task's stored
  # category.
  defp currently_in_waiting?(%Task{category_id: cat_id}) do
    case Repo.get(Category, cat_id) do
      nil -> false
      %Category{} = c -> in_waiting_group?(c)
    end
  end

  # Where to send the task when waiting is unticked.
  #   1. The stashed prior column (if it still exists)
  #   2. A non-waiting column with the same name on the same board
  #      (handy for tasks stored before prior_category_id existed)
  defp restore_target(%Task{prior_category_id: prior_id} = task) when not is_nil(prior_id) do
    case Repo.get(Category, prior_id) do
      nil -> fallback_same_name_target(task)
      cat -> if in_waiting_group?(cat), do: fallback_same_name_target(task), else: cat
    end
  end

  defp restore_target(%Task{} = task), do: fallback_same_name_target(task)

  defp fallback_same_name_target(%Task{category_id: cat_id}) do
    case Repo.get(Category, cat_id) do
      nil ->
        nil

      %Category{board_id: board_id, name: name} ->
        query =
          from c in Category,
            join: g in Category,
            on: g.id == c.parent_id,
            where:
              c.board_id == ^board_id and c.name == ^name and c.waiting == false and
                g.waiting == false,
            limit: 1

        Repo.one(query)
    end
  end

  defp explicit_unwait?(attrs) do
    case Map.get(attrs, "waiting") || Map.get(attrs, :waiting) do
      false -> true
      "false" -> true
      _ -> false
    end
  end

  # Whenever an update moves the task to a NEW category, append it at
  # the bottom of that column rather than carrying the old position
  # number across (which could collide or surface at a strange index).
  defp maybe_assign_position(%Task{category_id: old_cat_id}, attrs) do
    new_cat_id =
      case Map.get(attrs, "category_id") || Map.get(attrs, :category_id) do
        nil -> nil
        "" -> nil
        id -> to_int(id)
      end

    if new_cat_id && new_cat_id != old_cat_id do
      Map.put(attrs, "position", next_task_position(%{"category_id" => new_cat_id}))
    else
      attrs
    end
  end

  defp truthy_waiting?(attrs) do
    case Map.get(attrs, "waiting") || Map.get(attrs, :waiting) do
      true -> true
      "true" -> true
      _ -> false
    end
  end

  # Top-level categories with `waiting: true` ARE the waiting group.
  # For columns (parent_id present), the column is "in" a waiting group
  # if either the column or its parent group carries the flag.
  defp in_waiting_group?(%Category{parent_id: nil, waiting: w}), do: w

  defp in_waiting_group?(%Category{parent_id: parent_id, waiting: w}) do
    w or
      case Repo.get(Category, parent_id) do
        nil -> false
        %Category{waiting: pw} -> pw
      end
  end

  # Source can be a column (preferred) or a group. From a column we
  # mirror the column's name into the waiting group. From a group we
  # fall back to a generic "Waiting" column (no source column to mirror).
  defp find_or_create_waiting_column(%Category{board_id: board_id, parent_id: nil}) do
    waiting_group = find_or_create_waiting_group(board_id)
    find_or_create_named_subcolumn(waiting_group, "Waiting")
  end

  defp find_or_create_waiting_column(%Category{board_id: board_id, name: source_name}) do
    waiting_group = find_or_create_waiting_group(board_id)
    find_or_create_named_subcolumn(waiting_group, source_name)
  end

  defp find_or_create_waiting_group(board_id) do
    query =
      from c in Category,
        where: c.board_id == ^board_id and is_nil(c.parent_id) and c.waiting == true,
        limit: 1

    case Repo.one(query) do
      nil ->
        {:ok, group} =
          create_category(%{
            "board_id" => to_string(board_id),
            "name" => "Waiting",
            "color" => "#94a3b8",
            "waiting" => "true"
          })

        group

      group ->
        group
    end
  end

  defp find_or_create_named_subcolumn(%Category{id: parent_id, board_id: board_id}, name) do
    query =
      from c in Category,
        where: c.parent_id == ^parent_id and c.name == ^name,
        limit: 1

    case Repo.one(query) do
      nil ->
        {:ok, col} =
          create_category(%{
            "board_id" => to_string(board_id),
            "name" => name,
            "parent_id" => to_string(parent_id),
            "waiting" => "false"
          })

        col

      col ->
        col
    end
  end

  @doc """
  Toggle a task's done state. For a repeating task being checked (not→done),
  instead of marking done we advance `due_at` by `repeat_every` units and keep
  `done: false`. If the advanced date passes `repeat_until`, the final
  occurrence is marked done permanently. Unchecking always just clears `done`.
  """
  def toggle_task_done(%Task{} = task) do
    cond do
      task.done ->
        update_task(task, %{"done" => false})

      task.repeat in ["day", "week", "month", "year"] and not is_nil(task.due_at) ->
        every = max(task.repeat_every || 1, 1)
        next_due = advance_due_at(task.due_at, task.repeat, every)

        if past_repeat_until?(next_due, task.repeat_until) do
          update_task(task, %{"done" => true})
        else
          update_task(task, %{"done" => false, "due_at" => next_due})
        end

      true ->
        update_task(task, %{"done" => true})
    end
  end

  defp past_repeat_until?(_next, nil), do: false

  defp past_repeat_until?(%DateTime{} = next, %DateTime{} = until) do
    DateTime.compare(next, until) == :gt
  end

  defp advance_due_at(%DateTime{} = dt, "day", n), do: DateTime.shift(dt, day: n)
  defp advance_due_at(%DateTime{} = dt, "week", n), do: DateTime.shift(dt, day: 7 * n)
  defp advance_due_at(%DateTime{} = dt, "year", n), do: DateTime.shift(dt, year: n)

  # Monthly repeat — track day-of-week + ordinal-within-month, not the
  # date number. "Last Tuesday of May" repeats to "last Tuesday of
  # June", and "2nd Friday" stays "2nd Friday" — much closer to how
  # people actually mean "monthly" for meetings, club nights, chores,
  # etc.
  #
  # Rule:
  #   - If the source is the LAST <weekday> of its month (no further
  #     instance of that weekday inside the same month), the target is
  #     the LAST <weekday> of the target month.
  #   - Otherwise compute `nth = ceil(day / 7)` — the Nth <weekday> of
  #     the source month — and find the Nth <weekday> of the target
  #     month. If the target month doesn't have that many (e.g. source
  #     was 5th but target only has 4), fall back to the LAST one.
  defp advance_due_at(%DateTime{} = dt, "month", n) do
    source_date = DateTime.to_date(dt)
    weekday = Date.day_of_week(source_date)

    # `Date.shift/2` handles year rollover & month-length clamping for us.
    target_anchor = Date.shift(source_date, month: n)

    next_same_weekday = Date.add(source_date, 7)
    last_of_month? = next_same_weekday.month != source_date.month

    target_date =
      if last_of_month? do
        last_weekday_of_month(target_anchor.year, target_anchor.month, weekday)
      else
        nth = div(source_date.day - 1, 7) + 1

        nth_weekday_of_month(target_anchor.year, target_anchor.month, weekday, nth) ||
          last_weekday_of_month(target_anchor.year, target_anchor.month, weekday)
      end

    %{dt | year: target_date.year, month: target_date.month, day: target_date.day}
  end

  # Nth occurrence of `weekday` (1=Mon..7=Sun) in (year, month). Returns
  # nil if the month doesn't contain that many — caller falls back to
  # `last_weekday_of_month`.
  defp nth_weekday_of_month(year, month, weekday, nth) do
    first = Date.new!(year, month, 1)
    offset = Integer.mod(weekday - Date.day_of_week(first), 7)
    day = 1 + offset + (nth - 1) * 7

    if day <= Date.days_in_month(first) do
      Date.new!(year, month, day)
    end
  end

  defp last_weekday_of_month(year, month, weekday) do
    last_day = Date.days_in_month(Date.new!(year, month, 1))
    last = Date.new!(year, month, last_day)
    offset = Integer.mod(Date.day_of_week(last) - weekday, 7)
    Date.new!(year, month, last_day - offset)
  end

  def delete_task(%Task{} = task) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    task |> Task.changeset(%{"deleted_at" => now}) |> Repo.update()
  end

  def restore_task(%Task{} = task) do
    task |> Task.changeset(%{"deleted_at" => nil}) |> Repo.update()
  end

  def purge_task(%Task{} = task), do: Repo.delete(task)

  def get_task!(id), do: Repo.get!(Task, id)

  def reorder_tasks(category_id, task_ids) when is_list(task_ids) do
    Repo.transaction(fn ->
      for {task_id, index} <- Enum.with_index(task_ids) do
        from(t in Task, where: t.id == ^task_id)
        |> Repo.update_all(set: [category_id: category_id, position: index])
      end
    end)
  end

  @doc """
  Reorder a set of categories that share the same parent scope.
  `scope` is either `{:board, board_id}` for top-level groups or
  `{:parent, parent_id}` for sub-columns. Category ids outside the
  scope are ignored for safety.
  """
  def reorder_categories({:board, board_id}, category_ids) when is_list(category_ids) do
    Repo.transaction(fn ->
      for {category_id, index} <- Enum.with_index(category_ids) do
        from(c in Category,
          where: c.id == ^category_id and c.board_id == ^board_id and is_nil(c.parent_id)
        )
        |> Repo.update_all(set: [position: index])
      end
    end)
  end

  def reorder_categories({:parent, parent_id}, category_ids) when is_list(category_ids) do
    Repo.transaction(fn ->
      for {category_id, index} <- Enum.with_index(category_ids) do
        from(c in Category,
          where: c.id == ^category_id and c.parent_id == ^parent_id
        )
        |> Repo.update_all(set: [position: index])
      end
    end)
  end

  @doc """
  Move a column (child category) from one parent group to another, and apply
  the resulting orderings of both lists. Scoped to `board_id` for safety.
  """
  def move_column_between_parents(board_id, category_id, to_parent_id, from_ids, to_ids)
      when is_list(from_ids) and is_list(to_ids) do
    Repo.transaction(fn ->
      from(c in Category,
        where: c.id == ^category_id and c.board_id == ^board_id and not is_nil(c.parent_id)
      )
      |> Repo.update_all(set: [parent_id: to_parent_id])

      for {cid, index} <- Enum.with_index(from_ids) do
        from(c in Category, where: c.id == ^cid and c.board_id == ^board_id)
        |> Repo.update_all(set: [position: index])
      end

      for {cid, index} <- Enum.with_index(to_ids) do
        from(c in Category,
          where: c.id == ^cid and c.board_id == ^board_id and c.parent_id == ^to_parent_id
        )
        |> Repo.update_all(set: [position: index])
      end
    end)
  end

  @doc """
  End of the current (or given) local day in `tz`, as a UTC DateTime.
  The day boundary Today/Upcoming pivot on — pass the user's timezone
  so "due today" means their today, not UTC's.
  """
  def end_of_local_day(tz, date \\ nil) do
    date = date || (DateTime.now!(tz) |> DateTime.to_date())
    DateTime.new!(date, ~T[23:59:59], tz) |> DateTime.shift_zone!("Etc/UTC")
  end

  @doc """
  Returns tasks visible to `user_id` across owned + shared boards, filtered by
  `scope` — :today, :upcoming, :anytime, or :waiting.
  Each result is `%{task:, board:, category:, group:}`.
  Pass `tz:` (IANA name) so the day boundary is the user's; defaults to UTC.
  """
  def list_smart_tasks(user_id, scope, opts \\ []) do
    tz = Keyword.get(opts, :tz, "Etc/UTC")
    now = DateTime.utc_now()
    end_of_today = end_of_local_day(tz)
    scope_str = to_string(scope)

    # Left-join the per-user list-position table so the LIST view can
    # honour manual reordering (where set) and fall through to the
    # scope's natural chronological order otherwise.
    base =
      from(t in Task,
        join: c in Category, on: c.id == t.category_id,
        join: b in Board, on: b.id == c.board_id,
        left_join: g in Category, on: g.id == c.parent_id,
        left_join: bs in BoardShare, on: bs.board_id == b.id and bs.user_id == ^user_id,
        left_join: ts in TaskShare, on: ts.task_id == t.id and ts.user_id == ^user_id,
        left_join: tlp in TaskListPosition,
          on: tlp.task_id == t.id and tlp.user_id == ^user_id and tlp.scope == ^scope_str,
        where: b.owner_id == ^user_id or not is_nil(bs.id) or not is_nil(ts.id),
        select: %{task: t, board: b, category: c, group: g, list_position: tlp.position}
      )

    base =
      if scope == :trash do
        base
      else
        from [t, _c, _b, _g, _bs, _ts, _tlp] in base, where: is_nil(t.deleted_at)
      end

    base
    |> apply_smart_filter(scope, now, end_of_today)
    |> Repo.all()
  end

  @doc """
  Rewrite the user's list-view order for `scope` from `ordered_task_ids`.
  Each task in the list is assigned a sequential position starting at 1;
  tasks not in the list are left untouched (their existing TLP row is
  preserved so navigating away and back doesn't lose state).

  Idempotent. Safe to call with a stable order — nothing changes.
  """
  def reorder_list_tasks(user_id, scope, ordered_task_ids)
      when is_integer(user_id) and is_list(ordered_task_ids) do
    scope_str = to_string(scope)

    unless scope_str in TaskListPosition.scopes() do
      raise ArgumentError, "scope must be one of #{inspect(TaskListPosition.scopes())}"
    end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      ordered_task_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {task_id, pos} ->
        %{
          user_id: user_id,
          task_id: to_int(task_id),
          scope: scope_str,
          position: pos,
          inserted_at: now,
          updated_at: now
        }
      end)

    case entries do
      [] ->
        {:ok, 0}

      _ ->
        {count, _} =
          Repo.insert_all(TaskListPosition, entries,
            on_conflict: {:replace, [:position, :updated_at]},
            conflict_target: [:user_id, :task_id, :scope]
          )

        {:ok, count}
    end
  end

  defp to_int(n) when is_integer(n), do: n
  defp to_int(n) when is_binary(n), do: String.to_integer(n)

  # Each scope's order_by puts manual list_position (if set) first, then
  # falls through to a sensible chronological default. `asc_nulls_last`
  # means tasks the user has NOT manually dragged still appear in date
  # order behind the ones they have.
  defp apply_smart_filter(q, :today, _now, eod) do
    from [t, _c, _b, _g, _bs, _ts, tlp] in q,
      where: t.done == false and not is_nil(t.due_at) and t.due_at <= ^eod,
      order_by: [asc_nulls_last: tlp.position, asc: t.due_at, asc: t.position]
  end

  defp apply_smart_filter(q, :upcoming, _now, eod) do
    from [t, _c, _b, _g, _bs, _ts, tlp] in q,
      where: t.done == false and not is_nil(t.due_at) and t.due_at > ^eod,
      order_by: [asc_nulls_last: tlp.position, asc: t.due_at, asc: t.position]
  end

  defp apply_smart_filter(q, :anytime, _now, _eod) do
    from [t, _c, _b, _g, _bs, _ts, tlp] in q,
      where: t.done == false and is_nil(t.due_at),
      order_by: [asc_nulls_last: tlp.position, asc: t.inserted_at]
  end

  defp apply_smart_filter(q, :waiting, _now, _eod) do
    from [t, c, _b, g, _bs, _ts, tlp] in q,
      where:
        t.done == false and
          (t.waiting == true or c.waiting == true or
             (not is_nil(g.id) and g.waiting == true)),
      order_by: [asc_nulls_last: tlp.position, asc: t.position]
  end

  defp apply_smart_filter(q, :completed, _now, _eod) do
    from [t, _c, _b, _g, _bs, _ts, _tlp] in q,
      where: t.done == true,
      order_by: [desc: t.updated_at]
  end

  defp apply_smart_filter(q, :trash, _now, _eod) do
    from [t, _c, _b, _g, _bs, _ts, _tlp] in q,
      where: not is_nil(t.deleted_at),
      order_by: [desc: t.deleted_at]
  end

  # -- Permissions --

  @doc """
  Returns a permission atom for the given user on a board.

    * `:owner` — full control (implies edit)
    * `:edit`  — shared with edit rights
    * `:view`  — shared read-only
    * `:none`  — no access
  """
  def board_permission(%Board{} = board, user_id) do
    cond do
      board.owner_id == user_id -> :owner
      true ->
        case Repo.get_by(BoardShare, board_id: board.id, user_id: user_id) do
          nil -> :none
          %BoardShare{permission: "edit"} -> :edit
          %BoardShare{permission: "view"} -> :view
        end
    end
  end

  def board_permission(board_id, user_id) when is_integer(board_id) or is_binary(board_id) do
    case Repo.get(Board, board_id) do
      nil -> :none
      board -> board_permission(board, user_id)
    end
  end

  @doc """
  Task permission falls back to board permission if no direct share exists.
  """
  def task_permission(%Task{} = task, user_id) do
    case Repo.get_by(TaskShare, task_id: task.id, user_id: user_id) do
      %TaskShare{permission: "edit"} -> :edit
      %TaskShare{permission: "view"} -> :view
      nil -> board_permission(%Board{id: task_category_board_id(task), owner_id: task_owner_id(task)}, user_id)
    end
  end

  defp task_category_board_id(%Task{category_id: cid}) do
    Repo.one!(from c in Category, where: c.id == ^cid, select: c.board_id)
  end

  defp task_owner_id(%Task{category_id: cid}) do
    Repo.one!(
      from c in Category,
        join: b in Board, on: b.id == c.board_id,
        where: c.id == ^cid,
        select: b.owner_id
    )
  end

  def can_edit_board?(board, user_id), do: board_permission(board, user_id) in [:owner, :edit]
  def can_view_board?(board, user_id), do: board_permission(board, user_id) != :none

  # -- Sharing --

  @doc """
  Share a board with a user by email. If the user exists, creates/updates a
  BoardShare. Otherwise creates an Invitation and returns {:invited, invitation}.
  """
  def share_board_by_email(board_id, email, permission, invited_by_id) do
    email = String.downcase(String.trim(email))

    case Accounts.get_user_by_email(email) do
      nil ->
        create_invitation(%{
          "email" => email,
          "permission" => permission,
          "board_id" => board_id,
          "invited_by_id" => invited_by_id
        })
        |> tag(:invited)

      user ->
        result = upsert_board_share(board_id, user.id, permission)

        # Skip self-shares (a user re-sharing with themselves shouldn't ping them).
        if match?({:ok, _}, result) and user.id != invited_by_id do
          notify_board_shared(user.id, board_id, invited_by_id)
        end

        tag(result, :shared)
    end
  end

  def share_task_by_email(task_id, email, permission, invited_by_id) do
    email = String.downcase(String.trim(email))

    case Accounts.get_user_by_email(email) do
      nil ->
        create_invitation(%{
          "email" => email,
          "permission" => permission,
          "task_id" => task_id,
          "invited_by_id" => invited_by_id
        })
        |> tag(:invited)

      user ->
        result = upsert_task_share(task_id, user.id, permission)

        if match?({:ok, _}, result) and user.id != invited_by_id do
          notify_task_shared(user.id, task_id, invited_by_id)
        end

        tag(result, :shared)
    end
  end

  defp notify_board_shared(user_id, board_id, invited_by_id) do
    body =
      case Repo.get(Board, board_id) do
        nil -> "A board was shared with you."
        board -> "#{sharer_name(invited_by_id)} shared the board “#{board.name}” with you."
      end

    ToDo.Notifications.create_or_skip(%{
      user_id: user_id,
      kind: "board_shared",
      board_id: board_id,
      body: body
    })
  end

  defp notify_task_shared(user_id, task_id, invited_by_id) do
    body =
      case Repo.get(Task, task_id) do
        nil -> "A task was shared with you."
        task -> "#{sharer_name(invited_by_id)} shared the task “#{task.title}” with you."
      end

    ToDo.Notifications.create_or_skip(%{
      user_id: user_id,
      kind: "task_shared",
      task_id: task_id,
      body: body
    })
  end

  defp sharer_name(user_id) do
    case Accounts.get_user!(user_id) do
      %{email: email} -> email
      _ -> "Someone"
    end
  rescue
    Ecto.NoResultsError -> "Someone"
  end

  defp tag({:ok, record}, kind), do: {:ok, kind, record}
  defp tag({:error, cs}, _), do: {:error, cs}

  defp upsert_board_share(board_id, user_id, permission) do
    %BoardShare{}
    |> BoardShare.changeset(%{"board_id" => board_id, "user_id" => user_id, "permission" => permission})
    |> Repo.insert(
      on_conflict: [set: [permission: permission, updated_at: DateTime.utc_now(:second)]],
      conflict_target: [:board_id, :user_id]
    )
  end

  defp upsert_task_share(task_id, user_id, permission) do
    %TaskShare{}
    |> TaskShare.changeset(%{"task_id" => task_id, "user_id" => user_id, "permission" => permission})
    |> Repo.insert(
      on_conflict: [set: [permission: permission, updated_at: DateTime.utc_now(:second)]],
      conflict_target: [:task_id, :user_id]
    )
  end

  def list_board_shares(board_id) do
    from(s in BoardShare,
      where: s.board_id == ^board_id,
      join: u in assoc(s, :user),
      preload: [user: u],
      order_by: [asc: u.email]
    )
    |> Repo.all()
  end

  def list_task_shares(task_id) do
    from(s in TaskShare,
      where: s.task_id == ^task_id,
      join: u in assoc(s, :user),
      preload: [user: u],
      order_by: [asc: u.email]
    )
    |> Repo.all()
  end

  def list_board_invitations(board_id) do
    from(i in Invitation,
      where: i.board_id == ^board_id and is_nil(i.accepted_at),
      order_by: [asc: i.email]
    )
    |> Repo.all()
  end

  def list_task_invitations(task_id) do
    from(i in Invitation,
      where: i.task_id == ^task_id and is_nil(i.accepted_at),
      order_by: [asc: i.email]
    )
    |> Repo.all()
  end

  def revoke_board_share!(id), do: Repo.get!(BoardShare, id) |> Repo.delete!()
  def revoke_task_share!(id), do: Repo.get!(TaskShare, id) |> Repo.delete!()
  def revoke_invitation!(id), do: Repo.get!(Invitation, id) |> Repo.delete!()

  # Shared tasks directly (for /shared page) — exclude tasks on boards the user
  # already has access to via board_share (they'll see them there).
  def list_shared_tasks_for_user(user_id) do
    board_ids_accessible =
      from(s in BoardShare, where: s.user_id == ^user_id, select: s.board_id)

    from(t in Task,
      join: s in TaskShare, on: s.task_id == t.id,
      join: c in Category, on: c.id == t.category_id,
      join: b in Board, on: b.id == c.board_id,
      where: s.user_id == ^user_id and b.owner_id != ^user_id,
      where: is_nil(t.deleted_at),
      where: c.board_id not in subquery(board_ids_accessible),
      select: %{task: t, permission: s.permission, board: b, category: c},
      order_by: [asc: b.name, asc: c.position, asc: t.position]
    )
    |> Repo.all()
  end

  # -- Invitations --

  def create_invitation(attrs) do
    attrs =
      attrs
      |> Map.put_new_lazy("token", fn -> :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false) end)
      |> Map.put_new_lazy("expires_at", fn ->
        DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)
      end)

    %Invitation{}
    |> Invitation.changeset(attrs)
    |> Repo.insert()
  end

  def get_invitation_by_token(token) do
    Repo.get_by(Invitation, token: token)
  end

  @doc """
  Convert all pending invitations for `email` into real shares owned by `user_id`.
  Called after signup.
  """
  def accept_pending_invitations(email, user_id) do
    email = String.downcase(String.trim(email))
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    invitations =
      from(i in Invitation,
        where: i.email == ^email and is_nil(i.accepted_at) and i.expires_at > ^now
      )
      |> Repo.all()

    Repo.transaction(fn ->
      for inv <- invitations do
        cond do
          not is_nil(inv.board_id) ->
            upsert_board_share(inv.board_id, user_id, inv.permission)

          not is_nil(inv.task_id) ->
            upsert_task_share(inv.task_id, user_id, inv.permission)

          true ->
            :skip
        end

        inv
        |> Ecto.Changeset.change(accepted_at: now)
        |> Repo.update!()
      end

      length(invitations)
    end)
  end
end
