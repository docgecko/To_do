defmodule ToDo.Repo.Migrations.CreateGoals do
  use Ecto.Migration

  def change do
    # Goals are personal, long-running outcomes tasks ladder up to. A
    # user owns a goal; tasks are associated to it via `task_goals`
    # (many-to-many, since a shared task can be tagged to different
    # goals by different collaborators — each user tags to their own).
    create table(:goals) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false, size: 200
      add :description, :text
      add :color, :string
      add :target_date, :date
      add :status, :string, null: false, default: "active"
      add :position, :integer, null: false, default: 0
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:goals, [:user_id, :status])

    # Join table. Because each goal has a user_id, we don't repeat it
    # here — the "whose tag is this" comes from goal.user_id. Deleting
    # either the task or the goal removes the tag; that's the whole
    # point of nilify-free cascades in a join table.
    create table(:task_goals) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :goal_id, references(:goals, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:task_goals, [:task_id, :goal_id])
    create index(:task_goals, [:goal_id])
  end
end
