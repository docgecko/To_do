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
  alias ToDo.Boards.{Board, BoardShare, Category, Invitation, Task, TaskShare}

  # -- Boards CRUD --

  def list_boards_for_user(user_id) do
    Board
    |> where([b], b.owner_id == ^user_id)
    |> order_by([b], asc: b.position, asc: b.inserted_at)
    |> Repo.all()
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
    category |> Category.changeset(attrs) |> Repo.update()
  end

  def delete_category(%Category{} = category), do: Repo.delete(category)

  def get_category!(id), do: Repo.get!(Category, id)

  # -- Tasks --

  def create_task(attrs) do
    attrs = Map.put_new_lazy(attrs, "position", fn -> next_task_position(attrs) end)
    %Task{} |> Task.changeset(attrs) |> Repo.insert()
  end

  defp next_task_position(%{"category_id" => category_id}) do
    from(t in Task, where: t.category_id == ^category_id, select: coalesce(max(t.position), -1) + 1)
    |> Repo.one()
  end

  defp next_task_position(_), do: 0

  def update_task(%Task{} = task, attrs) do
    task |> Task.changeset(attrs) |> Repo.update()
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
  defp advance_due_at(%DateTime{} = dt, "month", n), do: DateTime.shift(dt, month: n)
  defp advance_due_at(%DateTime{} = dt, "year", n), do: DateTime.shift(dt, year: n)

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
  Returns tasks visible to `user_id` across owned + shared boards, filtered by
  `scope` — :today, :upcoming, :anytime, or :waiting.
  Each result is `%{task:, board:, category:, group:}`.
  """
  def list_smart_tasks(user_id, scope) do
    now = DateTime.utc_now()
    end_of_today = DateTime.new!(Date.utc_today(), ~T[23:59:59], "Etc/UTC")

    base =
      from(t in Task,
        join: c in Category, on: c.id == t.category_id,
        join: b in Board, on: b.id == c.board_id,
        left_join: g in Category, on: g.id == c.parent_id,
        left_join: bs in BoardShare, on: bs.board_id == b.id and bs.user_id == ^user_id,
        left_join: ts in TaskShare, on: ts.task_id == t.id and ts.user_id == ^user_id,
        where: b.owner_id == ^user_id or not is_nil(bs.id) or not is_nil(ts.id),
        select: %{task: t, board: b, category: c, group: g}
      )

    base =
      if scope == :trash do
        base
      else
        from [t, _c, _b, _g, _bs, _ts] in base, where: is_nil(t.deleted_at)
      end

    base
    |> apply_smart_filter(scope, now, end_of_today)
    |> Repo.all()
  end

  defp apply_smart_filter(q, :today, _now, eod) do
    from [t, _c, _b, _g, _bs, _ts] in q,
      where: t.done == false and not is_nil(t.due_at) and t.due_at <= ^eod,
      order_by: [asc: t.due_at, asc: t.position]
  end

  defp apply_smart_filter(q, :upcoming, _now, eod) do
    from [t, _c, _b, _g, _bs, _ts] in q,
      where: t.done == false and not is_nil(t.due_at) and t.due_at > ^eod,
      order_by: [asc: t.due_at, asc: t.position]
  end

  defp apply_smart_filter(q, :anytime, _now, _eod) do
    from [t, _c, _b, _g, _bs, _ts] in q,
      where: t.done == false and is_nil(t.due_at),
      order_by: [asc: t.inserted_at]
  end

  defp apply_smart_filter(q, :waiting, _now, _eod) do
    from [t, c, _b, g, _bs, _ts] in q,
      where:
        t.done == false and
          (t.waiting == true or c.waiting == true or
             (not is_nil(g.id) and g.waiting == true)),
      order_by: [asc: t.position]
  end

  defp apply_smart_filter(q, :completed, _now, _eod) do
    from [t, _c, _b, _g, _bs, _ts] in q,
      where: t.done == true,
      order_by: [desc: t.updated_at]
  end

  defp apply_smart_filter(q, :trash, _now, _eod) do
    from [t, _c, _b, _g, _bs, _ts] in q,
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
        upsert_board_share(board_id, user.id, permission) |> tag(:shared)
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
        upsert_task_share(task_id, user.id, permission) |> tag(:shared)
    end
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
