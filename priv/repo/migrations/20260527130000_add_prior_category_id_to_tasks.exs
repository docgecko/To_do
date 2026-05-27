defmodule ToDo.Repo.Migrations.AddPriorCategoryIdToTasks do
  use Ecto.Migration

  def change do
    # Origin column for the auto-relocate-to-Waiting feature. When a
    # task is moved into the Waiting group we stash its old column id
    # here; when the user unticks waiting we move it back. ON DELETE
    # SET NULL — if the origin column was deleted while the task was
    # in Waiting, we lose the breadcrumb but the task itself survives.
    alter table(:tasks) do
      add :prior_category_id, references(:categories, on_delete: :nilify_all)
    end

    create index(:tasks, [:prior_category_id])
  end
end
