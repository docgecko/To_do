defmodule ToDoWeb.PageController do
  use ToDoWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/boards")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
