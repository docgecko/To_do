defmodule ToDo.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :title, :string, null: false
      add :notes, :text
      add :position, :integer, null: false, default: 0
      add :done, :boolean, null: false, default: false
      add :category_id, references(:categories, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:tasks, [:category_id])
    create index(:tasks, [:created_by_id])
  end
end
