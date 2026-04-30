defmodule ToDo.Notifications.Notification do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(task_due_soon task_overdue task_shared board_shared)

  schema "notifications" do
    field :kind, :string
    field :body, :string
    field :read_at, :utc_datetime
    field :email_sent_at, :utc_datetime

    belongs_to :user, ToDo.Accounts.User
    belongs_to :task, ToDo.Boards.Task
    belongs_to :board, ToDo.Boards.Board

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :kind, :task_id, :board_id, :body, :read_at, :email_sent_at])
    |> validate_required([:user_id, :kind, :body])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:body, max: 500)
    |> unique_constraint([:user_id, :kind, :task_id], name: :notifications_user_kind_task_uniq)
    |> unique_constraint([:user_id, :kind, :board_id], name: :notifications_user_kind_board_uniq)
  end
end
