defmodule ToDo.InviteRequests do
  @moduledoc """
  Public-form invite-request store. Anyone can submit (subject to a honeypot
  check); an admin reviews from the admin LiveView and either approves
  (creates a `ToDo.Accounts.User` and emails them a magic-link login URL) or
  declines (marks the row, no email sent).

  Re-submitting from an already-known email "re-opens" the request: status
  flips back to `"pending"` so the admin sees it again. This avoids a
  rejected requester being silently blocked forever.
  """

  import Ecto.Query, warn: false
  alias ToDo.Repo
  alias ToDo.InviteRequests.InviteRequest

  ## Reads

  def list_pending do
    from(r in InviteRequest,
      where: r.status == "pending",
      order_by: [asc: r.inserted_at]
    )
    |> Repo.all()
  end

  def list_all do
    from(r in InviteRequest,
      order_by: [desc: r.inserted_at]
    )
    |> Repo.all()
    |> Repo.preload(:decided_by)
  end

  def get!(id), do: Repo.get!(InviteRequest, id)

  def pending_count do
    Repo.one(from r in InviteRequest, where: r.status == "pending", select: count(r.id))
  end

  ## Writes

  @doc """
  Insert a new invite request, or re-open an existing decided one.

  Returns `{:ok, request}` on success, `{:error, changeset}` on validation
  failure (including honeypot trips).
  """
  def submit(attrs) do
    cs = InviteRequest.submit_changeset(%InviteRequest{}, attrs)

    if cs.valid? do
      email = Ecto.Changeset.get_change(cs, :email)
      message = Ecto.Changeset.get_change(cs, :message)

      case Repo.get_by(InviteRequest, email: email) do
        nil ->
          %InviteRequest{}
          |> InviteRequest.submit_changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> Ecto.Changeset.change(%{
            status: "pending",
            decided_at: nil,
            decided_by_id: nil,
            message: message || existing.message
          })
          |> Repo.update()
      end
    else
      {:error, %{cs | action: :insert}}
    end
  end

  def mark_approved(%InviteRequest{} = req, %ToDo.Accounts.User{} = admin) do
    apply_decision(req, admin, "approved")
  end

  def mark_declined(%InviteRequest{} = req, %ToDo.Accounts.User{} = admin) do
    apply_decision(req, admin, "declined")
  end

  @doc """
  Grant an account to `email`: registers a User if one doesn't exist yet, then
  emails them a single-use magic-link login URL via the existing magic-link
  flow. `url_fun` is a 1-arity closure that turns a magic-link token into the
  full URL the recipient clicks (e.g. `&url(~p"/users/log-in/\#{&1}")`).

  Used by the admin-approve LV and by the `mix to_do.invite` task.
  """
  def grant(email, url_fun) when is_binary(email) and is_function(url_fun, 1) do
    email = email |> String.trim() |> String.downcase()

    user =
      case ToDo.Accounts.get_user_by_email(email) do
        nil ->
          {:ok, u} = ToDo.Accounts.register_user(%{"email" => email})
          u

        existing ->
          existing
      end

    {:ok, _} = ToDo.Accounts.deliver_login_instructions(user, url_fun)
    {:ok, user}
  end

  @doc """
  Approve an invite request: grants the account, sends the magic-link email,
  and marks the request `approved`.
  """
  def approve_request(%InviteRequest{} = req, %ToDo.Accounts.User{} = admin, url_fun) do
    with {:ok, _user} <- grant(req.email, url_fun),
         {:ok, updated} <- mark_approved(req, admin) do
      {:ok, updated}
    end
  end

  defp apply_decision(req, admin, status) do
    req
    |> InviteRequest.decision_changeset(%{
      status: status,
      decided_at: DateTime.utc_now() |> DateTime.truncate(:second),
      decided_by_id: admin.id
    })
    |> Repo.update()
  end
end
