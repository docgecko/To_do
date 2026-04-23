# Seeds the demo board matching the Excel layout.
# Usage: mix run priv/repo/seeds.exs
#
# Creates a user demo@example.com / DemoPassword123! if missing,
# then builds the Functional / Operational / Waiting board under them.

import Ecto.Query
alias ToDo.Accounts
alias ToDo.Boards
alias ToDo.Repo

email = "demo@example.com"
password = "DemoPassword123!"

user =
  case Accounts.get_user_by_email(email) do
    nil ->
      {:ok, user} = Accounts.register_user(%{email: email})

      confirmed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      user
      |> ToDo.Accounts.User.password_changeset(%{password: password})
      |> Ecto.Changeset.put_change(:confirmed_at, confirmed_at)
      |> Repo.update!()

    user ->
      user
  end

IO.puts("Seeding for user: #{user.email}")

# Wipe any existing board named "Risk Management" for this user to keep seed idempotent.
Repo.delete_all(
  from b in ToDo.Boards.Board,
    where: b.owner_id == ^user.id and b.name == "Risk Management"
)

{:ok, board} =
  Boards.create_board(%{
    "name" => "Risk Management",
    "color" => "#2563eb",
    "owner_id" => user.id
  })

groups = [
  {"Functional", "#f59e0b", [
    {"PMO", ["Ongoing operational support to packages",
             "Capture and define accountability of my role and package risk manager roles",
             "Develop risk governance structure",
             "Develop risk management drumbeat"]},
    {"Commercial", ["RMP Plan with Garry"]},
    {"Risk Management", []}
  ]},
  {"Operational", "#22c55e", [
    {"ATNC", []},
    {"EDEU", []},
    {"GWNC", []},
    {"KILN", []}
  ]},
  {"Waiting", "#3b82f6", [
    {"CGNC", []},
    {"CMN3", []},
    {"EDN2", []},
    {"FSU1", []},
    {"PNT0-PTC1", []},
    {"PSNC", []},
    {"TKRE", []},
    {"WMEL", []}
  ]}
]

groups
|> Enum.with_index()
|> Enum.each(fn {{group_name, color, subs}, g_idx} ->
  {:ok, group} =
    Boards.create_category(%{
      "name" => group_name,
      "color" => color,
      "board_id" => board.id,
      "position" => g_idx
    })

  subs
  |> Enum.with_index()
  |> Enum.each(fn {{sub_name, tasks}, s_idx} ->
    {:ok, sub} =
      Boards.create_category(%{
        "name" => sub_name,
        "board_id" => board.id,
        "parent_id" => group.id,
        "position" => s_idx
      })

    tasks
    |> Enum.with_index()
    |> Enum.each(fn {title, t_idx} ->
      {:ok, _} =
        Boards.create_task(%{
          "title" => title,
          "category_id" => sub.id,
          "created_by_id" => user.id,
          "position" => t_idx
        })
    end)
  end)
end)

IO.puts("Seed complete. Log in as #{email} / #{password}")
