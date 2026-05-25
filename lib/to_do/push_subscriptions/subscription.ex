defmodule ToDo.PushSubscriptions.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh_key, :string
    field :auth_key, :string
    field :user_agent, :string

    belongs_to :user, ToDo.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:user_id, :endpoint, :p256dh_key, :auth_key, :user_agent])
    |> validate_required([:user_id, :endpoint, :p256dh_key, :auth_key])
    |> validate_length(:endpoint, max: 2_000)
    |> unique_constraint(:endpoint)
  end
end
