defmodule ToDoWeb.GoalLive.Show do
  use ToDoWeb, :live_view

  alias ToDo.Boards
  alias ToDo.Goals

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    goal = Goals.get_user_goal!(String.to_integer(id), user_id)

    sidebar_board =
      case Boards.sidebar_board_for_user(user_id) do
        nil -> nil
        board -> Boards.load_board(board)
      end

    {:ok,
     socket
     |> assign(:sidebar_board, sidebar_board)
     |> assign(:goal, goal)
     |> load_tasks()}
  end

  defp load_tasks(socket) do
    goal = socket.assigns.goal
    boards = Goals.list_tasks_for_goal(goal)
    progress = Goals.goal_progress(goal)

    socket
    |> assign(:boards, boards)
    |> assign(:progress, progress)
  end

  @impl true
  def handle_event("toggle_done", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) in [:owner, :edit] do
      {:ok, _} = Boards.toggle_task_done(task)
      # Ticking a task moves this goal's done/total fraction in the sidebar too.
      {:noreply, socket |> load_tasks() |> ToDoWeb.UserAuth.refresh_sidebar_goals()}
    else
      {:noreply, put_flash(socket, :error, "You only have view access to that task.")}
    end
  end

  # -- helpers --

  defp pct({_done, 0}), do: 0
  defp pct({done, total}), do: round(done / total * 100)

  defp status_badge_class("active"), do: "badge-primary"
  defp status_badge_class("paused"), do: "badge-ghost"
  defp status_badge_class("done"), do: "badge-success"
  defp status_badge_class("abandoned"), do: "badge-ghost"

  defp format_target(nil), do: nil
  defp format_target(%Date{} = d), do: Calendar.strftime(d, "%a %d %b %Y")

  defp format_due(nil), do: nil
  defp format_due(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %d %b %Y · %H:%M")

  defp open_tasks(rows), do: Enum.reject(rows, & &1.task.done)
  defp done_tasks(rows), do: Enum.filter(rows, & &1.task.done)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell
      flash={@flash}
      current_scope={@current_scope}
      page_title={@goal.name}
      active={:goals}
      current_board={@sidebar_board}
      unread_notifications={@unread_notifications}
      recent_notifications={@recent_notifications}
      sidebar_goals={@sidebar_goals}
      sidebar_goal_progress={@sidebar_goal_progress}
    >
      <:actions>
        <.link navigate={~p"/goals?edit=#{@goal.id}"} class="btn btn-outline btn-sm">
          Edit
        </.link>
      </:actions>

      <div class="max-w-3xl space-y-6">
        <.link navigate={~p"/goals"} class="text-sm text-base-content/60 hover:text-base-content hover:underline inline-flex items-center gap-1">
          <.icon name="hero-arrow-left" class="size-4" /> Goals
        </.link>

        <div class="space-y-3">
          <div class="flex items-center gap-3 flex-wrap">
            <span class="w-3 h-3 rounded shrink-0" style={"background:#{@goal.color || "#3b82f6"}"} />
            <h2 class="text-xl font-semibold">{@goal.name}</h2>
            <span class={["badge badge-sm", status_badge_class(@goal.status)]}>{@goal.status}</span>
          </div>

          <p :if={@goal.description && @goal.description != ""} class="text-sm text-base-content/70 whitespace-pre-line">
            {@goal.description}
          </p>

          <div class="space-y-1.5">
            <div class="w-full h-2 bg-base-300 rounded overflow-hidden">
              <div
                class="h-full rounded"
                style={"width:#{pct(@progress)}%;background:#{@goal.color || "#3b82f6"}"}
              >
              </div>
            </div>
            <div class="flex items-center justify-between text-xs text-base-content/60">
              <span>{pct(@progress)}% — {elem(@progress, 0)} of {elem(@progress, 1)} tasks done</span>
              <span :if={@goal.target_date}>Due {format_target(@goal.target_date)}</span>
            </div>
          </div>
        </div>

        <div class="divider my-2"></div>

        <div :if={@boards == []} class="text-center text-base-content/60 py-12">
          No tasks tagged to this goal yet.<br />
          Open any task and tick this goal in its modal to link it.
        </div>

        <section :for={b <- @boards} :if={open_tasks(b.tasks) != []} class="space-y-2">
          <.link navigate={~p"/boards/#{b.board.id}"} class="flex items-center gap-2 text-sm font-semibold hover:underline">
            <span class="w-2 h-2 rounded shrink-0" style={"background:#{b.board.color || "#3b82f6"}"} />
            {b.board.name}
            <span class="text-xs font-normal text-base-content/50">
              {length(open_tasks(b.tasks))} open
            </span>
          </.link>

          <ul class="border border-base-300 rounded divide-y divide-base-300">
            <li :for={row <- open_tasks(b.tasks)} class="flex items-start gap-3 p-3 bg-base-100">
              <input
                type="checkbox"
                checked={row.task.done}
                phx-click="toggle_done"
                phx-value-id={row.task.id}
                class="checkbox checkbox-sm mt-1"
              />
              <div class="flex-1 min-w-0">
                <.link
                  navigate={~p"/boards/#{b.board.id}?edit=task:#{row.task.id}"}
                  class="block hover:underline"
                  title="Click to edit task"
                >
                  <div class="break-words leading-tight">{row.task.title}</div>
                  <div :if={row.task.notes && row.task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">
                    {row.task.notes}
                  </div>
                </.link>
                <div class="text-xs text-base-content/50 mt-1.5 flex flex-wrap gap-x-3 gap-y-1 items-center">
                  <span>
                    <span :if={row.group}>{row.group.name} / </span>{row.category.name}
                  </span>
                  <span :if={row.task.due_at} class="inline-flex items-center gap-1">
                    <.icon name="hero-clock" class="size-3.5" /> {format_due(row.task.due_at)}
                  </span>
                  <span :if={row.task.waiting} class="inline-flex items-center gap-1" title="Waiting">
                    ⏳ Waiting
                  </span>
                </div>
              </div>
            </li>
          </ul>
        </section>

        <details :if={Enum.any?(@boards, &(done_tasks(&1.tasks) != []))}>
          <summary class="text-xs font-semibold uppercase tracking-wide text-base-content/60 cursor-pointer select-none">
            Completed ({@boards |> Enum.map(&length(done_tasks(&1.tasks))) |> Enum.sum()})
          </summary>
          <div class="mt-3 space-y-4">
            <section :for={b <- @boards} :if={done_tasks(b.tasks) != []} class="space-y-2">
              <div class="flex items-center gap-2 text-sm font-semibold text-base-content/60">
                <span class="w-2 h-2 rounded shrink-0" style={"background:#{b.board.color || "#3b82f6"}"} />
                {b.board.name}
              </div>
              <ul class="border border-base-300 rounded divide-y divide-base-300">
                <li :for={row <- done_tasks(b.tasks)} class="flex items-start gap-3 p-3 bg-base-100">
                  <input
                    type="checkbox"
                    checked
                    phx-click="toggle_done"
                    phx-value-id={row.task.id}
                    class="checkbox checkbox-sm mt-1"
                  />
                  <div class="flex-1 min-w-0">
                    <div class="break-words leading-tight line-through text-base-content/50">
                      {row.task.title}
                    </div>
                  </div>
                </li>
              </ul>
            </section>
          </div>
        </details>
      </div>
    </Layouts.shell>
    """
  end
end
