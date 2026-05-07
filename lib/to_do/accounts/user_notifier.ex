defmodule ToDo.Accounts.UserNotifier do
  import Swoosh.Email

  alias ToDo.Mailer
  alias ToDo.Accounts.User

  # Sender identity for every outbound mail. Configurable so dev (Swoosh
  # local adapter) and prod (Resend) can disagree, and so swapping domains
  # later is one config change rather than a code edit.
  @default_from {"Orelle", "noreply@orelle.app"}

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(Application.get_env(:to_do, :mail_from, @default_from))
      |> subject(subject)
      |> text_body(body)

    case Mailer.deliver(email) do
      {:ok, _metadata} ->
        {:ok, email}

      {:error, reason} ->
        # Swoosh already logs the API response, but surface the failure as a
        # warning here so a "no email arrived" investigation can grep `flyctl
        # logs` for `[warning]` and find it without diving into Swoosh internals.
        require Logger
        Logger.warning("[UserNotifier] delivery failed: #{inspect(reason)}")
        {:error, reason}
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
  Notifies all admins that a new invite request just came in. `admin_url`
  deep-links to the admin review LV.
  """
  def deliver_invite_request_received(invite_request, admin_url) do
    require Ecto.Query
    admins = ToDo.Repo.all(Ecto.Query.from(u in User, where: u.is_admin == true))
    msg = invite_request.message || "(no message)"

    Enum.reduce_while(admins, {:ok, []}, fn admin, {:ok, acc} ->
      case deliver(admin.email, "New invite request: #{invite_request.email}", """

           ==============================

           A new request to access Orelle just came in.

           From:    #{invite_request.email}
           Message: #{msg}

           Review and approve / decline:

           #{admin_url}

           ==============================
           """) do
        {:ok, e} -> {:cont, {:ok, [e | acc]}}
        err -> {:halt, err}
      end
    end)
  end

  @doc """
  Notifies an approved requester that their account is ready and gives
  them the magic-link login URL.
  """
  def deliver_invite_approved(email, url) do
    deliver(email, "You're in: log in to Orelle", """

    ==============================

    Hi #{email},

    Your request to access Orelle has been approved. Click below to log
    in — the link is single-use:

    #{url}

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
