defmodule ToDoWeb.TaskLive.PlanningTest do
  use ToDoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ToDo.{Boards, Plans, Goals}

  setup :register_and_log_in_user

  # A board with one column and a task due today (in the user's zone),
  # plus one due next week and one with no due date, so every candidate
  # bucket has something in it.
  setup %{user: user} do
    {:ok, board} = Boards.create_board(%{"name" => "B", "color" => "#3b82f6", "owner_id" => user.id})
    {:ok, grp} = Boards.create_category(%{"board_id" => to_string(board.id), "name" => "G"})

    {:ok, col} =
      Boards.create_category(%{
        "board_id" => to_string(board.id),
        "name" => "Doing",
        "parent_id" => to_string(grp.id)
      })

    tz = Plans.user_tz(user)
    today = Plans.today(user)
    due_today = DateTime.new!(today, ~T[16:00:00], tz) |> DateTime.shift_zone!("Etc/UTC")
    due_next_week = DateTime.add(due_today, 5 * 24 * 3600, :second)

    mk = fn title, attrs ->
      {:ok, t} =
        Boards.create_task(
          Map.merge(
            %{"title" => title, "category_id" => to_string(col.id), "created_by_id" => user.id},
            attrs
          )
        )

      t
    end

    t_today = mk.("Due today", %{"due_at" => due_today, "estimated_minutes" => "60"})
    t_later = mk.("Due next week", %{"due_at" => due_next_week, "estimated_minutes" => "30"})
    t_anytime = mk.("Someday", %{})

    {:ok, goal} = Goals.create_goal(%{"user_id" => user.id, "name" => "Ship it"})
    :ok = Goals.replace_user_goal_tags(t_today, user.id, [goal.id])

    %{today: today, tz: tz, t_today: t_today, t_later: t_later, t_anytime: t_anytime, goal: goal}
  end

  test "Today renders the commitment badge and Plan today button with no plan", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/today")
    assert html =~ "1 task · ~1h committed"
    assert html =~ "Plan today"
    refute html =~ "Planned ·"
  end

  test "planning mode lists candidates by bucket and pulls tasks into the plan", ctx do
    %{conn: conn, t_today: t_today, t_later: t_later, t_anytime: t_anytime} = ctx
    {:ok, lv, html} = live(conn, ~p"/today?plan=1")

    assert html =~ "Candidates"
    assert html =~ "Due today · 1"
    assert html =~ "Upcoming (next 7 days) · 1"
    assert html =~ "Anytime · 1"
    assert html =~ "Nothing planned yet"

    # Pull the due-today task in.
    lv |> element(~s{#cand-today-#{t_today.id} button[phx-click="plan_task"]}) |> render_click()
    html = render(lv)
    assert html =~ "Today&#39;s plan · 1 · ~1h"
    assert html =~ "on a goal 1/1"
    assert html =~ "Most of your time today is on Ship it"
    refute html =~ "Due today · 1"

    # Pull in the unestimated Anytime task — coverage flags the missing estimate.
    lv |> element(~s{#cand-anytime-#{t_anytime.id} button[phx-click="plan_task"]}) |> render_click()
    html = render(lv)
    assert html =~ "Today&#39;s plan · 2"
    assert html =~ "1 task has no estimate"

    # Inline estimate from the ~? chip, then the sentence goes away.
    lv
    |> element(~s{#plan-row-#{t_anytime.id} button[phx-value-minutes="30"]})
    |> render_click()

    html = render(lv)
    assert html =~ "Today&#39;s plan · 2 · ~1h 30m"
    refute html =~ "has no estimate"

    # Remove one; the future task stays a candidate throughout.
    lv |> element(~s{#plan-row-#{t_anytime.id} button[phx-click="unplan_task"]}) |> render_click()
    html = render(lv)
    assert html =~ "Today&#39;s plan · 1"
    assert html =~ ~s{id="cand-upcoming-#{t_later.id}"}
  end

  test "Today with a plan shows Planned + Also due today, ticked rows stay struck through", ctx do
    %{conn: conn, user: user, today: today, t_today: t_today, t_anytime: t_anytime} = ctx
    {:ok, _} = Plans.plan_task(user.id, t_anytime.id, today)

    {:ok, lv, html} = live(conn, ~p"/today")
    assert html =~ "Planned · 1"
    assert html =~ "Also due today · 1"
    assert html =~ "Edit plan"
    assert html =~ "Wrap up"

    # "+ Plan" on the also-due row moves it into Planned.
    lv |> element(~s{#today-other-#{t_today.id} button[phx-click="plan_task"]}) |> render_click()
    html = render(lv)
    assert html =~ "Planned · 2"
    refute html =~ "Also due today"

    # Tick the planned task: it stays in Planned (struck through) and the
    # badge total drops to just the open task.
    lv |> element(~s{#today-plan-#{t_today.id} input[type=checkbox]}) |> render_click()
    html = render(lv)
    assert html =~ ~s{id="today-plan-#{t_today.id}"}
    assert html =~ "line-through"
    assert html =~ "done 1/2"
  end

  test "wrap-up defers unfinished work, moves due dates, snapshots the day", ctx do
    %{conn: conn, user: user, today: today, tz: tz, t_today: t_today, t_anytime: t_anytime} = ctx
    {:ok, _} = Plans.plan_task(user.id, t_today.id, today)
    {:ok, _} = Plans.plan_task(user.id, t_anytime.id, today)
    {:ok, _} = Boards.toggle_task_done(Boards.get_task!(t_anytime.id))

    {:ok, lv, _} = live(conn, ~p"/today")
    lv |> element(~s{button.btn-outline[phx-click="open_wrap_up"]}) |> render_click()
    html = render(lv)
    assert html =~ "Wrap up"
    assert html =~ "You planned"
    assert html =~ "Done: <span class=\"font-medium\">1</span>"
    assert html =~ "Unfinished · 1"

    # Default decision is tomorrow; type a reflection and finish.
    lv |> form(~s{#wrap-up-modal form[phx-change="wrap_reflection"]}) |> render_change(%{reflection: "Good day"})
    lv |> element(~s{button[phx-click="finish_day"]}) |> render_click()

    html = render(lv)
    assert html =~ "Day wrapped"
    refute html =~ "Planned ·"

    tomorrow = Date.add(today, 1)
    assert Plans.planned_task_ids(user.id, tomorrow) == [t_today.id]
    assert Plans.planned_task_ids(user.id, today) == []

    # Due date moved to tomorrow, same local time of day (16:00).
    moved = Boards.get_task!(t_today.id).due_at |> DateTime.shift_zone!(tz)
    assert DateTime.to_date(moved) == tomorrow
    assert DateTime.to_time(moved) == ~T[16:00:00]

    review = Plans.get_review(user.id, today)
    assert review.planned_count == 2
    assert review.done_count == 1
    assert review.planned_minutes == 60
    assert review.done_minutes == 0
    assert review.reflection == "Good day"
  end

  test "reorder_plan rewrites positions and a Keep decision leaves the due date alone", ctx do
    %{conn: conn, user: user, today: today, t_today: t_today, t_anytime: t_anytime} = ctx
    {:ok, _} = Plans.plan_task(user.id, t_today.id, today)
    {:ok, _} = Plans.plan_task(user.id, t_anytime.id, today)

    assert Enum.map(Plans.list_plan(user.id, today), & &1.task.id) == [t_today.id, t_anytime.id]
    :ok = Plans.reorder_plan(user.id, today, [t_anytime.id, t_today.id])
    assert Enum.map(Plans.list_plan(user.id, today), & &1.task.id) == [t_anytime.id, t_today.id]

    original_due = Boards.get_task!(t_today.id).due_at

    {:ok, lv, _} = live(conn, ~p"/today")
    lv |> element(~s{button.btn-outline[phx-click="open_wrap_up"]}) |> render_click()

    # Keep the due-today task; send the other to Anytime (clears its nil due date harmlessly).
    lv
    |> element(~s{#wrap-up-modal li:has(input[value="#{t_today.id}"]) form})
    |> render_change(%{task_id: t_today.id, value: "keep"})

    lv
    |> element(~s{#wrap-up-modal li:has(input[value="#{t_anytime.id}"]) form})
    |> render_change(%{task_id: t_anytime.id, value: "anytime"})

    lv |> element(~s{button[phx-click="finish_day"]}) |> render_click()

    assert Plans.planned_task_ids(user.id, today) == []
    assert Plans.planned_task_ids(user.id, Date.add(today, 1)) == []
    assert Boards.get_task!(t_today.id).due_at == original_due
    assert is_nil(Boards.get_task!(t_anytime.id).due_at)
  end

  test "Plan today is reachable from the Boards view and Done planning returns there", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/today?view=board")
    assert html =~ "Plan today"
    assert html =~ ~s{href="/today?plan=1&amp;view=board"}

    # Board cards are links, so goal chips inside them must be spans — an
    # <a> nested in an <a> gets split by the HTML parser and the chip
    # falls out beside the title, crushing it.
    assert html =~ ~r{<span[^>]*title="Goal: Ship it"}
    refute html =~ ~r{<a[^>]*edit=task[^>]*>(?:(?!</a>).)*<a }s

    lv |> element(~s{a[href="/today?plan=1&view=board"]}) |> render_click()
    assert render(lv) =~ "Candidates"

    lv |> element("a", "Done planning") |> render_click()
    assert_patch(lv, "/today?view=board")
    refute render(lv) =~ "Candidates"
  end

  test "waiting tasks stay out of Today/Upcoming/Anytime and show only under Waiting", ctx do
    %{conn: conn, user: user, t_today: t_today, t_later: t_later, t_anytime: t_anytime} = ctx
    {:ok, _} = Boards.update_task(t_today, %{"waiting" => "true"})
    {:ok, _} = Boards.update_task(t_later, %{"waiting" => "true"})
    {:ok, _} = Boards.update_task(t_anytime, %{"waiting" => "true"})

    ids = fn scope -> Boards.list_smart_tasks(user.id, scope) |> Enum.map(& &1.task.id) |> Enum.sort() end
    assert ids.(:today) == []
    assert ids.(:upcoming) == []
    assert ids.(:anytime) == []
    assert ids.(:waiting) == Enum.sort([t_today.id, t_later.id, t_anytime.id])

    {:ok, _lv, html} = live(conn, ~p"/today")
    refute html =~ "Due today"
    assert html =~ "Nothing here."

    # Planning candidates: not overdue/due-today, but offered under Waiting.
    {:ok, _lv, html} = live(conn, ~p"/today?plan=1")
    refute html =~ "Due today · "
    assert html =~ "Waiting · 3"
  end

  test "ticking a planned repeating task records the occurrence instead of silently rescheduling", ctx do
    %{conn: conn, user: user, today: today, tz: tz} = ctx
    board = Boards.list_boards_for_user(user.id) |> hd()
    [%{columns: [%{id: col_id} | _]} | _] = ToDo.Inbox.triage_destinations(user.id)
    _ = board

    due = DateTime.new!(today, ~T[16:00:00], tz) |> DateTime.shift_zone!("Etc/UTC")

    {:ok, weekly} =
      Boards.create_task(%{
        "title" => "Weekly meeting",
        "category_id" => to_string(col_id),
        "created_by_id" => user.id,
        "due_at" => due,
        "repeat" => "week",
        "estimated_minutes" => "60"
      })

    {:ok, _} = Plans.plan_task(user.id, weekly.id, today)
    {:ok, lv, html} = live(conn, ~p"/today")
    refute html =~ "done 1/"

    # First tick: occurrence recorded, due date moves one week, row shows done.
    lv |> element(~s{#today-plan-#{weekly.id} input[type=checkbox]}) |> render_click()
    html = render(lv)
    assert html =~ "done 1/"
    assert html =~ ~s{id="today-plan-#{weekly.id}"}
    assert %{completed_at: %DateTime{}} = Plans.get_plan(user.id, weekly.id, today)
    advanced = Boards.get_task!(weekly.id)
    refute advanced.done
    assert DateTime.diff(advanced.due_at, due, :day) == 7

    # Un-tick: clears the occurrence and rolls the date back, so the
    # cycle is reversible rather than drifting a week per tick.
    lv |> element(~s{#today-plan-#{weekly.id} input[type=checkbox]}) |> render_click()
    assert %{completed_at: nil} = Plans.get_plan(user.id, weekly.id, today)
    assert DateTime.diff(Boards.get_task!(weekly.id).due_at, due, :day) == 0
    refute render(lv) =~ "done 1/"

    # Tick once more (advances again, net +7), then wrap up: counted as done and off the plan.
    lv |> element(~s{#today-plan-#{weekly.id} input[type=checkbox]}) |> render_click()
    assert DateTime.diff(Boards.get_task!(weekly.id).due_at, due, :day) == 7
    lv |> element(~s{button.btn-outline[phx-click="open_wrap_up"]}) |> render_click()
    refute render(lv) =~ "Unfinished ·"
    lv |> element(~s{button[phx-click="finish_day"]}) |> render_click()

    review = Plans.get_review(user.id, today)
    assert review.done_count == 1
    assert review.done_minutes == 60
    assert Plans.planned_task_ids(user.id, today) == []
    assert Plans.planned_task_ids(user.id, Date.add(today, 1)) == []
  end

  test "another user's plan on a shared task is invisible to me", ctx do
    %{user: user, today: today, t_today: t_today} = ctx
    other = ToDo.AccountsFixtures.user_fixture()
    # `other` can't even see the task, so planning it is refused outright.
    assert {:error, :forbidden} = Plans.plan_task(other.id, t_today.id, today)
    assert Plans.planned_task_ids(other.id, today) == []
    assert {:ok, _} = Plans.plan_task(user.id, t_today.id, today)
    assert Plans.planned_task_ids(other.id, today) == []
  end
end
