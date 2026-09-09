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

  attr :sidebar_goals, :list,
    default: [],
    doc: "the user's active/paused goals for the sidebar Goals block"

  attr :inbox_count, :integer, default: 0, doc: "open Inbox items, for the sidebar badge"

  attr :sidebar_goal_progress, :map,
    default: %{},
    doc: "goal_id => {completed, total} fractions for the sidebar Goals block"

  slot :actions
  slot :title_extra, doc: "content rendered inline next to the page title"
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <%!-- DaisyUI drawer: sidebar slides out on `< md`, always-on at `md+`.
         The hidden checkbox is the toggle target — labels on the hamburger
         and on the backdrop both flip it. No JS needed. --%>
    <div id="orelle-shell" phx-hook="PullToRefresh" class="drawer md:drawer-open min-h-screen bg-base-100">
      <input id="orelle-sidebar-drawer" type="checkbox" class="drawer-toggle" />

      <%!-- Main content side --%>
      <div class="drawer-content flex flex-col min-w-0 min-h-screen">
        <header class="h-14 shrink-0 border-b border-base-300 px-3 sm:px-6 flex items-center justify-between gap-2 sm:gap-4">
          <div class="flex items-center gap-2 sm:gap-3 min-w-0">
            <%!-- Hamburger — only on small screens. Opens the drawer. --%>
            <label
              for="orelle-sidebar-drawer"
              class="btn btn-ghost btn-sm md:hidden -ml-1"
              aria-label="Open menu"
            >
              <.icon name="hero-bars-3" class="size-5" />
            </label>
            <h1 :if={@page_title} class="text-base sm:text-lg font-semibold truncate">{@page_title}</h1>
            <span :if={@title_extra != []} class="flex items-center gap-2 min-w-0">
              {render_slot(@title_extra)}
            </span>
          </div>
          <div class="flex items-center gap-2 sm:gap-3">
            <button
              :if={@current_scope && @current_scope.user}
              type="button"
              phx-click={JS.dispatch("orelle:quick-add")}
              class="btn btn-ghost btn-sm btn-square"
              title="Quick add (⌘K)"
              aria-label="Quick add"
            >
              <.icon name="hero-plus" class="size-5" />
            </button>
            {render_slot(@actions)}
            <.notifications_bell
              :if={@current_scope && @current_scope.user}
              unread={@unread_notifications}
              recent={@recent_notifications}
            />
            <.user_menu current_scope={@current_scope} />
          </div>
        </header>
        <main class="flex-1 overflow-auto p-3 sm:p-6">
          {render_slot(@inner_block)}
        </main>
      </div>

      <%!-- ⌘K capture box — one instance per page, on every page. --%>
      <.live_component
        :if={@current_scope && @current_scope.user}
        module={ToDoWeb.QuickAdd}
        id="quick-add"
        current_scope={@current_scope}
      />

      <%!-- Drawer side (sidebar) --%>
      <div class="drawer-side z-30">
        <%!-- Backdrop click closes the drawer (only present on `< md`,
             where md:drawer-open isn't pinning it open). --%>
        <label for="orelle-sidebar-drawer" aria-label="Close menu" class="drawer-overlay"></label>
        <aside class="w-64 shrink-0 border-r border-base-300 flex flex-col bg-base-200 h-screen">
          <div class="h-14 shrink-0 px-4 border-b border-base-300 flex items-center gap-2">
            <img src={~p"/images/logo.svg"} width="24" class="shrink-0" />
            <span class="font-semibold truncate">Orelle</span>
          </div>
          <nav class="flex-1 overflow-y-auto p-3 space-y-6">
            <div class="space-y-1">
              <.nav_item href={~p"/inbox"} label="Inbox" icon="hero-inbox-arrow-down" active={@active == :inbox} badge={@inbox_count} />
              <.nav_item href={~p"/today"} label="Today" icon="hero-sun" active={@active == :today} />
              <.nav_item href={~p"/upcoming"} label="Upcoming" icon="hero-calendar-days" active={@active == :upcoming} />
              <.nav_item href={~p"/anytime"} label="Anytime" icon="hero-inbox" active={@active == :anytime} />
              <.nav_item href={~p"/waiting"} label="Waiting" icon="hero-clock" active={@active == :waiting} />
              <.nav_item href={~p"/completed"} label="Completed" icon="hero-check-circle" active={@active == :completed} />
              <.nav_item href={~p"/trash"} label="Trash" icon="hero-trash" active={@active == :trash} />
            </div>
            <%!-- Always rendered for a signed-in user (not gated on having
                 goals) — otherwise nothing in the app links to /goals and a
                 first-time user has no way to create one. --%>
            <div :if={@current_scope && @current_scope.user} class="space-y-1">
              <%!-- Header row: "Goals" links to the index; the + on the
                   right opens the create modal. The + is hover/focus-
                   revealed on desktop but always visible below md, where
                   there's no hover to reveal it. --%>
              <div class="group/goals flex items-center px-2">
                <.link
                  navigate={~p"/goals"}
                  class="flex-1 text-xs font-semibold uppercase tracking-wide text-base-content/60 hover:text-base-content"
                >
                  Goals
                </.link>
                <.link
                  navigate={~p"/goals?new=1"}
                  class="inline-flex items-center justify-center rounded p-0.5 leading-none text-base-content/50 hover:text-base-content hover:bg-base-300/60 md:opacity-0 md:group-hover/goals:opacity-100 md:focus-visible:opacity-100 transition-opacity"
                  title="Add goal"
                  aria-label="Add goal"
                >
                  <.icon name="hero-plus" class="size-4" />
                </.link>
              </div>
              <.link
                :for={goal <- Enum.take(@sidebar_goals, 8)}
                navigate={~p"/goals/#{goal.id}"}
                class={[
                  "flex items-center gap-2 px-2 py-1.5 rounded text-sm",
                  "text-base-content/80 hover:bg-base-300/60",
                  goal.status == "paused" && "opacity-50"
                ]}
                title={goal.name}
              >
                <span class="w-2 h-2 rounded shrink-0" style={"background:#{goal.color || "#3b82f6"}"} />
                <span class="flex-1 truncate">{goal.name}</span>
                <span :if={goal.status == "active"} class="text-xs text-base-content/50 shrink-0">
                  {elem(Map.get(@sidebar_goal_progress, goal.id, {0, 0}), 0)}/{elem(Map.get(@sidebar_goal_progress, goal.id, {0, 0}), 1)}
                </span>
                <span :if={goal.status == "paused"} class="text-xs text-base-content/50 shrink-0">paused</span>
              </.link>
              <.link
                :if={length(@sidebar_goals) > 8}
                navigate={~p"/goals"}
                class="block px-2 py-1 text-xs text-base-content/60 hover:text-base-content hover:underline"
              >
                View all →
              </.link>
              <%!-- Zero goals: a one-line hint so the + on the header
                   isn't the only clue. --%>
              <.link
                :if={@sidebar_goals == []}
                navigate={~p"/goals?new=1"}
                class="block px-2 py-1 text-xs text-base-content/50 hover:text-base-content hover:underline"
              >
                No goals yet — add one
              </.link>
            </div>
            <div :if={@current_board} class="space-y-1">
              <%!-- Same treatment as the Goals header: the name links to the
                   board, the + opens its new-group modal — hover/focus-
                   revealed on desktop, always visible below md. --%>
              <div class="group/board flex items-center px-2">
                <.link
                  navigate={~p"/boards/#{@current_board.id}"}
                  class="flex-1 min-w-0 truncate text-xs font-semibold uppercase tracking-wide text-base-content/60 hover:text-base-content"
                  title={@current_board.name}
                >
                  Board: {@current_board.name}
                </.link>
                <.link
                  navigate={~p"/boards/#{@current_board.id}?new=group"}
                  class="inline-flex items-center justify-center rounded p-0.5 leading-none text-base-content/50 hover:text-base-content hover:bg-base-300/60 md:opacity-0 md:group-hover/board:opacity-100 md:focus-visible:opacity-100 transition-opacity"
                  title="Add group"
                  aria-label="Add group"
                >
                  <.icon name="hero-plus" class="size-4" />
                </.link>
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
  attr :badge, :integer, default: 0, doc: "count shown at the right edge when > 0"

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
      <span class="flex-1">{@label}</span>
      <span
        :if={@badge > 0}
        class={[
          "text-xs font-medium px-1.5 rounded-full",
          @active && "bg-primary-content/20 text-primary-content",
          !@active && "bg-primary/15 text-primary"
        ]}
      >
        {@badge}
      </span>
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
      <span class="flex-1">{@label}</span>
      <span
        :if={@badge > 0}
        class={[
          "text-xs font-medium px-1.5 rounded-full",
          @active && "bg-primary-content/20 text-primary-content",
          !@active && "bg-primary/15 text-primary"
        ]}
      >
        {@badge}
      </span>
    </.link>
    """
  end

  # ---- Notifications bell ----

  attr :unread, :integer, default: 0
  attr :recent, :list, default: []

  defp notifications_bell(assigns) do
    ~H"""
    <%!-- Open/closed is driven by JS.toggle / JS.hide rather than DaisyUI's
         :focus-based dropdown. LiveView re-applies JS-command state after
         every DOM patch, so flipping a row read/unread (which re-renders
         and re-orders the list) no longer drops focus and snaps the menu
         shut. Click-away and Escape close it. --%>
    <div
      id="notifications-bell"
      class="relative"
      phx-click-away={JS.hide(to: "#notifications-menu")}
      phx-window-keydown={JS.hide(to: "#notifications-menu")}
      phx-key="Escape"
    >
      <button
        type="button"
        phx-click={JS.toggle(to: "#notifications-menu")}
        class="cursor-pointer relative p-1 rounded hover:bg-base-300/60"
        aria-label="Notifications"
        aria-controls="notifications-menu"
      >
        <.icon name="hero-bell" class="size-5" />
        <span
          :if={@unread > 0}
          class="absolute -top-0.5 -right-0.5 min-w-[1.1rem] h-[1.1rem] px-1 rounded-full bg-error text-error-content text-[0.65rem] font-semibold leading-none flex items-center justify-center"
        >
          {if @unread > 99, do: "99+", else: @unread}
        </span>
      </button>
      <div
        id="notifications-menu"
        style="display: none"
        class="absolute right-0 top-full z-10 mt-2 w-80 max-w-[90vw] bg-base-100 border border-base-300 rounded-box shadow"
      >
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
          <%!-- Each row is two sibling buttons (never nested — the HTML
               parser would split them): the body opens the target and
               marks it read; the dot on the right flips read/unread in
               place. Rows carry ids so LiveView moves rather than
               recreates them when the unread-first order changes, which
               keeps focus (and therefore the dropdown) where it was. --%>
          <li
            :for={n <- @recent}
            id={"notification-#{n.id}"}
            class={[
              "flex items-start gap-1 pl-2 pr-1 py-2 border-l-2 hover:bg-base-200/60",
              if(is_nil(n.read_at), do: "border-primary bg-primary/5", else: "border-transparent")
            ]}
          >
            <button
              type="button"
              phx-click="mark_notification_read"
              phx-value-id={n.id}
              phx-value-href={notification_target(n)}
              class="flex-1 min-w-0 text-left flex gap-2 items-start cursor-pointer"
            >
              <.icon
                name={notification_icon(n.kind)}
                class={"size-4 mt-0.5 shrink-0 " <> if(is_nil(n.read_at), do: "text-base-content/80", else: "text-base-content/40")}
              />
              <div class="flex-1 min-w-0">
                <div class={["text-sm", if(is_nil(n.read_at), do: "font-semibold", else: "text-base-content/60")]}>
                  {n.body}
                </div>
                <div class="text-xs text-base-content/50">
                  {relative_time(n.inserted_at)}
                  <span :if={is_nil(n.read_at)} class="text-primary font-medium">· Unread</span>
                  <span :if={n.read_at} class="text-base-content/40">· Read</span>
                </div>
              </div>
            </button>
            <button
              type="button"
              id={"notification-#{n.id}-toggle"}
              phx-click="toggle_notification_read"
              phx-value-id={n.id}
              title={if is_nil(n.read_at), do: "Mark as read", else: "Mark as unread"}
              aria-label={if is_nil(n.read_at), do: "Mark as read", else: "Mark as unread"}
              class="size-7 shrink-0 inline-flex items-center justify-center rounded-full hover:bg-base-300/60 cursor-pointer"
            >
              <span class={[
                "size-2.5 rounded-full border-2 border-primary",
                if(is_nil(n.read_at), do: "bg-primary", else: "bg-transparent opacity-50")
              ]} />
            </button>
          </li>
        </ul>
        <%!-- Enable iPhone lock-screen / desktop push notifications. The
             hook reveals the row only when the browser supports push AND
             permission isn't already granted; once subscribed it hides
             itself. --%>
        <div
          id="enable-push-notifications"
          phx-hook="EnablePushNotifications"
          phx-update="ignore"
          hidden
          class="px-3 py-2 border-t border-base-300"
        >
          <button
            type="button"
            data-enable-push
            class="w-full text-left flex items-center gap-2 text-sm text-primary hover:underline"
          >
            <.icon name="hero-bell-alert" class="size-4" />
            <span>Enable lock-screen notifications</span>
          </button>
        </div>
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
