import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :to_do, ToDo.Repo,
  database: Path.expand("../priv/data/to_do_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :to_do, ToDoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "u9+El3O0ZrUBMKuaM4ZP2wET0uIANLkg4XUQGW+ZA8Mk//ZZCkwU5YXPFMeEiS+8",
  server: false

# In test we don't send emails
config :to_do, ToDo.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Don't run the notifications scanner in tests; tests that need it can call
# `ToDo.Notifications.Scanner.scan_now/0` explicitly.
config :to_do, ToDo.Notifications.Scanner, interval_ms: :disabled
config :to_do, ToDo.Notifications.Mailer, interval_ms: :disabled
