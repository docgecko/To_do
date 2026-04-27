defmodule ToDoWeb.BoardLive.Shared do
  @moduledoc """
  Lists tasks shared individually with the current user (i.e. via task_shares,
  where the user does not have board-level access).
  """
  use ToDoWeb, :live_view

  alias ToDo.Boards

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    rows = Boards.list_shared_tasks_for_user(user_id)

    by_board =
      Enum.group_by(rows, fn row -> row.board end)
      |> Enum.sort_by(fn {board, _} -> board.name end)

    {:ok, assign(socket, :by_board, by_board)}
  end

  @impl true
  def handle_event("toggle_done", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    case Boards.task_permission(task, user_id) do
      perm when perm in [:owner, :edit] ->
        {:ok, _} = Boards.update_task(task, %{"done" => !task.done})

        rows = Boards.list_shared_tasks_for_user(user_id)

        by_board =
          Enum.group_by(rows, fn row -> row.board end)
          |> Enum.sort_by(fn {board, _} -> board.name end)

        {:noreply, assign(socket, :by_board, by_board)}

      _ ->
        {:noreply, socket |> put_flash(:error, "You only have view access to that task.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_scope={@current_scope} page_title="Shared with me" active={:shared}>
      <div class="max-w-3xl space-y-6">
        <.header>
          Shared tasks
          <:subtitle>Tasks others have shared with you directly.</:subtitle>
          <:actions>
            <.link navigate={~p"/boards"} class="btn btn-ghost btn-sm">← Boards</.link>
          </:actions>
        </.header>

        <div :if={@by_board == []} class="text-center text-base-content/60 py-12">
          Nothing shared with you yet.
        </div>

        <section :for={{board, rows} <- @by_board} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60 flex items-center gap-2">
            <span class="w-3 h-3 rounded" style={"background:#{board.color || "#3b82f6"}"}></span>
            {board.name}
          </h2>
          <ul class="border border-base-300 rounded divide-y divide-base-300">
            <li :for={row <- rows} class="flex items-start gap-3 p-3 bg-base-100">
              <input
                type="checkbox"
                checked={row.task.done}
                disabled={row.permission == "view"}
                phx-click={row.permission == "edit" && "toggle_done"}
                phx-value-id={row.task.id}
                class="checkbox checkbox-sm mt-1"
              />
              <div class="flex-1">
                <div class={["break-words leading-tight", row.task.done && "line-through text-base-content/50"]}>
                  {row.task.title}
                </div>
                <div :if={row.task.notes && row.task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">{row.task.notes}</div>
                <div class="text-xs text-base-content/50 mt-2">
                  in <span class="italic">{row.category.name}</span>
                </div>
              </div>
              <span class="badge badge-ghost badge-sm">{row.permission}</span>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.shell>
    """
  end
end
