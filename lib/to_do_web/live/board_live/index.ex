defmodule ToDoWeb.BoardLive.Index do
  use ToDoWeb, :live_view

  alias ToDo.Boards
  alias ToDo.Boards.Board

  @presets ~w(#3b82f6 #10b981 #f59e0b #ef4444 #8b5cf6 #ec4899 #14b8a6 #64748b)

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    owned = Boards.list_boards_for_user(user_id)

    sidebar_board =
      case owned do
        [first | _] -> Boards.load_board(first)
        [] -> nil
      end

    {:ok,
     socket
     |> assign(:owned_boards, owned)
     |> assign(:shared_boards, Boards.list_shared_boards(user_id))
     |> assign(:sidebar_board, sidebar_board)
     |> assign(:color_presets, @presets)
     |> close_modal()}
  end

  # -- modal state --

  defp close_modal(socket) do
    socket
    |> assign(:modal, nil)
    |> assign(:modal_board, nil)
    |> assign(:form_params, %{})
    |> assign(:form, nil)
  end

  defp open_new_board(socket) do
    params = %{"name" => "", "color" => "#3b82f6"}
    changeset = Board.changeset(%Board{}, params)

    socket
    |> assign(:modal, :new)
    |> assign(:modal_board, nil)
    |> assign(:form_params, params)
    |> assign(:form, to_form(changeset))
  end

  defp open_edit_board(socket, %Board{} = board) do
    params = %{"name" => board.name, "color" => board.color || "#3b82f6"}
    changeset = Board.changeset(board, params)

    socket
    |> assign(:modal, :edit)
    |> assign(:modal_board, board)
    |> assign(:form_params, params)
    |> assign(:form, to_form(changeset))
  end

  @impl true
  def handle_event("show_new_board", _params, socket), do: {:noreply, open_new_board(socket)}

  def handle_event("edit_board", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    board = Boards.get_board_for_user!(id, user_id)
    {:noreply, open_edit_board(socket, board)}
  end

  def handle_event("close_modal", _params, socket), do: {:noreply, close_modal(socket)}

  def handle_event("validate_board", %{"board" => params}, socket) do
    subject = socket.assigns.modal_board || %Board{}

    changeset =
      subject
      |> Board.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form_params, Map.merge(socket.assigns.form_params, params))
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("pick_color", %{"color" => color}, socket) do
    params = Map.put(socket.assigns.form_params, "color", color)
    subject = socket.assigns.modal_board || %Board{}
    changeset = Board.changeset(subject, params)

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("save_board", %{"board" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case socket.assigns.modal do
      :new ->
        params = Map.put(params, "owner_id", user_id)

        case Boards.create_board(params) do
          {:ok, board} ->
            {:noreply, push_navigate(socket, to: ~p"/boards/#{board.id}")}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      :edit ->
        board = socket.assigns.modal_board

        case Boards.update_board(board, params) do
          {:ok, _board} ->
            owned = Boards.list_boards_for_user(user_id)

            sidebar_board =
              case owned do
                [first | _] -> Boards.load_board(first)
                [] -> nil
              end

            {:noreply,
             socket
             |> assign(:owned_boards, owned)
             |> assign(:sidebar_board, sidebar_board)
             |> close_modal()}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  def handle_event("delete_board", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    board = Boards.get_board_for_user!(id, user_id)
    {:ok, _} = Boards.delete_board(board)

    owned = Boards.list_boards_for_user(user_id)

    sidebar_board =
      case owned do
        [first | _] -> Boards.load_board(first)
        [] -> nil
      end

    {:noreply,
     socket
     |> assign(:owned_boards, owned)
     |> assign(:sidebar_board, sidebar_board)
     |> assign(:shared_boards, Boards.list_shared_boards(user_id))
     |> close_modal()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell
      flash={@flash}
      current_scope={@current_scope}
      page_title="Boards"
      active={:boards}
      current_board={@sidebar_board}
    >
      <:actions>
        <button
          :if={is_nil(@modal)}
          phx-click="show_new_board"
          class="btn btn-primary btn-sm"
        >
          + New board
        </button>
      </:actions>

      <.form_modal
        :if={@modal}
        id="board-modal"
        title={if @modal == :new, do: "Create a new board", else: "Edit board"}
        accent_color={@form_params["color"] || "#3b82f6"}
        on_cancel="close_modal"
      >
        <.form
          for={@form}
          phx-change="validate_board"
          phx-submit="save_board"
          class="space-y-5"
        >
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="e.g. Q2 Roadmap"
            required
            autofocus
          />

          <div>
            <label class="label pb-1.5">
              <span class="label-text font-medium">Color</span>
            </label>
            <.color_picker
              presets={@color_presets}
              selected={@form_params["color"] || "#3b82f6"}
              on_pick="pick_color"
              color_field="board[color]"
            />
          </div>

          <div class="pt-2">
            <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
              Preview
            </div>
            <div class="card bg-base-100 border border-base-300 shadow-sm overflow-hidden">
              <div class="h-2" style={"background:#{@form_params["color"] || "#3b82f6"}"}></div>
              <div class="p-4">
                <h3 class="font-semibold truncate">
                  {if @form_params["name"] in [nil, ""], do: "Board name", else: @form_params["name"]}
                </h3>
                <p class="text-xs text-base-content/60 mt-1">Open board →</p>
              </div>
            </div>
          </div>

          <.modal_footer>
            <:destructive>
              <button
                :if={@modal == :edit}
                type="button"
                phx-click="delete_board"
                phx-value-id={@modal_board.id}
                data-confirm="Delete this board? This cannot be undone."
                class="btn btn-ghost text-error"
              >
                Delete
              </button>
            </:destructive>
            <:secondary>
              <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
            </:secondary>
            <:primary>
              <.button type="submit" variant="primary">
                {if @modal == :new, do: "Create board", else: "Save changes"}
              </.button>
            </:primary>
          </.modal_footer>
        </.form>
      </.form_modal>

      <div class="max-w-5xl space-y-8">
        <section :if={@owned_boards != []} class="space-y-3">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Your boards
          </h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            <div
              :for={board <- @owned_boards}
              class="relative group card bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-primary/40 transition overflow-hidden"
            >
              <div class="h-2" style={"background:#{board.color || "#3b82f6"}"}></div>
              <.link navigate={~p"/boards/#{board.id}"} class="block card-body p-4">
                <h3 class="font-semibold truncate">{board.name}</h3>
                <p class="text-xs text-base-content/60 mt-1">Open board →</p>
              </.link>
              <button
                phx-click="edit_board"
                phx-value-id={board.id}
                class="absolute top-3 right-3 opacity-0 group-hover:opacity-100 btn btn-ghost btn-xs"
                title="Edit board"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
            </div>
          </div>
        </section>

        <section :if={@shared_boards != []} class="space-y-3">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Shared with you
          </h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            <.link
              :for={board <- @shared_boards}
              navigate={~p"/boards/#{board.id}"}
              class="card bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-primary/40 transition overflow-hidden"
            >
              <div class="h-2" style={"background:#{board.color || "#3b82f6"}"}></div>
              <div class="card-body p-4">
                <div class="flex items-center justify-between gap-2">
                  <h3 class="font-semibold truncate">{board.name}</h3>
                  <span class="badge badge-ghost badge-sm">{board.permission}</span>
                </div>
                <p class="text-xs text-base-content/60 mt-1">Open board →</p>
              </div>
            </.link>
          </div>
        </section>

        <div
          :if={@owned_boards == [] and @shared_boards == []}
          class="text-center text-base-content/60 py-16 border border-dashed border-base-300 rounded-lg"
        >
          No boards yet. Click <span class="font-medium">+ New board</span> to get started.
        </div>
      </div>
    </Layouts.shell>
    """
  end
end
