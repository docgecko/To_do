defmodule ToDo.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    email_type = if repo().__adapter__() == Ecto.Adapters.Postgres, do: :citext, else: :string

    create table(:invitations) do
      add :email, email_type, null: false
      add :permission, :string, null: false
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :accepted_at, :utc_datetime
      add :board_id, references(:boards, on_delete: :delete_all)
      add :task_id, references(:tasks, on_delete: :delete_all)
      add :invited_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:invitations, [:token])
    create index(:invitations, [:email])
    create index(:invitations, [:board_id])
    create index(:invitations, [:task_id])

    if repo().__adapter__() == Ecto.Adapters.Postgres do
      create constraint(:invitations, :invitation_target,
               check: "(board_id IS NOT NULL) <> (task_id IS NOT NULL)")
    else
      # SQLite/libsql doesn't support ALTER TABLE ADD CONSTRAINT.
      # The same invariant ("exactly one of board_id / task_id") is enforced
      # at the application layer in `ToDo.Boards.create_invitation/1`.
      :ok
    end
  end
end
