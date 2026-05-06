import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/to_do start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :to_do, ToDoWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Local libsql DB file (also serves as the embedded-replica when paired
  # with Turso). On Fly.io point this at a persistent volume (e.g.
  # `/data/to_do.db`).
  replica_path = System.get_env("REPLICA_PATH") || "/data/to_do.db"

  # Optional Turso config — when both env vars are set, the libsql adapter
  # turns on automatic sync between the local replica and the Turso primary.
  turso_url = System.get_env("TURSO_DATABASE_URL")
  turso_token = System.get_env("TURSO_AUTH_TOKEN")

  base_repo_config = [
    database: replica_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
  ]

  repo_config =
    if turso_url && turso_token do
      base_repo_config ++ [uri: turso_url, auth_token: turso_token, sync: true]
    else
      base_repo_config
    end

  config :to_do, ToDo.Repo, repo_config

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :to_do, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :to_do, ToDoWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base
  # `force_ssl` is a compile-time Endpoint setting and lives in `config/prod.exs`.

  # ----- Production mailer (Resend) ----------------------------------------
  resend_api_key = System.get_env("RESEND_API_KEY")

  config :to_do, ToDo.Mailer,
    adapter: Swoosh.Adapters.Resend,
    api_key: resend_api_key

  # ----- Avatar storage (S3-compatible: R2 / Tigris / AWS / MinIO / …) -----
  # When all five envs are set, switch the storage backend to S3.
  # Otherwise fall through to the local-disk default — useful for self-hosted
  # deploys that don't want object storage.
  #
  # For Cloudflare R2:
  #   S3_ENDPOINT     = <account-id>.r2.cloudflarestorage.com
  #   S3_REGION       = auto
  #   S3_BUCKET       = orelle-avatars
  #   S3_PUBLIC_BASE  = https://pub-<hash>.r2.dev   (or custom domain)
  #   S3_ACCESS_KEY_ID, S3_SECRET_ACCESS_KEY = R2 API token credentials
  s3_endpoint = System.get_env("S3_ENDPOINT")
  s3_bucket = System.get_env("S3_BUCKET")
  s3_public_base = System.get_env("S3_PUBLIC_BASE")
  s3_access_key = System.get_env("S3_ACCESS_KEY_ID")
  s3_secret_key = System.get_env("S3_SECRET_ACCESS_KEY")

  if s3_endpoint && s3_bucket && s3_public_base && s3_access_key && s3_secret_key do
    config :to_do, :avatar_storage, ToDo.AvatarStorage.S3

    config :to_do, :avatar_storage_s3,
      bucket: s3_bucket,
      public_base: s3_public_base

    config :ex_aws,
      access_key_id: s3_access_key,
      secret_access_key: s3_secret_key,
      region: System.get_env("S3_REGION") || "auto"

    config :ex_aws, :s3,
      scheme: "https://",
      host: s3_endpoint,
      region: System.get_env("S3_REGION") || "auto"
  end

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :to_do, ToDoWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :to_do, ToDoWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

end
