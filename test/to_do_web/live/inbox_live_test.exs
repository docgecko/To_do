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

  test "Quick Add captures into the Inbox from any page and closes once the item is in",
       %{conn: conn, user: user} do
    closed = "#quick-add [data-quick-add-modal][hidden]"
    {:ok, lv, _html} = live(conn, ~p"/today")
    # Closed until ⌘K (the hook pushes "open" to the component).
    assert has_element?(lv, closed)
    lv |> element("#quick-add") |> render_hook("open", %{})
    refute has_element?(lv, closed)
    # A note field and a visible Capture button, so a note can be added and
    # submitted without finding the way back to the title field.
    assert has_element?(lv, "#quick-add textarea#quick-add-notes[data-quick-add-notes]")
    assert has_element?(lv, "#quick-add form button#quick-add-submit[type=submit]")

    # Enter captures, the box closes, and the hook is told to show the toast.
    lv |> form("#quick-add form", item: %{title: "Chase Garry"}) |> render_submit()
    assert has_element?(lv, closed)
    assert_push_event(lv, "quick-add:captured", %{title: "Chase Garry"})

    # Reopen for the next one: the title field is blank again.
    lv |> element("#quick-add") |> render_hook("open", %{})
    refute has_element?(lv, closed)
    refute has_element?(lv, "#quick-add input[name='item[title]'][value='Chase Garry']")
    lv |> form("#quick-add form", item: %{title: "Book dentist", notes: "ask about x-ray"}) |> render_submit()
    assert has_element?(lv, closed)

    assert [%{title: "Chase Garry"}, %{title: "Book dentist", notes: "ask about x-ray"}] =
             Inbox.list_open(user.id)

    # Blank titles are rejected, not silently dropped — and the box stays
    # open so the title can be fixed.
    lv |> element("#quick-add") |> render_hook("open", %{})
    lv |> form("#quick-add form", item: %{title: "   "}) |> render_submit()
    refute has_element?(lv, closed)
    assert length(Inbox.list_open(user.id)) == 2
  end

  test "each inbox item keeps its own triage form", %{conn: conn, user: user, goal: goal} do
    {:ok, a} = Inbox.capture(user.id, %{"title" => "First thing"})
    {:ok, b} = Inbox.capture(user.id, %{"title" => "Second thing"})

    {:ok, lv, _html} = live(conn, ~p"/inbox")
    due_is = fn v -> has_element?(lv, "#triage-form input[name='triage[due]'][value='#{v}']") end
    est_is = fn v -> has_element?(lv, "#triage-form input[name='triage[estimated_minutes]'][value='#{v}']") end
    goal_on? = fn -> has_element?(lv, "#triage-form input[name='triage[goal_ids][]'][value='#{goal.id}'][checked]") end

    # Fill in the first item's form: due today, 30m, on the goal, planned.
    render_click(lv, "select", %{"id" => "#{a.id}"})
    lv |> element(~s{button[phx-value-field="due"][phx-value-to="today"]}) |> render_click()
    lv |> element(~s{button[phx-value-field="estimated_minutes"][phx-value-to="30"]}) |> render_click()
    lv |> form("#triage-form", triage: %{goal_ids: ["#{goal.id}"], plan_today: "true", notes: "ring first"}) |> render_change()
    assert due_is.("today") and est_is.("30") and goal_on?.()

    # The second item starts clean.
    render_click(lv, "select", %{"id" => "#{b.id}"})
    assert has_element?(lv, "#triage-form input[name='triage[title]'][value='Second thing']")
    assert due_is.("") and est_is.("")
    refute goal_on?.()
    refute has_element?(lv, "#triage-form input[name='triage[plan_today]'][checked]")

    # Choices made here stay here…
    lv |> element(~s{button[phx-value-field="due"][phx-value-to="tomorrow"]}) |> render_click()

    # …and the first item's draft comes back intact, edits included.
    render_click(lv, "select", %{"id" => "#{a.id}"})
    assert due_is.("today") and est_is.("30") and goal_on?.()
    assert has_element?(lv, "#triage-form input[name='triage[plan_today]'][checked]")
    assert lv |> element("#triage-form textarea[name='triage[notes]']") |> render() =~ "ring first"

    render_click(lv, "select", %{"id" => "#{b.id}"})
    assert due_is.("tomorrow") and est_is.("")

    # Moving the first item takes its own settings, not the second's; the
    # next item's form is its own draft.
    render_click(lv, "select", %{"id" => "#{a.id}"})
    lv |> form("#triage-form") |> render_submit()
    [task] = Boards.list_smart_tasks(user.id, :today) |> Enum.map(& &1.task) |> Enum.filter(&(&1.title == "First thing"))
    assert task.estimated_minutes == 30
    assert Goals.user_goal_ids_for_task(task.id, user.id) == [goal.id]
    assert due_is.("tomorrow")
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
    # Never `phx-value-value` on a button: the LiveView client replaces a
    # "value" key with the button's own empty value property, so the pick
    # would arrive as "" (the When buttons silently did nothing).
    refute render(lv) =~ "phx-value-value"
    lv |> element(~s{button[phx-value-field="due"][phx-value-to="today"]}) |> render_click()
    lv |> element(~s{button[phx-value-field="estimated_minutes"][phx-value-to="30"]}) |> render_click()

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
