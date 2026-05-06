defmodule ToDo.AvatarStorage.Tigris do
  @moduledoc """
  Tigris (S3-compatible) backend.

  Reads bucket + public-base config from
  `Application.get_env(:to_do, :avatar_storage_tigris, ...)`:

      config :to_do, :avatar_storage_tigris,
        bucket: "orelle-avatars",
        public_base: "https://orelle-avatars.fly.storage.tigris.dev"

  AWS credentials and the Tigris endpoint are configured via the standard
  `:ex_aws` keys (see runtime.exs in production).

  The bucket is expected to allow public reads on the `avatars/` prefix —
  avatar URLs land directly in `<img src=...>` tags.
  """

  @behaviour ToDo.AvatarStorage

  @impl true
  def put(tmp_path, filename) do
    %{bucket: bucket, public_base: public_base} = conf()
    key = "avatars/" <> filename
    body = File.read!(tmp_path)

    op =
      ExAws.S3.put_object(bucket, key, body,
        content_type: content_type_for(filename),
        cache_control: "public, max-age=31536000, immutable"
      )

    case ExAws.request(op) do
      {:ok, _} -> {:ok, public_base <> "/" <> key}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(value) when is_binary(value) do
    %{bucket: bucket, public_base: public_base} = conf()

    case String.split(value, public_base <> "/", parts: 2) do
      [_, key] ->
        ExAws.S3.delete_object(bucket, key) |> ExAws.request()
        :ok

      _ ->
        # Stored value isn't a Tigris URL we recognise; treat as a no-op so
        # the caller can swap backends without orphaning the user's row.
        :ok
    end
  end

  def delete(_), do: :ok

  defp conf do
    cfg = Application.fetch_env!(:to_do, :avatar_storage_tigris)
    %{bucket: Keyword.fetch!(cfg, :bucket), public_base: Keyword.fetch!(cfg, :public_base)}
  end

  defp content_type_for(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end
end
