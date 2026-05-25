defmodule ToDo.Repo.Migrations.CreateTaskListPositions do
  use Ecto.Migration

  def change do
    # Per-(user, task, scope) ordering for the smart-list LIST view.
    # Sharing means user A and user B may both see the same task in their
    # respective /today views; each user can drag their own list into a
    # different order, so the row is scoped by user_id.
    create table(:task_list_positions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :scope, :string, null: false
      add :position, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_list_positions, [:user_id, :task_id, :scope])
    create index(:task_list_positions, [:user_id, :scope, :position])
  end
end
