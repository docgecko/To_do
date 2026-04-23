defmodule ToDo.Repo.Migrations.CreateBoards do
  use Ecto.Migration

  def change do
    create table(:boards) do
      add :name, :string, null: false
      add :color, :string
      add :position, :integer, null: false, default: 0
      add :owner_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:boards, [:owner_id])
  end
end
