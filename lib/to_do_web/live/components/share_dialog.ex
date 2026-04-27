defmodule ToDoWeb.ShareDialog do
  @moduledoc """
  A modal LiveComponent for sharing a board or one-or-more tasks with users by email.

  Required assigns:
    * `:id`          — dom id
    * `:current_user` — the sharer
    * `:subject`     — `{:board, board}` or `{:tasks, [task]}`

  On close, the parent sends `{__MODULE__, :closed}` via `send/2`.
  """
  use ToDoWeb, :live_component

  alias ToDo.Boards

  @impl true
  def mount(socket) do
    {:ok, assign(socket, email: "", permission: "edit", error: nil, flash_msg: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_shares()

    {:ok, socket}
  end

  defp assign_shares(socket) do
    case socket.assigns.subject do
      {:board, board} ->
        socket
        |> assign(:shares, Boards.list_board_shares(board.id))
        |> assign(:invitations, Boards.list_board_invitations(board.id))

      {:tasks, [task | _]} when length(socket.assigns.subject |> elem(1)) == 1 ->
        socket
        |> assign(:shares, Boards.list_task_shares(task.id))
        |> assign(:invitations, Boards.list_task_invitations(task.id))

      {:tasks, _} ->
        socket |> assign(:shares, []) |> assign(:invitations, [])
    end
  end

  @impl true
  def handle_event("share", %{"email" => email, "permission" => permission}, socket) do
    user_id = socket.assigns.current_user.id

    result =
      case socket.assigns.subject do
        {:board, board} ->
          Boards.share_board_by_email(board.id, email, permission, user_id)

        {:tasks, tasks} ->
          results = Enum.map(tasks, fn t ->
            Boards.share_task_by_email(t.id, email, permission, user_id)
          end)
          Enum.find(results, {:ok, :shared, nil}, &match?({:error, _}, &1))
      end

    case result do
      {:ok, :shared, _} ->
        {:noreply,
         socket
         |> assign(email: "", error: nil, flash_msg: "Shared with #{email}")
         |> assign_shares()}

      {:ok, :invited, inv} ->
        send_invitation_email(inv, socket.assigns.current_user, socket.assigns.subject)

        {:noreply,
         socket
         |> assign(email: "", error: nil, flash_msg: "Invitation sent to #{email}")
         |> assign_shares()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           error: changeset_error_message(changeset),
           flash_msg: nil
         )}
    end
  end

  def handle_event("revoke_share", %{"id" => id}, socket) do
    case socket.assigns.subject do
      {:board, _} -> Boards.revoke_board_share!(id)
      {:tasks, _} -> Boards.revoke_task_share!(id)
    end

    {:noreply, assign_shares(socket)}
  end

  def handle_event("revoke_invitation", %{"id" => id}, socket) do
    Boards.revoke_invitation!(id)
    {:noreply, assign_shares(socket)}
  end

  def handle_event("close", _params, socket) do
    send(self(), {__MODULE__, :closed})
    {:noreply, socket}
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp send_invitation_email(invitation, inviter, subject) do
    url = ToDoWeb.Endpoint.url() <> "/invitations/#{invitation.token}"

    subject_desc =
      case subject do
        {:board, b} -> "the board “#{b.name}”"
        {:tasks, [t]} -> "the task “#{t.title}”"
        {:tasks, ts} -> "#{length(ts)} tasks"
      end

    Swoosh.Email.new()
    |> Swoosh.Email.to(invitation.email)
    |> Swoosh.Email.from({"Orelle", "noreply@orelle.app"})
    |> Swoosh.Email.subject("#{inviter.email} invited you to #{subject_desc}")
    |> Swoosh.Email.text_body("""
    Hi,

    #{inviter.email} has invited you to collaborate on #{subject_desc} (#{invitation.permission} access).

    Accept the invitation by signing in or registering:
    #{url}

    This invitation expires at #{invitation.expires_at}.
    """)
    |> ToDo.Mailer.deliver()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        class="fixed inset-0 bg-black/40 z-40"
        phx-click="close"
        phx-target={@myself}
      />
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4 pointer-events-none">
        <div class="bg-base-100 rounded-lg shadow-xl w-full max-w-lg pointer-events-auto">
          <div class="p-4 border-b border-base-300 flex items-center justify-between">
            <h2 class="text-lg font-semibold">{title(@subject)}</h2>
            <button phx-click="close" phx-target={@myself} class="btn btn-ghost btn-sm btn-square">✕</button>
          </div>

          <div class="p-4 space-y-4">
            <div :if={@flash_msg} class="alert alert-success text-sm">{@flash_msg}</div>
            <div :if={@error} class="alert alert-error text-sm">{@error}</div>

            <form phx-submit="share" phx-target={@myself} class="flex gap-2 items-end">
              <label class="form-control flex-1">
                <span class="label label-text">Email address</span>
                <input
                  type="email"
                  name="email"
                  value={@email}
                  required
                  class="input input-bordered"
                  placeholder="teammate@example.com"
                />
              </label>
              <label class="form-control">
                <span class="label label-text">Access</span>
                <select name="permission" class="select select-bordered">
                  <option value="edit" selected={@permission == "edit"}>Edit</option>
                  <option value="view" selected={@permission == "view"}>View</option>
                </select>
              </label>
              <button type="submit" class="btn btn-primary">Share</button>
            </form>

            <div :if={@shares != [] or @invitations != []} class="space-y-2">
              <h3 class="text-sm font-semibold text-base-content/70">People with access</h3>
              <ul class="divide-y divide-base-300 border border-base-300 rounded">
                <li :for={share <- @shares} class="flex items-center justify-between p-2 text-sm">
                  <span>{share.user.email}</span>
                  <div class="flex items-center gap-2">
                    <span class="badge badge-ghost">{share.permission}</span>
                    <button
                      phx-click="revoke_share"
                      phx-value-id={share.id}
                      phx-target={@myself}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Remove
                    </button>
                  </div>
                </li>
                <li :for={inv <- @invitations} class="flex items-center justify-between p-2 text-sm bg-base-200/50">
                  <span class="text-base-content/70">{inv.email} <span class="text-xs italic">(pending)</span></span>
                  <div class="flex items-center gap-2">
                    <span class="badge badge-ghost">{inv.permission}</span>
                    <button
                      phx-click="revoke_invitation"
                      phx-value-id={inv.id}
                      phx-target={@myself}
                      class="btn btn-ghost btn-xs text-error"
                    >
                      Cancel
                    </button>
                  </div>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp title({:board, b}), do: "Share “#{b.name}”"
  defp title({:tasks, [t]}), do: "Share “#{t.title}”"
  defp title({:tasks, ts}), do: "Share #{length(ts)} tasks"
end
