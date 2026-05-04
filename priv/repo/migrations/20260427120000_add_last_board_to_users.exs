defmodule ToDo.Repo.Migrations.AddLastBoardToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_board_id, references(:boards, on_delete: :nilify_all)
    end

    create index(:users, [:last_board_id])
  end
end
