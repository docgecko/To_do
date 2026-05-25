defmodule ToDo.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Push service URL the browser told us about. Unique because we
      # upsert on re-subscription rather than accumulate duplicates.
      add :endpoint, :text, null: false
      # The two key fragments needed to encrypt payloads for this device.
      add :p256dh_key, :string, null: false
      add :auth_key, :string, null: false
      # User-agent at subscription time — handy for a future "Manage
      # devices" UI so users can revoke a specific device.
      add :user_agent, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
  end
end
