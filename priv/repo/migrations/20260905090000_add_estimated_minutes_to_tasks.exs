defmodule ToDo.Repo.Migrations.AddEstimatedMinutesToTasks do
  use Ecto.Migration

  def change do
    # Optional per-task effort estimate. Feeds the running "~5h committed"
    # total on Today and, later, the daily planning flow. Minutes rather
    # than a duration type so the form can be a plain number input.
    alter table(:tasks) do
      add :estimated_minutes, :integer
    end
  end
end
