defmodule ToDoWeb.PageController do
  use ToDoWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias ToDo.InviteRequests
  alias ToDo.InviteRequests.InviteRequest

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/boards")
    else
      cs = InviteRequest.submit_changeset(%InviteRequest{}, %{})
      render(conn, :home, invite_request_form: to_form(cs, as: "invite_request"))
    end
  end

  def register_redirect(conn, _params) do
    conn
    |> put_flash(:info, "Orelle is invite-only — request access on the home page.")
    |> redirect(to: ~p"/")
  end

  def request_invite(conn, %{"invite_request" => params}) do
    case InviteRequests.submit(params) do
      {:ok, request} ->
        # Notify admins (best-effort; don't block the response if Resend fails).
        admin_url = url(~p"/admin/invite-requests")
        ToDo.Accounts.UserNotifier.deliver_invite_request_received(request, admin_url)

        conn
        |> put_flash(:info, "Thanks — we'll be in touch.")
        |> redirect(to: ~p"/")

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        # Honeypot trip — pretend success rather than tipping off the bot.
        if Keyword.has_key?(errors, :website) do
          conn |> put_flash(:info, "Thanks — we'll be in touch.") |> redirect(to: ~p"/")
        else
          render(conn, :home, invite_request_form: to_form(cs, as: "invite_request"))
        end
    end
  end
end
