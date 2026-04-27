defmodule ToDo.Repo.Migrations.AddDueAtToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :due_at, :utc_datetime
    end
  end
end
