defmodule ToDo.Repo.Migrations.AddRepeatToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :repeat, :string
    end
  end
end
