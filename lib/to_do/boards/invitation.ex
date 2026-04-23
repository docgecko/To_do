defmodule ToDo.Boards.Invitation do
  use Ecto.Schema
  import Ecto.Changeset

  @permissions ~w(view edit)

  schema "invitations" do
    field :email, :string
    field :permission, :string
    field :token, :string
    field :expires_at, :utc_datetime
    field :accepted_at, :utc_datetime

    belongs_to :board, ToDo.Boards.Board
    belongs_to :task, ToDo.Boards.Task
    belongs_to :invited_by, ToDo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [
      :email,
      :permission,
      :token,
      :expires_at,
      :accepted_at,
      :board_id,
      :task_id,
      :invited_by_id
    ])
    |> validate_required([:email, :permission, :token, :expires_at])
    |> validate_inclusion(:permission, @permissions)
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_target()
    |> unique_constraint(:token)
  end

  defp validate_target(changeset) do
    board_id = get_field(changeset, :board_id)
    task_id = get_field(changeset, :task_id)

    case {board_id, task_id} do
      {nil, nil} -> add_error(changeset, :base, "must target a board or task")
      {_, _} when not is_nil(board_id) and not is_nil(task_id) ->
        add_error(changeset, :base, "cannot target both a board and a task")
      _ -> changeset
    end
  end
end
