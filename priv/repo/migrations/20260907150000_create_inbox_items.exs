defmodule ToDo.Repo.Migrations.CreateInboxItems do
  use Ecto.Migration

  def change do
    # Captured-but-unprocessed items. Deliberately NOT tasks: a task needs
    # a column, and everything downstream assumes it has one. An item
    # becomes a task at triage (see ToDo.Inbox.triage/3) and the row is
    # deleted. Discard is a soft delete so items show in Trash.
    create table(:inbox_items) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string, null: false, size: 500
      add :notes, :text
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:inbox_items, [:user_id, :deleted_at, :inserted_at])

    # Last column the user triaged into — preselected next time so most
    # triages are just Enter.
    alter table(:users) do
      add :default_triage_category_id, references(:categories, on_delete: :nilify_all)
    end
  end
end
