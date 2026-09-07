defmodule ToDoWeb.InboxLiveTest do
  use ToDoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ToDo.{Accounts, Boards, Goals, Inbox, Plans, Repo}

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, board} = Boards.create_board(%{"name" => "Work", "color" => "#3b82f6", "owner_id" => user.id})
    {:ok, grp} = Boards.create_category(%{"board_id" => to_string(board.id), "name" => "Functional"})

    {:ok, col} =
      Boards.create_category(%{
        "board_id" => to_string(board.id),
        "name" => "Planning",
        "parent_id" => to_string(grp.id)
      })

    {:ok, goal} = Goals.create_goal(%{"user_id" => user.id, "name" => "Ship it"})
    %{board: board, col: col, goal: goal}
  end

  test "Quick Add captures into the Inbox from any page and keeps the box open", %{conn: conn, user: user} do
    {:ok, lv, html} = live(conn, ~p"/today")
    # Closed until ⌘K (the hook pushes "open" to the component).
    assert html =~ ~s{phx-hook="QuickAdd" phx-target="1" hidden}
    lv |> element("#quick-add") |> render_hook("open", %{})
    refute render(lv) =~ ~s{phx-hook="QuickAdd" phx-target="1" hidden}

    lv |> form("#quick-add form", item: %{title: "Chase Garry"}) |> render_submit()
    lv |> form("#quick-add form", item: %{title: "Book dentist", notes: "ask about x-ray"}) |> render_submit()

    html = render(lv)
    assert html =~ "Captured · 2"
    # Still open (no `hidden` on the root) and the title field is blank again.
    refute html =~ ~s{id="quick-add" phx-hook="QuickAdd" hidden}
    assert [%{title: "Chase Garry"}, %{title: "Book dentist", notes: "ask about x-ray"}] =
             Inbox.list_open(user.id)

    # Blank titles are rejected, not silently dropped.
    lv |> form("#quick-add form", item: %{title: "   "}) |> render_submit()
    assert length(Inbox.list_open(user.id)) == 2
  end

  test "triage turns the selected item into a task with everything set", ctx do
    %{conn: conn, user: user, col: col, goal: goal} = ctx
    {:ok, item} = Inbox.capture(user.id, %{title: "Write risk summary", notes: "for Garry"})
    {:ok, _later} = Inbox.capture(user.id, %{title: "Second thing"})

    {:ok, lv, html} = live(conn, ~p"/inbox")
    assert html =~ "Inbox · 2"
    assert html =~ ~s{id="inbox-item-#{item.id}"}
    # Oldest is selected and its text seeds the form.
    assert html =~ ~s{value="Write risk summary"}

    # Set due/effort via the buttons, tick the goal and today's plan, then Move.
    lv |> element(~s{button[phx-value-field="due"][phx-value-value="today"]}) |> render_click()
    lv |> element(~s{button[phx-value-field="estimated_minutes"][phx-value-value="30"]}) |> render_click()

    lv
    |> form("#triage-form", triage: %{category_id: col.id, goal_ids: ["", to_string(goal.id)], plan_today: "true"})
    |> render_submit()

    html = render(lv)
    assert html =~ "Moved"
    assert html =~ "Inbox · 1"
    refute html =~ ~s{id="inbox-item-#{item.id}"}

    [task] = Repo.all(ToDo.Boards.Task)
    assert task.title == "Write risk summary"
    assert task.notes == "for Garry"
    assert task.category_id == col.id
    assert task.estimated_minutes == 30
    assert Goals.user_goal_ids_for_task(task.id, user.id) == [goal.id]
    assert Plans.planned_task_ids(user.id, Plans.today(user)) == [task.id]

    tz = Plans.user_tz(user)
    local = DateTime.shift_zone!(task.due_at, tz)
    assert DateTime.to_date(local) == Plans.today(user)
    assert DateTime.to_time(local) == ~T[17:00:00]

    # The column is remembered as the default for next time.
    assert Accounts.get_user!(user.id).default_triage_category_id == col.id
  end

  test "discard moves an item to Trash where it can be restored or purged", ctx do
    %{conn: conn, user: user} = ctx
    {:ok, item} = Inbox.capture(user.id, %{title: "Noise"})

    {:ok, lv, _} = live(conn, ~p"/inbox")
    lv |> element(~s{#inbox-item-#{item.id} button[phx-click="discard"]}) |> render_click()

    assert render(lv) =~ "Nothing to process"
    assert Inbox.list_open(user.id) == []
    assert [%{id: id}] = Inbox.list_trashed(user.id)
    assert id == item.id

    {:ok, trash, html} = live(conn, ~p"/trash")
    assert html =~ "Noise"
    trash |> element(~s{button[phx-click="restore_inbox_item"][phx-value-id="#{item.id}"]}) |> render_click()
    assert [%{id: ^id}] = Inbox.list_open(user.id)

    {:ok, _} = Inbox.discard(Inbox.get_item!(item.id, user.id))
    {:ok, trash, _} = live(conn, ~p"/trash")
    trash |> element(~s{button[phx-click="purge_inbox_item"][phx-value-id="#{item.id}"]}) |> render_click()
    assert Inbox.list_trashed(user.id) == []
    assert Inbox.get_item(item.id, user.id) == nil
  end

  test "triage refuses a column the user can't edit, and items are per-user", ctx do
    %{user: user} = ctx
    other = ToDo.AccountsFixtures.user_fixture()
    {:ok, ob} = Boards.create_board(%{"name" => "Theirs", "owner_id" => other.id})
    {:ok, og} = Boards.create_category(%{"board_id" => to_string(ob.id), "name" => "G"})
    {:ok, oc} = Boards.create_category(%{"board_id" => to_string(ob.id), "name" => "C", "parent_id" => to_string(og.id)})

    {:ok, item} = Inbox.capture(user.id, %{title: "Mine"})
    assert {:error, :forbidden} = Inbox.triage(item, user, %{"category_id" => to_string(oc.id)})
    # Still in the inbox, untouched.
    assert [%{id: id}] = Inbox.list_open(user.id)
    assert id == item.id

    assert Inbox.list_open(other.id) == []
    assert Inbox.count_open(other.id) == 0
    assert_raise Ecto.NoResultsError, fn -> Inbox.get_item!(item.id, other.id) end
  end
end
