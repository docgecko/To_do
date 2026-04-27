defmodule ToDo.Repo.Migrations.AddRepeatIntervalAndUntil do
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :repeat_every, :integer, default: 1, null: false
      add :repeat_until, :utc_datetime
    end

    # Migrate existing repeat values from adverbs to singular noun units so
    # they read naturally with `repeat_every` ("Every 2 weeks", "Weekly", …).
    execute "UPDATE tasks SET repeat = 'day'   WHERE repeat = 'daily'"
    execute "UPDATE tasks SET repeat = 'week'  WHERE repeat = 'weekly'"
    execute "UPDATE tasks SET repeat = 'month' WHERE repeat = 'monthly'"
    execute "UPDATE tasks SET repeat = 'year'  WHERE repeat = 'yearly'"
  end

  def down do
    execute "UPDATE tasks SET repeat = 'daily'   WHERE repeat = 'day'"
    execute "UPDATE tasks SET repeat = 'weekly'  WHERE repeat = 'week'"
    execute "UPDATE tasks SET repeat = 'monthly' WHERE repeat = 'month'"
    execute "UPDATE tasks SET repeat = 'yearly'  WHERE repeat = 'year'"

    alter table(:tasks) do
      remove :repeat_until
      remove :repeat_every
    end
  end
end
