defmodule ToDoWeb.PageController do
  use ToDoWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/boards")
    else
      render(conn, :home)
    end
  end
end
