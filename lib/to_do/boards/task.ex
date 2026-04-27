defmodule ToDo.Boards.Task do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tasks" do
    field :title, :string
    field :notes, :string
    field :position, :integer, default: 0
    field :done, :boolean, default: false
    field :due_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :repeat, :string
    field :repeat_every, :integer, default: 1
    field :repeat_until, :utc_datetime
    field :waiting, :boolean, default: false

    belongs_to :category, ToDo.Boards.Category
    belongs_to :created_by, ToDo.Accounts.User
    has_many :task_shares, ToDo.Boards.TaskShare

    timestamps(type: :utc_datetime)
  end

  @repeat_units ~w(day week month year)

  def repeat_units, do: @repeat_units

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :notes,
      :position,
      :done,
      :due_at,
      :deleted_at,
      :repeat,
      :repeat_every,
      :repeat_until,
      :waiting,
      :category_id,
      :created_by_id
    ])
    |> normalize_repeat()
    |> validate_required([:title, :category_id])
    |> validate_length(:title, max: 500)
    |> validate_inclusion(:repeat, @repeat_units)
    |> validate_number(:repeat_every, greater_than: 0)
  end

  # Treat blank/"none" as no repeat. When repeat is cleared, also reset
  # the interval and until-date so the row stays tidy.
  defp normalize_repeat(changeset) do
    case get_change(changeset, :repeat) do
      val when val in ["", "none"] ->
        changeset
        |> put_change(:repeat, nil)
        |> put_change(:repeat_every, 1)
        |> put_change(:repeat_until, nil)

      _ ->
        changeset
    end
  end
end
