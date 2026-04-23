defmodule ToDoWeb.BoardLive.Show do
  use ToDoWeb, :live_view

  alias ToDo.Boards
  alias ToDoWeb.ShareDialog

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_visible_board!(id, user.id) |> Boards.load_board()

    {:ok,
     socket
     |> assign(:board, board)
     |> assign(:permission, board.permission)
     |> assign(:can_edit?, board.permission in ["owner", "edit"])
     |> assign(:is_owner?, board.permission == "owner")
     |> assign(:editing_task_id, nil)
     |> assign(:adding_task_in, nil)
     |> assign(:adding_group?, false)
     |> assign(:adding_sub_in, nil)
     |> assign(:share_target, nil)}
  end

  @impl true
  def handle_info({ShareDialog, :closed}, socket) do
    {:noreply, assign(socket, :share_target, nil)}
  end

  @impl true
  def handle_event("open_share_board", _params, socket) do
    {:noreply, assign(socket, :share_target, {:board, socket.assigns.board})}
  end

  def handle_event("open_share_task", %{"id" => id}, socket) do
    task = Boards.get_task!(id)
    {:noreply, assign(socket, :share_target, {:tasks, [task]})}
  end

  def handle_event("add_group", %{"category" => params}, socket) do
    require_edit!(socket)

    params =
      params
      |> Map.put("board_id", socket.assigns.board.id)
      |> Map.put_new("parent_id", nil)

    {:ok, _} = Boards.create_category(params)
    {:noreply, socket |> assign(:adding_group?, false) |> reload_board()}
  end

  def handle_event("add_sub", %{"category" => params, "parent_id" => parent_id}, socket) do
    require_edit!(socket)

    params =
      params
      |> Map.put("board_id", socket.assigns.board.id)
      |> Map.put("parent_id", parent_id)

    {:ok, _} = Boards.create_category(params)
    {:noreply, socket |> assign(:adding_sub_in, nil) |> reload_board()}
  end

  def handle_event("add_task", %{"task" => params, "category_id" => category_id}, socket) do
    require_edit!(socket)
    user_id = socket.assigns.current_scope.user.id

    params =
      params
      |> Map.put("category_id", category_id)
      |> Map.put("created_by_id", user_id)

    {:ok, _} = Boards.create_task(params)
    {:noreply, socket |> assign(:adding_task_in, nil) |> reload_board()}
  end

  def handle_event("toggle_done", %{"id" => id}, socket) do
    require_edit!(socket)
    task = Boards.get_task!(id)
    {:ok, _} = Boards.update_task(task, %{"done" => !task.done})
    {:noreply, reload_board(socket)}
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    require_edit!(socket)
    task = Boards.get_task!(id)
    {:ok, _} = Boards.delete_task(task)
    {:noreply, reload_board(socket)}
  end

  def handle_event("edit_task", %{"id" => id}, socket) do
    require_edit!(socket)
    {:noreply, assign(socket, :editing_task_id, String.to_integer(id))}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, :editing_task_id, nil)}
  end

  def handle_event("save_task", %{"id" => id, "task" => params}, socket) do
    require_edit!(socket)
    task = Boards.get_task!(id)
    {:ok, _} = Boards.update_task(task, params)
    {:noreply, socket |> assign(:editing_task_id, nil) |> reload_board()}
  end

  def handle_event("reorder_tasks", %{"category_id" => category_id, "task_ids" => task_ids}, socket) do
    require_edit!(socket)
    category_id = String.to_integer(category_id)
    task_ids = Enum.map(task_ids, &String.to_integer/1)
    {:ok, _} = Boards.reorder_tasks(category_id, task_ids)
    {:noreply, reload_board(socket)}
  end

  def handle_event("show_add_group", _params, socket), do: {:noreply, assign(socket, :adding_group?, true)}
  def handle_event("hide_add_group", _params, socket), do: {:noreply, assign(socket, :adding_group?, false)}

  def handle_event("show_add_sub", %{"parent_id" => id}, socket),
    do: {:noreply, assign(socket, :adding_sub_in, String.to_integer(id))}

  def handle_event("hide_add_sub", _params, socket), do: {:noreply, assign(socket, :adding_sub_in, nil)}

  def handle_event("show_add_task", %{"category_id" => id}, socket),
    do: {:noreply, assign(socket, :adding_task_in, String.to_integer(id))}

  def handle_event("hide_add_task", _params, socket), do: {:noreply, assign(socket, :adding_task_in, nil)}

  defp require_edit!(socket) do
    if not socket.assigns.can_edit? do
      raise "unauthorized: view-only access"
    end
  end

  defp reload_board(socket) do
    user = socket.assigns.current_scope.user
    board = Boards.get_visible_board!(socket.assigns.board.id, user.id) |> Boards.load_board()
    assign(socket, :board, board)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-4">
        <div class="flex items-center justify-between gap-4">
          <div class="flex items-center gap-3">
            <.link navigate={~p"/boards"} class="btn btn-ghost btn-sm">← Boards</.link>
            <h1 class="text-2xl font-semibold">{@board.name}</h1>
            <span :if={!@is_owner?} class="badge badge-info">{@permission}</span>
          </div>
          <div class="flex gap-2">
            <button
              :if={@is_owner?}
              phx-click="open_share_board"
              class="btn btn-outline btn-sm"
            >
              Share
            </button>
            <button
              :if={@can_edit?}
              phx-click="show_add_group"
              class="btn btn-primary btn-sm"
            >
              + Add group
            </button>
          </div>
        </div>

        <div :if={@adding_group?} class="card bg-base-200 p-4">
          <.form for={%{}} as={:category} phx-submit="add_group" class="flex gap-2 items-end">
            <.input name="category[name]" value="" label="Group name" required />
            <.input name="category[color]" value="#fbbf24" label="Color" type="color" />
            <.button type="submit" variant="primary">Add</.button>
            <button type="button" phx-click="hide_add_group" class="btn btn-ghost btn-sm">Cancel</button>
          </.form>
        </div>

        <div class="overflow-x-auto pb-8">
          <div class="flex gap-6 items-start min-w-max">
            <div :for={group <- @board.groups} class="flex flex-col gap-2">
              <div
                class="px-3 py-2 rounded-t font-semibold text-white min-w-[200px]"
                style={"background:#{group.color || "#64748b"}"}
              >
                {group.name}
              </div>

              <div class="flex gap-2 items-start">
                <div :for={sub <- group.children} class="w-64 bg-base-100 rounded-lg shadow-sm border border-base-300 flex flex-col">
                  <div class="px-3 py-2 border-b border-base-300 font-medium text-sm bg-base-200 rounded-t-lg">
                    {sub.name}
                  </div>

                  <ul
                    id={"category-#{sub.id}"}
                    phx-hook={@can_edit? && "SortableTasks"}
                    data-category-id={sub.id}
                    class="flex flex-col gap-1 p-2 min-h-[60px]"
                  >
                    <li
                      :for={task <- sub.tasks}
                      data-task-id={task.id}
                      class="bg-base-100 border border-base-300 rounded p-2 text-sm hover:shadow-sm group"
                    >
                      <%= if @editing_task_id == task.id do %>
                        <.form for={%{}} as={:task} phx-submit="save_task" phx-value-id={task.id} class="space-y-2">
                          <.input name="task[title]" value={task.title} required />
                          <.input name="task[notes]" value={task.notes} type="textarea" rows="2" />
                          <div class="flex gap-1 justify-end">
                            <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-xs">Cancel</button>
                            <button type="submit" class="btn btn-primary btn-xs">Save</button>
                          </div>
                        </.form>
                      <% else %>
                        <div class="flex items-start gap-2">
                          <span :if={@can_edit?} data-drag-handle class="cursor-grab select-none text-base-content/40 pt-0.5">⋮⋮</span>
                          <input
                            type="checkbox"
                            checked={task.done}
                            disabled={!@can_edit?}
                            phx-click={@can_edit? && "toggle_done"}
                            phx-value-id={task.id}
                            class="checkbox checkbox-xs mt-1"
                          />
                          <div class="flex-1">
                            <div class={["break-words", task.done && "line-through text-base-content/50"]}>
                              {task.title}
                            </div>
                            <div :if={task.notes && task.notes != ""} class="text-xs text-base-content/60 mt-1 whitespace-pre-line">
                              {task.notes}
                            </div>
                          </div>
                          <div class="opacity-0 group-hover:opacity-100 flex flex-col gap-1">
                            <button
                              :if={@is_owner?}
                              phx-click="open_share_task"
                              phx-value-id={task.id}
                              class="btn btn-ghost btn-xs"
                              title="Share task"
                            >↗</button>
                            <button :if={@can_edit?} phx-click="edit_task" phx-value-id={task.id} class="btn btn-ghost btn-xs" title="Edit">✎</button>
                            <button
                              :if={@can_edit?}
                              phx-click="delete_task"
                              phx-value-id={task.id}
                              data-confirm="Delete this task?"
                              class="btn btn-ghost btn-xs text-error"
                              title="Delete"
                            >
                              ✕
                            </button>
                          </div>
                        </div>
                      <% end %>
                    </li>
                  </ul>

                  <div :if={@can_edit?} class="p-2 border-t border-base-300">
                    <%= if @adding_task_in == sub.id do %>
                      <.form for={%{}} as={:task} phx-submit="add_task" phx-value-category_id={sub.id} class="space-y-2">
                        <.input name="task[title]" value="" placeholder="Task title" required />
                        <div class="flex gap-1 justify-end">
                          <button type="button" phx-click="hide_add_task" class="btn btn-ghost btn-xs">Cancel</button>
                          <button type="submit" class="btn btn-primary btn-xs">Add</button>
                        </div>
                      </.form>
                    <% else %>
                      <button
                        phx-click="show_add_task"
                        phx-value-category_id={sub.id}
                        class="btn btn-ghost btn-xs w-full justify-start"
                      >
                        + Add task
                      </button>
                    <% end %>
                  </div>
                </div>

                <div :if={@can_edit?} class="w-64 flex-shrink-0">
                  <%= if @adding_sub_in == group.id do %>
                    <.form for={%{}} as={:category} phx-submit="add_sub" phx-value-parent_id={group.id} class="card bg-base-200 p-3 space-y-2">
                      <.input name="category[name]" value="" placeholder="Column name" required />
                      <div class="flex gap-1 justify-end">
                        <button type="button" phx-click="hide_add_sub" class="btn btn-ghost btn-xs">Cancel</button>
                        <button type="submit" class="btn btn-primary btn-xs">Add</button>
                      </div>
                    </.form>
                  <% else %>
                    <button
                      phx-click="show_add_sub"
                      phx-value-parent_id={group.id}
                      class="btn btn-ghost btn-sm w-full border-2 border-dashed border-base-300"
                    >
                      + Add column
                    </button>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div :if={@board.groups == []} class="text-center text-base-content/60 py-16">
          No groups yet.
          <%= if @can_edit? do %>
            Click "Add group" to start (e.g. Functional, Operational, Waiting).
          <% end %>
        </div>
      </div>

      <.live_component
        :if={@share_target}
        module={ShareDialog}
        id="share-dialog"
        current_user={@current_scope.user}
        subject={@share_target}
      />
    </Layouts.app>
    """
  end
end
