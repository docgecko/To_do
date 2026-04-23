defmodule ToDo.Boards.TaskShare do
  use Ecto.Schema
  import Ecto.Changeset

  @permissions ~w(view edit)

  schema "task_shares" do
    field :permission, :string

    belongs_to :task, ToDo.Boards.Task
    belongs_to :user, ToDo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:task_id, :user_id, :permission])
    |> validate_required([:task_id, :user_id, :permission])
    |> validate_inclusion(:permission, @permissions)
    |> unique_constraint([:task_id, :user_id])
  end
end
