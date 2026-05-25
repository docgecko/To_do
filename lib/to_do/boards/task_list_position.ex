defmodule ToDo.Boards.TaskListPosition do
  use Ecto.Schema
  import Ecto.Changeset

  @scopes ~w(today upcoming anytime waiting)

  schema "task_list_positions" do
    field :scope, :string
    field :position, :integer

    belongs_to :user, ToDo.Accounts.User
    belongs_to :task, ToDo.Boards.Task

    timestamps(type: :utc_datetime)
  end

  def scopes, do: @scopes

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:user_id, :task_id, :scope, :position])
    |> validate_required([:user_id, :task_id, :scope, :position])
    |> validate_inclusion(:scope, @scopes)
    |> unique_constraint([:user_id, :task_id, :scope])
  end
end
