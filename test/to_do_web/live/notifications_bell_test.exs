defmodule ToDoWeb.NotificationsBellTest do
  use ToDoWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ToDo.{Notifications, Repo}
  alias ToDo.Notifications.Notification

  setup :register_and_log_in_user

  setup %{user: user} do
    # Insert directly rather than via `create_or_skip/1` so the test doesn't
    # spawn the async Web Push task.
    a = Repo.insert!(%Notification{user_id: user.id, kind: "task_overdue", body: "Chase Garry is overdue"})
    b = Repo.insert!(%Notification{user_id: user.id, kind: "task_due_soon", body: "Book dentist is due soon"})
    %{a: a, b: b}
  end

  test "each notification can be flipped between read and unread from the bell",
       %{conn: conn, user: user, a: a, b: b} do
    {:ok, lv, _html} = live(conn, ~p"/today")

    assert Notifications.unread_count(user.id) == 2
    assert has_element?(lv, "#notification-#{a.id}-toggle[title='Mark as read']")
    assert has_element?(lv, "#notification-#{b.id}-toggle[title='Mark as read']")
    assert lv |> element("#notification-#{a.id}") |> render() =~ "Unread"

    # Flip A to read: only A changes, badge drops to 1, row is labelled Read.
    lv |> element("#notification-#{a.id}-toggle") |> render_click()
    assert Notifications.unread_count(user.id) == 1
    assert has_element?(lv, "#notification-#{a.id}-toggle[title='Mark as unread']")
    assert has_element?(lv, "#notification-#{b.id}-toggle[title='Mark as read']")
    assert lv |> element("#notification-#{a.id}") |> render() =~ "· Read"
    refute lv |> element("#notification-#{a.id}") |> render() =~ "Unread"

    # Flip A back to unread.
    lv |> element("#notification-#{a.id}-toggle") |> render_click()
    assert Notifications.unread_count(user.id) == 2
    assert has_element?(lv, "#notification-#{a.id}-toggle[title='Mark as read']")
    assert is_nil(Notifications.get_for_user(user.id, a.id).read_at)

    # Mark all read clears both, and each can still be re-flagged afterwards.
    lv |> element("button", "Mark all read") |> render_click()
    assert Notifications.unread_count(user.id) == 0
    assert has_element?(lv, "#notification-#{a.id}-toggle[title='Mark as unread']")
    assert has_element?(lv, "#notification-#{b.id}-toggle[title='Mark as unread']")
    refute has_element?(lv, "button", "Mark all read")

    lv |> element("#notification-#{b.id}-toggle") |> render_click()
    assert Notifications.unread_count(user.id) == 1
    assert has_element?(lv, "#notification-#{b.id}-toggle[title='Mark as read']")
    assert has_element?(lv, "button", "Mark all read")
  end

  test "the toggle is scoped to the signed-in user", %{conn: conn, user: user} do
    other = ToDo.AccountsFixtures.user_fixture()

    theirs =
      Repo.insert!(%Notification{user_id: other.id, kind: "board_shared", body: "Someone shared a board"})

    {:ok, lv, _html} = live(conn, ~p"/today")
    refute has_element?(lv, "#notification-#{theirs.id}")

    # Pushing the event with a foreign id must be a silent no-op.
    render_click(lv, "toggle_notification_read", %{"id" => to_string(theirs.id)})
    assert is_nil(Repo.get!(Notification, theirs.id).read_at)
    assert Notifications.unread_count(user.id) == 2
  end
end
