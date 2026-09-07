defmodule ToDo.Inbox.Item do
  use Ecto.Schema
  import Ecto.Changeset

  schema "inbox_items" do
    field :title, :string
    field :notes, :string
    field :deleted_at, :utc_datetime

    belongs_to :user, ToDo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:user_id, :title, :notes])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:user_id, :title])
    |> validate_length(:title, min: 1, max: 500)
    |> validate_length(:notes, max: 5000)
  end
end
