defmodule ToDoWeb.InboxLive do
  @moduledoc """
  Triage. Left: open items, oldest first. Right: where the selected item
  goes — column (last-used preselected), due, estimate, goals, and
  whether it joins today's plan. Enter moves it and selects the next.
  """
  use ToDoWeb, :live_view

  alias ToDo.{Boards, Goals, Inbox}

  @estimates [{"15m", "15"}, {"30m", "30"}, {"1h", "60"}, {"2h", "120"}, {"Half day", "240"}]
  @dues [{"Today", "today"}, {"Tomorrow", "tomorrow"}, {"Next week", "next_week"}, {"No date", ""}]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    sidebar_board =
      case Boards.sidebar_board_for_user(user.id) do
        nil -> nil
        board -> Boards.load_board(board)
      end

    destinations = Inbox.triage_destinations(user.id)

    {:ok,
     socket
     |> assign(:sidebar_board, sidebar_board)
     |> assign(:destinations, destinations)
     |> assign(:my_goals, Goals.list_active_goals(user.id))
     |> assign(:selected_id, nil)
     |> assign(:triage, default_triage(user, destinations))
     |> load_items()}
  end

  # Board/column defaults: the user's remembered column if it still
  # exists in the destinations, else the first column of the first board.
  defp default_triage(user, destinations) do
    remembered = user.default_triage_category_id

    {board_id, category_id} =
      case find_destination(destinations, remembered) do
        {b, c} -> {b, c}
        nil ->
          case destinations do
            [%{board: b, columns: [%{id: c} | _]} | _] -> {b.id, c}
            _ -> {nil, nil}
          end
      end

    %{
      "board_id" => to_str(board_id),
      "category_id" => to_str(category_id),
      "title" => "",
      "notes" => "",
      "due" => "",
      "estimated_minutes" => "",
      "goal_ids" => [],
      "plan_today" => "false"
    }
  end

  defp find_destination(_destinations, nil), do: nil

  defp find_destination(destinations, category_id) do
    Enum.find_value(destinations, fn %{board: b, columns: cols} ->
      if Enum.any?(cols, &(&1.id == category_id)), do: {b.id, category_id}
    end)
  end

  defp load_items(socket) do
    user_id = socket.assigns.current_scope.user.id
    items = Inbox.list_open(user_id)

    selected_id =
      case {socket.assigns.selected_id, items} do
        {_, []} -> nil
        {nil, [first | _]} -> first.id
        {id, _} -> if Enum.any?(items, &(&1.id == id)), do: id, else: hd(items).id
      end

    socket
    |> assign(:items, items)
    |> assign(:selected_id, selected_id)
    |> assign(:selected, Enum.find(items, &(&1.id == selected_id)))
    |> seed_text_from_selection()
  end

  # Title/notes in the form follow the selected item unless the user has
  # already started editing them for this item.
  defp seed_text_from_selection(%{assigns: %{selected: nil}} = socket), do: socket

  defp seed_text_from_selection(%{assigns: %{selected: item, triage: triage}} = socket) do
    assign(socket, :triage, Map.merge(triage, %{"title" => item.title, "notes" => item.notes || ""}))
  end

  # Live count updates (from the :mount_inbox hook) mean another tab or
  # Quick Add changed the queue — reload, keeping the current selection.
  @impl true
  def handle_info({:inbox, :changed, _count}, socket), do: {:noreply, load_items(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_id, String.to_integer(id)) |> load_items()}
  end

  # From the InboxKeys hook — only fires when focus isn't in a field.
  def handle_event("key", %{"key" => key}, socket) do
    case key do
      "j" -> {:noreply, move_selection(socket, 1)}
      "k" -> {:noreply, move_selection(socket, -1)}
      "d" -> discard_selected(socket)
      "t" -> {:noreply, set_triage(socket, "due", "today")}
      "n" -> {:noreply, set_triage(socket, "due", "")}
      n when n in ["1", "2", "3", "4", "5"] ->
        {_, mins} = Enum.at(@estimates, String.to_integer(n) - 1)
        {:noreply, set_triage(socket, "estimated_minutes", mins)}
      _ -> {:noreply, socket}
    end
  end

  # The quick-pick buttons send `phx-value-to`, not `phx-value-value`: the
  # LiveView client overwrites a "value" key with the button element's own
  # (empty) value property, so a `phx-value-value` never reaches the server.
  def handle_event("set", %{"field" => field, "to" => value}, socket) do
    {:noreply, set_triage(socket, field, value)}
  end

  def handle_event("validate", %{"triage" => params}, socket) do
    triage = Map.merge(socket.assigns.triage, params)

    # Switching board: snap the column to that board's first column.
    triage =
      if params["board_id"] && params["board_id"] != socket.assigns.triage["board_id"] do
        Map.put(triage, "category_id", first_column_of(socket.assigns.destinations, params["board_id"]))
      else
        triage
      end

    {:noreply, assign(socket, :triage, triage)}
  end

  def handle_event("triage", %{"triage" => params}, socket) do
    case socket.assigns.selected do
      nil ->
        {:noreply, socket}

      item ->
        user = socket.assigns.current_scope.user
        attrs = Map.merge(socket.assigns.triage, params)

        case Inbox.triage(item, user, attrs) do
          {:ok, task} ->
            # Keep the destination for the next item; clear per-item fields.
            triage =
              attrs
              |> Map.merge(%{"due" => "", "estimated_minutes" => "", "goal_ids" => [], "plan_today" => "false"})

            {:noreply,
             socket
             |> assign(:triage, triage)
             |> assign(:selected_id, next_after(socket.assigns.items, item.id))
             |> put_flash(:info, "Moved “#{task.title}”.")
             |> load_items()
             |> ToDoWeb.UserAuth.refresh_sidebar_goals()}

          {:error, :forbidden} ->
            {:noreply, put_flash(socket, :error, "Pick a column on a board you can edit.")}

          {:error, %Ecto.Changeset{} = cs} ->
            msg = cs.errors |> Enum.map(fn {f, {m, _}} -> "#{f} #{m}" end) |> Enum.join(", ")
            {:noreply, put_flash(socket, :error, "Couldn't move it: #{msg}")}
        end
    end
  end

  def handle_event("discard", %{"id" => id}, socket) do
    socket = assign(socket, :selected_id, String.to_integer(id)) |> load_items()
    discard_selected(socket)
  end

  defp discard_selected(%{assigns: %{selected: nil}} = socket), do: {:noreply, socket}

  defp discard_selected(%{assigns: %{selected: item, items: items}} = socket) do
    {:ok, _} = Inbox.discard(item)

    {:noreply,
     socket
     |> assign(:selected_id, next_after(items, item.id))
     |> put_flash(:info, "Moved to Trash — restore it from there if you change your mind.")
     |> load_items()}
  end

  defp move_selection(%{assigns: %{items: [], selected_id: _}} = socket, _), do: socket

  defp move_selection(%{assigns: %{items: items, selected_id: sel}} = socket, delta) do
    idx = Enum.find_index(items, &(&1.id == sel)) || 0
    new_idx = idx + delta

    if new_idx >= 0 and new_idx < length(items) do
      socket |> assign(:selected_id, Enum.at(items, new_idx).id) |> load_items()
    else
      socket
    end
  end

  # After removing `id`, select the item that was next (or the last one).
  defp next_after(items, id) do
    case Enum.find_index(items, &(&1.id == id)) do
      nil -> nil
      idx ->
        remaining = List.delete_at(items, idx)
        case Enum.at(remaining, idx) || List.last(remaining) do
          nil -> nil
          item -> item.id
        end
    end
  end

  defp set_triage(socket, field, value) do
    assign(socket, :triage, Map.put(socket.assigns.triage, field, value))
  end

  defp first_column_of(destinations, board_id) do
    case Enum.find(destinations, &(to_str(&1.board.id) == to_str(board_id))) do
      %{columns: [%{id: id} | _]} -> to_str(id)
      _ -> ""
    end
  end

  defp columns_for(destinations, board_id) do
    case Enum.find(destinations, &(to_str(&1.board.id) == to_str(board_id))) do
      %{columns: cols} -> cols
      _ -> []
    end
  end

  defp to_str(nil), do: ""
  defp to_str(v), do: to_string(v)

  defp estimates, do: @estimates
  defp dues, do: @dues

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell
      flash={@flash}
      current_scope={@current_scope}
      page_title="Inbox"
      active={:inbox}
      current_board={@sidebar_board}
      unread_notifications={@unread_notifications}
      recent_notifications={@recent_notifications}
      sidebar_goals={@sidebar_goals}
      sidebar_goal_progress={@sidebar_goal_progress}
      inbox_count={@inbox_count}
    >
      <div id="inbox-keys" phx-hook="InboxKeys" class="space-y-4">
        <div class="flex items-center justify-between gap-3 flex-wrap">
          <p class="text-sm text-base-content/60">
            Process oldest first. <kbd class="kbd kbd-xs">J</kbd>/<kbd class="kbd kbd-xs">K</kbd> select ·
            <kbd class="kbd kbd-xs">Enter</kbd> move · <kbd class="kbd kbd-xs">D</kbd> discard ·
            <kbd class="kbd kbd-xs">T</kbd> today · <kbd class="kbd kbd-xs">1</kbd>–<kbd class="kbd kbd-xs">5</kbd> effort
          </p>
          <button type="button" phx-click={JS.dispatch("orelle:quick-add")} class="btn btn-sm btn-outline">
            <.icon name="hero-plus" class="size-4" /> Capture <kbd class="kbd kbd-xs hidden sm:inline-flex">⌘K</kbd>
          </button>
        </div>

        <div :if={@items == []} class="text-center text-base-content/60 py-16 border border-dashed border-base-300 rounded">
          Nothing to process.
          <div class="text-sm mt-1">Press <kbd class="kbd kbd-xs">⌘K</kbd> anywhere to capture something.</div>
        </div>

        <div :if={@items != []} class="grid grid-cols-1 lg:grid-cols-5 gap-6">
          <%!-- Queue --%>
          <section class="lg:col-span-2 space-y-2">
            <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Inbox · {length(@items)}
            </h2>
            <ul class="border border-base-300 rounded divide-y divide-base-300">
              <li
                :for={item <- @items}
                id={"inbox-item-#{item.id}"}
                phx-click="select"
                phx-value-id={item.id}
                class={[
                  "flex items-start gap-3 p-3 cursor-pointer",
                  item.id == @selected_id && "bg-primary/10 border-l-2 border-l-primary",
                  item.id != @selected_id && "bg-base-100 hover:bg-base-200/60"
                ]}
              >
                <div class="flex-1 min-w-0">
                  <div class="break-words leading-tight">{item.title}</div>
                  <div :if={item.notes && item.notes != ""} class="text-xs text-base-content/60 leading-tight whitespace-pre-line line-clamp-2">{item.notes}</div>
                  <div class="text-xs text-base-content/40 mt-1">captured {Calendar.strftime(item.inserted_at, "%a %-d %b · %H:%M")}</div>
                </div>
                <button
                  type="button"
                  phx-click="discard"
                  phx-value-id={item.id}
                  class="btn btn-ghost btn-xs btn-square text-base-content/40 hover:text-error"
                  title="Discard (to Trash)"
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </li>
            </ul>
          </section>

          <%!-- Triage form --%>
          <section :if={@selected} class="lg:col-span-3 lg:sticky lg:top-4 self-start">
            <form id="triage-form" phx-change="validate" phx-submit="triage" class="border border-base-300 rounded p-4 space-y-4 bg-base-100">
              <input type="hidden" name="triage[due]" value={@triage["due"]} />
              <input type="hidden" name="triage[estimated_minutes]" value={@triage["estimated_minutes"]} />

              <.input name="triage[title]" value={@triage["title"]} type="text" label="Title" />
              <.input name="triage[notes]" value={@triage["notes"]} type="textarea" rows="2" label="Notes" />

              <div :if={@destinations == []} class="text-sm text-warning-content bg-warning/20 rounded px-3 py-2">
                You don't have a board with any columns yet — create one first, then come back to triage.
              </div>

              <div :if={@destinations != []} class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                <.input
                  name="triage[board_id]"
                  value={@triage["board_id"]}
                  type="select"
                  label="Board"
                  options={Enum.map(@destinations, &{&1.board.name, &1.board.id})}
                />
                <.input
                  name="triage[category_id]"
                  value={@triage["category_id"]}
                  type="select"
                  label="Column"
                  options={Enum.map(columns_for(@destinations, @triage["board_id"]), &{&1.label, &1.id})}
                />
              </div>

              <div>
                <label class="label pb-1"><span class="label-text font-medium">When</span></label>
                <div class="flex flex-wrap gap-1">
                  <button
                    :for={{label, v} <- dues()}
                    type="button"
                    phx-click="set"
                    phx-value-field="due"
                    phx-value-to={v}
                    class={["btn btn-xs", @triage["due"] == v && "btn-primary", @triage["due"] != v && "btn-ghost"]}
                  >
                    {label}
                  </button>
                </div>
              </div>

              <div>
                <label class="label pb-1"><span class="label-text font-medium">Effort</span></label>
                <div class="flex flex-wrap gap-1">
                  <button
                    :for={{{label, v}, i} <- Enum.with_index(estimates(), 1)}
                    type="button"
                    phx-click="set"
                    phx-value-field="estimated_minutes"
                    phx-value-to={v}
                    class={["btn btn-xs", @triage["estimated_minutes"] == v && "btn-primary", @triage["estimated_minutes"] != v && "btn-ghost"]}
                    title={"Press #{i}"}
                  >
                    {label}
                  </button>
                  <button type="button" phx-click="set" phx-value-field="estimated_minutes" phx-value-to="" class="btn btn-ghost btn-xs">
                    Clear
                  </button>
                </div>
              </div>

              <div :if={@my_goals != []}>
                <label class="label pb-1"><span class="label-text font-medium">Goals</span></label>
                <input type="hidden" name="triage[goal_ids][]" value="" />
                <div class="flex flex-wrap gap-x-4 gap-y-1">
                  <label :for={goal <- @my_goals} class="flex items-center gap-2 cursor-pointer text-sm">
                    <input
                      type="checkbox"
                      name="triage[goal_ids][]"
                      value={goal.id}
                      checked={to_string(goal.id) in (@triage["goal_ids"] || [])}
                      class="checkbox checkbox-sm"
                    />
                    <span class="w-2 h-2 rounded shrink-0" style={"background:#{goal.color || "#3b82f6"}"} />
                    <span>{goal.name}</span>
                  </label>
                </div>
              </div>

              <label class="flex items-center gap-2 cursor-pointer text-sm">
                <input type="hidden" name="triage[plan_today]" value="false" />
                <input type="checkbox" name="triage[plan_today]" value="true" checked={@triage["plan_today"] == "true"} class="checkbox checkbox-sm" />
                <span>Add to today's plan</span>
              </label>

              <div class="flex items-center justify-between pt-2 border-t border-base-300">
                <button type="button" phx-click="discard" phx-value-id={@selected.id} class="btn btn-ghost btn-sm text-error">
                  Discard
                </button>
                <button type="submit" class="btn btn-primary btn-sm" disabled={@destinations == []}>
                  Move → <kbd class="kbd kbd-xs ml-1 hidden sm:inline-flex">Enter</kbd>
                </button>
              </div>
            </form>
          </section>
        </div>
      </div>
    </Layouts.shell>
    """
  end
end
