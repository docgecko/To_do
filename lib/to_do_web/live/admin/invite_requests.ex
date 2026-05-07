defmodule ToDoWeb.AdminLive.InviteRequests do
  @moduledoc """
  Admin review of invite requests submitted from the marketing page.

  Approve grants an account (creates a User if none, emails a magic-link
  login URL via `Accounts.deliver_login_instructions/2`) and stamps the
  request `approved`. Decline just stamps `declined` — no email sent to
  the requester.

  Re-submission of an already-decided email re-opens the row, so
  declines aren't permanent gates.
  """

  use ToDoWeb, :live_view

  alias ToDo.InviteRequests

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Invite requests")
     |> load_requests()}
  end

  defp load_requests(socket) do
    assign(socket,
      pending: InviteRequests.list_pending(),
      decided: Enum.reject(InviteRequests.list_all(), &(&1.status == "pending"))
    )
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    request = InviteRequests.get!(id)
    admin = socket.assigns.current_scope.user

    url_fun = fn token -> url(~p"/users/log-in/#{token}") end

    case InviteRequests.approve_request(request, admin, url_fun) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Approved #{request.email}. Magic-link email sent.")
         |> load_requests()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(reason)}")}
    end
  end

  def handle_event("decline", %{"id" => id}, socket) do
    request = InviteRequests.get!(id)
    admin = socket.assigns.current_scope.user

    case InviteRequests.mark_declined(request, admin) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Declined #{request.email}.")
         |> load_requests()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Decline failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_scope={@current_scope} page_title="Invite requests" unread_notifications={@unread_notifications} recent_notifications={@recent_notifications}>
      <div class="max-w-3xl mx-auto space-y-8">
        <div>
          <.header>
            Invite requests
            <:subtitle>
              <span :if={@pending == []}>No pending requests.</span>
              <span :if={@pending != []}>
                {length(@pending)} pending — approve to send a magic-link login email.
              </span>
            </:subtitle>
          </.header>
        </div>

        <div :if={@pending != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Pending</h2>
          <ul class="space-y-2">
            <li
              :for={req <- @pending}
              class="card bg-base-100 border border-base-300 p-4 flex flex-col sm:flex-row sm:items-start gap-4"
            >
              <div class="flex-1 min-w-0 space-y-1">
                <div class="font-medium">{req.email}</div>
                <div :if={req.message} class="text-sm text-base-content/70 whitespace-pre-wrap">
                  {req.message}
                </div>
                <div class="text-xs text-base-content/50">
                  Requested {Calendar.strftime(req.inserted_at, "%a %d %b %Y · %H:%M")} UTC
                </div>
              </div>
              <div class="flex gap-2 shrink-0">
                <.button
                  variant="primary"
                  phx-click="approve"
                  phx-value-id={req.id}
                  data-confirm={"Approve #{req.email}? They'll get a magic-link email."}
                >
                  Approve
                </.button>
                <.button
                  phx-click="decline"
                  phx-value-id={req.id}
                  data-confirm={"Decline #{req.email}?"}
                  class="btn-ghost text-error"
                >
                  Decline
                </.button>
              </div>
            </li>
          </ul>
        </div>

        <div :if={@decided != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Decided</h2>
          <ul class="space-y-2">
            <li
              :for={req <- @decided}
              class="card bg-base-100 border border-base-300 p-3 flex items-start gap-3"
            >
              <span class={[
                "px-2 py-0.5 rounded text-xs font-semibold uppercase",
                req.status == "approved" && "bg-success/15 text-success",
                req.status == "declined" && "bg-base-300 text-base-content/60"
              ]}>
                {req.status}
              </span>
              <div class="flex-1 min-w-0">
                <div class="text-sm">{req.email}</div>
                <div class="text-xs text-base-content/50">
                  by {(req.decided_by && req.decided_by.email) || "—"} ·
                  {Calendar.strftime(req.decided_at, "%a %d %b %Y · %H:%M")} UTC
                </div>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.shell>
    """
  end
end
