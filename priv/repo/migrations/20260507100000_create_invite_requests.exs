defmodule ToDo.Repo.Migrations.CreateInviteRequests do
  use Ecto.Migration

  def change do
    create table(:invite_requests) do
      add :email, :string, null: false
      # `:text` (not `:string`) so longer free-form messages from prospects
      # (and the occasional spammer's full pitch) aren't rejected by the
      # 255-char varchar cap.
      add :message, :text
      add :status, :string, null: false, default: "pending"
      add :decided_at, :utc_datetime
      add :decided_by_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # Re-requests collapse — one row per email. New submissions for an
    # already-decided email reset status to "pending" so admins see them.
    create unique_index(:invite_requests, [:email])
    create index(:invite_requests, [:status])
  end
end
