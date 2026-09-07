defmodule ToDo.Repo.Migrations.CreateTaskPlansAndDayReviews do
  use Ecto.Migration

  def change do
    # A task's place in ONE user's day. Per-user (like goal tags and
    # list ordering) so a shared board never shares a plan. A task is
    # in at most one of a user's days — deferring moves the row.
    create table(:task_plans) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :planned_on, :date, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:task_plans, [:user_id, :task_id])
    create index(:task_plans, [:user_id, :planned_on, :position])

    # Snapshot written at wrap-up. Counts are frozen at that moment so
    # later deferrals don't rewrite history; this is what a weekly
    # digest ("finished 23 of 31 planned") will read from.
    create table(:day_reviews) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :planned_count, :integer, null: false, default: 0
      add :done_count, :integer, null: false, default: 0
      add :planned_minutes, :integer, null: false, default: 0
      add :done_minutes, :integer, null: false, default: 0
      add :reflection, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:day_reviews, [:user_id, :date])

    # Planning preferences. timezone drives the day boundary for
    # Today/Upcoming and planned_on; previously everything was UTC.
    alter table(:users) do
      add :daily_capacity_minutes, :integer, null: false, default: 360
      add :timezone, :string, null: false, default: "Europe/London"
    end
  end
end
