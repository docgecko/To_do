defmodule ToDo.InviteRequests.InviteRequest do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending approved declined)

  schema "invite_requests" do
    field :email, :string
    field :message, :string
    field :status, :string, default: "pending"
    field :decided_at, :utc_datetime

    belongs_to :decided_by, ToDo.Accounts.User

    # Honeypot field — never persisted. Bots fill in every visible-or-hidden
    # input; real users (using a browser) leave it untouched. We reject the
    # submission server-side if it's non-empty.
    field :website, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc "User-facing changeset (request submission)."
  def submit_changeset(request, attrs) do
    request
    |> cast(attrs, [:email, :message, :website])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/, message: "must include the @ sign")
    |> validate_length(:email, max: 160)
    |> validate_length(:message, max: 1000)
    |> validate_honeypot()
    |> unique_constraint(:email)
  end

  @doc "Admin-facing changeset (approve/decline)."
  def decision_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :decided_at, :decided_by_id])
    |> validate_required([:status, :decided_at])
    |> validate_inclusion(:status, ~w(approved declined))
  end

  defp normalize_email(nil), do: nil
  defp normalize_email(s) when is_binary(s), do: s |> String.trim() |> String.downcase()

  defp validate_honeypot(changeset) do
    case get_field(changeset, :website) do
      val when is_binary(val) and val != "" -> add_error(changeset, :website, "spam")
      _ -> changeset
    end
  end
end
