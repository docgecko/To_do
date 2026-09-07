defmodule ToDoWeb.QuickAdd do
  @moduledoc """
  ⌘K capture box, rendered once in the app shell so it exists on every
  page. Open/closed state lives here (not client-side) so it survives
  re-renders; the `QuickAdd` JS hook just forwards ⌘K / Esc / the header
  "+" button and keeps the input focused. Enter captures and keeps the
  box open for the next item.
  """
  use ToDoWeb, :live_component

  alias ToDo.Inbox
  alias ToDo.Inbox.Item

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:open, fn -> false end)
     |> assign_new(:captured, fn -> 0 end)
     |> assign_new(:form, fn -> blank_form() end)}
  end

  @impl true
  def handle_event("open", _params, socket) do
    {:noreply, socket |> assign(:open, true) |> push_event("quick-add:focus", %{})}
  end

  def handle_event("close", _params, socket) do
    {:noreply, socket |> assign(:open, false) |> assign(:form, blank_form())}
  end

  def handle_event("validate", %{"item" => params}, socket) do
    changeset = %Item{} |> Item.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :form, to_form(changeset, as: "item"))}
  end

  def handle_event("capture", %{"item" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id

    case Inbox.capture(user_id, params) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(:captured, socket.assigns.captured + 1)
         |> assign(:form, blank_form())
         |> push_event("quick-add:focus", %{})}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "item"))}
    end
  end

  defp blank_form, do: to_form(Item.changeset(%Item{}, %{}), as: "item")

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="QuickAdd"
      phx-target={@myself}
      hidden={!@open}
      class="fixed inset-0 z-[60] flex items-start justify-center pt-20 sm:pt-32 px-3"
    >
      <div class="absolute inset-0 bg-base-content/40 backdrop-blur-sm" phx-click="close" phx-target={@myself}></div>
      <div class="relative w-full max-w-xl bg-base-100 rounded-xl shadow-xl border border-base-300 p-4 sm:p-5 space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Quick add</h2>
          <div class="flex items-center gap-2">
            <kbd class="kbd kbd-sm hidden sm:inline-flex">⌘K</kbd>
            <button type="button" phx-click="close" phx-target={@myself} class="btn btn-ghost btn-sm btn-circle" aria-label="Close">✕</button>
          </div>
        </div>

        <.form for={@form} phx-change="validate" phx-submit="capture" phx-target={@myself} class="space-y-2">
          <.input
            field={@form[:title]}
            placeholder="What needs doing?"
            autocomplete="off"
            phx-debounce="blur"
          />
          <textarea
            name="item[notes]"
            rows="1"
            placeholder="Note (optional)"
            class="textarea textarea-bordered textarea-sm w-full"
          >{@form[:notes].value}</textarea>
          <div class="flex items-center justify-between text-xs text-base-content/60">
            <span>Enter to capture · it lands in your Inbox to triage later</span>
            <span :if={@captured > 0} class="font-medium">Captured · {@captured}</span>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
