defmodule ToDoWeb.GoalLive.IndexTest do
  use ToDoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ToDo.Goals

  setup :register_and_log_in_user

  setup %{user: user} do
    {:ok, a} = Goals.create_goal(%{"user_id" => user.id, "name" => "Alpha"})
    {:ok, b} = Goals.create_goal(%{"user_id" => user.id, "name" => "Bravo"})
    {:ok, c} = Goals.create_goal(%{"user_id" => user.id, "name" => "Charlie"})
    {:ok, p} = Goals.create_goal(%{"user_id" => user.id, "name" => "Paused one", "status" => "paused"})
    %{a: a, b: b, c: c, p: p}
  end

  defp names(user_id), do: Goals.list_goals(user_id) |> Enum.map(& &1.name)

  test "dragging goal cards reorders them and the sidebar follows", %{conn: conn, user: user, a: a, b: b, c: c, p: p} do
    assert names(user.id) == ["Alpha", "Bravo", "Charlie", "Paused one"]

    {:ok, lv, _html} = live(conn, ~p"/goals")
    assert has_element?(lv, "#goals-active[phx-hook='SortableGoals'] #goal-card-#{a.id}")

    lv |> element("#goals-active") |> render_hook("reorder_goals", %{"goal_ids" => ["#{c.id}", "#{a.id}", "#{b.id}"]})

    # Only the active goals moved; the paused one keeps its place after them.
    assert names(user.id) == ["Charlie", "Alpha", "Bravo", "Paused one"]
    assert Goals.list_goals(user.id) |> Enum.map(& &1.position) == [0, 1, 2, 3]

    # The sidebar (rendered by the same LiveView) reflects the new order.
    html = render(lv)
    assert sidebar_order_of(html, [c, a, b]) == [c.name, a.name, b.name]

    # Reordering the paused grid on its own leaves the active ones alone.
    lv |> element("#goals-paused") |> render_hook("reorder_goals", %{"goal_ids" => ["#{p.id}"]})
    assert names(user.id) == ["Charlie", "Alpha", "Bravo", "Paused one"]
  end

  test "ids that aren't the user's goals are ignored", %{conn: conn, user: user, a: a, b: b, c: c} do
    other = ToDo.AccountsFixtures.user_fixture()
    {:ok, theirs} = Goals.create_goal(%{"user_id" => other.id, "name" => "Not mine"})

    {:ok, lv, _html} = live(conn, ~p"/goals")
    lv |> element("#goals-active") |> render_hook("reorder_goals", %{"goal_ids" => ["#{theirs.id}", "#{b.id}", "#{a.id}", "#{c.id}", "nonsense"]})

    assert names(user.id) == ["Bravo", "Alpha", "Charlie", "Paused one"]
    assert Goals.list_goals(other.id) |> Enum.map(& &1.name) == ["Not mine"]
  end

  # Positions of the goal links in the sidebar, in the order given.
  defp sidebar_order_of(html, goals) do
    goals
    |> Enum.map(fn g -> {g.name, :binary.match(html, "href=\"/goals/#{g.id}\"") |> elem(0)} end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end
end
