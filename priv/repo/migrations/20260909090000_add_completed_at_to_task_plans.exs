defmodule ToDo.Repo.Migrations.AddCompletedAtToTaskPlans do
  use Ecto.Migration

  def change do
    # A repeating task is never `done` — completing it advances its due
    # date. For the day's plan we still need "I did this today", so the
    # completed occurrence is recorded on the plan row instead.
    alter table(:task_plans) do
      add :completed_at, :utc_datetime
    end
  end
end
