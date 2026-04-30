defmodule ToDo.Accounts.UserNotifier do
  import Swoosh.Email

  alias ToDo.Mailer
  alias ToDo.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from({"ToDo", "contact@example.com"})
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end

  @doc """
  Delivers a digest of unread, not-yet-emailed notifications. `notifications`
  is a list of `%ToDo.Notifications.Notification{}` for the same user.
  """
  def deliver_task_digest(%User{} = user, notifications) when is_list(notifications) and notifications != [] do
    {due_soon, overdue, shared} = group_by_kind(notifications)
    body = render_digest(user, due_soon, overdue, shared)
    subject = digest_subject(due_soon, overdue, shared)
    deliver(user.email, subject, body)
  end

  defp group_by_kind(notifications) do
    Enum.reduce(notifications, {[], [], []}, fn n, {soon, over, share} ->
      case n.kind do
        "task_due_soon" -> {[n | soon], over, share}
        "task_overdue" -> {soon, [n | over], share}
        "task_shared" -> {soon, over, [n | share]}
        "board_shared" -> {soon, over, [n | share]}
        _ -> {soon, over, share}
      end
    end)
    |> then(fn {a, b, c} -> {Enum.reverse(a), Enum.reverse(b), Enum.reverse(c)} end)
  end

  defp digest_subject([], [], shared) when shared != [], do: "Orelle: #{length(shared)} new share(s)"
  defp digest_subject([], over, _) when over != [], do: "Orelle: #{length(over)} overdue task(s)"
  defp digest_subject(soon, [], _) when soon != [], do: "Orelle: #{length(soon)} task(s) due soon"
  defp digest_subject(soon, over, _), do: "Orelle: #{length(soon)} due soon, #{length(over)} overdue"

  defp render_digest(user, due_soon, overdue, shared) do
    """

    ==============================

    Hi #{user.email},

    Here's your task update from Orelle.

    #{section("Overdue", overdue)}#{section("Due soon", due_soon)}#{section("Shared with you", shared)}

    Open Orelle to view and manage these tasks.

    To stop receiving these emails, visit your account settings.

    ==============================
    """
  end

  defp section(_title, []), do: ""

  defp section(title, notifications) do
    lines = Enum.map(notifications, fn n -> "  • #{n.body}" end) |> Enum.join("\n")

    """
    #{title}:
    #{lines}

    """
  end
end
