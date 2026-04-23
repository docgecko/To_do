defmodule ToDo.Boards.Board do
  use Ecto.Schema
  import Ecto.Changeset

  schema "boards" do
    field :name, :string
    field :color, :string
    field :position, :integer, default: 0
    field :permission, :string, virtual: true

    belongs_to :owner, ToDo.Accounts.User
    has_many :categories, ToDo.Boards.Category, preload_order: [asc: :position]
    has_many :groups, ToDo.Boards.Category,
      where: [parent_id: nil],
      preload_order: [asc: :position]
    has_many :board_shares, ToDo.Boards.BoardShare

    timestamps(type: :utc_datetime)
  end

  def changeset(board, attrs) do
    board
    |> cast(attrs, [:name, :color, :position, :owner_id])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, max: 100)
  end
end
