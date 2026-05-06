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
    # The migration names the partial unique indexes
    # `notifications_user_kind_{task,board}_uniq`, and Postgres's error path
    # surfaces those names. libsql/SQLite, however, only reports the
    # (table.col, ...) tuple in its constraint error and ecto_libsql 0.9
    # synthesizes Ecto's default index name from that tuple — a different
    # string. Declaring both names lets the changeset translate either
    # backend's collision into a clean validation error.
    |> unique_constraint([:user_id, :kind, :task_id], name: :notifications_user_kind_task_uniq)
    |> unique_constraint([:user_id, :kind, :task_id], name: :notifications_user_id_kind_task_id_index)
    |> unique_constraint([:user_id, :kind, :board_id], name: :notifications_user_kind_board_uniq)
    |> unique_constraint([:user_id, :kind, :board_id], name: :notifications_user_id_kind_board_id_index)
  end
end
