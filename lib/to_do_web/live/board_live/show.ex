defmodule ToDoWeb.BoardLive.Show do
  use ToDoWeb, :live_view

  alias ToDo.Boards
  alias ToDo.Boards.{Category, Task}
  alias ToDoWeb.ShareDialog

  @group_presets ~w(#fbbf24 #f97316 #f43f5e #ec4899 #8b5cf6 #3b82f6 #10b981 #64748b)

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
     |> assign(:filter_group_id, nil)
     |> assign(:share_target, nil)
     |> assign(:group_presets, @group_presets)
     |> close_modal()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter =
      case params["group"] do
        nil -> nil
        "" -> nil
        v -> String.to_integer(v)
      end

    socket = assign(socket, :filter_group_id, filter)

    case params["edit"] do
      nil -> {:noreply, socket}
      "" -> {:noreply, socket}
      target -> {:noreply, handle_edit_param(socket, target)}
    end
  end

  defp handle_edit_param(socket, target) do
    socket = open_modal_from_target(socket, target)

    # Strip the ?edit=… so refreshes don't re-open and the URL stays clean.
    qs =
      socket.assigns
      |> Map.take([:filter_group_id])
      |> case do
        %{filter_group_id: nil} -> ""
        %{filter_group_id: id} -> "?group=#{id}"
      end

    push_patch(socket, to: ~p"/boards/#{socket.assigns.board.id}" <> qs, replace: true)
  end

  defp open_modal_from_target(socket, target) do
    if not socket.assigns.can_edit? do
      put_flash(socket, :info, "You only have view access to this board.")
    else
      case String.split(target, ":", parts: 2) do
        ["task", id] -> try_open(socket, &maybe_edit_task/2, id)
        ["column", id] -> try_open(socket, &maybe_edit_column/2, id)
        ["group", id] -> try_open(socket, &maybe_edit_group/2, id)
        _ -> socket
      end
    end
  end

  defp try_open(socket, fun, id) do
    case Integer.parse(id) do
      {int_id, ""} -> fun.(socket, int_id)
      _ -> socket
    end
  rescue
    Ecto.NoResultsError -> socket
  end

  defp maybe_edit_task(socket, id) do
    task = Boards.get_task!(id)
    board_id = socket.assigns.board.id
    category = Boards.get_category!(task.category_id)

    if category.board_id == board_id do
      open_task_edit_modal(socket, task)
    else
      socket
    end
  end

  defp maybe_edit_column(socket, id) do
    category = Boards.get_category!(id)

    if category.board_id == socket.assigns.board.id and not is_nil(category.parent_id) do
      open_column_edit_modal(socket, category)
    else
      socket
    end
  end

  defp maybe_edit_group(socket, id) do
    category = Boards.get_category!(id)

    if category.board_id == socket.assigns.board.id and is_nil(category.parent_id) do
      open_group_edit_modal(socket, category)
    else
      socket
    end
  end

  @impl true
  def handle_info({ShareDialog, :closed}, socket) do
    {:noreply, assign(socket, :share_target, nil)}
  end

  # -- share dialog --

  @impl true
  def handle_event("open_share_board", _params, socket) do
    {:noreply, assign(socket, :share_target, {:board, socket.assigns.board})}
  end

  def handle_event("open_share_task", %{"id" => id}, socket) do
    task = Boards.get_task!(id)

    {:noreply,
     socket
     |> close_modal()
     |> assign(:share_target, {:tasks, [task]})}
  end

  # -- task checkbox + sort handlers (no modal) --

  def handle_event("toggle_done", %{"id" => id}, socket) do
    require_edit!(socket)
    task = Boards.get_task!(id)
    {:ok, _} = Boards.toggle_task_done(task)
    {:noreply, reload_board(socket)}
  end

  def handle_event("reorder_tasks", %{"category_id" => category_id, "task_ids" => task_ids}, socket) do
    require_edit!(socket)
    category_id = String.to_integer(category_id)
    task_ids = Enum.map(task_ids, &String.to_integer/1)
    {:ok, _} = Boards.reorder_tasks(category_id, task_ids)
    {:noreply, reload_board(socket)}
  end

  def handle_event("reorder_categories", %{"scope" => scope, "scope_id" => scope_id, "category_ids" => ids}, socket) do
    require_edit!(socket)
    ids = Enum.map(ids, &String.to_integer/1)
    scope_id = String.to_integer(scope_id)

    board_id = socket.assigns.board.id

    scope_tuple =
      case scope do
        "board" ->
          if scope_id == board_id, do: {:board, board_id}

        "parent" ->
          parent = Boards.get_category!(scope_id)
          if parent.board_id == board_id, do: {:parent, scope_id}
      end

    if scope_tuple, do: Boards.reorder_categories(scope_tuple, ids)
    {:noreply, reload_board(socket)}
  end

  def handle_event(
        "move_category",
        %{
          "category_id" => category_id,
          "to_scope" => "parent",
          "to_scope_id" => to_parent_id,
          "from_category_ids" => from_ids,
          "to_category_ids" => to_ids
        },
        socket
      ) do
    require_edit!(socket)
    board_id = socket.assigns.board.id
    category_id = String.to_integer(category_id)
    to_parent_id = String.to_integer(to_parent_id)
    from_ids = Enum.map(from_ids, &String.to_integer/1)
    to_ids = Enum.map(to_ids, &String.to_integer/1)

    to_parent = Boards.get_category!(to_parent_id)
    moved = Boards.get_category!(category_id)

    if to_parent.board_id == board_id and moved.board_id == board_id and not is_nil(moved.parent_id) do
      Boards.move_column_between_parents(board_id, category_id, to_parent_id, from_ids, to_ids)
    end

    {:noreply, reload_board(socket)}
  end

  def handle_event("move_category", _params, socket),
    do: {:noreply, reload_board(socket)}

  # -- modal open/close --

  def handle_event("close_modal", _params, socket), do: {:noreply, close_modal(socket)}

  def handle_event("show_new_group", _params, socket) do
    require_edit!(socket)
    params = %{"name" => "", "color" => "#fbbf24", "waiting" => "false"}

    {:noreply,
     socket
     |> assign(:modal, %{kind: :group, mode: :new})
     |> assign(:form_params, params)
     |> assign(:form, to_form(Category.changeset(%Category{}, params)))}
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    require_edit!(socket)
    category = Boards.get_category!(id)

    if category.board_id == socket.assigns.board.id and is_nil(category.parent_id) do
      {:noreply, open_group_edit_modal(socket, category)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_new_column", params, socket) do
    require_edit!(socket)

    preset_parent =
      case params["parent_id"] do
        nil -> nil
        "" -> nil
        v -> v
      end

    form_params = %{"name" => "", "parent_id" => preset_parent || "", "waiting" => "false"}

    {:noreply,
     socket
     |> assign(:modal, %{kind: :column, mode: :new})
     |> assign(:form_params, form_params)
     |> assign(:form, to_form(Category.changeset(%Category{}, form_params)))}
  end

  def handle_event("edit_column", %{"id" => id}, socket) do
    require_edit!(socket)
    category = Boards.get_category!(id)

    if category.board_id == socket.assigns.board.id and not is_nil(category.parent_id) do
      {:noreply, open_column_edit_modal(socket, category)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_new_task", %{"category_id" => cid}, socket) do
    require_edit!(socket)

    params = %{
      "title" => "",
      "notes" => "",
      "due_at" => "",
      "repeat" => "",
      "repeat_every" => "1",
      "repeat_until" => "",
      "waiting" => "false",
      "category_id" => cid
    }

    {:noreply,
     socket
     |> assign(:modal, %{kind: :task, mode: :new, category_id: String.to_integer(cid)})
     |> assign(:form_params, params)
     |> assign(:form, to_form(Task.changeset(%Task{}, params)))}
  end

  def handle_event("edit_task", %{"id" => id}, socket) do
    require_edit!(socket)
    task = Boards.get_task!(id)
    {:noreply, open_task_edit_modal(socket, task)}
  end

  # -- modal validation (live preview + error feedback) --

  def handle_event("validate_group", %{"category" => params}, socket) do
    subject = modal_subject(socket) || %Category{}

    changeset =
      subject
      |> Category.changeset(Map.put(params, "board_id", socket.assigns.board.id))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form_params, Map.merge(socket.assigns.form_params, params))
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("validate_column", %{"category" => params}, socket) do
    subject = modal_subject(socket) || %Category{}

    changeset =
      subject
      |> Category.changeset(Map.put(params, "board_id", socket.assigns.board.id))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form_params, Map.merge(socket.assigns.form_params, params))
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    subject = modal_subject(socket) || %Task{}

    changeset =
      subject
      |> Task.changeset(normalize_due_at(params))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form_params, Map.merge(socket.assigns.form_params, params))
     |> assign(:form, to_form(changeset))}
  end

  # -- color preset picker (groups only) --

  def handle_event("pick_color", %{"color" => color}, socket) do
    params = Map.put(socket.assigns.form_params, "color", color)
    subject = modal_subject(socket) || %Category{}

    changeset =
      subject
      |> Category.changeset(Map.put(params, "board_id", socket.assigns.board.id))
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign(:form, to_form(changeset))}
  end

  # -- save handlers --

  def handle_event("save_group", %{"category" => params}, socket) do
    require_edit!(socket)
    board_id = socket.assigns.board.id

    case socket.assigns.modal do
      %{kind: :group, mode: :new} ->
        attrs =
          params
          |> Map.put("board_id", board_id)
          |> Map.put("parent_id", nil)

        case Boards.create_category(attrs) do
          {:ok, _} -> {:noreply, socket |> close_modal() |> reload_board()}
          {:error, cs} -> {:noreply, assign(socket, :form, to_form(cs))}
        end

      %{kind: :group, mode: :edit, subject: subject} ->
        case Boards.update_category(subject, params) do
          {:ok, _} -> {:noreply, socket |> close_modal() |> reload_board()}
          {:error, cs} -> {:noreply, assign(socket, :form, to_form(cs))}
        end
    end
  end

  def handle_event("save_column", %{"category" => params}, socket) do
    require_edit!(socket)
    board_id = socket.assigns.board.id

    parent_id_str = params["parent_id"]

    cond do
      parent_id_str in [nil, ""] ->
        cs =
          (modal_subject(socket) || %Category{})
          |> Category.changeset(Map.put(params, "board_id", board_id))
          |> Ecto.Changeset.add_error(:parent_id, "is required")
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:form_params, Map.merge(socket.assigns.form_params, params))
         |> assign(:form, to_form(cs))}

      true ->
        parent = Boards.get_category!(String.to_integer(parent_id_str))

        if parent.board_id != board_id do
          {:noreply, put_flash(socket, :error, "Invalid group.")}
        else
          case socket.assigns.modal do
            %{kind: :column, mode: :new} ->
              attrs =
                params
                |> Map.put("board_id", board_id)
                |> Map.put("parent_id", parent_id_str)

              case Boards.create_category(attrs) do
                {:ok, _} -> {:noreply, socket |> close_modal() |> reload_board()}
                {:error, cs} -> {:noreply, assign(socket, :form, to_form(cs))}
              end

            %{kind: :column, mode: :edit, subject: subject} ->
              case Boards.update_category(subject, params) do
                {:ok, _} -> {:noreply, socket |> close_modal() |> reload_board()}
                {:error, cs} -> {:noreply, assign(socket, :form, to_form(cs))}
              end
          end
        end
    end
  end

  def handle_event("save_task", %{"task" => params}, socket) do
    require_edit!(socket)
    user_id = socket.assigns.current_scope.user.id
    params = normalize_due_at(params)

    case socket.assigns.modal do
      %{kind: :task, mode: :new, category_id: cid} ->
        attrs =
          params
          |> Map.put("category_id", Integer.to_string(cid))
          |> Map.put("created_by_id", user_id)

        case Boards.create_task(attrs) do
          {:ok, _} -> {:noreply, socket |> close_modal() |> reload_board()}
          {:error, cs} -> {:noreply, assign(socket, :form, to_form(cs))}
        end

      %{kind: :task, mode: :edit, subject: subject} ->
        case Boards.update_task(subject, params) do
          {:ok, _} -> {:noreply, socket |> close_modal() |> reload_board()}
          {:error, cs} -> {:noreply, assign(socket, :form, to_form(cs))}
        end
    end
  end

  # -- deletes (fired from modal) --

  def handle_event("delete_task", %{"id" => id}, socket) do
    require_edit!(socket)
    task = Boards.get_task!(id)
    {:ok, _} = Boards.delete_task(task)
    {:noreply, socket |> close_modal() |> reload_board()}
  end

  def handle_event("delete_category", %{"id" => id}, socket) do
    require_edit!(socket)
    category = Boards.get_category!(id)

    if category.board_id == socket.assigns.board.id do
      {:ok, _} = Boards.delete_category(category)
    end

    {:noreply, socket |> close_modal() |> reload_board()}
  end

  # -- helpers --

  defp open_group_edit_modal(socket, %Category{} = category) do
    params = %{
      "name" => category.name,
      "color" => category.color || "#fbbf24",
      "waiting" => to_string(category.waiting)
    }

    socket
    |> assign(:modal, %{kind: :group, mode: :edit, subject: category})
    |> assign(:form_params, params)
    |> assign(:form, to_form(Category.changeset(category, params)))
  end

  defp open_column_edit_modal(socket, %Category{} = category) do
    params = %{
      "name" => category.name,
      "parent_id" => Integer.to_string(category.parent_id),
      "waiting" => to_string(category.waiting)
    }

    socket
    |> assign(:modal, %{kind: :column, mode: :edit, subject: category})
    |> assign(:form_params, params)
    |> assign(:form, to_form(Category.changeset(category, params)))
  end

  defp open_task_edit_modal(socket, %Task{} = task) do
    params = %{
      "title" => task.title || "",
      "notes" => task.notes || "",
      "due_at" => due_input_value(task.due_at),
      "repeat" => task.repeat || "",
      "repeat_every" => to_string(task.repeat_every || 1),
      "repeat_until" => due_input_value(task.repeat_until),
      "waiting" => to_string(task.waiting),
      "category_id" => Integer.to_string(task.category_id)
    }

    socket
    |> assign(:modal, %{kind: :task, mode: :edit, subject: task})
    |> assign(:form_params, params)
    |> assign(:form, to_form(Task.changeset(task, params)))
  end

  defp close_modal(socket) do
    socket
    |> assign(:modal, nil)
    |> assign(:form_params, %{})
    |> assign(:form, nil)
  end

  defp modal_subject(%{assigns: %{modal: %{subject: subject}}}), do: subject
  defp modal_subject(_), do: nil

  defp normalize_due_at(params) do
    params
    |> normalize_datetime_field("due_at")
    |> normalize_datetime_field("repeat_until")
  end

  defp normalize_datetime_field(params, key) do
    case Map.get(params, key) do
      "" -> Map.put(params, key, nil)
      val when is_binary(val) -> Map.put(params, key, val <> ":00Z")
      _ -> params
    end
  end

  defp format_due(nil), do: nil

  defp format_due(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a %d %b %Y · %H:%M")
  end

  defp due_input_value(nil), do: ""

  defp due_input_value(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%dT%H:%M")
  end

  defp visible_groups(groups, nil), do: groups
  defp visible_groups(groups, id), do: Enum.filter(groups, &(&1.id == id))

  defp repeat_options do
    [
      {"No repeat", ""},
      {"Day(s)", "day"},
      {"Week(s)", "week"},
      {"Month(s)", "month"},
      {"Year(s)", "year"}
    ]
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

  defp find_group_by_id(_, nil), do: nil
  defp find_group_by_id(_, ""), do: nil

  defp find_group_by_id(groups, id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> Enum.find(groups, &(&1.id == int))
      _ -> nil
    end
  end

  defp find_group_by_id(groups, id) when is_integer(id) do
    Enum.find(groups, &(&1.id == id))
  end

  defp column_accent_color(groups, parent_id) do
    case find_group_by_id(groups, parent_id) do
      nil -> "#64748b"
      %{color: nil} -> "#64748b"
      %{color: c} -> c
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_scope={@current_scope} page_title={@board.name} active={:board} current_board={@board} current_group_id={@filter_group_id}>
      <:actions>
        <span :if={!@is_owner?} class="badge badge-info">{@permission}</span>
        <button
          :if={@is_owner?}
          phx-click="open_share_board"
          class="btn btn-outline btn-sm"
        >
          Share
        </button>
        <button
          :if={@can_edit?}
          phx-click="show_new_group"
          class="btn btn-primary btn-sm"
        >
          + Add group
        </button>
        <button
          :if={@can_edit? && @board.groups != []}
          phx-click="show_new_column"
          class="btn btn-primary btn-sm"
        >
          + Add column
        </button>
      </:actions>

      <%!-- Group modal --%>
      <.form_modal
        :if={@modal && @modal.kind == :group}
        id="group-modal"
        title={if @modal.mode == :new, do: "Create a group", else: "Edit group"}
        accent_color={@form_params["color"] || "#fbbf24"}
        on_cancel="close_modal"
      >
        <.form
          for={@form}
          phx-change="validate_group"
          phx-submit="save_group"
          class="space-y-5"
        >
          <.input
            field={@form[:name]}
            label="Name"
            placeholder="e.g. Functional, Operational, Waiting"
            required
            autofocus
          />

          <div>
            <label class="label pb-1.5">
              <span class="label-text font-medium">Color</span>
            </label>
            <.color_picker
              presets={@group_presets}
              selected={@form_params["color"] || "#fbbf24"}
              on_pick="pick_color"
              color_field="category[color]"
            />
          </div>

          <.input
            field={@form[:waiting]}
            type="checkbox"
            label="Treat this group as Waiting (its tasks show in the Waiting smart list)"
          />

          <div class="pt-2">
            <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
              Preview
            </div>
            <div
              class="px-3 py-2 rounded font-semibold text-white flex items-center gap-2"
              style={"background:#{@form_params["color"] || "#fbbf24"}"}
            >
              <span>
                {if @form_params["name"] in [nil, ""], do: "Group name", else: @form_params["name"]}
              </span>
              <span :if={@form_params["waiting"] == "true"} class="text-xs opacity-80">⏳ Waiting</span>
            </div>
          </div>

          <.modal_footer>
            <:destructive>
              <button
                :if={@modal.mode == :edit}
                type="button"
                phx-click="delete_category"
                phx-value-id={@modal.subject.id}
                data-confirm="Delete this group and everything in it? This cannot be undone."
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
                {if @modal.mode == :new, do: "Create group", else: "Save changes"}
              </.button>
            </:primary>
          </.modal_footer>
        </.form>
      </.form_modal>

      <%!-- Column modal --%>
      <.form_modal
        :if={@modal && @modal.kind == :column}
        id="column-modal"
        title={if @modal.mode == :new, do: "Create a column", else: "Edit column"}
        accent_color={column_accent_color(@board.groups, @form_params["parent_id"])}
        on_cancel="close_modal"
      >
        <.form
          for={@form}
          phx-change="validate_column"
          phx-submit="save_column"
          class="space-y-5"
        >
          <.input
            name="category[parent_id]"
            value={@form_params["parent_id"] || ""}
            label="Group"
            type="select"
            options={[{"Select a group…", ""} | Enum.map(@board.groups, &{&1.name, &1.id})]}
            required
          />

          <.input
            field={@form[:name]}
            label="Name"
            placeholder="e.g. Backlog, In Progress, Done"
            required
            autofocus
          />

          <.input
            field={@form[:waiting]}
            type="checkbox"
            label="Treat this column as Waiting (its tasks show in the Waiting smart list)"
          />

          <div class="pt-2">
            <div class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
              Preview
            </div>
            <div class="w-64 bg-base-100 rounded-lg shadow-sm border border-base-300">
              <div class="px-3 py-2 border-b border-base-300 font-medium text-sm bg-base-200 rounded-t-lg flex items-center justify-between gap-2">
                <span>
                  {if @form_params["name"] in [nil, ""],
                    do: "Column name",
                    else: @form_params["name"]}
                </span>
                <span :if={@form_params["waiting"] == "true"} class="text-xs text-base-content/60">
                  ⏳
                </span>
              </div>
              <div class="p-2 text-xs text-base-content/50">
                {case find_group_by_id(@board.groups, @form_params["parent_id"]) do
                  nil -> "No group selected"
                  g -> "In group: #{g.name}"
                end}
              </div>
            </div>
          </div>

          <.modal_footer>
            <:destructive>
              <button
                :if={@modal.mode == :edit}
                type="button"
                phx-click="delete_category"
                phx-value-id={@modal.subject.id}
                data-confirm="Delete this column and all its tasks? This cannot be undone."
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
                {if @modal.mode == :new, do: "Create column", else: "Save changes"}
              </.button>
            </:primary>
          </.modal_footer>
        </.form>
      </.form_modal>

      <%!-- Task modal --%>
      <.form_modal
        :if={@modal && @modal.kind == :task}
        id="task-modal"
        title={if @modal.mode == :new, do: "Create a task", else: "Edit task"}
        on_cancel="close_modal"
        max_width="max-w-xl"
      >
        <.form
          for={@form}
          phx-change="validate_task"
          phx-submit="save_task"
          class="space-y-4"
        >
          <.input
            field={@form[:title]}
            label="Title"
            placeholder="Task title"
            required
            autofocus
          />

          <.input
            field={@form[:notes]}
            type="textarea"
            label="Notes"
            rows="3"
            placeholder="Optional notes"
          />

          <div>
            <div class="flex gap-1 mb-1">
              <button type="button" data-due-set="0" class="btn btn-ghost btn-xs">Today</button>
              <button type="button" data-due-set="1" class="btn btn-ghost btn-xs">Tomorrow</button>
              <button type="button" data-due-set="clear" class="btn btn-ghost btn-xs">Clear</button>
            </div>
            <.input
              name="task[due_at]"
              value={@form_params["due_at"] || ""}
              type="datetime-local"
              label="Due"
            />
          </div>

          <div>
            <label class="label pb-1">
              <span class="label-text font-medium">Repeat</span>
            </label>
            <div class="flex items-end gap-2">
              <div class="shrink-0 w-20">
                <.input
                  name="task[repeat_every]"
                  value={@form_params["repeat_every"] || "1"}
                  type="number"
                  min="1"
                  label="Every"
                  disabled={@form_params["repeat"] in [nil, ""]}
                />
              </div>
              <div class="flex-1">
                <.input
                  name="task[repeat]"
                  value={@form_params["repeat"] || ""}
                  type="select"
                  label="Unit"
                  options={repeat_options()}
                />
              </div>
            </div>
          </div>

          <.input
            :if={@form_params["repeat"] not in [nil, ""]}
            name="task[repeat_until]"
            value={@form_params["repeat_until"] || ""}
            type="datetime-local"
            label="Repeat until (optional)"
          />

          <.input
            field={@form[:waiting]}
            type="checkbox"
            label="Mark this task as Waiting (blocked / waiting on someone else)"
          />

          <.modal_footer>
            <:destructive>
              <button
                :if={@modal.mode == :edit}
                type="button"
                phx-click="delete_task"
                phx-value-id={@modal.subject.id}
                data-confirm="Delete this task?"
                class="btn btn-ghost text-error"
              >
                Delete
              </button>
              <button
                :if={@modal.mode == :edit and @is_owner?}
                type="button"
                phx-click="open_share_task"
                phx-value-id={@modal.subject.id}
                class="btn btn-ghost"
                title="Share this task with someone else"
              >
                <.icon name="hero-share" class="size-4" /> Share
              </button>
            </:destructive>
            <:secondary>
              <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
            </:secondary>
            <:primary>
              <.button type="submit" variant="primary">
                {if @modal.mode == :new, do: "Create task", else: "Save changes"}
              </.button>
            </:primary>
          </.modal_footer>
        </.form>
      </.form_modal>

      <div class="space-y-4">
        <div class="pb-8">
          <div
            id={"board-#{@board.id}-groups"}
            phx-hook={@can_edit? && "SortableCategories"}
            data-sort-scope="board"
            data-sort-scope-id={@board.id}
            class="flex gap-6 items-start min-w-max"
          >
            <div
              :for={group <- visible_groups(@board.groups, @filter_group_id)}
              id={"group-#{group.id}"}
              data-category-id={group.id}
              class="flex flex-col gap-2 group/grp scroll-mt-20"
            >
              <div
                class="rounded-t font-semibold text-white min-w-[200px] flex items-stretch"
                style={"background:#{group.color || "#64748b"}"}
              >
                <span
                  :if={@can_edit?}
                  data-category-drag-handle
                  class="cursor-grab select-none opacity-70 hover:opacity-100 px-3 py-2 flex items-center"
                  title="Drag to reorder group"
                >⋮⋮</span>
                <button
                  :if={@can_edit?}
                  phx-click="edit_group"
                  phx-value-id={group.id}
                  class="flex-1 text-left px-3 py-2 hover:bg-white/10 transition rounded-tr cursor-pointer flex items-center gap-2"
                  title="Click to edit group"
                >
                  <span class="flex-1">{group.name}</span>
                  <span :if={group.waiting} class="text-xs opacity-80" title="Waiting group">⏳</span>
                </button>
                <div :if={!@can_edit?} class="flex-1 px-3 py-2 flex items-center gap-2">
                  <span class="flex-1">{group.name}</span>
                  <span :if={group.waiting} class="text-xs opacity-80" title="Waiting group">⏳</span>
                </div>
              </div>

              <div
                id={"group-#{group.id}-cols"}
                phx-hook={@can_edit? && "SortableCategories"}
                data-sort-scope="parent"
                data-sort-scope-id={group.id}
                class="flex gap-2 items-start min-h-[80px]"
              >
                <div
                  :for={sub <- group.children}
                  data-category-id={sub.id}
                  class="w-64 bg-base-100 rounded-lg shadow-sm border border-base-300 flex flex-col group/col"
                >
                  <div class="border-b border-base-300 bg-base-200 rounded-t-lg flex items-stretch">
                    <span
                      :if={@can_edit?}
                      data-category-drag-handle
                      class="cursor-grab select-none text-base-content/40 hover:text-base-content/70 px-3 py-2 flex items-center"
                      title="Drag to reorder column"
                    >⋮⋮</span>
                    <button
                      :if={@can_edit?}
                      phx-click="edit_column"
                      phx-value-id={sub.id}
                      class="flex-1 text-left font-medium text-sm px-3 py-2 hover:bg-base-300/60 transition rounded-tr-lg cursor-pointer flex items-center gap-2"
                      title="Click to edit column"
                    >
                      <span class="flex-1">{sub.name}</span>
                      <span :if={sub.waiting} class="text-xs text-base-content/60" title="Waiting column">⏳</span>
                    </button>
                    <div :if={!@can_edit?} class="flex-1 font-medium text-sm px-3 py-2 flex items-center gap-2">
                      <span class="flex-1">{sub.name}</span>
                      <span :if={sub.waiting} class="text-xs text-base-content/60" title="Waiting column">⏳</span>
                    </div>
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
                      class="bg-base-100 border border-base-300 rounded p-2 text-sm hover:shadow-sm hover:border-base-content/30 transition group"
                    >
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
                        <button
                          :if={@can_edit?}
                          type="button"
                          phx-click="edit_task"
                          phx-value-id={task.id}
                          class="flex-1 min-w-0 text-left cursor-pointer"
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
                        </button>
                        <div :if={!@can_edit?} class="flex-1 min-w-0">
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
                        </div>
                      </div>
                    </li>
                  </ul>

                  <div :if={@can_edit?} class="p-2 border-t border-base-300">
                    <button
                      phx-click="show_new_task"
                      phx-value-category_id={sub.id}
                      class="btn btn-ghost btn-xs w-full justify-start"
                    >
                      + Add task
                    </button>
                  </div>
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
    </Layouts.shell>
    """
  end
end
