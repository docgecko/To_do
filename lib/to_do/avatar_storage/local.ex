defmodule ToDo.AvatarStorage.Local do
  @moduledoc """
  Local-disk backend: copies the temp file into `priv/static/uploads/avatars/`
  and returns the relative URL `Plug.Static` serves it from.
  """

  @behaviour ToDo.AvatarStorage

  @impl true
  def put(tmp_path, filename) do
    dir = Path.join([:code.priv_dir(:to_do), "static", "uploads", "avatars"])
    File.mkdir_p!(dir)
    dest = Path.join(dir, filename)

    case File.cp(tmp_path, dest) do
      :ok -> {:ok, "/uploads/avatars/#{filename}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete("/uploads/" <> rest) do
    path = Path.join([:code.priv_dir(:to_do), "static", "uploads", rest])
    File.rm(path)
    :ok
  end

  def delete(_), do: :ok
end
