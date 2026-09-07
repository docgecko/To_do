defmodule ToDo.Plans.TaskPlan do
  use Ecto.Schema
  import Ecto.Changeset

  schema "task_plans" do
    field :planned_on, :date
    field :position, :integer, default: 0

    belongs_to :user, ToDo.Accounts.User
    belongs_to :task, ToDo.Boards.Task

    timestamps(type: :utc_datetime)
  end

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [:user_id, :task_id, :planned_on, :position])
    |> validate_required([:user_id, :task_id, :planned_on, :position])
    |> unique_constraint([:user_id, :task_id])
  end
end
