defmodule ToDo.Repo.Migrations.CreateBoardShares do
  use Ecto.Migration

  def change do
    create table(:board_shares) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :permission, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:board_shares, [:board_id, :user_id])
    create index(:board_shares, [:user_id])
  end
end
