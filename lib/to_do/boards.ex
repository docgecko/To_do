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
    Repo.preload(board, groups: [children: [tasks: [:created_by]]])
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

  def delete_task(%Task{} = task), do: Repo.delete(task)

  def get_task!(id), do: Repo.get!(Task, id)

  def reorder_tasks(category_id, task_ids) when is_list(task_ids) do
    Repo.transaction(fn ->
      for {task_id, index} <- Enum.with_index(task_ids) do
        from(t in Task, where: t.id == ^task_id)
        |> Repo.update_all(set: [category_id: category_id, position: index])
      end
    end)
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
