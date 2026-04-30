defmodule ToDoWeb.UserLive.Settings do
  use ToDoWeb, :live_view

  on_mount {ToDoWeb.UserAuth, :require_sudo_mode}

  alias ToDo.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.shell flash={@flash} current_scope={@current_scope} page_title="Settings" unread_notifications={@unread_notifications} recent_notifications={@recent_notifications}>
      <div class="max-w-xl mx-auto space-y-6">
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Manage your account email address and password settings</:subtitle>
        </.header>
      </div>

      <%!-- Avatar --%>
      <div id="avatar-section" class="space-y-3">
        <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/60">Avatar</h2>

        <div class="flex items-start gap-4">
          <%= if @user.avatar_path do %>
            <img
              src={@user.avatar_path}
              alt="Your avatar"
              class="w-20 h-20 rounded-full object-cover border border-base-300"
            />
          <% else %>
            <div class="w-20 h-20 rounded-full bg-primary text-primary-content flex items-center justify-center text-2xl font-semibold">
              {@user.email |> String.first() |> String.upcase()}
            </div>
          <% end %>

          <div class="flex-1 space-y-2">
            <p class="text-sm text-base-content/70">
              <%= if @user.avatar_path do %>
                A circular avatar appears in the top-right user menu and across the app.
              <% else %>
                Upload an image and crop it to a circular avatar.
              <% end %>
            </p>

            <div id="avatar-cropper" phx-hook="AvatarCropper">
              <form phx-change="validate_avatar" phx-submit="validate_avatar">
                <%!-- Hidden upload input — receives the cropped blob from the JS hook. --%>
                <.live_file_input upload={@uploads.avatar} data-cropper-output class="hidden" />
              </form>

              <div class="flex flex-wrap gap-2">
                <label class="btn btn-primary btn-sm cursor-pointer">
                  <.icon name="hero-arrow-up-tray" class="size-4" />
                  <span>{if @user.avatar_path, do: "Change", else: "Upload"}</span>
                  <input type="file" accept="image/*" data-cropper-input class="hidden" />
                </label>

                <button
                  :if={@user.avatar_path}
                  type="button"
                  phx-click="remove_avatar"
                  data-confirm="Remove your avatar?"
                  class="btn btn-ghost btn-sm text-error"
                >
                  <.icon name="hero-trash" class="size-4" /> Remove
                </button>
              </div>

              <%!-- Cropper modal --%>
              <div
                data-cropper-stage
                hidden
                class="fixed inset-0 z-50 bg-black/60 backdrop-blur flex items-center justify-center p-4"
              >
                <div class="card bg-base-100 border border-base-300 shadow-xl w-full max-w-lg p-4 space-y-3">
                  <h3 class="font-semibold">Crop avatar</h3>
                  <div class="bg-base-200 rounded-lg overflow-hidden" style="height: min(60vh, 480px);">
                    <img data-cropper-image alt="Avatar source" style="display:block; max-width:100%;" />
                  </div>
                  <p class="text-xs text-base-content/60">
                    Drag the image to reposition it. Drag the crop frame's corners or edges to resize. Scroll to zoom.
                  </p>
                  <div class="flex justify-end gap-2 pt-1">
                    <button type="button" data-cropper-cancel class="btn btn-ghost btn-sm">Cancel</button>
                    <button type="button" data-cropper-save class="btn btn-primary btn-sm">Save</button>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div class="divider" />

      <.form for={@email_form} id="email_form" phx-submit="update_email" phx-change="validate_email">
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>
      </div>
    </Layouts.shell>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)
      |> assign(:user, user)
      |> allow_upload(:avatar,
        accept: ~w(.jpg .jpeg .png .webp),
        max_entries: 1,
        max_file_size: 5_000_000,
        auto_upload: true,
        progress: &handle_avatar_progress/3
      )

    {:ok, socket}
  end

  # LiveView upload progress callback. When the file finishes uploading we
  # consume it (i.e. write to disk + record the path on the user) immediately;
  # there's no separate "save" button because the cropper already gated the
  # upload to the user's chosen frame.
  defp handle_avatar_progress(:avatar, entry, socket) do
    if entry.done? do
      uploads_dir = Path.join([:code.priv_dir(:to_do), "static", "uploads", "avatars"])
      File.mkdir_p!(uploads_dir)

      user = socket.assigns.user
      filename = "#{user.id}-#{System.unique_integer([:positive])}.jpg"
      dest = Path.join(uploads_dir, filename)
      web_path = "/uploads/avatars/#{filename}"

      consume_uploaded_entry(socket, entry, fn %{path: tmp} ->
        # Best-effort cleanup of any prior avatar so we don't fill the disk.
        case user.avatar_path do
          "/uploads/" <> rest ->
            old = Path.join([:code.priv_dir(:to_do), "static", "uploads", rest])
            File.rm(old)

          _ ->
            :ok
        end

        File.cp!(tmp, dest)
        {:ok, dest}
      end)

      {:ok, updated} = Accounts.set_user_avatar(user, web_path)

      {:noreply,
       socket
       |> assign(:user, updated)
       |> assign_new_current_scope(updated)
       |> put_flash(:info, "Avatar updated.")}
    else
      {:noreply, socket}
    end
  end

  # Re-asserts current_scope so the layout's user menu picks up the new
  # avatar without needing a full page navigate.
  defp assign_new_current_scope(socket, user) do
    scope = socket.assigns.current_scope
    assign(socket, :current_scope, %{scope | user: user})
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_avatar", _params, socket) do
    # Required so the upload control posts. The actual write happens in
    # `handle_avatar_progress/3` once the upload finishes.
    {:noreply, socket}
  end

  def handle_event("remove_avatar", _params, socket) do
    user = socket.assigns.user

    case user.avatar_path do
      "/uploads/" <> rest ->
        path = Path.join([:code.priv_dir(:to_do), "static", "uploads", rest])
        File.rm(path)

      _ ->
        :ok
    end

    {:ok, updated} = Accounts.set_user_avatar(user, nil)

    {:noreply,
     socket
     |> assign(:user, updated)
     |> assign_new_current_scope(updated)
     |> put_flash(:info, "Avatar removed.")}
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
