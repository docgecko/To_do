defmodule ToDo.Repo.Migrations.AddWaitingFlags do
  use Ecto.Migration

  def up do
    alter table(:categories) do
      add :waiting, :boolean, default: false, null: false
    end

    alter table(:tasks) do
      add :waiting, :boolean, default: false, null: false
    end

    create index(:categories, [:waiting])
    create index(:tasks, [:waiting])

    # Migrate existing categories whose name starts with "waiting" (case-insensitive)
    # so the previous name-based heuristic continues to work for existing data.
    execute "UPDATE categories SET waiting = TRUE WHERE LOWER(name) LIKE 'waiting%'"
  end

  def down do
    drop index(:tasks, [:waiting])
    drop index(:categories, [:waiting])

    alter table(:tasks) do
      remove :waiting
    end

    alter table(:categories) do
      remove :waiting
    end
  end
end
