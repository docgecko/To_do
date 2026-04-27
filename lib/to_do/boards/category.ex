defmodule ToDo.Boards.Category do
  use Ecto.Schema
  import Ecto.Changeset

  schema "categories" do
    field :name, :string
    field :position, :integer, default: 0
    field :color, :string
    field :waiting, :boolean, default: false

    belongs_to :board, ToDo.Boards.Board
    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id, preload_order: [asc: :position]
    has_many :tasks, ToDo.Boards.Task, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:name, :position, :color, :waiting, :board_id, :parent_id])
    |> validate_required([:name, :board_id])
    |> validate_length(:name, max: 100)
  end
end
