defmodule ToDo.Repo.Migrations.CreateCategories do
  use Ecto.Migration

  def change do
    create table(:categories) do
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      add :color, :string
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :parent_id, references(:categories, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:categories, [:board_id])
    create index(:categories, [:parent_id])
  end
end
