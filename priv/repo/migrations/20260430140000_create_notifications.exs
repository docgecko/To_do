defmodule ToDo.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      # Nullable FKs: a deleted task or board shouldn't block the notification row;
      # we just lose the click-through target.
      add :task_id, references(:tasks, on_delete: :nilify_all)
      add :board_id, references(:boards, on_delete: :nilify_all)
      add :body, :string, null: false
      add :read_at, :utc_datetime
      add :email_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Idempotent inserts from the scanner: the same (user, kind, task) shouldn't
    # produce two rows. Share-events use (user, kind, board) for board_shared
    # and (user, kind, task) for task_shared — both are covered.
    create unique_index(:notifications, [:user_id, :kind, :task_id],
             name: :notifications_user_kind_task_uniq,
             where: "task_id IS NOT NULL"
           )

    create unique_index(:notifications, [:user_id, :kind, :board_id],
             name: :notifications_user_kind_board_uniq,
             where: "board_id IS NOT NULL"
           )

    create index(:notifications, [:user_id, :inserted_at])
    create index(:notifications, [:user_id, :read_at])
  end
end
