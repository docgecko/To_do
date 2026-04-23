defmodule ToDo.Boards.BoardShare do
  use Ecto.Schema
  import Ecto.Changeset

  @permissions ~w(view edit)

  schema "board_shares" do
    field :permission, :string

    belongs_to :board, ToDo.Boards.Board
    belongs_to :user, ToDo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:board_id, :user_id, :permission])
    |> validate_required([:board_id, :user_id, :permission])
    |> validate_inclusion(:permission, @permissions)
    |> unique_constraint([:board_id, :user_id])
  end
end
