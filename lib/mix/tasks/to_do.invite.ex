defmodule Mix.Tasks.ToDo.Invite do
  @shortdoc "Grant an account + magic-link login email to an email address"

  @moduledoc """
  Manually invite someone bypassing the request-an-invite form.

  Registers a `ToDo.Accounts.User` with the given email if one doesn't
  exist, then emails them a single-use magic-link login URL through the
  same flow the public registration would use. Useful for admin grants
  without the public form.

  ## Usage

      $ mix to_do.invite alice@example.com
  """

  use Mix.Task

  @impl Mix.Task
  def run([email | _]) do
    Mix.Task.run("app.start")

    url_fun = fn token ->
      ToDoWeb.Endpoint.url() <> "/users/log-in/" <> token
    end

    {:ok, user} = ToDo.InviteRequests.grant(email, url_fun)
    Mix.shell().info("Invited #{user.email} (id=#{user.id}). Magic-link email sent.")
  end

  def run(_) do
    Mix.raise("Usage: mix to_do.invite <email>")
  end
end
