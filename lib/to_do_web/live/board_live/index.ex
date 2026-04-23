defmodule ToDoWeb.BoardLive.Index do
  use ToDoWeb, :live_view

  alias ToDo.Boards
  alias ToDo.Boards.Board

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    {:ok,
     socket
     |> assign(:owned_boards, Boards.list_boards_for_user(user_id))
     |> assign(:shared_boards, Boards.list_shared_boards(user_id))
     |> assign(:form, to_form(Board.changeset(%Board{}, %{})))}
  end

  @impl true
  def handle_event("create_board", %{"board" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id
    params = Map.put(params, "owner_id", user_id)

    case Boards.create_board(params) do
      {:ok, board} ->
        {:noreply, push_navigate(socket, to: ~p"/boards/#{board.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_board", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    board = Boards.get_board_for_user!(id, user_id)
    {:ok, _} = Boards.delete_board(board)

    {:noreply,
     socket
     |> assign(:owned_boards, Boards.list_boards_for_user(user_id))
     |> assign(:shared_boards, Boards.list_shared_boards(user_id))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-4xl mx-auto space-y-8">
        <.header>
          Your boards
          <:subtitle>A board is a shareable workspace of to-do categories.</:subtitle>
          <:actions>
            <.link navigate={~p"/shared"} class="btn btn-ghost btn-sm">Shared tasks →</.link>
          </:actions>
        </.header>

        <.form for={@form} phx-submit="create_board" class="flex gap-2 items-end">
          <.input field={@form[:name]} label="New board name" class="flex-1" required />
          <.input field={@form[:color]} label="Color" type="color" value="#3b82f6" />
          <.button type="submit" variant="primary">Create</.button>
        </.form>

        <section :if={@owned_boards != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Owned</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
            <div :for={board <- @owned_boards} class="card bg-base-100 shadow hover:shadow-lg transition">
              <div class="card-body">
                <div class="flex items-center gap-2">
                  <div class="w-4 h-4 rounded" style={"background:#{board.color || "#3b82f6"}"}></div>
                  <h3 class="card-title">{board.name}</h3>
                </div>
                <div class="card-actions justify-end">
                  <.link navigate={~p"/boards/#{board.id}"} class="btn btn-sm btn-primary">Open</.link>
                  <button
                    phx-click="delete_board"
                    phx-value-id={board.id}
                    data-confirm="Delete this board? This cannot be undone."
                    class="btn btn-sm btn-ghost text-error"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section :if={@shared_boards != []} class="space-y-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Shared with you</h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-4">
            <div :for={board <- @shared_boards} class="card bg-base-100 shadow hover:shadow-lg transition">
              <div class="card-body">
                <div class="flex items-center gap-2">
                  <div class="w-4 h-4 rounded" style={"background:#{board.color || "#3b82f6"}"}></div>
                  <h3 class="card-title">{board.name}</h3>
                  <span class="badge badge-ghost badge-sm ml-auto">{board.permission}</span>
                </div>
                <div class="card-actions justify-end">
                  <.link navigate={~p"/boards/#{board.id}"} class="btn btn-sm btn-primary">Open</.link>
                </div>
              </div>
            </div>
          </div>
        </section>

        <div :if={@owned_boards == [] and @shared_boards == []} class="text-center text-base-content/60 py-12">
          No boards yet — create your first one above.
        </div>
      </div>
    </Layouts.app>
    """
  end
end
