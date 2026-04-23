defmodule ToDo.Boards.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field :title, :string
    field :notes, :string
    field :position, :integer, default: 0
    field :done, :boolean, default: false

    belongs_to :category, ToDo.Boards.Category
    belongs_to :created_by, ToDo.Accounts.User
    has_many :task_shares, ToDo.Boards.TaskShare

    timestamps(type: :utc_datetime)
  end

  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :notes, :position, :done, :category_id, :created_by_id])
    |> validate_required([:title, :category_id])
    |> validate_length(:title, max: 500)
  end
end
