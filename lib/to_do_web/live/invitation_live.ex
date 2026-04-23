defmodule ToDoWeb.InvitationLive do
  @moduledoc """
  Handles invitation links. If the user is logged in and their email matches,
  accept. If logged in as the wrong user, show mismatch message. If not logged
  in, redirect to registration/login with the email pre-filled via flash.
  """
  use ToDoWeb, :live_view

  alias ToDo.Boards

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Boards.get_invitation_by_token(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Invitation not found or already used.")
         |> push_navigate(to: ~p"/")}

      invitation ->
        cond do
          DateTime.compare(invitation.expires_at, DateTime.utc_now()) == :lt ->
            {:ok,
             socket
             |> put_flash(:error, "This invitation has expired.")
             |> push_navigate(to: ~p"/")}

          invitation.accepted_at ->
            {:ok,
             socket
             |> put_flash(:info, "Invitation already accepted.")
             |> push_navigate(to: ~p"/boards")}

          socket.assigns[:current_scope] &&
              socket.assigns.current_scope.user.email == invitation.email ->
            {:ok, count} = Boards.accept_pending_invitations(invitation.email, socket.assigns.current_scope.user.id)

            {:ok,
             socket
             |> put_flash(:info, "Accepted #{count} invitation(s).")
             |> push_navigate(to: ~p"/boards")}

          socket.assigns[:current_scope] ->
            {:ok, assign(socket, :mismatch, %{invited: invitation.email, logged_in: socket.assigns.current_scope.user.email})}

          true ->
            {:ok,
             socket
             |> put_flash(:info, "Register or sign in as #{invitation.email} to accept.")
             |> push_navigate(to: ~p"/users/register?email=#{invitation.email}")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-md mx-auto py-12 text-center space-y-4">
        <h1 class="text-xl font-semibold">Invitation email mismatch</h1>
        <p class="text-sm">
          This invitation was sent to <strong>{@mismatch.invited}</strong>, but you are logged in as
          <strong>{@mismatch.logged_in}</strong>.
        </p>
        <p class="text-sm">
          <.link href={~p"/users/log-out"} method="delete" class="link">Log out</.link>
          and sign in with the correct email.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
