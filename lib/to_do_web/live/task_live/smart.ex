defmodule ToDoWeb.TaskLive.Smart do
  use ToDoWeb, :live_view

  alias ToDo.Boards
  alias ToDo.Goals
  alias ToDo.Inbox
  alias ToDo.Plans

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
    user = socket.assigns.current_scope.user

    sidebar_board =
      case Boards.sidebar_board_for_user(user.id) do
        nil -> nil
        board -> Boards.load_board(board)
      end

    {:ok,
     socket
     |> assign(:sidebar_board, sidebar_board)
     # Day boundary + capacity come from the user's planning preferences.
     |> assign(:tz, Plans.user_tz(user))
     |> assign(:daily_capacity_minutes, user.daily_capacity_minutes || 360)
     |> assign(:plan_date, Plans.today(user))
     |> assign(:planning?, false)
     |> assign(:wrap_up, nil)
     |> assign(:candidates, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.live_action
    view = if params["view"] == "board", do: :board, else: :list
    # `/today?plan=1` swaps the page into planning mode (Today only).
    planning? = scope == :today and params["plan"] not in [nil, ""]

    {:noreply,
     socket
     |> assign(:scope, scope)
     |> assign(:view, view)
     |> assign(:planning?, planning?)
     |> assign(:title, Map.fetch!(@titles, scope))
     |> assign(:subtitle, Map.fetch!(@subtitles, scope))
     |> refresh()}
  end

  # Everything the page derives from the database, recomputed in one
  # place so every event that mutates tasks/plans stays consistent:
  # smart rows, board grouping, today's plan split, planning candidates,
  # goal chips, coverage stats, sidebar goal fractions.
  defp refresh(socket) do
    %{scope: scope, tz: tz, plan_date: date, planning?: planning?} = socket.assigns
    user = socket.assigns.current_scope.user
    rows = Boards.list_smart_tasks(user.id, scope, tz: tz)

    {plan_rows, other_rows, candidates} =
      if scope == :today do
        plan_rows = Plans.list_plan(user.id, date)
        planned = MapSet.new(plan_rows, & &1.task.id)
        other = Enum.reject(rows, &MapSet.member?(planned, &1.task.id))
        cands = if planning?, do: Plans.candidates(user, date), else: nil
        {plan_rows, other, cands}
      else
        {[], rows, nil}
      end

    cand_rows = if candidates, do: candidates |> Map.values() |> List.flatten(), else: []

    ids =
      (rows ++ plan_rows ++ cand_rows)
      |> Enum.map(& &1.task.id)
      |> Enum.uniq()

    task_goals = Goals.goals_by_task_ids(ids)

    socket
    |> assign(:rows, rows)
    |> assign(:grouped, group_by_board(rows))
    # Discarded Inbox items live in Trash alongside trashed tasks.
    |> assign(:trashed_inbox, if(scope == :trash, do: Inbox.list_trashed(user.id), else: []))
    |> assign(:plan_rows, plan_rows)
    |> assign(:other_rows, other_rows)
    |> assign(:has_plan?, plan_rows != [])
    |> assign(:candidates, candidates)
    |> assign(:task_goals, task_goals)
    |> assign(:coverage, Plans.coverage(plan_rows, task_goals))
    # Ticking a task here shifts its goals' done/total fractions in the sidebar.
    |> ToDoWeb.UserAuth.refresh_sidebar_goals()
  end

  @impl true
  def handle_event("toggle_done", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) in [:owner, :edit] do
      {:ok, _} = Boards.toggle_task_done(task)
      {:noreply, refresh(socket)}
    else
      {:noreply, put_flash(socket, :error, "You only have view access to that task.")}
    end
  end

  def handle_event("restore_task", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) in [:owner, :edit] do
      {:ok, _} = Boards.restore_task(task)
      {:noreply, refresh(socket)}
    else
      {:noreply, put_flash(socket, :error, "You only have view access to that task.")}
    end
  end

  def handle_event("purge_task", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) == :owner do
      {:ok, _} = Boards.purge_task(task)
      {:noreply, refresh(socket)}
    else
      {:noreply, put_flash(socket, :error, "Only the board owner can permanently delete a task.")}
    end
  end

  # Reorder the smart-list LIST view by drag. Ignore the client-supplied
  # scope and use the LV's own — the client's claim is only used as a
  # sanity check. The Boards function rewrites the user's
  # TaskListPosition rows for this scope from the ordered ids array.
  def handle_event("reorder_list_tasks", %{"scope" => scope_str, "task_ids" => ids}, socket) do
    user_id = socket.assigns.current_scope.user.id
    scope = socket.assigns.scope

    cond do
      scope not in [:today, :upcoming, :anytime, :waiting] ->
        {:noreply, socket}

      to_string(scope) != scope_str ->
        {:noreply, socket}

      true ->
        {:ok, _} = Boards.reorder_list_tasks(user_id, scope, ids)
        {:noreply, refresh(socket)}
    end
  end

  # -- Daily plan events (Today only) --

  def handle_event("plan_task", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Plans.plan_task(user_id, id, socket.assigns.plan_date) do
      {:ok, _} -> {:noreply, refresh(socket)}
      {:error, :forbidden} -> {:noreply, put_flash(socket, :error, "You can't see that task.")}
      {:error, _} -> {:noreply, refresh(socket)}
    end
  end

  def handle_event("unplan_task", %{"id" => id}, socket) do
    Plans.unplan_task(socket.assigns.current_scope.user.id, id)
    {:noreply, refresh(socket)}
  end

  def handle_event("reorder_plan", %{"task_ids" => ids}, socket) do
    Plans.reorder_plan(socket.assigns.current_scope.user.id, socket.assigns.plan_date, ids)
    {:noreply, refresh(socket)}
  end

  # Inline estimate quick-pick from a row's "~?" chip.
  def handle_event("set_estimate", %{"id" => id, "minutes" => minutes}, socket) do
    user_id = socket.assigns.current_scope.user.id
    task = Boards.get_task!(id)

    if Boards.task_permission(task, user_id) in [:owner, :edit] do
      {:ok, _} = Boards.update_task(task, %{"estimated_minutes" => minutes})
      {:noreply, refresh(socket)}
    else
      {:noreply, put_flash(socket, :error, "You only have view access to that task.")}
    end
  end

  # -- Trashed Inbox items --

  def handle_event("restore_inbox_item", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    {:ok, _} = Inbox.restore(Inbox.get_item!(id, user_id))
    {:noreply, refresh(socket)}
  end

  def handle_event("purge_inbox_item", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    {:ok, _} = Inbox.purge(Inbox.get_item!(id, user_id))
    {:noreply, refresh(socket)}
  end

  # -- Wrap-up --

  def handle_event("open_wrap_up", _params, socket) do
    tomorrow = Date.add(socket.assigns.plan_date, 1) |> Date.to_iso8601()

    decisions =
      socket.assigns.plan_rows
      |> Enum.reject(& &1.task.done)
      |> Map.new(fn row -> {to_string(row.task.id), tomorrow} end)

    {:noreply, assign(socket, :wrap_up, %{decisions: decisions, reflection: ""})}
  end

  def handle_event("close_wrap_up", _params, socket), do: {:noreply, assign(socket, :wrap_up, nil)}

  def handle_event("wrap_decision", %{"task_id" => id, "value" => value}, socket) do
    wrap = socket.assigns.wrap_up
    {:noreply, assign(socket, :wrap_up, %{wrap | decisions: Map.put(wrap.decisions, id, value)})}
  end

  def handle_event("wrap_all_tomorrow", _params, socket) do
    wrap = socket.assigns.wrap_up
    tomorrow = Date.add(socket.assigns.plan_date, 1) |> Date.to_iso8601()
    decisions = Map.new(wrap.decisions, fn {id, _} -> {id, tomorrow} end)
    {:noreply, assign(socket, :wrap_up, %{wrap | decisions: decisions})}
  end

  def handle_event("wrap_reflection", %{"reflection" => text}, socket) do
    wrap = socket.assigns.wrap_up
    {:noreply, assign(socket, :wrap_up, %{wrap | reflection: text})}
  end

  def handle_event("finish_day", _params, socket) do
    user = socket.assigns.current_scope.user
    %{decisions: decisions, reflection: reflection} = socket.assigns.wrap_up

    case Plans.wrap_up(user, socket.assigns.plan_date, decisions, reflection) do
      {:ok, review} ->
        {:noreply,
         socket
         |> assign(:wrap_up, nil)
         |> put_flash(:info, "Day wrapped — #{review.done_count} of #{review.planned_count} planned tasks done.")
         |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Couldn't wrap up the day — try again.")}
    end
  end

  # True for scopes that allow user-controlled drag-reordering of the LIST view.
  defp reorderable?(scope), do: scope in [:today, :upcoming, :anytime, :waiting]

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

  # Where the board view should push_navigate back to after closing a modal
  # opened from this LV. Maps the smart-list scope atom to its URL path.
  defp return_path(scope) when scope in [:today, :upcoming, :anytime, :waiting], do: "/#{scope}"
  defp return_path(_), do: "/today"

  # Header chips: show every board whose tasks appear in the current smart list.
  # If the list is empty, fall back to the user's primary (sidebar) board so the
  # header still gives a sense of board context.
  defp header_boards([], nil), do: []
  defp header_boards([], sidebar_board), do: [sidebar_board]
  defp header_boards(grouped, _), do: Enum.map(grouped, & &1.board)

  defp format_due(nil), do: nil
  defp format_due(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %d %b %Y · %H:%M")

  # -- Today commitment total --

  # When a plan exists the badge describes the plan; otherwise all open
  # tasks due today (the pre-planning behaviour).
  defp badge_rows(true, plan_rows, _rows), do: plan_rows
  defp badge_rows(false, _plan_rows, rows), do: rows

  defp open_rows(rows), do: Enum.reject(rows, & &1.task.done)

  defp estimate_total(rows) do
    rows |> open_rows() |> Enum.map(&(&1.task.estimated_minutes || 0)) |> Enum.sum()
  end

  defp over_capacity?(rows, capacity), do: estimate_total(rows) > capacity

  # After 18:00 in the user's zone, nudge towards wrap-up (banner only).
  defp evening?(tz), do: DateTime.now!(tz).hour >= 18

  defp unfinished(plan_rows), do: Enum.reject(plan_rows, & &1.task.done)

  # Goals touched by DONE planned tasks — the "moved forward" line.
  defp goals_moved(plan_rows, task_goals) do
    plan_rows
    |> Enum.filter(& &1.task.done)
    |> Enum.flat_map(&Map.get(task_goals, &1.task.id, []))
    |> Enum.group_by(& &1.id)
    |> Enum.map(fn {_, [g | _] = gs} -> {g, length(gs)} end)
    |> Enum.sort_by(fn {_, n} -> -n end)
  end

  # Wrap-up deferral targets: tomorrow, the following five days by name,
  # Anytime (clears the due date), Keep (leaves plan, due date untouched).
  defp wrap_options(%Date{} = date) do
    days =
      for n <- 1..6 do
        d = Date.add(date, n)
        label = if n == 1, do: "Tomorrow (#{Calendar.strftime(d, "%a %-d %b")})", else: Calendar.strftime(d, "%a %-d %b")
        {label, Date.to_iso8601(d)}
      end

    days ++ [{"Anytime (drop due date)", "anytime"}, {"Keep on today's list", "keep"}]
  end

  defp decision_value(nil, _id), do: "keep"
  defp decision_value(%{decisions: d}, id), do: Map.get(d, to_string(id), "keep")

  # Plain-language read of the plan's shape. No score — just the facts
  # that answer "is today serving my goals?" and "is the total honest?".
  defp coverage_sentences(%{total: 0}), do: []

  defp coverage_sentences(%{total_minutes: 0, unestimated: n}) when n > 0 do
    ["No estimates yet — add some so the total means something."]
  end

  defp coverage_sentences(cov) do
    goal_s =
      case cov.minutes_by_goal do
        [] ->
          "None of today's time is attached to a goal."

        [{g, m} | _] when cov.goal_share >= 0.5 ->
          "Most of your time today is on #{g.name} (~#{format_minutes(m)})."

        [{g, m} | _] ->
          "Only #{round(cov.goal_share * 100)}% of today's time is on a goal — the biggest is #{g.name} (~#{format_minutes(m)})."
      end

    est_s =
      case cov.unestimated do
        0 -> nil
        1 -> "1 task has no estimate — the total is a floor."
        n -> "#{n} tasks have no estimate — the total is a floor."
      end

    Enum.reject([goal_s, est_s], &is_nil/1)
  end

  defp committed_label(rows) do
    open = open_rows(rows)
    n = length(open)
    noun = if n == 1, do: "task", else: "tasks"
    unestimated = Enum.count(open, &is_nil(&1.task.estimated_minutes))

    case estimate_total(open) do
      0 ->
        "#{n} #{noun} · no estimates yet"

      total when unestimated > 0 ->
        "#{n} #{noun} · ~#{format_minutes(total)} committed (#{unestimated} unestimated)"

      total ->
        "#{n} #{noun} · ~#{format_minutes(total)} committed"
    end
  end

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

  # -- Row component --
  #
  # One task row, shared by the plain smart list, Today's Planned and
  # "Also due today" sections, and the planning-mode candidate lists.
  # `mode` picks the affordances:
  #   :list      — checkbox + optional list drag handle (existing behaviour)
  #   :planned   — checkbox + plan drag handle + remove-from-plan ×
  #   :other     — checkbox + "+ Plan" (due today but not planned)
  #   :candidate — [+] add-to-plan instead of a checkbox (planning mode)
  attr :row, :map, required: true
  attr :scope, :atom, required: true
  attr :task_goals, :map, required: true
  attr :mode, :atom, default: :list
  attr :id_prefix, :string, required: true
  attr :draggable, :boolean, default: false
  attr :handle_attr, :string, default: "data-list-drag-handle"

  defp smart_row(assigns) do
    ~H"""
    <li
      id={"#{@id_prefix}-#{@row.task.id}"}
      data-task-id={@row.task.id}
      class={["flex items-start gap-3 p-3 bg-base-100", @mode == :other && "opacity-80"]}
    >
      <span
        :if={@draggable}
        {%{@handle_attr => true}}
        class="cursor-grab active:cursor-grabbing text-base-content/40 hover:text-base-content/70 mt-1 touch-none select-none"
        title="Drag to reorder"
      >
        <.icon name="hero-bars-3" class="size-4" />
      </span>
      <input
        :if={@scope != :trash and @mode != :candidate}
        type="checkbox"
        checked={@row.task.done}
        phx-click="toggle_done"
        phx-value-id={@row.task.id}
        class="checkbox checkbox-sm mt-1"
      />
      <button
        :if={@mode == :candidate}
        type="button"
        phx-click="plan_task"
        phx-value-id={@row.task.id}
        class="btn btn-ghost btn-xs btn-square mt-0.5"
        title="Add to today's plan"
      >
        <.icon name="hero-plus" class="size-4" />
      </button>
      <div :if={@scope == :trash} class="flex gap-1 mt-0.5">
        <button phx-click="restore_task" phx-value-id={@row.task.id} class="btn btn-ghost btn-xs" title="Restore">
          <.icon name="hero-arrow-uturn-left" class="size-4" />
        </button>
        <button
          phx-click="purge_task"
          phx-value-id={@row.task.id}
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
          navigate={~p"/boards/#{@row.board.id}?edit=task:#{@row.task.id}"}
          class="block hover:underline"
          title="Click to edit task"
        >
          <div class={["break-words leading-tight", @row.task.done && "line-through text-base-content/50"]}>
            {@row.task.title}
          </div>
          <div :if={@row.task.notes && @row.task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">{@row.task.notes}</div>
        </.link>
        <div :if={@scope == :trash}>
          <div class={["break-words leading-tight", @row.task.done && "line-through text-base-content/50"]}>
            {@row.task.title}
          </div>
          <div :if={@row.task.notes && @row.task.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line">{@row.task.notes}</div>
        </div>
        <div class="text-xs text-base-content/50 mt-2 flex flex-wrap gap-x-3 gap-y-1 items-center">
          <.link navigate={~p"/boards/#{@row.board.id}"} class="hover:underline flex items-center gap-1">
            <span class="w-2 h-2 rounded" style={"background:#{@row.board.color || "#3b82f6"}"} />
            {@row.board.name}
          </.link>
          <span>·</span>
          <span>
            <.link
              :if={@row.group}
              navigate={~p"/boards/#{@row.board.id}?edit=group:#{@row.group.id}"}
              class="hover:underline"
              title="Click to edit group"
            >{@row.group.name}</.link><span :if={@row.group}> / </span><.link
              navigate={~p"/boards/#{@row.board.id}?edit=column:#{@row.category.id}"}
              class="hover:underline"
              title="Click to edit column"
            >{@row.category.name}</.link>
          </span>
          <span :if={@row.task.due_at} class="inline-flex items-center gap-1">
            <.icon name="hero-clock" class="size-3.5" /> {format_due(@row.task.due_at)}
          </span>
          <.estimate_chip minutes={@row.task.estimated_minutes} />
          <%!-- No estimate yet: a "~?" that opens the quick-pick inline, so
               estimating happens while planning, not in a separate modal. --%>
          <div
            :if={is_nil(@row.task.estimated_minutes) and @mode in [:planned, :other, :candidate] and not @row.task.done}
            class="dropdown dropdown-end"
          >
            <div
              tabindex="0"
              role="button"
              class="inline-flex items-center gap-1 cursor-pointer hover:text-base-content"
              title="No estimate — click to set one"
            >
              <.icon name="hero-clock" class="size-3.5" /> ~?
            </div>
            <ul tabindex="0" class="dropdown-content menu menu-xs bg-base-100 rounded-box z-20 p-1 shadow border border-base-300">
              <li :for={{label, m} <- [{"15m", "15"}, {"30m", "30"}, {"1h", "60"}, {"2h", "120"}, {"Half day", "240"}]}>
                <button
                  type="button"
                  onmousedown="event.preventDefault()"
                  phx-click="set_estimate"
                  phx-value-id={@row.task.id}
                  phx-value-minutes={m}
                >
                  {label}
                </button>
              </li>
            </ul>
          </div>
          <span :if={repeat_label(@row.task.repeat, @row.task.repeat_every)} class="inline-flex items-center gap-1" title="Repeats">
            <.icon name="hero-arrow-path" class="size-3.5" /> {repeat_label(@row.task.repeat, @row.task.repeat_every)}
          </span>
          <span :if={@row.task.waiting} class="inline-flex items-center gap-1" title="Task flagged as waiting">
            ⏳ Waiting
          </span>
        </div>
        <.goal_chips goals={@task_goals[@row.task.id]} />
      </div>
      <button
        :if={@mode == :planned}
        type="button"
        phx-click="unplan_task"
        phx-value-id={@row.task.id}
        class="btn btn-ghost btn-xs btn-square shrink-0 text-base-content/50 hover:text-base-content"
        title="Remove from today's plan"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
      <button
        :if={@mode == :other}
        type="button"
        phx-click="plan_task"
        phx-value-id={@row.task.id}
        class="btn btn-ghost btn-xs shrink-0"
      >
        + Plan
      </button>
    </li>
    """
  end

  # Collapsible candidate group for planning mode. Overdue and Due today
  # open by default; the proactive sources (Upcoming, Anytime, Waiting)
  # stay collapsed so the default view is "what's already on fire".
  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :scope, :atom, required: true
  attr :task_goals, :map, required: true
  attr :id_prefix, :string, required: true
  attr :open, :boolean, default: false

  defp candidate_group(assigns) do
    ~H"""
    <details :if={@rows != []} open={@open} class="border border-base-300 rounded">
      <summary class="cursor-pointer select-none px-3 py-2 text-xs font-semibold uppercase tracking-wide text-base-content/60 hover:bg-base-200/60">
        {@title} · {length(@rows)}
      </summary>
      <ul class="divide-y divide-base-300 border-t border-base-300">
        <.smart_row
          :for={row <- @rows}
          row={row}
          scope={@scope}
          task_goals={@task_goals}
          mode={:candidate}
          id_prefix={@id_prefix}
        />
      </ul>
    </details>
    """
  end

  attr :minutes, :integer, required: true
  attr :capacity, :integer, required: true

  defp capacity_bar(assigns) do
    ~H"""
    <div class="space-y-1">
      <progress
        class={["progress w-full", @minutes > @capacity && "progress-warning", @minutes <= @capacity && "progress-primary"]}
        value={min(@minutes, @capacity)}
        max={@capacity}
      />
      <div class="text-xs text-base-content/70">
        <span :if={@minutes <= @capacity}>~{format_minutes(@minutes)} of {format_minutes(@capacity)}</span>
        <span :if={@minutes > @capacity} class="text-warning-content font-medium">
          ~{format_minutes(@minutes)} — {format_minutes(@minutes - @capacity)} over your {format_minutes(@capacity)} capacity
        </span>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_scope={@current_scope} page_title={@title} active={@scope} current_board={@sidebar_board} unread_notifications={@unread_notifications} recent_notifications={@recent_notifications} sidebar_goals={@sidebar_goals} sidebar_goal_progress={@sidebar_goal_progress} inbox_count={@inbox_count}>
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
        <div :if={not @planning?} class="flex items-center justify-between gap-3 flex-wrap">
          <div class="flex items-center gap-2 flex-wrap text-sm text-base-content/60">
            <p>{@subtitle}</p>
            <%!-- Today only: how much you've committed to. Describes the
                 plan once one exists, else every open task due today.
                 Amber past the user's daily capacity so overcommit is
                 visible before the day starts, not in hindsight. --%>
            <span
              :if={@scope == :today and badge_rows(@has_plan?, @plan_rows, @rows) != []}
              class={[
                "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium",
                over_capacity?(badge_rows(@has_plan?, @plan_rows, @rows), @daily_capacity_minutes) && "bg-warning/25 text-base-content",
                !over_capacity?(badge_rows(@has_plan?, @plan_rows, @rows), @daily_capacity_minutes) && "bg-base-200 text-base-content/70"
              ]}
              title={"Sum of estimates on open #{if @has_plan?, do: "planned", else: "due"} tasks. Turns amber past #{format_minutes(@daily_capacity_minutes)} (change in Settings)."}
            >
              <.icon
                :if={over_capacity?(badge_rows(@has_plan?, @plan_rows, @rows), @daily_capacity_minutes)}
                name="hero-exclamation-triangle"
                class="size-3.5"
              />
              {committed_label(badge_rows(@has_plan?, @plan_rows, @rows))}
            </span>
          </div>
          <div class="flex items-center gap-2 flex-wrap">
            <div :if={@scope == :today} class="flex items-center gap-1">
              <.link :if={not @has_plan?} patch={~p"/today?plan=1&view=#{@view}"} class="btn btn-sm btn-outline">
                <.icon name="hero-sparkles" class="size-4" /> Plan today
              </.link>
              <.link :if={@has_plan?} patch={~p"/today?plan=1&view=#{@view}"} class="btn btn-sm btn-ghost">
                Edit plan
              </.link>
              <button :if={@has_plan?} type="button" phx-click="open_wrap_up" class="btn btn-sm btn-outline">
                <.icon name="hero-moon" class="size-4" /> Wrap up
              </button>
            </div>
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
        </div>

        <%!-- Evening nudge — banner only, never a modal ambush. --%>
        <div
          :if={@scope == :today and @has_plan? and not @planning? and evening?(@tz)}
          class="flex items-center gap-2 rounded bg-base-200 px-3 py-2 text-sm"
        >
          <.icon name="hero-moon" class="size-4 text-base-content/60" />
          <span class="flex-1">Wrap up your day when you're done.</span>
          <button type="button" phx-click="open_wrap_up" class="btn btn-xs btn-ghost">Wrap up →</button>
        </div>

        <div :if={@rows == [] and @plan_rows == [] and @trashed_inbox == [] and not @planning?} class="text-center text-base-content/60 py-12">
          Nothing here.
          <div :if={@scope == :today} class="mt-3">
            <.link patch={~p"/today?plan=1&view=#{@view}"} class="btn btn-sm btn-outline">Plan today</.link>
          </div>
        </div>

        <%!-- ============ Planning mode (Today, ?plan=1) ============
             Two columns: candidates on the left (overdue + due today
             open by default; the proactive sources collapsed), the
             day's plan on the right with the capacity bar and coverage
             sentences. --%>
        <div :if={@planning? and @candidates} class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <section class="space-y-3 order-2 lg:order-1">
            <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">Candidates</h2>
            <%!-- Inbox items aren't tasks yet, so they can't be planned —
                 but a plan built while ignoring them isn't honest either. --%>
            <.link
              :if={@inbox_count > 0}
              navigate={~p"/inbox"}
              class="flex items-center gap-2 rounded bg-base-200 px-3 py-2 text-sm hover:bg-base-300/60"
            >
              <.icon name="hero-inbox-arrow-down" class="size-4 text-base-content/60" />
              <span class="flex-1">
                {@inbox_count} {if @inbox_count == 1, do: "item", else: "items"} in your Inbox haven't been triaged
              </span>
              <span class="text-primary">Process →</span>
            </.link>
            <.candidate_group title="Overdue" rows={@candidates.overdue} scope={@scope} task_goals={@task_goals} id_prefix="cand-overdue" open />
            <.candidate_group title="Due today" rows={@candidates.due_today} scope={@scope} task_goals={@task_goals} id_prefix="cand-today" open />
            <.candidate_group title="Upcoming (next 7 days)" rows={@candidates.upcoming} scope={@scope} task_goals={@task_goals} id_prefix="cand-upcoming" />
            <.candidate_group title="Anytime" rows={@candidates.anytime} scope={@scope} task_goals={@task_goals} id_prefix="cand-anytime" />
            <.candidate_group title="Waiting" rows={@candidates.waiting} scope={@scope} task_goals={@task_goals} id_prefix="cand-waiting" />
            <p
              :if={Enum.all?(Map.values(@candidates), &(&1 == []))}
              class="text-sm text-base-content/60 text-center py-6 border border-dashed border-base-300 rounded"
            >
              Nothing left to pull in — everything visible is already planned.
            </p>
          </section>

          <section class="space-y-3 order-1 lg:order-2 lg:sticky lg:top-4 self-start">
            <div class="flex items-center justify-between gap-2">
              <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Today's plan · {length(@plan_rows)} · ~{format_minutes(@coverage.total_minutes)}
              </h2>
              <.link patch={view_href(@scope, @view)} class="btn btn-primary btn-sm">Done planning</.link>
            </div>
            <.capacity_bar minutes={@coverage.total_minutes} capacity={@daily_capacity_minutes} />
            <p :if={@coverage.total > 0} class="text-xs text-base-content/60">
              estimated {@coverage.estimated}/{@coverage.total} · on a goal {@coverage.with_goal}/{@coverage.total}
            </p>
            <ul
              :if={@plan_rows != []}
              id="plan-list-planning"
              phx-hook="SortablePlan"
              class="border border-base-300 rounded divide-y divide-base-300"
            >
              <.smart_row
                :for={row <- @plan_rows}
                row={row}
                scope={@scope}
                task_goals={@task_goals}
                mode={:planned}
                id_prefix="plan-row"
                draggable
                handle_attr="data-plan-drag-handle"
              />
            </ul>
            <div
              :if={@plan_rows == []}
              class="text-sm text-base-content/60 text-center py-8 border border-dashed border-base-300 rounded"
            >
              Nothing planned yet — add from the candidates.
            </div>
            <div :if={coverage_sentences(@coverage) != []} class="text-sm text-base-content/70 space-y-1 pt-1">
              <p :for={s <- coverage_sentences(@coverage)}>{s}</p>
            </div>
          </section>
        </div>

        <%!-- ============ Today with a plan ============
             Planned (ordered, drag to reorder, ticked rows stay struck
             through until wrap-up) then everything else due today,
             demoted below a fold. --%>
        <div :if={@scope == :today and @view == :list and not @planning? and @has_plan?} class="space-y-6">
          <div class="space-y-2">
            <div class="flex items-center justify-between gap-2 flex-wrap">
              <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                Planned · {length(@plan_rows)} · ~{format_minutes(@coverage.total_minutes)}
              </h2>
              <span :if={@coverage.total + @coverage.done > 0} class="text-xs text-base-content/50">
                done {@coverage.done}/{@coverage.total + @coverage.done} · estimated {@coverage.estimated}/{@coverage.total} · on a goal {@coverage.with_goal}/{@coverage.total}
              </span>
            </div>
            <ul id="plan-list" phx-hook="SortablePlan" class="border border-base-300 rounded divide-y divide-base-300">
              <.smart_row
                :for={row <- @plan_rows}
                row={row}
                scope={@scope}
                task_goals={@task_goals}
                mode={:planned}
                id_prefix="today-plan"
                draggable
                handle_attr="data-plan-drag-handle"
              />
            </ul>
          </div>

          <details :if={@other_rows != []} open class="space-y-2">
            <summary class="cursor-pointer select-none text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Also due today · {length(@other_rows)}
            </summary>
            <ul class="border border-base-300 rounded divide-y divide-base-300 mt-2">
              <.smart_row
                :for={row <- @other_rows}
                row={row}
                scope={@scope}
                task_goals={@task_goals}
                mode={:other}
                id_prefix="today-other"
              />
            </ul>
          </details>
        </div>

        <%!-- ============ Plain smart list (every scope; Today without a plan) ============
             `@rows` is sorted by the SQL query — manual
             TaskListPosition.position first (asc, nulls last) then the
             scope's chronological default. The four "active" scopes get
             the SortableListTasks hook; completed/trash are read-only.
             Stable <li> ids keep morphdom from flickering on reorder. --%>
        <ul
          :if={@view == :list and @rows != [] and not @planning? and not (@scope == :today and @has_plan?)}
          id={"list-tasks-#{@scope}"}
          phx-hook={if reorderable?(@scope), do: "SortableListTasks"}
          data-scope={@scope}
          class="border border-base-300 rounded divide-y divide-base-300"
        >
          <.smart_row
            :for={row <- @rows}
            row={row}
            scope={@scope}
            task_goals={@task_goals}
            mode={:list}
            id_prefix={"list-task-#{@scope}"}
            draggable={reorderable?(@scope)}
            handle_attr="data-list-drag-handle"
          />
        </ul>

        <%!-- ============ Trash: discarded Inbox items ============ --%>
        <div :if={@scope == :trash and @trashed_inbox != []} class="space-y-2">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            Captured items · {length(@trashed_inbox)}
          </h2>
          <ul class="border border-base-300 rounded divide-y divide-base-300">
            <li :for={item <- @trashed_inbox} id={"trashed-inbox-#{item.id}"} class="flex items-start gap-3 p-3 bg-base-100">
              <div class="flex gap-1 mt-0.5">
                <button phx-click="restore_inbox_item" phx-value-id={item.id} class="btn btn-ghost btn-xs" title="Restore to Inbox">
                  <.icon name="hero-arrow-uturn-left" class="size-4" />
                </button>
                <button
                  phx-click="purge_inbox_item"
                  phx-value-id={item.id}
                  data-confirm="Permanently delete this captured item? This cannot be undone."
                  class="btn btn-ghost btn-xs text-error"
                  title="Delete permanently"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
              <div class="flex-1 min-w-0">
                <div class="break-words leading-tight text-base-content/70">{item.title}</div>
                <div :if={item.notes && item.notes != ""} class="text-xs text-base-content/50 leading-tight whitespace-pre-line">{item.notes}</div>
                <div class="text-xs text-base-content/40 mt-1">discarded {Calendar.strftime(item.deleted_at, "%a %-d %b · %H:%M")}</div>
              </div>
            </li>
          </ul>
        </div>

        <%!-- ============ Wrap-up modal ============ --%>
        <.form_modal
          :if={@wrap_up}
          id="wrap-up-modal"
          title={"Wrap up #{Calendar.strftime(@plan_date, "%A %-d %b")}"}
          on_cancel="close_wrap_up"
        >
          <div class="space-y-5">
            <div class="text-sm space-y-1">
              <p>
                You planned <span class="font-medium">{@coverage.total + @coverage.done}</span>
                {if @coverage.total + @coverage.done == 1, do: "task", else: "tasks"}
                (~{format_minutes(@coverage.total_minutes + @coverage.done_minutes)}).
                Done: <span class="font-medium">{@coverage.done}</span> (~{format_minutes(@coverage.done_minutes)}).
              </p>
              <p :if={goals_moved(@plan_rows, @task_goals) != []} class="flex flex-wrap items-center gap-x-2 gap-y-1">
                <span>Moved forward:</span>
                <span :for={{g, n} <- goals_moved(@plan_rows, @task_goals)} class="inline-flex items-center gap-1">
                  <span class="w-2 h-2 rounded-full" style={"background:#{g.color || "#3b82f6"}"} />
                  {g.name} ×{n}
                </span>
              </p>
            </div>

            <div :if={unfinished(@plan_rows) != []} class="space-y-2">
              <div class="flex items-center justify-between gap-2">
                <h3 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
                  Unfinished · {length(unfinished(@plan_rows))}
                </h3>
                <button type="button" phx-click="wrap_all_tomorrow" class="btn btn-ghost btn-xs">
                  Move all to tomorrow
                </button>
              </div>
              <ul class="border border-base-300 rounded divide-y divide-base-300">
                <li :for={row <- unfinished(@plan_rows)} class="flex items-center gap-3 p-2 text-sm">
                  <span class="flex-1 min-w-0 truncate">{row.task.title}</span>
                  <.estimate_chip minutes={row.task.estimated_minutes} />
                  <form phx-change="wrap_decision" class="contents">
                    <input type="hidden" name="task_id" value={row.task.id} />
                    <select name="value" class="select select-bordered select-xs w-44">
                      <option
                        :for={{label, v} <- wrap_options(@plan_date)}
                        value={v}
                        selected={decision_value(@wrap_up, row.task.id) == v}
                      >
                        {label}
                      </option>
                    </select>
                  </form>
                </li>
              </ul>
              <p class="text-xs text-base-content/60">
                Moving a task also moves its due date to that day (same time) if it was due today or earlier.
              </p>
            </div>

            <form phx-change="wrap_reflection">
              <label class="label pb-1">
                <span class="label-text font-medium">One line about today (optional)</span>
              </label>
              <textarea
                name="reflection"
                rows="2"
                class="textarea textarea-bordered w-full"
                placeholder="What worked, what got in the way…"
                phx-debounce="300"
              >{@wrap_up.reflection}</textarea>
            </form>

            <.modal_footer>
              <:secondary>
                <button type="button" phx-click="close_wrap_up" class="btn btn-ghost">Cancel</button>
              </:secondary>
              <:primary>
                <button type="button" phx-click="finish_day" class="btn btn-primary">Finish day</button>
              </:primary>
            </.modal_footer>
          </div>
        </.form_modal>

        <div :if={@view == :board and @rows != [] and not @planning?} class="space-y-8">
          <section :for={b <- @grouped} class="space-y-3">
            <%!-- overflow-x-auto sits here so the horizontal kanban scroll
                 is contained inside this section rather than propagating up
                 to <main>. Without this, wide boards drag the header row
                 (subtitle + List/Boards toggle) sideways with them, since
                 the shell's <main> also overflows horizontally.

                 md:min-h-… stretches the scroll container so its bottom
                 (where the horizontal scrollbar lives) reaches the
                 viewport floor even when columns are short. The
                 negative bottom margin cancels <main>'s p-6 padding so
                 the scrollbar sits right at the viewport edge instead
                 of hovering ~24px above it. --%>
            <div class="pb-4 overflow-x-auto md:min-h-[calc(100vh-7rem)] md:-mb-6">
              <%!-- Same layout pivot as board_live/show.ex: groups stack
                   vertically and fill the viewport on mobile (so a kanban
                   board is actually readable on a phone); switches to the
                   horizontal kanban layout at the `md` breakpoint. --%>
              <div class="flex flex-col gap-6 md:flex-row md:items-start md:min-w-max md:pr-6">
                <div :for={grp <- b.groups} class="flex flex-col gap-2 w-full md:w-auto">
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

                  <div class="flex flex-col gap-2 md:flex-row md:items-start min-h-[80px]">
                    <div
                      :for={col <- grp.columns}
                      class="w-full md:w-64 bg-base-100 rounded-lg shadow-sm border border-base-300 flex flex-col"
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
                              <div :if={task.due_at || task.estimated_minutes || repeat_label(task.repeat, task.repeat_every) || task.waiting} class="text-xs mt-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-base-content/70">
                                <span :if={task.due_at} class="inline-flex items-center gap-1">
                                  <.icon name="hero-clock" class="size-3.5" />
                                  <span>{format_due(task.due_at)}</span>
                                </span>
                                <.estimate_chip minutes={task.estimated_minutes} />
                                <span :if={repeat_label(task.repeat, task.repeat_every)} class="inline-flex items-center gap-1" title="Repeats">
                                  <.icon name="hero-arrow-path" class="size-3.5" />
                                  <span>{repeat_label(task.repeat, task.repeat_every)}</span>
                                </span>
                                <span :if={task.waiting} class="inline-flex items-center gap-1" title="Waiting">
                                  <span>⏳</span>
                                  <span>Waiting</span>
                                </span>
                              </div>
                              <.goal_chips goals={@task_goals[task.id]} linked={false} />
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
                      <div :if={@scope in [:today, :upcoming, :anytime, :waiting]} class="p-2 border-t border-base-300">
                        <%!-- `return_to` tells the board LV where to push_navigate when the
                             modal closes (cancel or save), so the user lands back on the
                             smart-list view they came from rather than stuck on the board's
                             All tab. --%>
                        <.link
                          navigate={~p"/boards/#{b.board.id}?new=task:#{col.category.id}&return_to=#{return_path(@scope)}"}
                          class="btn btn-ghost btn-xs w-full justify-start"
                        >
                          + Add task
                        </.link>
                      </div>
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
