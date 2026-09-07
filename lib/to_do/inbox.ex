defmodule ToDo.Inbox do
  @moduledoc """
  Capture now, decide later. An Inbox item is a title (+ optional note)
  owned by one user. It is not a task: it has no column, date, estimate
  or goal until the user triages it, at which point `triage/3` creates a
  real task through the normal Boards path and deletes the item.

  Every write broadcasts the user's open count on `inbox:<user_id>` so
  the sidebar badge updates in every open tab.
  """

  import Ecto.Query, warn: false

  alias ToDo.Repo
  alias ToDo.Inbox.Item
  alias ToDo.{Accounts, Boards, Goals, Plans}
  alias ToDo.Boards.Category
  alias ToDo.Accounts.User

  @pubsub ToDo.PubSub

  # -- PubSub --

  def topic(user_id), do: "inbox:#{user_id}"
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(@pubsub, topic(user_id))

  defp broadcast(user_id) do
    Phoenix.PubSub.broadcast(@pubsub, topic(user_id), {:inbox, :changed, count_open(user_id)})
  end

  # -- Capture / read --

  def capture(user_id, attrs) when is_integer(user_id) do
    attrs = attrs |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("user_id", user_id)

    case %Item{} |> Item.changeset(attrs) |> Repo.insert() do
      {:ok, _item} = ok ->
        broadcast(user_id)
        ok

      error ->
        error
    end
  end

  @doc "Open items, oldest first — that's the order to process them in."
  def list_open(user_id) when is_integer(user_id) do
    from(i in Item,
      where: i.user_id == ^user_id and is_nil(i.deleted_at),
      order_by: [asc: i.inserted_at, asc: i.id]
    )
    |> Repo.all()
  end

  def list_trashed(user_id) when is_integer(user_id) do
    from(i in Item,
      where: i.user_id == ^user_id and not is_nil(i.deleted_at),
      order_by: [desc: i.deleted_at]
    )
    |> Repo.all()
  end

  def count_open(user_id) when is_integer(user_id) do
    from(i in Item, where: i.user_id == ^user_id and is_nil(i.deleted_at), select: count(i.id))
    |> Repo.one()
  end

  def get_item!(id, user_id) when is_integer(user_id) do
    from(i in Item, where: i.id == ^id and i.user_id == ^user_id) |> Repo.one!()
  end

  def get_item(id, user_id) when is_integer(user_id) do
    from(i in Item, where: i.id == ^id and i.user_id == ^user_id) |> Repo.one()
  end

  # -- Discard / restore / purge --

  def discard(%Item{} = item) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    result = item |> Ecto.Changeset.change(deleted_at: now) |> Repo.update()
    broadcast(item.user_id)
    result
  end

  def restore(%Item{} = item) do
    result = item |> Ecto.Changeset.change(deleted_at: nil) |> Repo.update()
    broadcast(item.user_id)
    result
  end

  def purge(%Item{} = item) do
    result = Repo.delete(item)
    broadcast(item.user_id)
    result
  end

  # -- Triage --

  @doc """
  Turns an item into a task. `attrs` (string keys, from the triage form):

    * `"category_id"` — required; a column on a board the user can edit
    * `"title"` / `"notes"` — override the captured text (default: as captured)
    * `"due"` — `"today"` (17:00 local) | `"tomorrow"` (09:00) | `"next_week"`
      (next Monday 09:00) | anything else → no due date
    * `"estimated_minutes"` — optional
    * `"goal_ids"` — optional list; only the user's own goals attach
    * `"plan_today"` — `"true"` also puts the task on today's plan

  The task goes through `Boards.create_task/1`, so waiting relocation and
  positioning behave exactly as if it had been created on the board.
  Remembers the column as the user's default. Returns `{:ok, task}`,
  `{:error, :forbidden}`, or `{:error, changeset}`.
  """
  def triage(%Item{user_id: uid} = item, %User{id: uid} = user, attrs) when is_map(attrs) do
    with {:ok, category} <- editable_column(attrs["category_id"], user.id) do
      task_attrs = %{
        "title" => present(attrs["title"]) || item.title,
        "notes" => present(attrs["notes"]) || item.notes || "",
        "category_id" => Integer.to_string(category.id),
        "created_by_id" => user.id,
        "due_at" => due_for(attrs["due"], user),
        "estimated_minutes" => attrs["estimated_minutes"] || ""
      }

      Repo.transaction(fn ->
        case Boards.create_task(task_attrs) do
          {:ok, task} ->
            :ok = Goals.replace_user_goal_tags(task, user.id, attrs["goal_ids"])

            if attrs["plan_today"] in ["true", true] do
              {:ok, _} = Plans.plan_task(user.id, task.id, Plans.today(user))
            end

            Repo.delete!(item)
            {:ok, _} = Accounts.remember_triage_column(user, category.id)
            task

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
      |> case do
        {:ok, task} ->
          broadcast(user.id)
          {:ok, task}

        {:error, _} = err ->
          err
      end
    end
  end

  # A column (has a parent group) on a board the user owns or can edit.
  defp editable_column(nil, _), do: {:error, :forbidden}
  defp editable_column("", _), do: {:error, :forbidden}

  defp editable_column(id, user_id) do
    with {int, ""} <- Integer.parse(to_string(id)),
         %Category{parent_id: pid} = cat when not is_nil(pid) <- Repo.get(Category, int),
         perm when perm in [:owner, :edit] <- Boards.board_permission(cat.board_id, user_id) do
      {:ok, cat}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp due_for("today", user), do: local_at(Plans.today(user), ~T[17:00:00], user)
  defp due_for("tomorrow", user), do: local_at(Date.add(Plans.today(user), 1), ~T[09:00:00], user)

  defp due_for("next_week", user) do
    today = Plans.today(user)
    # Monday = 1 … Sunday = 7; always the *next* Monday, never today.
    local_at(Date.add(today, 8 - Date.day_of_week(today)), ~T[09:00:00], user)
  end

  defp due_for(_, _), do: nil

  defp local_at(%Date{} = date, %Time{} = time, user) do
    DateTime.new!(date, time, Plans.user_tz(user)) |> DateTime.shift_zone!("Etc/UTC")
  end

  defp present(nil), do: nil
  defp present(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)

  # -- Destinations for the triage picker --

  @doc """
  Boards the user can put a task on (owned, or shared with edit), each
  with its columns labelled "Group / Column". Boards with no columns
  are omitted — there's nowhere to put anything.
  """
  def triage_destinations(user_id) when is_integer(user_id) do
    owned = Boards.list_boards_for_user(user_id)
    shared = Boards.list_shared_boards(user_id) |> Enum.filter(&(&1.permission == "edit"))
    boards = owned ++ shared
    board_ids = Enum.map(boards, & &1.id)

    cats =
      from(c in Category,
        where: c.board_id in ^board_ids,
        order_by: [asc: c.position, asc: c.inserted_at]
      )
      |> Repo.all()

    by_board = Enum.group_by(cats, & &1.board_id)

    boards
    |> Enum.map(fn board ->
      all = Map.get(by_board, board.id, [])
      groups = Enum.filter(all, &is_nil(&1.parent_id))
      group_names = Map.new(groups, &{&1.id, &1.name})

      columns =
        all
        |> Enum.reject(&is_nil(&1.parent_id))
        |> Enum.sort_by(fn c ->
          {Enum.find_index(groups, &(&1.id == c.parent_id)) || 999, c.position}
        end)
        |> Enum.map(fn c ->
          %{id: c.id, label: "#{Map.get(group_names, c.parent_id, "?")} / #{c.name}"}
        end)

      %{board: board, columns: columns}
    end)
    |> Enum.reject(&(&1.columns == []))
  end
end
