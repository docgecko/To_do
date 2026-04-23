defmodule ToDo.Repo.Migrations.CreateTaskShares do
  use Ecto.Migration

  def change do
    create table(:task_shares) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :permission, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_shares, [:task_id, :user_id])
    create index(:task_shares, [:user_id])
  end
end
