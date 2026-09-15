defmodule ToDo.NotificationsTaskStateTest do
  use ToDo.DataCase, async: true

  import ToDo.AccountsFixtures

  alias ToDo.{Boards, Notifications, Repo}
  alias ToDo.Notifications.Notification

  setup do
    user = user_fixture()
    {:ok, board} = Boards.create_board(%{"name" => "B", "color" => "#3b82f6", "owner_id" => user.id})
    {:ok, grp} = Boards.create_category(%{"board_id" => "#{board.id}", "name" => "G"})

    {:ok, col} =
      Boards.create_category(%{"board_id" => "#{board.id}", "name" => "C", "parent_id" => "#{grp.id}"})

    yesterday = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)

    {:ok, task} =
      Boards.create_task(%{"title" => "Overdue thing", "category_id" => "#{col.id}", "due_at" => yesterday})

    # What the scanner would have raised, plus an unrelated share notification
    # on the same task that must never be touched.
    overdue =
      Repo.insert!(%Notification{user_id: user.id, kind: "task_overdue", task_id: task.id, body: "Overdue thing is overdue"})

    shared =
      Repo.insert!(%Notification{user_id: user.id, kind: "task_shared", task_id: task.id, body: "Someone shared Overdue thing"})

    %{user: user, task: task, overdue: overdue, shared: shared}
  end

  test "completing settles the task's due notifications; reopening raises them again",
       %{user: user, task: task, overdue: overdue, shared: shared} do
    Notifications.subscribe(user.id)

    {:ok, done} = Boards.toggle_task_done(task)
    assert done.done
    assert %DateTime{} = Repo.get!(Notification, overdue.id).read_at
    assert is_nil(Repo.get!(Notification, shared.id).read_at)
    assert Notifications.unread_count(user.id) == 1
    assert_receive {:notifications, :changed}

    {:ok, reopened} = Boards.toggle_task_done(done)
    refute reopened.done
    assert is_nil(Repo.get!(Notification, overdue.id).read_at)
    assert Notifications.unread_count(user.id) == 2
    assert_receive {:notifications, :changed}
  end

  test "a changed due date clears the due notifications so the scanner can re-evaluate",
       %{task: task, overdue: overdue, shared: shared} do
    tomorrow = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)
    {:ok, _} = Boards.update_task(task, %{"due_at" => tomorrow})
    refute Repo.get(Notification, overdue.id)
    assert Repo.get(Notification, shared.id)
  end

  test "ticking a repeating task advances it and clears the old due notifications",
       %{task: task, overdue: overdue} do
    {:ok, weekly} = Boards.update_task(task, %{"repeat" => "week"})
    # Setting repeat alone doesn't move the date, so nothing changes yet.
    assert Repo.get(Notification, overdue.id)

    {:ok, advanced} = Boards.toggle_task_done(weekly)
    refute advanced.done
    assert DateTime.compare(advanced.due_at, task.due_at) == :gt
    refute Repo.get(Notification, overdue.id)
  end

  test "deleting a task clears its due notifications", %{task: task, overdue: overdue, shared: shared} do
    {:ok, _} = Boards.delete_task(task)
    refute Repo.get(Notification, overdue.id)
    assert Repo.get(Notification, shared.id)
  end
end
