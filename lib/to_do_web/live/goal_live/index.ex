defmodule ToDoWeb.GoalLive.Index do
  use ToDoWeb, :live_view

  alias ToDo.Boards
  alias ToDo.Goals
  alias ToDo.Goals.Goal

  # Same palette as board groups so goal chips feel native.
  @presets ~w(#fbbf24 #f97316 #f43f5e #ec4899 #8b5cf6 #3b82f6 #10b981 #64748b)

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id

    sidebar_board =
      case Boards.sidebar_board_for_user(user_id) do
        nil -> nil
        board -> Boards.load_board(board)
      end

    {:ok,
     socket
     |> assign(:sidebar_board, sidebar_board)
     |> assign(:color_presets, @presets)
     |> load_goals()
     |> close_modal()}
  end

  # Deep-link support: /goals?edit=<id> opens the edit modal directly —
  # used by the Edit button on the goal detail page.
  @impl true
  def handle_params(%{"edit" => id}, _uri, socket) when id not in [nil, ""] do
    user_id = socket.assigns.current_scope.user.id

    case Integer.parse(id) do
      {int, ""} ->
        case Goals.get_user_goal(int, user_id) do
          nil -> {:noreply, socket}
          goal -> {:noreply, open_edit_goal(socket, goal)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # `/goals?new=1` — deep-link from the sidebar's "+ Add goal" entry so
  # first-time users land straight in the create modal.
  def handle_params(%{"new" => v}, _uri, socket) when v not in [nil, ""] do
    {:noreply, open_new_goal(socket)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp load_goals(socket) do
    user_id = socket.assigns.current_scope.user.id
    goals = Goals.list_goals(user_id)
    progress = Goals.progress_for_goals(Enum.map(goals, & &1.id))

    socket
    |> assign(:goals, goals)
    |> assign(:progress, progress)
  end

  # -- modal state --

  defp close_modal(socket) do
    socket
    |> assign(:modal, nil)
    |> assign(:modal_goal, nil)
    |> assign(:form_params, %{})
    |> assign(:form, nil)
  end

  defp open_new_goal(socket) do
    params = %{"name" => "", "description" => "", "color" => "#3b82f6", "status" => "active"}

    socket
    |> assign(:modal, :new)
    |> assign(:modal_goal, nil)
    |> assign(:form_params, params)
    |> assign(:form, to_form(Goal.changeset(%Goal{}, params)))
  end

  defp open_edit_goal(socket, %Goal{} = goal) do
    params = %{
      "name" => goal.name,
      "description" => goal.description || "",
      "color" => goal.color || "#3b82f6",
      "status" => goal.status,
      "target_date" => if(goal.target_date, do: Date.to_iso8601(goal.target_date), else: "")
    }

    socket
    |> assign(:modal, :edit)
    |> assign(:modal_goal, goal)
    |> assign(:form_params, params)
    |> assign(:form, to_form(Goal.changeset(goal, params)))
  end

  # -- events --

  @impl true
  def handle_event("show_new_goal", _params, socket), do: {:noreply, open_new_goal(socket)}

  def handle_event("edit_goal", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    goal = Goals.get_user_goal!(String.to_integer(id), user_id)
    {:noreply, open_edit_goal(socket, goal)}
  end

  def handle_event("close_modal", _params, socket), do: {:noreply, close_modal(socket)}

  def handle_event("validate_goal", %{"goal" => params}, socket) do
    subject = socket.assigns.modal_goal || %Goal{}

    changeset =
      subject
      |> Goal.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form_params, Map.merge(socket.assigns.form_params, params))
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("pick_color", %{"color" => color}, socket) do
    params = Map.put(socket.assigns.form_params, "color", color)
    subject = socket.assigns.modal_goal || %Goal{}

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign(:form, to_form(Goal.changeset(subject, params)))}
  end

  def handle_event("save_goal", %{"goal" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case socket.assigns.modal do
      :new ->
        params = Map.put(params, "user_id", user_id)

        case Goals.create_goal(params) do
          {:ok, _goal} ->
            {:noreply, socket |> load_goals() |> close_modal()}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end

      :edit ->
        goal = socket.assigns.modal_goal

        case Goals.update_goal(goal, params) do
          {:ok, _goal} ->
            {:noreply, socket |> load_goals() |> close_modal()}

          {:error, changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset))}
        end
    end
  end

  def handle_event("delete_goal", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    goal = Goals.get_user_goal!(String.to_integer(id), user_id)
    {:ok, _} = Goals.delete_goal(goal)
    {:noreply, socket |> load_goals() |> close_modal()}
  end

  # -- helpers --

  defp by_status(goals, status), do: Enum.filter(goals, &(&1.status == status))

  defp pct({_done, 0}), do: 0
  defp pct({done, total}), do: round(done / total * 100)

  defp format_target(nil), do: nil
  defp format_target(%Date{} = d), do: Calendar.strftime(d, "%a %d %b %Y")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell
      flash={@flash}
      current_scope={@current_scope}
      page_title="Goals"
      active={:goals}
      current_board={@sidebar_board}
      unread_notifications={@unread_notifications}
      recent_notifications={@recent_notifications}
      sidebar_goals={@sidebar_goals}
      sidebar_goal_progress={@sidebar_goal_progress}
    >
      <:actions>
        <button :if={is_nil(@modal)} phx-click="show_new_goal" class="btn btn-primary btn-sm">
          + Add goal
        </button>
      </:actions>

      <.form_modal
        :if={@modal}
        id="goal-modal"
        title={if @modal == :new, do: "New goal", else: "Edit goal"}
        accent_color={@form_params["color"] || "#3b82f6"}
        on_cancel="close_modal"
      >
        <.form for={@form} phx-change="validate_goal" phx-submit="save_goal" class="space-y-5">
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="e.g. Ship v2 launch"
            required
            autofocus
          />

          <.input
            field={@form[:description]}
            type="textarea"
            label="Description (optional)"
            placeholder="Why this matters / what done looks like"
          />

          <div>
            <label class="label pb-1.5">
              <span class="label-text font-medium">Color</span>
            </label>
            <.color_picker
              presets={@color_presets}
              selected={@form_params["color"] || "#3b82f6"}
              on_pick="pick_color"
              color_field="goal[color]"
            />
          </div>

          <div class="grid grid-cols-2 gap-4">
            <.input
              field={@form[:target_date]}
              type="date"
              label="Target date (optional)"
            />
            <.input
              field={@form[:status]}
              type="select"
              label="Status"
              options={[
                {"Active", "active"},
                {"Paused", "paused"},
                {"Done", "done"},
                {"Abandoned", "abandoned"}
              ]}
            />
          </div>

          <.modal_footer>
            <:destructive>
              <button
                :if={@modal == :edit}
                type="button"
                phx-click="delete_goal"
                phx-value-id={@modal_goal.id}
                data-confirm="Delete this goal? Tasks keep their other tags; this cannot be undone."
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
                {if @modal == :new, do: "Create goal", else: "Save changes"}
              </.button>
            </:primary>
          </.modal_footer>
        </.form>
      </.form_modal>

      <div class="max-w-5xl space-y-8">
        <p class="text-sm text-base-content/60">
          Long-running outcomes your tasks ladder up to.
        </p>

        <section :for={{label, status} <- [{"Active", "active"}, {"Paused", "paused"}]} :if={by_status(@goals, status) != []} class="space-y-3">
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
            {label} ({length(by_status(@goals, status))})
          </h2>
          <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">
            <div
              :for={goal <- by_status(@goals, status)}
              class={[
                "relative group card bg-base-100 border border-base-300 shadow-sm hover:shadow-md hover:border-primary/40 transition overflow-hidden",
                status == "paused" && "opacity-60"
              ]}
            >
              <div class="h-2" style={"background:#{goal.color || "#3b82f6"}"}></div>
              <.link navigate={~p"/goals/#{goal.id}"} class="block card-body p-4 space-y-2">
                <h3 class="font-semibold truncate">{goal.name}</h3>
                <p :if={goal.description && goal.description != ""} class="text-xs text-base-content/60 line-clamp-2">
                  {goal.description}
                </p>
                <div class="space-y-1">
                  <div class="w-full h-1.5 bg-base-300 rounded overflow-hidden">
                    <div
                      class="h-full rounded"
                      style={"width:#{pct(@progress[goal.id] || {0, 0})}%;background:#{goal.color || "#3b82f6"}"}
                    >
                    </div>
                  </div>
                  <div class="flex items-center justify-between text-xs text-base-content/60">
                    <span>
                      {elem(@progress[goal.id] || {0, 0}, 0)} of {elem(@progress[goal.id] || {0, 0}, 1)} tasks done
                    </span>
                    <span :if={goal.target_date}>Due {format_target(goal.target_date)}</span>
                  </div>
                </div>
              </.link>
              <button
                phx-click="edit_goal"
                phx-value-id={goal.id}
                class="absolute top-3 right-3 opacity-0 group-hover:opacity-100 btn btn-ghost btn-xs"
                title="Edit goal"
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </button>
            </div>
          </div>
        </section>

        <section :for={{label, status} <- [{"Done", "done"}, {"Abandoned", "abandoned"}]} :if={by_status(@goals, status) != []} class="space-y-3">
          <details>
            <summary class="text-xs font-semibold uppercase tracking-wide text-base-content/60 cursor-pointer select-none">
              {label} ({length(by_status(@goals, status))})
            </summary>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 mt-3">
              <div
                :for={goal <- by_status(@goals, status)}
                class="relative group card bg-base-100 border border-base-300 shadow-sm overflow-hidden opacity-60"
              >
                <div class="h-2" style={"background:#{goal.color || "#3b82f6"}"}></div>
                <.link navigate={~p"/goals/#{goal.id}"} class="block card-body p-4">
                  <h3 class={["font-semibold truncate", status == "done" && "line-through"]}>{goal.name}</h3>
                  <p :if={goal.completed_at} class="text-xs text-base-content/60 mt-1">
                    Completed {Calendar.strftime(goal.completed_at, "%d %b %Y")}
                  </p>
                </.link>
                <button
                  phx-click="edit_goal"
                  phx-value-id={goal.id}
                  class="absolute top-3 right-3 opacity-0 group-hover:opacity-100 btn btn-ghost btn-xs"
                  title="Edit goal"
                >
                  <.icon name="hero-pencil-square" class="size-4" />
                </button>
              </div>
            </div>
          </details>
        </section>

        <div
          :if={@goals == []}
          class="text-center text-base-content/60 py-16 border border-dashed border-base-300 rounded-lg"
        >
          Goals are long-running outcomes your tasks ladder up to.<br />
          Click <span class="font-medium">+ Add goal</span> to create your first one.
        </div>
      </div>
    </Layouts.shell>
    """
  end
end
