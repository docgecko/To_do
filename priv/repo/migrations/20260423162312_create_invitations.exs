defmodule ToDo.Repo.Migrations.CreateInvitations do
  use Ecto.Migration

  def change do
    create table(:invitations) do
      add :email, :citext, null: false
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

    create constraint(:invitations, :invitation_target,
             check: "(board_id IS NOT NULL) <> (task_id IS NOT NULL)")
  end
end
