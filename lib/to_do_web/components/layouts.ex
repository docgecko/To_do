defmodule ToDoWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ToDoWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :wide, :boolean, default: false, doc: "if true, inner content spans the full viewport width"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <.theme_toggle />
          </li>
        </ul>
      </div>
    </header>

    <main class={["px-4 py-8 sm:px-6 lg:px-8", !@wide && "py-20"]}>
      <div class={["space-y-4", @wide && "w-full", !@wide && "mx-auto max-w-2xl"]}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  App shell: left sidenav (smart lists + boards) and top header with user menu.
  Used by authenticated pages.
  """
  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :page_title, :string, default: nil
  attr :active, :atom, default: nil, doc: "key for highlighting the active nav item"
  attr :current_board, :any, default: nil, doc: "the board in focus, if any"
  attr :current_group_id, :any, default: nil, doc: "the currently filtered group id, if any"

  attr :unread_notifications, :integer,
    default: 0,
    doc: "unread-notification count for the current user"

  attr :recent_notifications, :list,
    default: [],
    doc: "the user's most recent notifications, for the bell-icon dropdown"

  slot :actions
  slot :title_extra, doc: "content rendered inline next to the page title"
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <div class="flex min-h-screen bg-base-100">
      <aside class="w-60 shrink-0 border-r border-base-300 flex flex-col bg-base-200/40 sticky top-0 h-screen">
        <div class="h-14 shrink-0 px-4 border-b border-base-300 flex items-center gap-2">
          <img src={~p"/images/logo.svg"} width="24" class="shrink-0" />
          <span class="font-semibold truncate">Orelle</span>
        </div>
        <nav class="flex-1 overflow-y-auto p-3 space-y-6">
          <div class="space-y-1">
            <.nav_item href={~p"/today"} label="Today" icon="hero-sun" active={@active == :today} />
            <.nav_item href={~p"/upcoming"} label="Upcoming" icon="hero-calendar-days" active={@active == :upcoming} />
            <.nav_item href={~p"/anytime"} label="Anytime" icon="hero-inbox" active={@active == :anytime} />
            <.nav_item href={~p"/waiting"} label="Waiting" icon="hero-clock" active={@active == :waiting} />
            <.nav_item href={~p"/completed"} label="Completed" icon="hero-check-circle" active={@active == :completed} />
            <.nav_item href={~p"/trash"} label="Trash" icon="hero-trash" active={@active == :trash} />
          </div>
          <div :if={@current_board} class="space-y-1">
            <div class="px-2 text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Board: {@current_board.name}
            </div>
            <.nav_item
              href={~p"/boards/#{@current_board.id}"}
              label="All"
              icon="hero-squares-2x2"
              active={@active == :board and is_nil(@current_group_id)}
              patch
            />
            <.nav_item
              :for={g <- (Map.get(@current_board, :groups) || [])}
              href={~p"/boards/#{@current_board.id}?group=#{g.id}"}
              label={g.name}
              icon="hero-folder"
              active={@active == :board and @current_group_id == g.id}
              patch
            />
          </div>
        </nav>
        <div class="p-3 border-t border-base-300">
          <.link navigate={~p"/boards"} class="btn btn-ghost btn-sm w-full justify-start">
            <.icon name="hero-rectangle-stack" class="size-4" />
            <span>Switch boards</span>
          </.link>
        </div>
      </aside>
      <div class="flex-1 flex flex-col min-w-0">
        <header class="h-14 shrink-0 border-b border-base-300 px-4 sm:px-6 flex items-center justify-between gap-4">
          <div class="flex items-center gap-3 min-w-0">
            <h1 :if={@page_title} class="text-lg font-semibold truncate">{@page_title}</h1>
            <span :if={@title_extra != []} class="flex items-center gap-2 min-w-0">
              {render_slot(@title_extra)}
            </span>
          </div>
          <div class="flex items-center gap-3">
            {render_slot(@actions)}
            <.notifications_bell
              :if={@current_scope && @current_scope.user}
              unread={@unread_notifications}
              recent={@recent_notifications}
            />
            <.user_menu current_scope={@current_scope} />
          </div>
        </header>
        <main class="flex-1 overflow-auto p-4 sm:p-6">
          {render_slot(@inner_block)}
        </main>
      </div>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :href, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :active, :boolean, default: false
  attr :patch, :boolean, default: false

  defp nav_item(%{patch: true} = assigns) do
    ~H"""
    <.link
      patch={@href}
      class={[
        "flex items-center gap-2 px-2 py-1.5 rounded text-sm",
        @active && "bg-primary text-primary-content font-medium",
        !@active && "text-base-content/80 hover:bg-base-300/60"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "flex items-center gap-2 px-2 py-1.5 rounded text-sm",
        @active && "bg-primary text-primary-content font-medium",
        !@active && "text-base-content/80 hover:bg-base-300/60"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span>{@label}</span>
    </.link>
    """
  end

  # ---- Notifications bell ----

  attr :unread, :integer, default: 0
  attr :recent, :list, default: []

  defp notifications_bell(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="cursor-pointer relative p-1 rounded hover:bg-base-300/60" aria-label="Notifications">
        <.icon name="hero-bell" class="size-5" />
        <span
          :if={@unread > 0}
          class="absolute -top-0.5 -right-0.5 min-w-[1.1rem] h-[1.1rem] px-1 rounded-full bg-error text-error-content text-[0.65rem] font-semibold leading-none flex items-center justify-center"
        >
          {if @unread > 99, do: "99+", else: @unread}
        </span>
      </div>
      <div tabindex="0" class="dropdown-content z-10 mt-2 w-80 max-w-[90vw] bg-base-100 border border-base-300 rounded-box shadow">
        <div class="flex items-center justify-between px-3 py-2 border-b border-base-300">
          <span class="font-semibold text-sm">Notifications</span>
          <button
            :if={@unread > 0}
            type="button"
            phx-click="mark_all_notifications_read"
            class="text-xs text-base-content/60 hover:text-base-content"
          >
            Mark all read
          </button>
        </div>
        <ul class="max-h-96 overflow-y-auto py-1">
          <li :if={@recent == []} class="px-3 py-6 text-center text-sm text-base-content/60">
            You're all caught up.
          </li>
          <li :for={n <- @recent} class={["px-3 py-2 cursor-pointer hover:bg-base-200/60", is_nil(n.read_at) && "bg-primary/5"]}>
            <button
              type="button"
              phx-click="mark_notification_read"
              phx-value-id={n.id}
              phx-value-href={notification_target(n)}
              class="w-full text-left flex gap-2 items-start"
            >
              <.icon name={notification_icon(n.kind)} class="size-4 mt-0.5 shrink-0 text-base-content/70" />
              <div class="flex-1 min-w-0">
                <div class={["text-sm", is_nil(n.read_at) && "font-medium"]}>{n.body}</div>
                <div class="text-xs text-base-content/50">{relative_time(n.inserted_at)}</div>
              </div>
              <span :if={is_nil(n.read_at)} class="size-2 rounded-full bg-primary mt-1.5 shrink-0" />
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp notification_icon("task_due_soon"), do: "hero-clock"
  defp notification_icon("task_overdue"), do: "hero-exclamation-triangle"
  defp notification_icon("task_shared"), do: "hero-user-plus"
  defp notification_icon("board_shared"), do: "hero-rectangle-stack"
  defp notification_icon(_), do: "hero-bell"

  defp notification_target(%{kind: "board_shared", board_id: id}) when not is_nil(id), do: "/boards/#{id}"
  defp notification_target(%{task_id: id}) when not is_nil(id), do: "/today?edit=task:#{id}"
  defp notification_target(_), do: ""

  defp relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :minute)

    cond do
      diff < 1 -> "just now"
      diff < 60 -> "#{diff}m ago"
      diff < 1440 -> "#{div(diff, 60)}h ago"
      diff < 10_080 -> "#{div(diff, 1440)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  # ---- User menu ----

  attr :current_scope, :map, default: nil

  defp user_menu(%{current_scope: nil} = assigns) do
    ~H"""
    <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
    """
  end

  defp user_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <div tabindex="0" role="button" class="cursor-pointer">
        <%= if @current_scope.user.avatar_path do %>
          <img
            src={@current_scope.user.avatar_path}
            alt="Your avatar"
            class="w-9 h-9 rounded-full object-cover border border-base-300"
          />
        <% else %>
          <div class="w-9 h-9 rounded-full bg-primary text-primary-content flex items-center justify-center text-sm font-semibold">
            {@current_scope.user.email |> String.first() |> String.upcase()}
          </div>
        <% end %>
      </div>
      <ul tabindex="0" class="dropdown-content menu bg-base-100 rounded-box z-10 mt-2 w-56 p-2 shadow border border-base-300">
        <li class="menu-title">
          <span class="truncate">{@current_scope.user.email}</span>
        </li>
        <li class="hidden [[data-theme-pref=system]_&]:block">
          <button type="button" onmousedown="event.preventDefault()" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="light" class="flex items-center gap-2 w-full">
            <.icon name="hero-computer-desktop-micro" class="size-4" /> Theme: System
          </button>
        </li>
        <li class="hidden [[data-theme-pref=light]_&]:block">
          <button type="button" onmousedown="event.preventDefault()" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="dark" class="flex items-center gap-2 w-full">
            <.icon name="hero-sun-micro" class="size-4" /> Theme: Light
          </button>
        </li>
        <li class="hidden [[data-theme-pref=dark]_&]:block">
          <button type="button" onmousedown="event.preventDefault()" phx-click={JS.dispatch("phx:set-theme")} data-phx-theme="system" class="flex items-center gap-2 w-full">
            <.icon name="hero-moon-micro" class="size-4" /> Theme: Dark
          </button>
        </li>
        <li><.link navigate={~p"/users/settings"}>Settings</.link></li>
        <li>
          <.link href={~p"/users/log-out"} method="delete">Log out</.link>
        </li>
      </ul>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
