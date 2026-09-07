defmodule ToDo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Prod only: apply pending migrations before anything can serve a
    # request. Closes the deploy→migrate gap that 500'd twice when the
    # schema gained a column the DB didn't have yet. Ecto.Migrator takes
    # an advisory lock, so the brief blue-green overlap is safe; if it
    # fails the machine doesn't boot, which blue-green turns into an
    # aborted deploy rather than an outage.
    if Application.get_env(:to_do, :migrate_on_boot, false), do: ToDo.Release.migrate()

    children = [
      ToDoWeb.Telemetry,
      ToDo.Repo,
      {DNSCluster, query: Application.get_env(:to_do, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ToDo.PubSub},
      # Async-task supervisor for fire-and-forget side-effects (e.g.
      # dispatching Web Push payloads from `Notifications.create_or_skip/1`
      # without blocking the calling process).
      {Task.Supervisor, name: ToDo.TaskSupervisor},
      ToDo.Notifications.Scanner,
      ToDo.Notifications.Mailer,
      # Start to serve requests, typically the last entry
      ToDoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ToDo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ToDoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
