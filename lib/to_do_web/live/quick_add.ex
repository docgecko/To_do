defmodule ToDoWeb.QuickAdd do
  @moduledoc """
  ⌘K capture box, rendered once in the app shell so it exists on every
  page. Open/closed state lives here (not client-side) so it survives
  re-renders; the `QuickAdd` JS hook just forwards ⌘K / Esc / the header
  "+" button and keeps the input focused. Enter captures and closes the
  box; the hook shows a short "Captured to Inbox" toast so the save is
  visible even though the box is gone.
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
      {:ok, item} ->
        {:noreply,
         socket
         |> assign(:open, false)
         |> assign(:form, blank_form())
         |> push_event("quick-add:captured", %{title: item.title})}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "item"))}
    end
  end

  defp blank_form, do: to_form(Item.changeset(%Item{}, %{}), as: "item")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="QuickAdd" phx-target={@myself}>
      <div
        data-quick-add-modal
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
            <div class="text-xs text-base-content/60">
              Enter to capture · it lands in your Inbox to triage later
            </div>
          </.form>
        </div>
      </div>

      <%!-- Shown by the hook for ~2.5s after a capture. phx-update="ignore"
           so LiveView doesn't re-hide it mid-toast. --%>
      <div
        id={"#{@id}-toast"}
        data-quick-add-toast
        phx-update="ignore"
        role="status"
        hidden
        class="fixed bottom-4 right-4 z-[70] flex items-center gap-2 rounded-lg bg-base-100 border border-base-300 shadow-lg px-3 py-2 text-sm"
      >
        <.icon name="hero-inbox-arrow-down" class="size-4 text-primary shrink-0" />
        <span class="font-medium">Captured to Inbox</span>
        <span data-toast-title class="text-base-content/60 truncate max-w-[14rem]"></span>
      </div>
    </div>
    """
  end
end
