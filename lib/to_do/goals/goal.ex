defmodule ToDo.Goals.Goal do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(active paused done abandoned)

  schema "goals" do
    field :name, :string
    field :description, :string
    field :color, :string
    field :target_date, :date
    field :status, :string, default: "active"
    field :position, :integer, default: 0
    field :completed_at, :utc_datetime

    belongs_to :user, ToDo.Accounts.User

    many_to_many :tasks, ToDo.Boards.Task,
      join_through: "task_goals",
      on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(goal, attrs) do
    goal
    |> cast(attrs, [:user_id, :name, :description, :color, :target_date, :status, :position])
    |> validate_required([:user_id, :name])
    |> validate_length(:name, max: 200)
    |> validate_length(:description, max: 5000)
    |> validate_inclusion(:status, @statuses)
    |> maybe_stamp_completed_at()
  end

  # Reflects `status` into `completed_at`. Moving into `done` stamps
  # the completion time; moving back to any non-done status clears it.
  # No-op when the status field wasn't changed on this save.
  defp maybe_stamp_completed_at(changeset) do
    case get_change(changeset, :status) do
      "done" ->
        put_change(changeset, :completed_at, DateTime.utc_now() |> DateTime.truncate(:second))

      status when status in ["active", "paused", "abandoned"] ->
        put_change(changeset, :completed_at, nil)

      _ ->
        changeset
    end
  end
end
