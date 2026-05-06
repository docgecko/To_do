defmodule ToDo.AvatarStorage do
  @moduledoc """
  Pluggable backend for storing user avatars.

  Two implementations live in this module's namespace:

    * `ToDo.AvatarStorage.Local` — copies the temp file into
      `priv/static/uploads/avatars/` and returns a relative path served by
      `Plug.Static`. Used in dev/test.

    * `ToDo.AvatarStorage.Tigris` — uploads the file to a Tigris (S3-compatible)
      bucket via `ExAws` and returns the public URL. Used in production.

  Backend is selected at runtime via `config :to_do, :avatar_storage,
  ToDo.AvatarStorage.<Backend>`. Callers go through `put/2` and `delete/1`
  here; the backend is opaque to them.

  The `value` returned from `put/2` and accepted by `delete/1` is whatever
  ends up in `users.avatar_path`. For Local that's a relative path; for
  Tigris it's a fully-qualified URL. Both work directly as the `src`
  attribute on an `<img>` tag.
  """

  @callback put(tmp_path :: Path.t(), filename :: String.t()) ::
              {:ok, String.t()} | {:error, term()}

  @callback delete(value :: String.t()) :: :ok

  @doc "Copy/upload `tmp_path` and return the public path or URL."
  def put(tmp_path, filename) do
    backend().put(tmp_path, filename)
  end

  @doc "Remove the avatar identified by `value` (the prior `put/2` result)."
  def delete(value) do
    backend().delete(value)
  end

  defp backend do
    Application.get_env(:to_do, :avatar_storage, ToDo.AvatarStorage.Local)
  end
end
