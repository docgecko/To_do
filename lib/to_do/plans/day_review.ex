defmodule ToDo.Plans.DayReview do
  use Ecto.Schema
  import Ecto.Changeset

  schema "day_reviews" do
    field :date, :date
    field :planned_count, :integer, default: 0
    field :done_count, :integer, default: 0
    field :planned_minutes, :integer, default: 0
    field :done_minutes, :integer, default: 0
    field :reflection, :string

    belongs_to :user, ToDo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(review, attrs) do
    review
    |> cast(attrs, [
      :user_id,
      :date,
      :planned_count,
      :done_count,
      :planned_minutes,
      :done_minutes,
      :reflection
    ])
    |> validate_required([:user_id, :date])
    |> validate_length(:reflection, max: 2000)
    |> unique_constraint([:user_id, :date])
  end
end
