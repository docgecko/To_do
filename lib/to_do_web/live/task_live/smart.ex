defmodule ToDoWeb.TaskLive.Smart do
  use ToDoWeb, :live_view

  alias ToDo.Boards

  @titles %{
    today: "Today",
    upcoming: "Upcoming",
    anytime: "Anytime",
    waiting: "Waiting",
    completed: "Completed",
    trash: "Trash"
  }

  @subtitles %{
    today: "Tasks due today or earlier.",
    upcoming: "Tasks due later.",
    anytime: "Tasks with no due date.",
    waiting: "Tasks flagged as waiting — directly, or via their column or group.",
    completed: "Tasks you've finished.",
    trash: "Deleted tasks. Restore or purge permanently."
  }

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    sidebar_board =
      case Boards.list_boards_for_user(user_id) do
        [first | _] -> Boards.load_board(first)
        [] -> nil
      end

    {:ok, assign(socket, :sidebar_board, sidebar_board)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.live_action
    user_id = socket.assigns.current_scope.user.id
    rows = Boards.list_smart_tasks(user_id, scope)
    view = if params["view"] == "board", do: :board, else: :list

    {:noreply,
     socket
     |> assign(:scope, scope)
     |> assign(:rows, rows)
     |> assign(:view, view)
     |> assign(:grouped, group_by_board(rows))
     |> assign(:title, Map.fetch!(@titles, scope))
     |> assign(:subtitle, Map.fetch!(@subtitles, scope))}
  end

  @impl true
  def handle_event("toggle_done", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) in [:owner, :edit] do
      {:ok, _} = Boards.toggle_task_done(task)
      rows = Boards.list_smart_tasks(user_id, socket.assigns.scope)
      {:noreply, socket |> assign(:rows, rows) |> assign(:grouped, group_by_board(rows))}
    else
      {:noreply, put_flash(socket, :error, "You only have view access to that task.")}
    end
  end

  def handle_event("restore_task", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) in [:owner, :edit] do
      {:ok, _} = Boards.restore_task(task)
      rows = Boards.list_smart_tasks(user_id, socket.assigns.scope)
      {:noreply, socket |> assign(:rows, rows) |> assign(:grouped, group_by_board(rows))}
    else
      {:noreply, put_flash(socket, :error, "You only have view access to that task.")}
    end
  end

  def handle_event("purge_task", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) == :owner do
      {:ok, _} = Boards.purge_task(task)
      rows = Boards.list_smart_tasks(user_id, socket.assigns.scope)
      {:noreply, socket |> assign(:rows, rows) |> assign(:grouped, group_by_board(rows))}
    else
      {:noreply, put_flash(socket, :error, "Only the board owner can permanently delete a task.")}
    end
  end

  defp group_by_board(rows) do
    rows
    |> Enum.group_by(& &1.board.id)
    |> Enum.map(fn {_id, board_rows} ->
      [%{board: board} | _] = board_rows

      groups =
        board_rows
        |> Enum.group_by(fn r -> r.group && r.group.id end)
        |> Enum.map(fn {_gid, grp_rows} ->
          [%{group: group} | _] = grp_rows

          cols =
            grp_rows
            |> Enum.group_by(& &1.category.id)
            |> Enum.map(fn {_cid, crows} ->
              [%{category: cat} | _] = crows
              %{category: cat, tasks: Enum.map(crows, & &1.task)}
            end)
            |> Enum.sort_by(& &1.category.position)

          %{group: group, columns: cols}
        end)
        |> Enum.sort_by(fn %{group: g} -> (g && g.position) || -1 end)

      %{board: board, groups: groups}
    end)
    |> Enum.sort_by(& &1.board.name)
  end

  defp view_href(scope, :list), do: "/#{scope}"
  defp view_href(scope, :board), do: "/#{scope}?view=board"

  # Header chips: show every board whose tasks appear in the current smart list.
  # If the list is empty, fall back to the user's primary (sidebar) board so the
  # header still gives a sense of board context.
  defp header_boards([], nil), do: []
  defp header_boards([], sidebar_board), do: [sidebar_board]
  defp header_boards(grouped, _), do: Enum.map(grouped, & &1.board)

  defp format_due(nil), do: nil
  defp format_due(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %d %b %Y · %H:%M")

  defp repeat_label(nil, _), do: nil
  defp repeat_label("", _), do: nil
  defp repeat_label(unit, every) when is_binary(unit) do
    every = if is_integer(every) and every > 0, do: every, else: 1

    case {unit, every} do
      {"day", 1} -> "Daily"
      {"week", 1} -> "Weekly"
      {"month", 1} -> "Monthly"
      {"year", 1} -> "Yearly"
      {u, n} -> "Every #{n} #{plural_unit(u)}"
    end
  end

  defp plural_unit("day"), do: "days"
  defp plural_unit("week"), do: "weeks"
  defp plural_unit("month"), do: "months"
  defp plural_unit("year"), do: "years"
  defp plural_unit(other), do: other

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_scope={@current_scope} page_title={@title} active={@scope} current_board={@sidebar_board}>
      <:title_extra>
        <.link
          :for={board <- header_boards(@grouped, @sidebar_board)}
          navigate={~p"/boards/#{board.id}"}
          class="inline-flex items-center gap-1.5 text-sm font-normal text-base-content/70 hover:text-base-content hover:underline"
          title={"Open #{board.name}"}
        >
          <span class="w-2 h-2 rounded shrink-0" style={"background:#{board.color || "#3b82f6"}"} />
          {board.name}
        </.link>
      </:title_extra>
      <div class={[@view == :list && "max-w-3xl", "space-y-4"]}>
        <div class="flex items-center justify-between gap-3 flex-wrap">
          <p class="text-sm text-base-content/60">{@subtitle}</p>
          <div id="smart-view-toggle" phx-hook="SmartViewPersist" class="join">
            <.link
              patch={view_href(@scope, :list)}
              data-view-set="list"
              class={["btn btn-sm join-item", @view == :list && "btn-primary", @view != :list && "btn-ghost"]}
            >
              <.icon name="hero-list-bullet" class="size-4" /> List
            </.link>
            <.link
              patch={view_href(@scope, :board)}
              data-view-set="board"
              class={["btn btn-sm join-item", @view == :board && "btn-primary", @view != :board && "btn-ghost"]}
            >
              <.icon name="hero-view-columns" class="size-4" /> Boards
            </.link>
          </div>
        </div>

        <div :if={@rows == []} class="text-center text-base-content/60 py-12">
          Nothing here.
        </div>

        <ul :if={@view == :list and @rows != []} class="border border-base-300 rounded divide-y divide-base-300">
          <li :for={row <- @rows} class="flex items-start gap-3 p-3 bg-base-100">
            <input
              :if={@scope != :trash}
              type="checkbox"
              checked={row.task.done}
              phx-click="toggle_done"
              phx-value-id={row.task.id}
              class="checkbox checkbox-sm mt-1"
            />
            <div :if={@scope == :trash} class="flex gap-1 mt-0.5">
              <button
                phx-click="restore_task"
                phx-value-id={row.task.id}
                class="btn btn-ghost btn-xs"
                title="Restore"
              >
                <.icon name="hero-arrow-uturn-left" class="size-4" />
              </button>
              <button
                phx-click="purge_task"
                phx-value-id={row.task.id}
                data-confirm="Permanently delete this task? This cannot be undone."
                class="btn btn-ghost btn-xs text-error"
                title="Delete permanently"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
            <div class="flex-1 min-w-0">
              <.link
                :if={@scope != :trash}
                navigate={~p"/boards/#{row.board.id}?edit=task:#{row.task.id}"}
                class="block hover:underline"
                title="Click to edit task"
              >
                <div class={["break-words leading-tight", row.task.done && "line-through text-base-content/50"]}>
                  {row.task.title}
                </div>
                <div :if={row.task.notes && row.task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">{row.task.notes}</div>
              </.link>
              <div :if={@scope == :trash}>
                <div class={["break-words leading-tight", row.task.done && "line-through text-base-content/50"]}>
                  {row.task.title}
                </div>
                <div :if={row.task.notes && row.task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">{row.task.notes}</div>
              </div>
              <div class="text-xs text-base-content/50 mt-2 flex flex-wrap gap-x-3 gap-y-1 items-center">
                <.link navigate={~p"/boards/#{row.board.id}"} class="hover:underline flex items-center gap-1">
                  <span class="w-2 h-2 rounded" style={"background:#{row.board.color || "#3b82f6"}"} />
                  {row.board.name}
                </.link>
                <span>·</span>
                <span>
                  <.link
                    :if={row.group}
                    navigate={~p"/boards/#{row.board.id}?edit=group:#{row.group.id}"}
                    class="hover:underline"
                    title="Click to edit group"
                  >{row.group.name}</.link><span :if={row.group}> / </span><.link
                    navigate={~p"/boards/#{row.board.id}?edit=column:#{row.category.id}"}
                    class="hover:underline"
                    title="Click to edit column"
                  >{row.category.name}</.link>
                </span>
                <span :if={row.task.due_at} class="inline-flex items-center gap-1">
                  <.icon name="hero-clock" class="size-3.5" /> {format_due(row.task.due_at)}
                </span>
                <span :if={repeat_label(row.task.repeat, row.task.repeat_every)} class="inline-flex items-center gap-1" title="Repeats">
                  <.icon name="hero-arrow-path" class="size-3.5" /> {repeat_label(row.task.repeat, row.task.repeat_every)}
                </span>
                <span :if={row.task.waiting} class="inline-flex items-center gap-1" title="Task flagged as waiting">
                  ⏳ Waiting
                </span>
              </div>
            </div>
          </li>
        </ul>

        <div :if={@view == :board and @rows != []} class="space-y-8">
          <section :for={b <- @grouped} class="space-y-3">
            <div class="pb-4">
              <div class="flex gap-6 items-start min-w-max">
                <div :for={grp <- b.groups} class="flex flex-col gap-2">
                  <.link
                    :if={grp.group && @scope != :trash}
                    navigate={~p"/boards/#{b.board.id}?edit=group:#{grp.group.id}"}
                    class="px-3 py-2 rounded-t font-semibold text-white min-w-[200px] hover:brightness-110 transition cursor-pointer block"
                    style={"background:#{grp.group.color || "#64748b"}"}
                    title="Click to edit group"
                  >
                    {grp.group.name}
                  </.link>
                  <div
                    :if={grp.group && @scope == :trash}
                    class="px-3 py-2 rounded-t font-semibold text-white min-w-[200px]"
                    style={"background:#{grp.group.color || "#64748b"}"}
                  >
                    {grp.group.name}
                  </div>
                  <div
                    :if={!grp.group}
                    class="px-3 py-2 rounded-t font-semibold text-white min-w-[200px] bg-base-content/40"
                  >
                    Ungrouped
                  </div>

                  <div class="flex gap-2 items-start min-h-[80px]">
                    <div
                      :for={col <- grp.columns}
                      class="w-64 bg-base-100 rounded-lg shadow-sm border border-base-300 flex flex-col"
                    >
                      <.link
                        :if={@scope != :trash}
                        navigate={~p"/boards/#{b.board.id}?edit=column:#{col.category.id}"}
                        class="px-3 py-2 border-b border-base-300 font-medium text-sm bg-base-200 rounded-t-lg hover:bg-base-300/60 transition cursor-pointer block"
                        title="Click to edit column"
                      >
                        {col.category.name}
                      </.link>
                      <div :if={@scope == :trash} class="px-3 py-2 border-b border-base-300 font-medium text-sm bg-base-200 rounded-t-lg">
                        {col.category.name}
                      </div>

                      <ul class="flex flex-col gap-1 p-2 min-h-[60px]">
                        <li
                          :for={task <- col.tasks}
                          class="bg-base-100 border border-base-300 rounded p-2 text-sm hover:shadow-sm"
                        >
                          <div class="flex items-start gap-2">
                            <input
                              :if={@scope != :trash}
                              type="checkbox"
                              checked={task.done}
                              phx-click="toggle_done"
                              phx-value-id={task.id}
                              class="checkbox checkbox-xs mt-1"
                            />
                            <div :if={@scope == :trash} class="flex gap-1 mt-0.5">
                              <button
                                phx-click="restore_task"
                                phx-value-id={task.id}
                                class="btn btn-ghost btn-xs btn-square"
                                title="Restore"
                              >
                                <.icon name="hero-arrow-uturn-left" class="size-3" />
                              </button>
                              <button
                                phx-click="purge_task"
                                phx-value-id={task.id}
                                data-confirm="Permanently delete this task? This cannot be undone."
                                class="btn btn-ghost btn-xs btn-square text-error"
                                title="Delete permanently"
                              >
                                <.icon name="hero-trash" class="size-3" />
                              </button>
                            </div>
                            <.link
                              :if={@scope != :trash}
                              navigate={~p"/boards/#{b.board.id}?edit=task:#{task.id}"}
                              class="flex-1 min-w-0 cursor-pointer"
                              title="Click to edit task"
                            >
                              <div class={["break-words leading-tight", task.done && "line-through text-base-content/50"]}>
                                {task.title}
                              </div>
                              <div :if={task.notes && task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">{task.notes}</div>
                              <div :if={task.due_at || repeat_label(task.repeat, task.repeat_every) || task.waiting} class="text-xs mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-base-content/70">
                                <span :if={task.due_at} class="inline-flex items-center gap-1">
                                  <.icon name="hero-clock" class="size-3.5" />
                                  <span>{format_due(task.due_at)}</span>
                                </span>
                                <span :if={repeat_label(task.repeat, task.repeat_every)} class="inline-flex items-center gap-1" title="Repeats">
                                  <.icon name="hero-arrow-path" class="size-3.5" />
                                  <span>{repeat_label(task.repeat, task.repeat_every)}</span>
                                </span>
                                <span :if={task.waiting} class="inline-flex items-center gap-1" title="Waiting">
                                  <span>⏳</span>
                                  <span>Waiting</span>
                                </span>
                              </div>
                            </.link>
                            <div :if={@scope == :trash} class="flex-1 min-w-0">
                              <div class={["break-words leading-tight", task.done && "line-through text-base-content/50"]}>
                                {task.title}
                              </div>
                              <div :if={task.notes && task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">{task.notes}</div>
                            </div>
                          </div>
                        </li>
                      </ul>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.shell>
    """
  end
end
